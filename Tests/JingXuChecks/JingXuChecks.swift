import CoreGraphics
import Foundation
import ImageIO
import JingXuCore
import UniformTypeIdentifiers
import GRDB

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

private struct StubMetadataExtractor: MetadataExtractor {
    func extract(from url: URL, kind: MediaKind) async -> ExtractedMetadata {
        ExtractedMetadata(
            uniformType: kind == .photo ? "public.jpeg" : "com.apple.quicktime-movie",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            width: 6_000,
            height: 4_000,
            cameraMake: "Test",
            cameraModel: "Test Camera",
            lens: "35mm"
        )
    }
}

private struct TestTrash: TrashService {
    let directory: URL
    func trash(_ url: URL) throws -> URL? {
        if url.lastPathComponent == "fail.jpg" { throw CocoaError(.fileWriteNoPermission) }
        let target = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

@main
private enum JingXuChecks {
    static func main() async throws {
        if let index = CommandLine.arguments.firstIndex(of: "--preview-file"), CommandLine.arguments.count > index + 2 {
            try await PreviewCanvasChecks.verifyFile(URL(fileURLWithPath: CommandLine.arguments[index+1]),
                output: URL(fileURLWithPath: CommandLine.arguments[index+2]))
            return
        }
        if CommandLine.arguments.contains("--ui-fixtures") {
            let root = try temporaryWorkspace()
            try writeSolidJPEG(to: root.appendingPathComponent("light.jpg"), gray: 220)
            try writeSolidJPEG(to: root.appendingPathComponent("dark.jpg"), gray: 35)
            print(root.path)
            return
        }
        let checks: [(String, () async throws -> Void)] = [
            ("目录命名与清理", checkImportNaming),
            ("文件路径与 SHA-256", checkFileIdentityAndHash),
            ("目录持久化、筛选与标注", checkCatalog),
            ("稳定资源身份与相册", checkStableIdentityAndAlbum),
            ("XMP 编码", checkXMP),
            ("图像元数据与质量建议", checkMetadataAndQuality),
            ("质量 v2 双尺度、噪声、透明与校准门禁", QualityV2Checks.synthetic),
            ("质量 v2 兼容、审核隔离、指纹与断点队列", QualityV2Checks.persistence),
            ("增量扫描与 RAW/JPEG 配对", checkIncrementalScan),
            ("校验导入、重复跳过与不覆盖", checkSafeImport),
            ("删除范围、文件复核与中断恢复", checkDeletion),
            ("原图解码、方向、错误和取消", checkPreview),
            ("单图切换顺序、边界及筛选隐藏", checkPreviewNavigation),
            ("大图可见区域绘制、100% 比例、缩放及清帧", PreviewCanvasChecks.run),
            ("直方图统计、透明像素与取消", checkHistogram),
            ("来源注册、合并、备份与移除", checkSourceManagement),
            ("图库升级备份、锁、失败保护及恢复", checkCatalogUpgrade),
            ("10 万条目录查询性能", checkLargeCatalog)
        ]

        print("镜序自动化校验（\(checks.count) 项）")
        for (name, check) in checks {
            do {
                try await check()
                print("✓ \(name)")
            } catch {
                print("✗ \(name)：\(error)")
                throw error
            }
        }
        print("全部校验通过")
    }

    private static func checkPreviewNavigation() async throws {
        var navigation = PreviewNavigation(photoIDs: ["a", "b", "c", "d", "b"])
        try require(navigation.filmstripIDs(currentID: "b") == ["a", "b", "c", "d"], "胶片栏保持照片顺序且去重")
        try require(navigation.neighbor(of: "a", direction: -1) == nil, "首张不循环")
        try require(navigation.neighbor(of: "d", direction: 1) == nil, "末张不循环")
        try require(navigation.neighbor(of: "b", direction: 1) == "c", "按网格顺序向后")
        try require(navigation.neighbor(of: "b", direction: -1) == "a", "按网格顺序向前")
        navigation.refresh(photoIDs: ["d", "a", "new"])
        try require(navigation.filmstripIDs(currentID: "b") == ["a", "b", "d"], "胶片栏保留隐藏当前锚点，不纳入范围外照片")
        try require(navigation.filmstripIDs(currentID: "d") == ["a", "d"], "离开隐藏照片后从胶片栏移除")
        try require(navigation.neighbor(of: "b", direction: 1) == "d", "隐藏当前和相邻照片后保留锚点")
        try require(navigation.neighbor(of: "b", direction: -1) == "a", "隐藏当前照片仍可向前")
        try require(navigation.neighbor(of: "d", direction: 1) == nil, "刷新不纳入快照外照片")
        navigation.refresh(photoIDs: ["a", "b", "c", "d"])
        try require(navigation.neighbor(of: "a", direction: 1) == "b", "取消旗标恢复匹配候选")
        var current = "a"
        for _ in 0..<100 { current = navigation.neighbor(of: current, direction: 1) ?? current }
        try require(current == "d", "连续切换不越界")
        let single = PreviewNavigation(photoIDs: ["a"])
        try require(single.filmstripIDs(currentID: "a") == ["a"], "单张胶片栏")
        try require(PreviewNavigation(photoIDs: []).filmstripIDs(currentID: "missing").isEmpty, "空胶片栏不注入未知照片")
        let largeIDs = (0..<2_000).map { "photo-\($0)" }
        let largeStrip = PreviewNavigation(photoIDs: largeIDs)
        try require(largeStrip.filmstripIDs(currentID: "photo-1999") == largeIDs, "胶片栏完整保留 2000 项范围")
        try require(single.neighbor(of: "a", direction: 1) == nil && single.neighbor(of: "a", direction: -1) == nil, "单张禁用双向切换")
        try require(PreviewNavigation(photoIDs: []).neighbor(of: "a", direction: 1) == nil, "空列表安全")
        try require(navigation.neighbor(of: "missing", direction: 1) == nil && navigation.neighbor(of: "a", direction: 0) == nil, "无效目标和方向安全")
    }

    private static func checkImportNaming() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = Date(timeIntervalSince1970: 1_721_433_600)
        try require(
            ImportNaming.destinationFolder(date: date, batchName: " 杭州/旅行 ", calendar: calendar)
                == "2024/2024-07-20-杭州-旅行",
            "导入目录格式不正确"
        )
        try require(ImportNaming.sanitizePathComponent("a:b?c") == "a-b-c", "目录名未正确清理")
    }

    private static func checkFileIdentityAndHash() async throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("DCIM/100APPLE", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("IMG_0001.JPG")
        try Data("jingxu".utf8).write(to: file)
        try require(
            FileIdentity.relativePath(of: file, under: root) == "DCIM/100APPLE/IMG_0001.JPG",
            "相对路径不正确"
        )
        let fileHash = try FileHasher.sha256(of: file)
        try require(fileHash == "a235a8e71937b565e17cb4baf2046a370f260870621a2a27a556ef6b3c4dc1aa", "SHA-256 不稳定")
    }

    private static func checkCatalog() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try CatalogStore(databaseURL: workspace.appendingPathComponent("catalog.sqlite"))
        let source = SourceRoot(name: "相机图库", bookmarkData: nil, pathHint: "/tmp/library")
        try await store.upsertSource(source)
        let raw = MediaAsset(
            sourceID: source.id,
            relativePath: "IMG_0001.ARW",
            fileIdentifier: "raw-1",
            fileName: "IMG_0001.ARW",
            uniformType: "com.sony.arw-raw-image",
            kind: .photo,
            fileSize: 2_048,
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            cameraModel: "Alpha 7",
            lens: "35mm F1.4",
            rawPairKey: "img_0001"
        )
        let stored = try await store.upsertAsset(raw)
        var annotation = try await store.annotation(for: stored.id)
        annotation.rating = 4
        annotation.flag = .picked
        annotation.keywords = ["旅行", " 夜景 ", "旅行", ""]
        try await store.saveAnnotation(annotation)

        let all = try await store.assets(AssetQuery())
        let rawResults = try await store.assets(AssetQuery(collection: .raw))
        let filtered = try await store.assets(AssetQuery(searchText: "Alpha", minimumRating: 4, flag: .picked))
        try require(all.count == 1, "目录未返回已保存资源")
        try require(all.first?.keywords == ["夜景", "旅行"], "关键词未规范化")
        try require(rawResults.first?.fileName == "IMG_0001.ARW", "RAW 筛选失败")
        try require(filtered.count == 1, "组合筛选失败")
    }

    private static func checkStableIdentityAndAlbum() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try CatalogStore(databaseURL: workspace.appendingPathComponent("catalog.sqlite"))
        let source = SourceRoot(name: "图库", bookmarkData: nil, pathHint: "/tmp/library")
        try await store.upsertSource(source)
        var asset = MediaAsset(
            sourceID: source.id,
            relativePath: "A.JPG",
            fileIdentifier: "one",
            fileName: "A.JPG",
            uniformType: "public.jpeg",
            kind: .photo,
            fileSize: 100,
            modifiedAt: Date()
        )
        let first = try await store.upsertAsset(asset)
        asset.id = UUID().uuidString
        asset.fileSize = 200
        let second = try await store.upsertAsset(asset)
        try require(first.id == second.id && second.fileSize == 200, "增量更新改变了资源身份")

        let album = Album(name: "精选")
        try await store.saveAlbum(album)
        try await store.add(assetID: first.id, toAlbum: album.id)
        try await store.saveAnalysis(AnalysisResult(
            assetID: first.id,
            sharpnessScore: 0.01,
            shadowClipping: 0,
            highlightClipping: 0,
            issues: [.blurry]
        ))
        let albumAssets = try await store.assets(AssetQuery(albumID: album.id))
        let reviewAssets = try await store.assets(AssetQuery(collection: .review))
        try require(albumAssets.count == 1, "相册成员关系失败")
        try require(reviewAssets.isEmpty && albumAssets.first?.qualityStatus == .legacy, "旧版建议不应进入新版待审核")
    }

    private static func checkXMP() async throws {
        let asset = MediaAsset(
            sourceID: "source",
            relativePath: "A.ARW",
            fileIdentifier: nil,
            fileName: "A.ARW",
            uniformType: nil,
            kind: .photo,
            fileSize: 1,
            modifiedAt: Date()
        )
        let annotation = UserAnnotation(assetID: asset.id, rating: 5, flag: .picked, keywords: ["人与风景", "A<B"])
        let document = DefaultXMPExporter.document(asset: asset, annotation: annotation)
        try require(document.contains("xmp:Rating=\"5\""), "XMP 未写评分")
        try require(document.contains("xmp:Label=\"Pick\""), "XMP 未写旗标")
        try require(document.contains("A&lt;B"), "XMP 未转义关键词")
    }

    private static func checkMetadataAndQuality() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let imageURL = workspace.appendingPathComponent("white.jpg")
        try writeSolidJPEG(to: imageURL, gray: 255)
        let metadata = await DefaultMetadataExtractor().extract(from: imageURL, kind: .photo)
        try require(metadata.width == 64 && metadata.height == 64, "图像尺寸元数据不正确")
        try require(metadata.errorMessage == nil, "合法 JPEG 被标为错误")
        let result = try await DefaultQualityAnalyzer().analyze(assetID: "asset", at: imageURL)
        try require(result.issues.isEmpty && result.highlightClipping > 0.99, "曝光仅为客观统计，不应报警")
        try require(result.status == .insufficientEvidence, "小图无细节必须保留无法判断")
        try require(result.featurePrint != nil, "未生成相似度特征")
    }

    private static func checkIncrementalScan() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let library = workspace.appendingPathComponent("library", isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("jpeg".utf8).write(to: library.appendingPathComponent("IMG_0001.JPG"))
        try Data("raw".utf8).write(to: library.appendingPathComponent("IMG_0001.ARW"))
        let store = try CatalogStore(databaseURL: workspace.appendingPathComponent("catalog.sqlite"))
        let source = SourceRoot(name: "library", bookmarkData: nil, pathHint: library.path)
        try await store.upsertSource(source)
        let scanner = DefaultSourceScanner(repository: store, metadataExtractor: StubMetadataExtractor())
        let first = try await scanner.scan(source: source, progress: nil)
        let second = try await scanner.scan(source: source, progress: nil)
        let assets = try await store.assets(AssetQuery())
        var pairKeys: Set<String> = []
        for id in first.assetIDs {
            if let pairKey = try await store.asset(id: id)?.rawPairKey { pairKeys.insert(pairKey) }
        }
        try require(first.assetIDs.count == 2 && second.assetIDs.isEmpty, "扫描未正确增量跳过")
        try require(assets.count == 2 && pairKeys == ["img_0001"], "RAW/JPEG 未正确配对")
    }

    private static func checkSafeImport() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let card = workspace.appendingPathComponent("card/DCIM", isDirectory: true)
        let destinationRoot = workspace.appendingPathComponent("photos", isDirectory: true)
        try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let cardFile = card.appendingPathComponent("IMG_1000.JPG")
        try Data("original-camera-bytes".utf8).write(to: cardFile)
        let store = try CatalogStore(databaseURL: workspace.appendingPathComponent("catalog.sqlite"))
        let scanner = DefaultSourceScanner(repository: store, metadataExtractor: StubMetadataExtractor())
        let importer = ImportCoordinator(repository: store, scanner: scanner)

        let first = try await importer.importMedia(from: card.deletingLastPathComponent(), to: destinationRoot, batchName: "测试", progress: nil)
        let copied = first.destination.appendingPathComponent("IMG_1000.JPG")
        try require(first.session.completedFiles == 1, "首次导入未完成")
        let sourceHash = try FileHasher.sha256(of: cardFile)
        let copiedHash = try FileHasher.sha256(of: copied)
        try require(sourceHash == copiedHash, "目标校验值与来源不同")

        let second = try await importer.importMedia(from: card.deletingLastPathComponent(), to: destinationRoot, batchName: "测试", progress: nil)
        try require(second.session.skippedFiles == 1, "相同文件未跳过")
        let sourceCount = try await store.sources().count
        try require(sourceCount == 1, "重复导入创建了重复来源")

        try Data("changed-camera-bytes".utf8).write(to: cardFile, options: .atomic)
        let third = try await importer.importMedia(from: card.deletingLastPathComponent(), to: destinationRoot, batchName: "测试", progress: nil)
        let collisionCopy = third.destination.appendingPathComponent("IMG_1000-2.JPG")
        try require(FileManager.default.fileExists(atPath: collisionCopy.path), "同名不同内容未生成安全后缀")
        let copiedContents = String(decoding: try Data(contentsOf: copied), as: UTF8.self)
        let sourceContents = String(decoding: try Data(contentsOf: cardFile), as: UTF8.self)
        try require(copiedContents == "original-camera-bytes", "旧目标被覆盖")
        try require(sourceContents == "changed-camera-bytes", "来源文件被修改")
    }

    private static func checkLargeCatalog() async throws {
        let workspace = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: workspace) }
        let store = try CatalogStore(databaseURL: workspace.appendingPathComponent("catalog.sqlite"))
        let source = SourceRoot(name: "性能图库", bookmarkData: nil, pathHint: "/tmp/performance")
        try await store.upsertSource(source)
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        var assets: [MediaAsset] = []
        assets.reserveCapacity(100_000)
        for index in 0..<100_000 {
            let timestamp = baseDate.addingTimeInterval(Double(index))
            let asset = MediaAsset(
                id: "performance-\(index)",
                sourceID: source.id,
                relativePath: String(format: "%04d/IMG_%06d.JPG", index / 1_000, index),
                fileIdentifier: "file-\(index)",
                fileName: String(format: "IMG_%06d.JPG", index),
                uniformType: "public.jpeg",
                kind: .photo,
                fileSize: Int64(1_000_000 + index),
                modifiedAt: timestamp,
                capturedAt: timestamp,
                width: 6_000,
                height: 4_000,
                cameraModel: index.isMultiple(of: 2) ? "Camera A" : "Camera B",
                lens: "35mm"
            )
            assets.append(asset)
        }
        _ = try await store.upsertAssets(assets)

        let start = ContinuousClock.now
        let firstPage = try await store.assets(AssetQuery(searchText: "Camera A", limit: 2_000))
        let elapsed = start.duration(to: .now)
        try require(firstPage.count == 2_000, "10 万条目录未返回完整首批结果")
        try require(elapsed < .milliseconds(500), "10 万条目录筛选超过 500ms：\(elapsed)")
    }

    private static func checkDeletion() async throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("db.sqlite"))
        let source = SourceRoot(name: "测试来源", bookmarkData: nil, pathHint: root.path)
        try await store.upsertSource(source)
        var many: [MediaAsset] = []
        for i in 0..<2_005 {
            many.append(MediaAsset(sourceID: source.id, relativePath: "many\(i).jpg", fileIdentifier: nil, fileName: "many\(i).jpg", uniformType: nil, kind: .photo, fileSize: 1, modifiedAt: Date()))
        }
        let saved = try await store.upsertAssets(many)
        for asset in saved { try await store.saveAnnotation(UserAnnotation(assetID: asset.id, flag: .rejected)) }
        let journal = root.appendingPathComponent("journal.json")
        let trashDir = root.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trashDir, withIntermediateDirectories: true)
        let coordinator = DeletionCoordinator(store: store, journalURL: journal, trash: TestTrash(directory: trashDir))
        let all = try await coordinator.prepare(AssetQuery(limit: 2_000))
        try require(all.files.count == 2_005, "删除候选被显示上限截断")
        let excluded = try await coordinator.prepare(AssetQuery(searchText: "absent"))
        try require(excluded.files.isEmpty, "搜索范围泄漏")
        let picked = try await coordinator.prepare(AssetQuery(flag: .picked))
        try require(picked.files.isEmpty, "旗标范围泄漏")
        let album = Album(name: "隔离")
        try await store.saveAlbum(album)
        try await store.add(assetID: saved[0].id, toAlbum: album.id)
        let albumPlan = try await coordinator.prepare(AssetQuery(albumID: album.id))
        try require(albumPlan.files.count == 1, "相册范围泄漏")
        try await store.removeAssetRecords(saved.map(\.id))

        var files: [MediaAsset] = []
        for name in ["ok.jpg", "fail.jpg", "changed.jpg", "unflag.jpg", "video.mov", "pair.raw", "missing.jpg"] {
            let url = root.appendingPathComponent(name)
            try Data("original".utf8).write(to: url)
            let date = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
            let asset = try await store.upsertAsset(MediaAsset(sourceID: source.id, relativePath: name, fileIdentifier: FileIdentity.resourceIdentifier(for: url), fileName: name, uniformType: nil, kind: name == "video.mov" ? .video : .photo, fileSize: 8, modifiedAt: date))
            try await store.saveAnnotation(UserAnnotation(assetID: asset.id, flag: name == "pair.raw" ? .none : .rejected))
            files.append(asset)
        }
        let plan = try await coordinator.prepare(AssetQuery())
        try require(plan.files.count == 5, "视频或未标记配对文件被列入删除")
        try Data("replacement contents".utf8).write(to: root.appendingPathComponent("changed.jpg"), options: .atomic)
        try await store.saveAnnotation(UserAnnotation(assetID: files[3].id))
        try FileManager.default.moveItem(at: root.appendingPathComponent("missing.jpg"), to: root.appendingPathComponent("offline.jpg"))
        let report = try await coordinator.execute(plan)
        try require(report.deleted == 1 && report.skipped == 3 && report.failures.count == 1, "部分失败统计错误：\(report)")
        let deleted = try await store.asset(id: files[0].id)
        try require(deleted == nil, "成功删除后目录记录仍在")
        try require(FileManager.default.fileExists(atPath: root.appendingPathComponent("pair.raw").path), "误删配对文件")
        let recovery = try await coordinator.recover()
        try require(recovery.isEmpty, "已知权限失败不应阻塞重试")

        // Simulate a crash after a successful move, before database cleanup.
        let moved = files[1]
        try FileManager.default.moveItem(at: root.appendingPathComponent(moved.relativePath), to: trashDir.appendingPathComponent("recovered"))
        try JSONEncoder().encode([DeletionJournalEntry(asset: moved, state: "moved")]).write(to: journal)
        _ = try await coordinator.recover()
        let remaining = try await store.asset(id: moved.id)
        try require(remaining == nil, "中断恢复未清理目录")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.execute(DeletionPlan(files: [files[2]]))
        }
        let cancelled = try await task.value
        try require(cancelled.cancelled && cancelled.deleted == 0, "取消后仍删除文件")

        let duplicateURL = root.appendingPathComponent("duplicate.jpg")
        try Data("duplicate".utf8).write(to: duplicateURL)
        let stamp = try duplicateURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let duplicate = try await store.upsertAsset(MediaAsset(sourceID: source.id, relativePath: "duplicate.jpg", fileIdentifier: FileIdentity.resourceIdentifier(for: duplicateURL), fileName: "duplicate.jpg", uniformType: nil, kind: .photo, fileSize: 9, modifiedAt: stamp))
        try await store.saveAnnotation(UserAnnotation(assetID: duplicate.id, rating: 4, flag: .rejected, keywords: ["删除测试"]))
        try await store.add(assetID: duplicate.id, toAlbum: album.id)
        let stableDuplicate = try await store.asset(id: duplicate.id)!
        let duplicateReport = try await coordinator.execute(DeletionPlan(files: [stableDuplicate, stableDuplicate]))
        try require(duplicateReport.deleted == 1 && duplicateReport.skipped == 1, "重复路径被多次处理")
        let cleanedAnnotation = try await store.annotation(for: duplicate.id)
        let cleanedAlbum = try await store.assets(AssetQuery(albumID: album.id))
        try require(cleanedAnnotation.rating == 0 && cleanedAnnotation.keywords.isEmpty && cleanedAlbum.isEmpty, "关联数据未级联清理")
    }

    private static func checkPreview() async throws {
        try require(PreviewScale.actualPixels(backingScale: 2) == 0.5 && PreviewScale.actualPixels(backingScale: 1) == 1, "100% 屏幕像素换算错误")
        try require(PreviewScale.bounded(0) == 0.01 && PreviewScale.bounded(99) == 16, "缩放边界错误")
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("preview.jpg")
        try writeSolidJPEG(to: url, gray: 128)
        let loaded = try await ImagePreviewLoader().load(url: url)
        try require(loaded.image.width == 64 && !loaded.isEmbedded, "原图尺寸错误")
        let oriented = root.appendingPathComponent("oriented.jpg")
        let cropped = loaded.image.cropping(to: CGRect(x: 0, y: 0, width: 32, height: 64))!
        let target = CGImageDestinationCreateWithURL(oriented as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(target, cropped, [kCGImagePropertyOrientation: 6] as CFDictionary)
        try require(CGImageDestinationFinalize(target), "写入方向样本失败")
        let rotated = try await ImagePreviewLoader().load(url: oriented)
        try require(rotated.image.width == 64 && rotated.image.height == 32, "未应用 EXIF 方向")
        let baseline = try SRGBPixels(rotated.image).rgba
        for _ in 0..<8 {
            _ = try await ImagePreviewLoader().load(url: url)
            let returned = try await ImagePreviewLoader().load(url: oriented)
            let returnedPixels = try SRGBPixels(returned.image).rgba
            try require(returnedPixels == baseline, "A → B → A 返回后像素变化")
        }
        var lease: PreviewAccessLease? = PreviewAccessLease(url: root)
        weak var weakLease = lease
        var retained: PreviewImage? = try await ImagePreviewLoader().load(url: oriented, access: lease)
        lease = nil
        try require(weakLease != nil, "加载返回后提前释放访问授权")
        try FileManager.default.removeItem(at: oriented)
        let detachedPixels = try SRGBPixels(retained!.image).rgba
        try require(detachedPixels == baseline, "原文件移走后显示仍依赖文件读取")
        try require(retained!.image.bitsPerComponent == 8 && retained!.image.bitsPerPixel == 32, "显示像素格式不固定")
        retained = nil
        try require(weakLease == nil, "释放预览后访问授权未释放")
        weakLease = nil
        let heic = root.appendingPathComponent("preview.heic")
        if let destination = CGImageDestinationCreateWithURL(heic as CFURL, UTType.heic.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, loaded.image, nil)
            try require(CGImageDestinationFinalize(destination), "HEIC 测试样本写入失败")
            let decodedHEIC = try await ImagePreviewLoader().load(url: heic)
            try require(decodedHEIC.image.width == 64, "HEIC 解码失败")
        } else { print("  HEIC 编码器不可用，跳过成功路径") }
        for name in ["bad.jpg", "bad.heic", "bad.arw"] {
            let bad = root.appendingPathComponent(name)
            try Data("bad".utf8).write(to: bad)
            do { _ = try await ImagePreviewLoader().load(url: bad); throw CheckFailure(description: "损坏图像未报错") }
            catch is CocoaError {}
        }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ImagePreviewLoader().load(url: url)
        }
        do { _ = try await task.value; throw CheckFailure(description: "未取消原图加载") }
        catch is CancellationError {}
    }

    private static func checkHistogram() async throws {
        let colors: [UInt8] = [0,0,0,255, 255,255,255,255, 128,128,128,255,
                               255,0,0,255, 0,255,0,255, 0,0,255,255, 0,0,0,0]
        let data = Data(colors)
        let image = CGImage(width: 7, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 28,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let histogram = try HistogramProvider.calculate(image)
        try require(histogram.luminance.reduce(0,+) == 6, "透明像素未排除")
        try require(histogram.luminance[0] == 1 && histogram.luminance[255] == 1 && histogram.luminance[128] == 1, "黑白灰亮度统计错误")
        try require(histogram.red[255] == 2 && histogram.green[255] == 2 && histogram.blue[255] == 2, "RGB 通道统计错误")
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("image.jpg")
        try writeSolidJPEG(to: url, gray: 128)
        let asset = MediaAsset(sourceID: "test", relativePath: "image.jpg", fileIdentifier: nil, fileName: "image.jpg", uniformType: nil, kind: .photo, fileSize: 1, modifiedAt: Date())
        let provider = HistogramProvider()
        let decoded = try await provider.histogram(asset: asset, url: url)
        try require(decoded.luminance.reduce(0,+) == 4096, "JPEG 直方图样本数错误")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await provider.histogram(asset: asset, url: url)
        }
        do { _ = try await cancelled.value; throw CheckFailure(description: "缓存命中未响应取消") } catch is CancellationError {}
    }

    private static func checkSourceManagement() async throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("catalog.sqlite")
        let store = try CatalogStore(databaseURL: dbURL)
        let original = try await store.registerSource(at: folder)
        let same = try await store.registerSource(at: folder)
        try require(original.id == same.id, "重复添加未复用来源")
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let linked = try await store.registerSource(at: link)
        try require(linked.id == original.id, "符号链接未识别为同一目录")
        let child = folder.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let childSource = try await store.registerSource(at: child)
        try require(childSource.id != original.id, "父子目录被误合并")
        let other = root.appendingPathComponent("elsewhere/photos")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let otherSource = try await store.registerSource(at: other)
        try require(otherSource.id != original.id, "同名目录被误合并")
        let duplicate = SourceRoot(name: "重复", bookmarkData: nil, pathHint: folder.path)
        try await store.upsertSource(duplicate)
        let url = folder.appendingPathComponent("one.jpg")
        try Data("original".utf8).write(to: url)
        let modified = Date(timeIntervalSince1970: 1000)
        let first = try await store.upsertAsset(MediaAsset(sourceID: original.id, relativePath: "one.jpg", fileIdentifier: "same-id", fileName: "one.jpg", uniformType: nil, kind: .photo, fileSize: 8, modifiedAt: modified))
        let second = try await store.upsertAsset(MediaAsset(sourceID: duplicate.id, relativePath: "one.jpg", fileIdentifier: "same-id", fileName: "one.jpg", uniformType: nil, kind: .photo, fileSize: 8, modifiedAt: modified))
        try await store.saveAnnotation(UserAnnotation(assetID: first.id, rating: 2, flag: .picked, keywords: ["A"]))
        try await Task.sleep(for: .milliseconds(10))
        try await store.saveAnnotation(UserAnnotation(assetID: second.id, rating: 5, flag: .rejected, keywords: ["B"]))
        let album = Album(name: "保留成员")
        try await store.saveAlbum(album)
        try await store.add(assetID: second.id, toAlbum: album.id)
        let plan = try await store.prepareSourceMerge()
        try require(plan.groups.count == 1 && plan.conflicts == 1, "重复来源或标注冲突统计错误")
        let backup = root.appendingPathComponent("backup.sqlite")
        let faultDB = try DatabaseQueue(path: dbURL.path)
        try await faultDB.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_source_merge BEFORE DELETE ON sourceRoots BEGIN SELECT RAISE(ABORT, 'injected merge failure'); END")
        }
        do {
            _ = try await store.mergeSources(plan, backupURL: root.appendingPathComponent("rollback-backup.sqlite"))
            throw CheckFailure(description: "故障注入未触发回滚")
        } catch is DatabaseError {}
        let rolledBack = try await store.asset(id: second.id)
        let oldAnnotation = try await store.annotation(for: first.id)
        try require(rolledBack != nil && oldAnnotation.keywords == ["A"], "合并失败后发生部分提交")
        try await faultDB.write { db in try db.execute(sql: "DROP TRIGGER fail_source_merge") }
        let report = try await store.mergeSources(plan, backupURL: backup)
        try require(report.mergedGroups == 1 && report.skipped.isEmpty, "来源未合并")
        let merged = try await store.annotation(for: first.id)
        try require(merged.rating == 5 && merged.flag == .rejected && merged.keywords == ["A", "B"], "标注合并规则错误")
        let members = try await store.assets(AssetQuery(albumID: album.id))
        try require(members.count == 1 && members[0].id == first.id, "相册关系未迁移")
        let backupStore = try CatalogStore(databaseURL: backup)
        let backupSource = try await backupStore.source(id: duplicate.id)
        try require(backupSource != nil, "备份不包含合并前数据")
        let reopened = try CatalogStore(databaseURL: dbURL)
        let restored = try await reopened.annotation(for: first.id)
        try require(restored.keywords == ["A", "B"], "合并结果重启丢失")
        let conflicting = SourceRoot(name: "冲突来源", bookmarkData: nil, pathHint: folder.path)
        try await store.upsertSource(conflicting)
        _ = try await store.upsertAsset(MediaAsset(sourceID: conflicting.id, relativePath: "one.jpg", fileIdentifier: "different-id", fileName: "one.jpg", uniformType: nil, kind: .photo, fileSize: 8, modifiedAt: modified))
        let offline = SourceRoot(name: "离线", bookmarkData: nil, pathHint: root.appendingPathComponent("unmounted").path)
        try await store.upsertSource(offline)
        let conflictingPlan = try await store.prepareSourceMerge()
        try require(conflictingPlan.warnings.count == 1, "未报告离线来源")
        let skipped = try await store.mergeSources(conflictingPlan, backupURL: root.appendingPathComponent("conflict-backup.sqlite"))
        try require(skipped.mergedGroups == 0 && skipped.skipped.count == 1, "文件身份冲突没有跳过整个组")
        let preserved = try await store.asset(id: first.id)
        try require(preserved != nil, "冲突组索引被修改")
        try await store.deleteAlbum(id: album.id)
        let kept = try await store.asset(id: first.id)
        try require(kept != nil, "删除相册误删索引")
        do {
            _ = try await store.removeSource(id: original.id, backupURL: backup)
            throw CheckFailure(description: "备份路径冲突仍执行删除")
        } catch is CocoaError {}
        let stillPresent = try await store.source(id: original.id)
        try require(stillPresent != nil, "备份失败后来源丢失")
        _ = try await store.removeSource(id: original.id, backupURL: root.appendingPathComponent("remove-backup.sqlite"))
        let removed = try await store.asset(id: first.id)
        try require(removed == nil && FileManager.default.fileExists(atPath: url.path), "来源移除未清理索引或修改原文件")
    }

    private static func seedUpgradeFixture(_ url: URL, version: Int) async throws {
        do {
            let store = try CatalogStore(databaseURL: url)
            let source = SourceRoot(id: "upgrade-source", name: "升级测试", bookmarkData: nil, pathHint: url.deletingLastPathComponent().path)
            try await store.upsertSource(source)
            let asset = MediaAsset(id: "upgrade-photo", sourceID: source.id, relativePath: "original.jpg", fileIdentifier: "file-1", fileName: "original.jpg", uniformType: "public.jpeg", kind: .photo, fileSize: 8, modifiedAt: Date(timeIntervalSince1970: 1000))
            _ = try await store.upsertAsset(asset)
            try await store.saveAnnotation(UserAnnotation(assetID: asset.id, rating: 4, flag: .picked, keywords: ["升级保留"]))
            let album = Album(id: "upgrade-album", name: "旧相册")
            try await store.saveAlbum(album)
            try await store.add(assetID: asset.id, toAlbum: album.id)
            try await store.saveAnalysis(AnalysisResult(assetID: asset.id, sharpnessScore: 0.015, shadowClipping: 0.4,
                highlightClipping: 0.2, issues: [.blurry, .similarBurst], suggestionState: .ignored, similarGroupID: "old-burst"))
        }
        let db = try DatabaseQueue(path: url.path)
        try await db.write { db in
            if version < 4 {
                try db.execute(sql: "DROP INDEX analysisResults_qualityStatus")
                try db.execute(sql: "DROP TABLE qualityJobItems")
                for column in ["assessmentStatus", "diagnosticJSON", "fingerprintJSON", "analysisError"] {
                    try db.execute(sql: "ALTER TABLE analysisResults DROP COLUMN \(column)")
                }
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v4-quality-assessment'")
            }
            if version < 3 {
                try db.execute(sql: "DROP INDEX sourceRoots_directoryIdentity")
                try db.execute(sql: "ALTER TABLE sourceRoots DROP COLUMN directoryIdentityJSON")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v3-source-directory-identity'")
            }
            if version < 2 {
                try db.execute(sql: "DROP INDEX mediaAssets_fileIdentifier")
                try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'v2-file-identity-index'")
            }
        }
        try db.close()
    }

    private static func checkCatalogUpgrade() async throws {
        let root = try temporaryWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        for version in 1...4 {
            let directory = root.appendingPathComponent("v\(version)")
            let url = directory.appendingPathComponent("Catalog.sqlite")
            try await seedUpgradeFixture(url, version: version)
            try Data("original".utf8).write(to: directory.appendingPathComponent("original.jpg"))
            try JSONEncoder().encode([DeletionJournalEntry]()).write(to: directory.appendingPathComponent("deletions.json"))
            let coordinator = CatalogUpgradeCoordinator(databaseURL: url)
            do {
                let store = try await coordinator.open()
                let annotation = try await store.annotation(for: "upgrade-photo")
                let members = try await store.assets(AssetQuery(albumID: "upgrade-album"))
                try require(annotation.rating == 4 && annotation.flag == .picked && annotation.keywords == ["升级保留"] && members.count == 1, "升级损坏用户数据")
                let legacy = try await store.analysis(for: "upgrade-photo")
                try require(legacy?.algorithmVersion == 1 && legacy?.suggestionState == .ignored && legacy?.similarGroupID == "old-burst" && legacy?.sharpnessScore == 0.015, "迁移改变旧分析或人工审核")
                do { _ = try CatalogLease(databaseURL: url); throw CheckFailure(description: "第二个实例获得图库锁") } catch is CatalogUpgradeError {}
                do { try await coordinator.restore(from: directory); throw CheckFailure(description: "连接尚未关闭就恢复") } catch is CatalogUpgradeError {}
            }
            let backups = (try? FileManager.default.contentsOfDirectory(at: CatalogUpgradeCoordinator.backupDirectory(for: url), includingPropertiesForKeys: nil)) ?? []
            try require(backups.count == (version < 4 ? 1 : 0), "备份创建时机错误")
            if version < 4 {
                let backup = backups[0]
                let manifest = try JSONDecoder().decode(UpgradeManifest.self, from: Data(contentsOf: backup.appendingPathComponent("manifest.json")))
                try require(manifest.migrations.count == version && manifest.journalHash != nil, "备份缺少版本或日志")
                // A persisted intent simulates a process stopping before recovery completes.
                let preserved = directory.appendingPathComponent("Backups/preserved")
                try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true)
                try JSONEncoder().encode(["backup": backup.path, "preserved": preserved.path]).write(to: directory.appendingPathComponent("restore-state.json"))
                do { _ = try CatalogStore(databaseURL: url); throw CheckFailure(description: "恢复中断时仍允许打开图库") } catch is CatalogUpgradeError {}
                try await coordinator.restore(from: backup)
                var config = Configuration(); config.readonly = true
                let reader = try DatabaseQueue(path: url.path, configuration: config)
                let count = try await reader.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations")! }
                try require(count == version, "没有恢复升级前版本")
                try reader.close()
            }
            let photo = try Data(contentsOf: directory.appendingPathComponent("original.jpg"))
            try require(photo == Data("original".utf8), "升级或恢复修改原照片")
        }
        let unknownURL = root.appendingPathComponent("unknown/Catalog.sqlite")
        try await seedUpgradeFixture(unknownURL, version: 3)
        let unknownDB = try DatabaseQueue(path: unknownURL.path)
        try await unknownDB.write { try $0.execute(sql: "INSERT INTO grdb_migrations(identifier) VALUES ('v99-future')") }
        do { _ = try CatalogStore(databaseURL: unknownURL); throw CheckFailure(description: "新版数据库允许降级打开") } catch is CatalogUpgradeError {}
        try unknownDB.close()
        let failureURL = root.appendingPathComponent("backup-failure/Catalog.sqlite")
        try await seedUpgradeFixture(failureURL, version: 1)
        try Data("not a directory".utf8).write(to: failureURL.deletingLastPathComponent().appendingPathComponent("Backups"))
        do { _ = try CatalogStore(databaseURL: failureURL); throw CheckFailure(description: "备份失败仍继续迁移") } catch is CocoaError {}
        let reader = try DatabaseQueue(path: failureURL.path)
        let applied = try await reader.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations")! }
        try require(applied == 1, "备份失败后改变数据库版本")
        try reader.close()
        let walURL = root.appendingPathComponent("wal/Catalog.sqlite")
        try await seedUpgradeFixture(walURL, version: 1)
        let walWriter = try DatabaseQueue(path: walURL.path)
        try await walWriter.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "UPDATE annotations SET rating = 5 WHERE assetID = 'upgrade-photo'")
        }
        do { _ = try CatalogStore(databaseURL: walURL) }
        let walBackups = try FileManager.default.contentsOfDirectory(at: CatalogUpgradeCoordinator.backupDirectory(for: walURL), includingPropertiesForKeys: nil)
        let snapshot = try DatabaseQueue(path: walBackups[0].appendingPathComponent("Catalog.sqlite").path)
        let rating = try await snapshot.read { try Int.fetchOne($0, sql: "SELECT rating FROM annotations WHERE assetID = 'upgrade-photo'") }
        try require(rating == 5, "在线备份遗漏 WAL 中已提交数据")
        try snapshot.close(); try walWriter.close()

        let faultURL = root.appendingPathComponent("migration-fault/Catalog.sqlite")
        try await seedUpgradeFixture(faultURL, version: 1)
        let faultWriter = try DatabaseQueue(path: faultURL.path)
        try await faultWriter.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_upgrade BEFORE INSERT ON grdb_migrations BEGIN SELECT RAISE(ABORT, 'injected migration failure'); END")
        }
        do { _ = try CatalogStore(databaseURL: faultURL); throw CheckFailure(description: "迁移故障未阻止启动") } catch is DatabaseError {}
        let unchanged = try await faultWriter.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM grdb_migrations") }
        try require(unchanged == 1, "失败的迁移没有回滚")
        try faultWriter.close()

        let v4FaultURL = root.appendingPathComponent("v4-fault/Catalog.sqlite")
        try await seedUpgradeFixture(v4FaultURL, version: 3)
        let v4Writer = try DatabaseQueue(path: v4FaultURL.path)
        try await v4Writer.write { db in
            try db.execute(sql: "CREATE TRIGGER fail_quality_upgrade BEFORE INSERT ON grdb_migrations WHEN NEW.identifier = 'v4-quality-assessment' BEGIN SELECT RAISE(ABORT, 'injected v4 failure'); END")
        }
        do { _ = try CatalogStore(databaseURL: v4FaultURL); throw CheckFailure(description: "v4 迁移失败仍允许打开") } catch is DatabaseError {}
        let v4Unchanged = try await v4Writer.read { db in
            let hasItems = try db.tableExists("qualityJobItems")
            let hasStatus = try db.columns(in: "analysisResults").contains { $0.name == "assessmentStatus" }
            return !hasItems && !hasStatus
        }
        try require(v4Unchanged, "v4 事务失败未回滚新增表和字段")
        try v4Writer.close()
    }

    private static func temporaryWorkspace() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JingXu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func writeSolidJPEG(to url: URL, gray: UInt8) throws {
        let width = 64
        let height = 64
        var pixels = [UInt8](repeating: gray, count: width * height * 4)
        for index in stride(from: 3, to: pixels.count, by: 4) { pixels[index] = 255 }
        let image = pixels.withUnsafeMutableBytes { buffer -> CGImage? in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            return context.makeImage()
        }
        guard let image,
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
