import Foundation
import CoreGraphics
import ImageIO
import GRDB
import JingXuCore
import UniformTypeIdentifiers

enum ColorChecks {
    struct Failure: Error, CustomStringConvertible { let description: String }
    static func check(_ value: Bool, _ reason: String) throws { if !value { throw Failure(description: reason) } }
    static func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("JingXuColor-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func verifyFile(_ file: URL, output: URL) async throws {
        var parent = output.standardizedFileURL.resolvingSymlinksInPath()
        while parent.path != "/" {
            guard !FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) else { throw Failure(description: "原片验证输出不能写入 Git 仓库") }
            parent.deleteLastPathComponent()
        }
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure(description: "验证输出目录已存在") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let hash = try FileHasher.sha256(of: file)
        let store = try CatalogStore(databaseURL: output.appendingPathComponent("Catalog.sqlite"))
        let source = SourceRoot(name: "validation", bookmarkData: nil, pathHint: file.deletingLastPathComponent().path)
        try await store.upsertSource(source)
        let fp = try AnalysisFingerprint(url: file)
        let asset = MediaAsset(sourceID: source.id, relativePath: file.lastPathComponent, fileIdentifier: fp.identifier,
            fileName: file.lastPathComponent, uniformType: nil, kind: .photo, fileSize: fp.size, modifiedAt: fp.modifiedAt)
        _ = try await store.upsertAsset(asset)
        let snapshot = try await store.colorSnapshot(assetID: asset.id)
        let renderer = ColorImageRenderer()
        let plain = try await renderer.render(snapshot, adjustments: ColorAdjustments())
        var values = ColorAdjustments(); values.exposure = 0.5; values.contrast = 10; values.shadows = 15; values.vibrance = 12
        if snapshot.isRAW { values.whiteBalance = .raw; values.temperature = min(50000, max(2000, plain.rawTemperature + 800)); values.tint = plain.rawTint }
        let adjusted = try await renderer.render(snapshot, adjustments: values)
        try check(adjusted.nativeSize == plain.nativeSize, "RAW 调色改变原尺寸")
        try await renderer.encode(snapshot, adjustments: ColorAdjustments(), format: .jpeg, to: output.appendingPathComponent("before.jpg"))
        for format in [ColorExportFormat.jpeg, .tiff] {
            let destination = output.appendingPathComponent("after." + format.fileExtension)
            try await renderer.encode(snapshot, adjustments: values, format: format, to: destination)
            let readback = try await ImagePreviewLoader().load(url: destination)
            try check(readback.image.width == adjusted.image.width && readback.image.height == adjusted.image.height, "真实原片导出尺寸不一致")
        }
        try check(try FileHasher.sha256(of: file) == hash, "真实原片内容改变")
        print("真实原片调色与导出通过：\(adjusted.image.width) × \(adjusted.image.height)，JPEG／16 位 TIFF；原片 SHA-256 不变。")
        print(output.path)
        await renderer.release()
    }
    static func fixture(store: CatalogStore, source: SourceRoot, name: String, orientation: Int = 1, gray: UInt8? = nil) async throws -> ColorEditSnapshot {
        let url = URL(fileURLWithPath: source.pathHint).appendingPathComponent(name)
        let image = try QualityV2Checks.image(width: 128, height: 80) { x,y in
            if let gray { return (gray, gray, gray, 255) }
            return (UInt8(25+x), UInt8(30+y), UInt8(160-x/2), x < 8 ? 0 : 255)
        }
        try QualityV2Checks.write(image, to: url, type: .png, orientation: orientation)
        let fp = try AnalysisFingerprint(url: url)
        let asset = MediaAsset(sourceID: source.id, relativePath: name, fileIdentifier: fp.identifier, fileName: name,
            uniformType: "public.png", kind: .photo, fileSize: fp.size, modifiedAt: fp.modifiedAt)
        _ = try await store.upsertAsset(asset)
        return try await store.colorSnapshot(assetID: asset.id)
    }
    static func brightness(_ image: CGImage) throws -> Double {
        let h = try HistogramProvider.calculate(image).luminance
        return Double(h.enumerated().reduce(0) { $0 + $1.offset * $1.element }) / Double(max(1, h.reduce(0,+)))
    }
    static func xmp(_ attributes: String, body: String = "", prefix: String = "crs") -> Data {
        Data("<x:xmpmeta xmlns:x='adobe:ns:meta/'><rdf:RDF xmlns:rdf='http://www.w3.org/1999/02/22-rdf-syntax-ns#'><rdf:Description xmlns:\(prefix)='http://ns.adobe.com/camera-raw-settings/1.0/' \(attributes)>\(body)</rdf:Description></rdf:RDF></x:xmpmeta>".utf8)
    }
    static func presets() throws {
        let preset = try ColorXMPImporter.parse(xmp("p:Exposure2012='1.2' p:Saturation='-30' p:Name='测试'", prefix: "p"), suggestedName: "x")
        let patch = try preset.patch
        try check(preset.name == "测试" && patch.values[.exposure] == 1.2, "XMP 前缀被硬编码")
        var original = ColorAdjustments(); original.shadows = 35
        let result = try patch.applying(to: original, groups: Set(ColorGroup.allCases), isRAW: false)
        try check(result.shadows == 35 && result.exposure == 1.2 && result.saturation == -30, "稀疏预设重置了未提供参数")
        let element = try ColorXMPImporter.parse(xmp("", body: "<crs:Exposure2012>1.2</crs:Exposure2012><crs:Name><rdf:Alt><rdf:li xml:lang='x-default'>元素预设</rdf:li></rdf:Alt></crs:Name>"), suggestedName: "x")
        try check(element.name == "元素预设" && element.patch.values[.exposure] == 1.2, "XMP 元素值或 RDF 名称读取失败")
        let wb = try ColorXMPImporter.parse(xmp("crs:WhiteBalance='Custom' crs:Temperature='5500' crs:Tint='12'"), suggestedName: "raw")
        let raw = try wb.patch.applying(to: original, groups: Set(ColorGroup.allCases), isRAW: true)
        try check(raw.whiteBalance == .raw && raw.temperature == 5500, "绝对白平衡导入失败")
        do { _ = try wb.patch.applying(to: original, groups: Set(ColorGroup.allCases), isRAW: false); throw Failure(description: "RAW 白平衡错误地应用到普通图片") } catch is ColorEditError {}
        try check(try wb.patch.applying(to: original, groups: [.tone, .color], isRAW: false) == original, "未勾选白平衡时不应套用 RAW 白平衡限制")
        let rejected = ["crs:CameraProfile='Adobe Color'", "crs:Clarity2012='0'", "crs:Exposure2012='NaN'",
            "crs:Exposure2012='6'", "crs:WhiteBalance='Auto'", "crs:Temperature='5000'", "crs:WhiteBalance='Custom' crs:Tint='0'",
            "crs:Exposure='1'", "crs:IncrementalTemperature='10'", "crs:HasCrop='True'", "crs:Exposure2012='1' crs:SupportsSceneReferred='maybe'"]
        for attributes in rejected {
            do { _ = try ColorXMPImporter.parse(xmp(attributes), suggestedName: "x"); throw Failure(description: "不支持参数被接受：\(attributes)") } catch is ColorEditError {}
        }
        for body in ["<crs:ToneCurvePV2012><rdf:Seq><rdf:li>0,0</rdf:li></rdf:Seq></crs:ToneCurvePV2012>", "<crs:Exposure2012>2</crs:Exposure2012>"] {
            do { _ = try ColorXMPImporter.parse(xmp("crs:Exposure2012='1'", body: body), suggestedName: "x"); throw Failure(description: "曲线或冲突字段被忽略") } catch is ColorEditError {}
        }
        for data in [Data("<!DOCTYPE a [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><a>&x;</a>".utf8), Data("<bad>".utf8), xmp("")] {
            do { _ = try ColorXMPImporter.parse(data, suggestedName: "x"); throw Failure(description: "非法 XML 或空预设被接受") } catch is ColorEditError {}
        }
        var history = ColorEditHistory(); history.push(ColorAdjustments()); history.push(result)
        try check(history.undo(raw) == result && history.undo(result) == ColorAdjustments() && history.redo(ColorAdjustments()) == result, "调色撤销／重做错误")
    }

    static func rendering() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        let source = SourceRoot(name: "test", bookmarkData: nil, pathHint: root.path); try await store.upsertSource(source)
        let snapshot = try await fixture(store: store, source: source, name: "oriented.png", orientation: 6)
        let url = root.appendingPathComponent(snapshot.asset.fileName), before = try FileHasher.sha256(of: root.appendingPathComponent(snapshot.asset.fileName))
        let renderer = ColorImageRenderer()
        let plain = try await renderer.render(snapshot, adjustments: ColorAdjustments())
        try check(plain.image.width == 80 && plain.image.height == 128, "调色没有应用 EXIF 方向")
        let decoded = try await ImagePreviewLoader().load(url: url)
        let left = try SRGBPixels(plain.image), right = try SRGBPixels(decoded.image)
        let difference = zip(left.rgba, right.rgba).map { abs(Int($0) - Int($1)) }.max() ?? 0
        try check(difference <= 3, "默认参数改变图像：最大通道差 \(difference)")
        var edits = ColorAdjustments(); edits.exposure = 1
        let brighter = try await renderer.render(snapshot, adjustments: edits)
        try check(try brightness(brighter.image) > brightness(plain.image) + 10, "正曝光没有变亮")
        for parameter in [ColorParameter.shadows, .highlights, .whites, .blacks] {
            // Verify the relevant tonal region, not a highlights control against a dark-only image.
            let tone = try await fixture(store: store, source: source, name: parameter.rawValue + ".png",
                gray: parameter == .blacks ? 20 : parameter == .shadows ? 65 : parameter == .highlights ? 190 : 245)
            var positive = ColorAdjustments(), negative = ColorAdjustments()
            positive[parameter] = 60; negative[parameter] = -60
            let light = try await renderer.render(tone, adjustments: positive)
            let dark = try await renderer.render(tone, adjustments: negative)
            try check(try brightness(light.image) > brightness(dark.image), "\(parameter.title)调整方向错误")
        }
        var warm = ColorAdjustments(), cold = ColorAdjustments()
        warm.whiteBalance = .relative; warm.temperature = 60
        cold.whiteBalance = .relative; cold.temperature = -60
        func warmth(_ image: CGImage) throws -> Int {
            let rgba = try SRGBPixels(image).rgba
            return stride(from: 0, to: rgba.count, by: 4).reduce(0) { $0 + Int(rgba[$1]) - Int(rgba[$1+2]) }
        }
        let warmImage = try await renderer.render(snapshot, adjustments: warm), coldImage = try await renderer.render(snapshot, adjustments: cold)
        try check(try warmth(warmImage.image) > warmth(coldImage.image), "普通图片色温正向没有变暖")
        edits.exposure = 0; edits.saturation = -100
        let gray = try await renderer.render(snapshot, adjustments: edits)
        let pixels = try SRGBPixels(gray.image)
        for i in stride(from: 0, to: pixels.rgba.count, by: 4) where pixels.rgba[i+3] > 0 {
            try check(abs(Int(pixels.rgba[i])-Int(pixels.rgba[i+1])) <= 2 && abs(Int(pixels.rgba[i])-Int(pixels.rgba[i+2])) <= 2, "去饱和未生成灰度")
        }
        let preview = try await renderer.render(snapshot, adjustments: edits, maximumDimension: 40)
        try check(max(preview.image.width, preview.image.height) == 40 && preview.nativeSize == plain.nativeSize, "降采样改变原片尺寸")
        for format in ColorExportFormat.allCases {
            let output = root.appendingPathComponent("output." + format.fileExtension)
            try await renderer.encode(snapshot, adjustments: edits, format: format, to: output)
            guard let input = CGImageSourceCreateWithURL(output as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(input, 0, nil) else { throw Failure(description: "导出文件无法重新打开") }
            try check(image.width == 80 && image.height == 128, "导出不是原尺寸")
            if format == .tiff { try check(image.bitsPerComponent == 16, "TIFF 不是 16 位") }
            if format == .png { try check(try SRGBPixels(image).rgba == pixels.rgba, "PNG 导出和预览不一致") }
        }
        let cancel = Task { try await renderer.render(snapshot, adjustments: edits) }; cancel.cancel()
        do { _ = try await cancel.value; throw Failure(description: "渲染没有响应取消") } catch is CancellationError {}
        try check(try FileHasher.sha256(of: url) == before, "调色修改原照片")
        let bad = try await fixture(store: store, source: source, name: "bad.arw")
        do { _ = try await renderer.render(bad, adjustments: ColorAdjustments()); throw Failure(description: "不支持 RAW 使用了嵌入预览") } catch is ColorEditError {}
        await renderer.release()
    }

    static func persistence() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let pictures = root.appendingPathComponent("pictures"); try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let dbURL = root.appendingPathComponent("Catalog.sqlite"), store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        let source = SourceRoot(name: "test", bookmarkData: nil, pathHint: pictures.path); try await store.upsertSource(source)
        var first = try await fixture(store: store, source: source, name: "a.png")
        let second = try await fixture(store: store, source: source, name: "b.png")
        var a = ColorAdjustments(); a.exposure = 0.8
        first = try await store.saveColorAdjustments(a, snapshot: first)
        let reopened = try CatalogStore(databaseURL: dbURL)
        try check(try await reopened.colorSnapshot(assetID: first.asset.id).adjustments == a, "重开丢失调整")
        let preset = try ColorPreset(name: "test", patch: ColorPatch(a)); try await store.saveColorPreset(preset)
        try check(try await reopened.colorPresets().first?.patch == ColorPatch(a), "重开丢失预设")
        var patch = ColorPatch(values: [.shadows: 25])
        let plan = try await store.prepareColorBatch(assetIDs: [first.asset.id, second.asset.id], patch: patch, groups: [.tone])
        try check(plan.items.count == 2 && plan.warnings.isEmpty && plan.groups == [.tone], "有效批量照片被跳过或分组未冻结")
        let blocker = root.appendingPathComponent("blocker"); try Data().write(to: blocker)
        do { _ = try await store.applyColorBatch(plan, backupURL: blocker.appendingPathComponent("bad.sqlite")); throw Failure(description: "备份失败仍修改调整") } catch is CocoaError {}
        try check(try await store.colorSnapshot(assetID: first.asset.id).adjustments == a, "备份失败改变调整")
        let rawDB = try DatabaseQueue(path: dbURL.path)
        let failID = plan.items.last!.id
        try await rawDB.write { db in
            for operation in ["INSERT", "UPDATE"] {
                try db.execute(sql: "CREATE TRIGGER fail_color_\(operation) BEFORE \(operation) ON colorEdits WHEN NEW.assetID = '\(failID)' BEGIN SELECT RAISE(ABORT, 'injected color failure'); END")
            }
        }
        do { _ = try await store.applyColorBatch(plan, backupURL: root.appendingPathComponent("failed.sqlite")); throw Failure(description: "事务故障未触发") } catch is DatabaseError {}
        let failedFirst = try await store.colorSnapshot(assetID: first.asset.id), failedSecond = try await store.colorSnapshot(assetID: second.asset.id)
        try check(try failedFirst.adjustments == a && failedSecond.record == nil, "批量失败没有回滚全部调整")
        try await rawDB.write { try $0.execute(sql: "DROP TRIGGER fail_color_INSERT; DROP TRIGGER fail_color_UPDATE") }; try rawDB.close()
        let undo = try await store.applyColorBatch(plan, backupURL: root.appendingPathComponent("before.sqlite"))
        try check(try await store.colorSnapshot(assetID: first.asset.id).adjustments.shadows == 25, "批量没有应用")
        _ = try await store.applyColorBatch(undo, backupURL: root.appendingPathComponent("undo.sqlite"))
        let undoneFirst = try await store.colorSnapshot(assetID: first.asset.id), undoneSecond = try await store.colorSnapshot(assetID: second.asset.id)
        try check(try undoneFirst.adjustments == a && undoneSecond.adjustments.isIdentity, "批量撤销失败")
        do { _ = try await store.applyColorBatch(plan, backupURL: root.appendingPathComponent("stale.sqlite")); throw Failure(description: "过期计划覆盖最新调整") } catch is ColorEditError {}
        let thumb = ColorThumbnailProvider(cache: ThumbnailCache(directory: root.appendingPathComponent("thumbnails")))
        first = try await store.colorSnapshot(assetID: first.asset.id)
        let beforeThumb = try await thumb.thumbnail(first, pixelSize: 128)
        a.exposure = -1; first = try await store.saveColorAdjustments(a, snapshot: first)
        let afterThumb = try await thumb.thumbnail(first, pixelSize: 128)
        try check(beforeThumb != afterThumb, "调整后缩略图仍命中旧缓存")
        let target = root.appendingPathComponent("target"); try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let mover = ArchiveCoordinator(store: store, journalURL: root.appendingPathComponent("archive.json"))
        let move = try await mover.prepare(selectedIDs: [first.asset.id], destination: target)
        _ = try await mover.execute(move, backupURL: root.appendingPathComponent("move.sqlite"))
        let moved = try await store.colorSnapshot(assetID: first.asset.id)
        _ = try ColorSourceAccess(moved)
        try check(try moved.adjustments == a, "跨来源移动丢失调整")
        _ = try await mover.resume(undo: true)
        let restored = try await store.colorSnapshot(assetID: first.asset.id); _ = try ColorSourceAccess(restored)
        try check(try restored.adjustments == a, "撤销移动丢失调整")
        let duplicate = SourceRoot(name: "duplicate", bookmarkData: nil, pathHint: pictures.path); try await store.upsertSource(duplicate)
        var duplicateAsset = restored.asset; duplicateAsset.id = UUID().uuidString; duplicateAsset.sourceID = duplicate.id
        _ = try await store.upsertAsset(duplicateAsset)
        let duplicateSnapshot = try await store.colorSnapshot(assetID: duplicateAsset.id)
        var different = a; different.exposure = 2
        _ = try await store.saveColorAdjustments(different, snapshot: duplicateSnapshot)
        let merge = try await store.prepareSourceMerge()
        let conflict = try await store.mergeSources(merge, backupURL: root.appendingPathComponent("merge.sqlite"))
        try check(conflict.mergedGroups == 0 && conflict.skipped.contains { $0.contains("调色记录冲突") }, "来源合并丢弃了不同调整")
        let currentDuplicate = try await store.colorSnapshot(assetID: duplicateAsset.id)
        _ = try await store.saveColorAdjustments(a, snapshot: currentDuplicate)
        let aligned = try await store.prepareSourceMerge()
        let combined = try await store.mergeSources(aligned, backupURL: root.appendingPathComponent("merge-equal.sqlite"))
        try check(combined.mergedGroups == 1, "相同调色未允许来源合并")
        let mergedAsset = try await store.assets(AssetQuery()).first { $0.fileName == first.asset.fileName }!
        let mergedSnapshot = try await store.colorSnapshot(assetID: mergedAsset.id)
        try check(try mergedSnapshot.adjustments == a, "合并相同调整丢失参数")
        let path = pictures.appendingPathComponent(first.asset.fileName)
        try Data("replacement".utf8).write(to: path, options: .atomic)
        do { _ = try ColorSourceAccess(mergedSnapshot); throw Failure(description: "替换文件仍应用调整") } catch is ColorEditError {}
        try check(try await store.colorSnapshot(assetID: mergedAsset.id).adjustments == a, "替换文件删除了旧调整")
        var rescanned = mergedSnapshot.asset
        let replacedFingerprint = try AnalysisFingerprint(url: path)
        rescanned.fileIdentifier = replacedFingerprint.identifier; rescanned.fileSize = replacedFingerprint.size; rescanned.modifiedAt = replacedFingerprint.modifiedAt
        _ = try await store.upsertAsset(rescanned)
        let refreshed = try await store.assetListItem(id: mergedAsset.id)!
        try check(refreshed.fileVersion != mergedAsset.fileVersion, "重新扫描文件变化后界面缓存标识未更新")
        do { _ = try ColorSourceAccess(try await store.colorSnapshot(assetID: mergedAsset.id)); throw Failure(description: "扫描新指纹后错误地应用了旧调整") } catch is ColorEditError {}
        patch.values[.exposure] = 1
        let skip = try await store.prepareColorBatch(assetIDs: [mergedAsset.id], patch: patch, groups: [.tone])
        try check(skip.items.isEmpty && skip.warnings.count == 1, "文件变化没有被隔离")
        try await store.removeAssetRecords([second.asset.id])
        let query = try DatabaseQueue(path: dbURL.path)
        let count = try await query.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM colorEdits WHERE assetID = ?", arguments: [second.asset.id]) }
        try check(count == 0, "删除索引没有清理调整")
        try query.close()
    }

    static func exporting() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        let source = SourceRoot(name: "source", bookmarkData: nil, pathHint: root.path); try await store.upsertSource(source)
        let a = try await fixture(store: store, source: source, name: "first.png"), b = try await fixture(store: store, source: source, name: "second.png")
        let output = root.appendingPathComponent("output"); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let exporter = ColorExportCoordinator(store: store)
        let plan = try await exporter.prepare(assetIDs: [a.asset.id, b.asset.id], directory: output, format: .png)
        try check(plan.items.count == 2, "导出清单不完整")
        let occupied = plan.items[0].destination; try Data("occupied".utf8).write(to: occupied)
        let result = try await exporter.execute(plan)
        try check(result.written.count == 1 && result.skipped.count == 1 && result.failed.isEmpty, "导出重名未跳过")
        try check(try Data(contentsOf: occupied) == Data("occupied".utf8), "覆盖了已有文件")
        let failureDirectory = root.appendingPathComponent("fail"); try FileManager.default.createDirectory(at: failureDirectory, withIntermediateDirectories: true)
        let failing = ColorExportCoordinator(store: store, encode: { _,_,_,url in
            try Data("partial".utf8).write(to: url); throw CocoaError(.fileWriteOutOfSpace)
        })
        let failurePlan = try await failing.prepare(assetIDs: [a.asset.id], directory: failureDirectory, format: .jpeg)
        let failure = try await failing.execute(failurePlan)
        try check(failure.failed.count == 1 && failure.written.isEmpty && FileManager.default.contentsOfDirectory(atPath: failureDirectory.path).isEmpty, "编码失败留下成片或临时文件")
        let denied = root.appendingPathComponent("read-only"); try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        let deniedPlan = try await exporter.prepare(assetIDs: [a.asset.id], directory: denied, format: .png)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: denied.path)
        let permission = try await exporter.execute(deniedPlan)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
        try check(permission.failed.count == 1 && permission.written.isEmpty, "目录权限失败没有阻止导出")
        let raced = root.appendingPathComponent("raced"); try FileManager.default.createDirectory(at: raced, withIntermediateDirectories: true)
        let occupiedDuringEncoding = raced.appendingPathComponent("first-调色.png")
        let racing = ColorExportCoordinator(store: store, encode: { snapshot, values, format, url in
            try await ColorImageRenderer.shared.encode(snapshot, adjustments: values, format: format, to: url)
            try Data("arrived during encoding".utf8).write(to: occupiedDuringEncoding)
        })
        let racePlan = try await racing.prepare(assetIDs: [a.asset.id], directory: raced, format: .png)
        let race = try await racing.execute(racePlan)
        try check(race.skipped.count == 1 && race.written.isEmpty && Data(contentsOf: occupiedDuringEncoding) == Data("arrived during encoding".utf8), "原子提交覆盖了编码期间出现的文件")
        let cancelDirectory = root.appendingPathComponent("cancel"); try FileManager.default.createDirectory(at: cancelDirectory, withIntermediateDirectories: true)
        let cancelPlan = try await exporter.prepare(assetIDs: [a.asset.id,b.asset.id], directory: cancelDirectory, format: .png)
        let task = Task { try await exporter.execute(cancelPlan) { _,_ in withUnsafeCurrentTask { $0?.cancel() } } }
        let cancelled = try await task.value
        try check(cancelled.written.count == 1 && cancelled.cancelled, "取消没有保留已完成成片并停止后续项目")
        let stalePlan = try await exporter.prepare(assetIDs: [a.asset.id], directory: failureDirectory, format: .png)
        var edit = ColorAdjustments(); edit.exposure = 1
        _ = try await store.saveColorAdjustments(edit, snapshot: a)
        let stale = try await exporter.execute(stalePlan)
        try check(stale.failed.count == 1 && stale.written.isEmpty, "导出未冻结调整修订")
    }
}
