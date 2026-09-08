import CoreGraphics
import CoreImage
import Foundation
import GRDB
import ImageIO
import JingXuCore
import UniformTypeIdentifiers

enum QualityV2Checks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    struct DeniedAnalyzer: QualityAnalyzer {
        func analyze(assetID: String, at url: URL) async throws -> AnalysisResult { throw CocoaError(.fileReadNoPermission) }
        func featureDistance(_ lhs: Data, _ rhs: Data) throws -> Float { 1 }
    }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(description: message) }
    }

    static func image(width: Int = 1024, height: Int = 768, pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) throws -> CGImage {
        var bytes = [UInt8](); bytes.reserveCapacity(width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let (r,g,b,a) = pixel(x,y); bytes += [r,g,b,a]
        } }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

    static func write(_ image: CGImage, to url: URL, type: UTType = .jpeg, orientation: Int = 1) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    static func synthetic() async throws {
        let analyzer = DefaultQualityAnalyzer()
        let checker = try image { x,y in let v: UInt8 = ((x/8+y/8)%2 == 0 ? 40 : 215); return (v,v,v,255) }
        let clear = try analyzer.assess(image: checker, assetID: "clear")
        try check(clear.diagnostic?.scales.count == 2 && clear.issues.isEmpty, "默认报警必须关闭")
        try check(clear.diagnostic!.scales.allSatisfy { $0.validBlocks > 6 && $0.hasReliableSharpRegion }, "清晰纹理区域没有被识别")
        let ci = CIContext(options: [.cacheIntermediates: false])
        var scores = [clear.sharpnessScore]
        for radius in [1.0, 3.0, 8.0] {
            let input = CIImage(cgImage: checker)
            let blurred = input.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: input.extent)
            let result = try analyzer.assess(image: ci.createCGImage(blurred, from: input.extent)!, assetID: "blur")
            scores.append(result.sharpnessScore)
            try check(result.issues.isEmpty, "合成模糊不能绕过校准门禁")
        }
        try check(scores[1] < scores[0] && scores[2] < scores[1] && scores[3] <= scores[2], "逐级模糊指标趋势错误：\(scores)")
        for gray: UInt8 in [0, 128, 255] {
            let flat = try analyzer.assess(image: image { _,_ in (gray,gray,gray,255) }, assetID: "flat")
            try check(flat.status == .insufficientEvidence && flat.issues.isEmpty, "纯色不能等同模糊或正常")
            let exposure = flat.diagnostic!.exposure
            try check((gray != 0 || exposure.nearBlack == 1) && (gray != 255 || exposure.nearWhite == 1), "明暗统计错误")
        }
        let sky = try analyzer.assess(image: image { _,y in let v = UInt8(120+y/12); return (v,v,v,255) }, assetID: "sky")
        try check(sky.status == .insufficientEvidence, "渐变天空不能被可靠判为模糊")
        let dof = try analyzer.assess(image: image { x,y in let v: UInt8 = x < 256 ? ((x/8+y/8)%2 == 0 ? 40 : 215) : 128; return (v,v,v,255) }, assetID: "dof")
        try check(dof.diagnostic!.scales.contains { $0.hasReliableSharpRegion } && !dof.diagnostic!.candidateBlur, "虚化背景不应拉低清晰局部")
        var rng: UInt64 = 7
        let noise = try image { _,_ in rng = rng &* 6364136223846793005 &+ 1; let v = UInt8(truncatingIfNeeded: rng >> 32); return (v,v,v,255) }
        let noisy = try analyzer.assess(image: noise, assetID: "noise")
        try check(noisy.status == .insufficientEvidence && noisy.diagnostic!.scales.contains { $0.noisyBlocks > 0 }, "噪声不应被当作可靠清晰度")
        let alpha = try image { x,y in
            if x < 512 { return (255,255,255,0) }
            let v: UInt8 = ((x/8+y/8)%2 == 0 ? 40 : 215); return (v,v,v,128)
        }
        let transparent = try analyzer.assess(image: alpha, assetID: "alpha")
        let histogram = try HistogramProvider.calculate(alpha)
        try check(transparent.diagnostic!.exposure.validPixels == histogram.luminance.reduce(0,+), "透明像素处理与直方图不一致")
        try check(transparent.diagnostic!.scales.allSatisfy { $0.transparentBlocks > 0 }, "透明边界不应参与梯度")
        let small = try analyzer.assess(image: image(width: 80, height: 40) { _,_ in (128,128,128,255) }, assetID: "small")
        try check(small.status == .insufficientEvidence && small.diagnostic!.scales.allSatisfy { $0.width == 80 && $0.height == 40 }, "小图被放大")
        var parameters = QualityParameters()
        try check(!parameters.warningsEnabled, "无人工证据启用了报警")
        parameters.validation = QualityValidationEvidence(parameterDigest: parameters.digest, usableCount: 20, falsePositives: 1,
            blurryCount: 10, truePositives: 6, humanLabelsComplete: true, independentHoldout: true)
        try check(parameters.warningsEnabled, "验收门禁边界不正确")
        var weak = clear.diagnostic!
        for index in weak.scales.indices {
            weak.scales[index].sobelEnergy = 0.0001; weak.scales[index].laplacianVariance = 0.0001
            weak.scales[index].hasReliableSharpRegion = false
        }
        try check(weak.decision(using: parameters).0 == .suspectedBlur, "双尺度充分证据且已验证时应允许建议")
        try check(weak.decision(using: QualityParameters()).0 == .pendingCalibration, "未验证指标不能产生质量正常或报警结论")
        var contradictory = weak; contradictory.scales[1].sobelEnergy = 1
        try check(contradictory.decision(using: parameters).0 == .insufficientEvidence, "矛盾指标没有保留不确定")
        let observations = Array(repeating: CalibrationObservation(label: .usable, diagnostic: clear.diagnostic), count: 40) +
            Array(repeating: CalibrationObservation(label: .blurry, diagnostic: weak), count: 20) +
            [CalibrationObservation(label: .uncertain, diagnostic: nil)]
        let counts = QualityCalibration.measure(observations, parameters: parameters)
        try check(counts.falsePositives == 0 && counts.truePositives == 20 && counts.unableToJudge == 1 && counts.decodeFailures == 1, "校准计数或无法判断分母错误")
        let reportData = try JSONEncoder().encode(counts)
        let decodedCounts = try JSONDecoder().decode(CalibrationCounts.self, from: reportData)
        let reportObject = try JSONSerialization.jsonObject(with: reportData) as! [String: Any]
        try check(decodedCounts.total == 61 && reportObject["recall"] as? Double == 1, "校准报告缺少实际比率或无法重读")
        let selected = QualityCalibration.selectParameters(calibration: observations)
        try check(selected != nil && selected!.validation == nil && !selected!.warningsEnabled, "校准集选参错误地启用报警")
        try check(QualityCalibration.selectParameters(calibration: Array(observations.prefix(10))) == nil, "小样本被当作已校准")
        parameters.weakSobel += 0.001
        try check(!parameters.warningsEnabled, "修改已冻结参数后仍沿用旧验证")
        let task = Task { try Task.checkCancellation(); return try analyzer.assess(image: checker, assetID: "cancel") }
        task.cancel()
        do { _ = try await task.value; throw Failure(description: "计算未响应取消") } catch is CancellationError {}
    }

    static func persistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("JingXu-v2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = SourceRoot(name: "test", bookmarkData: nil, pathHint: root.path)
        let dbURL = root.appendingPathComponent("catalog.sqlite")
        let store = try CatalogStore(databaseURL: dbURL)
        try await store.upsertSource(source)
        let photo = try image(width: 80, height: 40) { x,_ in x < 40 ? (255,0,0,255) : (0,0,255,255) }
        var assets: [MediaAsset] = []
        for name in ["a.jpg", "b.heic", "c.jpg", "bad.arw", "offline.jpg"] {
            let url = root.appendingPathComponent(name)
            if name == "bad.arw" { try Data("invalid RAW".utf8).write(to: url) }
            else { try write(photo, to: url, type: name.hasSuffix("heic") ? .heic : .jpeg, orientation: 6) }
            let fingerprint = try AnalysisFingerprint(url: url)
            let asset = MediaAsset(sourceID: source.id, relativePath: name, fileIdentifier: fingerprint.identifier, fileName: name,
                uniformType: nil, kind: .photo, fileSize: fingerprint.size, modifiedAt: fingerprint.modifiedAt)
            assets.append(try await store.upsertAsset(asset))
        }
        let first = assets[0], firstURL = root.appendingPathComponent(first.relativePath)
        let originalHEIC = try FileHasher.sha256(of: root.appendingPathComponent("b.heic"))
        let old = AnalysisResult(assetID: first.id, sharpnessScore: 0.01, shadowClipping: 0.5, highlightClipping: 0.2, issues: [.blurry,.similarBurst,.clippedHighlights])
        try await store.saveAnalysis(old)
        try check(try await store.analysisCandidates(legacyOnly: true) == [first.id], "全部旧结果范围包含了尚未分析资源")
        let pending = try await store.assetIDsNeedingAnalysis(sourceID: source.id, algorithmVersion: 2)
        try check(!pending.contains(first.id) && pending.count == 4, "普通扫描偷偷升级了旧结果")
        try check(try await store.assets(AssetQuery(collection: .review)).isEmpty, "旧版进入黄色建议")
        let analyzer = DefaultQualityAnalyzer(featureExtractor: { _ in throw CocoaError(.featureUnsupported) })
        let computed = try await analyzer.analyze(assetID: first.id, at: firstURL)
        try check(computed.diagnostic!.scales[0].width == 40 && computed.diagnostic!.scales[0].height == 80, "质量预览未正确应用 EXIF 方向")
        try check(computed.diagnostic?.featurePrintFailure != nil && computed.diagnostic?.exposure.validPixels == 3200, "Vision 失败丢失质量统计")
        var warning = computed; warning.assessmentStatus = .suspectedBlur; warning.issues = [.blurry]
        try await store.saveAnalysis(warning) // Explicit fixture; production defaults cannot produce this until calibrated.
        try check(try await store.assets(AssetQuery(collection: .review)).count == 1, "新版待审核筛选失败")
        let album = Album(name: "keep")
        try await store.saveAlbum(album); try await store.add(assetID: first.id, toAlbum: album.id)
        try await store.saveAnnotation(UserAnnotation(assetID: first.id, rating: 5, flag: .picked, keywords: ["keep"]))
        // A worker captured `computed` before this review; its later commit must not revert the review.
        _ = try await store.saveQualityReview(assetID: first.id, state: .ignored)
        try await store.saveComputedAnalysis(computed, expectedAsset: first, fileURL: firstURL)
        try check(try await store.analysis(for: first.id)?.suggestionState == .ignored, "重算覆盖了最新人工审核")
        try check(try await store.assets(AssetQuery(collection: .review)).isEmpty, "忽略后警告未消失")
        async let reviewSafe: Void = store.saveComputedAnalysis(computed, expectedAsset: first, fileURL: firstURL)
        async let annotationSafe: Void = store.saveAnnotation(UserAnnotation(assetID: first.id, rating: 4, flag: .picked, keywords: ["concurrent"]))
        _ = try await (reviewSafe, annotationSafe)
        let annotation = try await store.annotation(for: first.id)
        try check(annotation.rating == 4 && annotation.flag == .picked && annotation.keywords == ["concurrent"], "计算修改了并发标注")
        try check(try await store.assets(AssetQuery(albumID: album.id)).count == 1, "重算改变相册成员")
        try await store.saveSimilarGroup("burst", assetIDs: [first.id])
        try check(try await store.assets(AssetQuery(collection: .review)).isEmpty, "连拍进入质量问题计数")
        try Data("replacement".utf8).write(to: firstURL, options: .atomic)
        do { try await store.saveComputedAnalysis(computed, expectedAsset: first, fileURL: firstURL); throw Failure(description: "替换文件仍提交旧结果") }
        catch is QualityAnalysisError {}
        let coordinator = AnalysisCoordinator(repository: store, analyzer: analyzer)
        try check(try await coordinator.analyzeOne(assetID: first.id) == false, "被替换文件没有失败隔离")
        try check(try await store.analysis(for: first.id)?.status == .failed, "失败写成正常结果")
        try FileManager.default.removeItem(at: root.appendingPathComponent("offline.jpg"))
        let runner = QualityReanalysisCoordinator(store: store, analyzer: coordinator)
        let plan = QualityReanalysisPlan(title: "test", assetIDs: assets.map(\.id) + [first.id])
        try check(plan.assetIDs.count == 5, "重复候选未去重")
        let blocker = root.appendingPathComponent("not-directory")
        try Data().write(to: blocker)
        do { _ = try await runner.prepare(plan, backupDirectory: blocker); throw Failure(description: "备份失败仍创建任务") } catch is CocoaError {}
        try check(try await store.qualityJobs().isEmpty, "备份失败后写入队列")
        let jobID = try await runner.prepare(plan, backupDirectory: root.appendingPathComponent("backups"))
        let pause = Task {
            try await runner.run(jobID: jobID) { progress in
                if progress.completed == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        try await pause.value
        let paused = try await store.qualityJobs()[0]
        try check(paused.job.state == .paused && paused.completed == 1, "暂停没有持久化断点")
        let reopened = try CatalogStore(databaseURL: dbURL)
        try await reopened.setQualityJobState(jobID, state: .running)
        try await reopened.recoverQualityJobs()
        try check(try await reopened.qualityJobs()[0].job.state == .paused, "重启未暂停上次运行任务")
        try await QualityReanalysisCoordinator(store: reopened, analyzer: coordinator).run(jobID: jobID)
        let done = try await reopened.qualityJobs()[0]
        try check(done.job.state == .completed && done.completed == 5 && done.failed == 3, "部分失败导致批次中断或进度错误")
        try check(try FileHasher.sha256(of: root.appendingPathComponent("b.heic")) == originalHEIC, "重算修改了原照片内容")
        do { try await runner.run(jobID: jobID); throw Failure(description: "已完成任务被重新启动") } catch is CatalogUpgradeError {}
        try check(try await store.qualityJobs().first { $0.id == jobID }?.job.state == .completed, "非法继续破坏已完成状态")
        try check(try await reopened.analysis(for: first.id)?.suggestionState == .ignored, "失败或重启改变审核")
        let denied = AnalysisCoordinator(repository: store, analyzer: DeniedAnalyzer())
        try check(try await denied.analyzeOne(assetID: assets[1].id) == false, "权限失败没有隔离")
        try check(try await store.analysis(for: assets[1].id)?.status == .failed, "权限失败写成正常结果")
        let cancelID = try await runner.prepare(QualityReanalysisPlan(title: "cancel", assetIDs: assets.map(\.id)), backupDirectory: root.appendingPathComponent("backups"))
        try await runner.run(jobID: cancelID) { progress in if progress.completed == 1 { await runner.requestCancel() } }
        let cancelled = try await store.qualityJobs().first { $0.id == cancelID }!
        try check(cancelled.job.state == .cancelled && cancelled.completed < cancelled.total, "取消没有停止后续项目")
        // The full candidate query shares all browse predicates but has no 2,000-item display limit.
        var many: [MediaAsset] = []
        for i in 0..<2005 {
            many.append(MediaAsset(sourceID: source.id, relativePath: "scope-\(i).jpg", fileIdentifier: nil, fileName: "scope-\(i).jpg", uniformType: nil, kind: .photo, fileSize: 1, modifiedAt: Date()))
        }
        _ = try await store.upsertAssets(many)
        try check(try await store.analysisCandidates(AssetQuery(sourceID: source.id, searchText: "scope-", limit: 1)).count == 2005, "完整重算范围仍被网格截断")
        try check(try await store.analysisCandidates(AssetQuery(albumID: album.id, flag: .picked)).count == 1, "相册和旗标筛选隔离失败")
    }
}
