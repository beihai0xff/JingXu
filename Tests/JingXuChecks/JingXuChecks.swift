import CoreGraphics
import Foundation
import ImageIO
import JingXuCore
import UniformTypeIdentifiers

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
        let checks: [(String, () async throws -> Void)] = [
            ("目录命名与清理", checkImportNaming),
            ("文件路径与 SHA-256", checkFileIdentityAndHash),
            ("目录持久化、筛选与标注", checkCatalog),
            ("稳定资源身份与相册", checkStableIdentityAndAlbum),
            ("XMP 编码", checkXMP),
            ("图像元数据与质量建议", checkMetadataAndQuality),
            ("增量扫描与 RAW/JPEG 配对", checkIncrementalScan),
            ("校验导入、重复跳过与不覆盖", checkSafeImport),
            ("删除范围、文件复核与中断恢复", checkDeletion),
            ("原图解码、方向、错误和取消", checkPreview),
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
        try require(reviewAssets.first?.issues == [.blurry], "待审核建议筛选失败")
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
        try require(result.issues.contains(.clippedHighlights), "未识别高光溢出")
        try require(result.issues.contains(.blurry), "未识别无细节图像")
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
