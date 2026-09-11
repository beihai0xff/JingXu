import Foundation
import GRDB
import JingXuCore

enum ScanChecks {
    private actor Counter {
        var count = 0
        func increment() { count += 1 }
    }
    private struct Metadata: MetadataExtractor {
        var counter: Counter? = nil
        var cancel = false
        func extract(from url: URL, kind: MediaKind) async -> ExtractedMetadata {
            await counter?.increment()
            if cancel { withUnsafeCurrentTask { $0?.cancel() } }
            return ExtractedMetadata(width: 10, height: 10, errorMessage: url.lastPathComponent == "bad.jpg" ? "无法解析测试文件" : nil)
        }
    }
    static func run() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: photos.path) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        var source = SourceRoot(name: "photos", bookmarkData: nil, pathHint: photos.path)
        let oldDate = Date(timeIntervalSince1970: 1234); source.lastScanAt = oldDate
        try await store.upsertSource(source)
        for name in ["good.jpg", "bad.jpg", "gone.jpg", "notes.txt"] { try Data(name.utf8).write(to: photos.appendingPathComponent(name)) }
        let denied = photos.appendingPathComponent("denied")
        try FileManager.default.createDirectory(at: denied, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: denied.appendingPathComponent("hidden.jpg"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        let scanner = DefaultSourceScanner(repository: store, metadataExtractor: Metadata())
        let partial = try await scanner.scan(source: source) { progress in
            if progress.currentFile == "gone.jpg" { try? FileManager.default.removeItem(at: photos.appendingPathComponent("gone.jpg")) }
        }
        try ColorChecks.check(partial.assetIDs.count == 2 && partial.failedFiles == 2 && partial.failedDirectories == 1 && partial.skippedFiles == 1, "部分扫描数量或权限诊断错误：\(partial)")
        try ColorChecks.check(Set(partial.failures.map(\.stage)) == [.directory, .file, .metadata], "扫描丢失失败阶段")
        try ColorChecks.check(try await store.source(id: source.id)?.lastScanAt == oldDate, "部分失败推进了完整扫描时间")
        try ColorChecks.check(try await store.source(id: source.id)?.isOnline == true, "子目录权限错误被标记离线")
        // Failed metadata must remain visible on an unchanged rescan.
        let again = try await scanner.scan(source: source)
        try ColorChecks.check(again.isPartial && again.failedFiles == 1 && again.unchangedFiles == 1, "重新扫描隐藏了已有解析错误")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
        try FileManager.default.removeItem(at: photos.appendingPathComponent("bad.jpg"))
        let complete = try await scanner.scan(source: source)
        try ColorChecks.check(!complete.isPartial && complete.unchangedFiles == 1, "可读照片没有继续索引")
        try ColorChecks.check(try await store.source(id: source.id)?.lastScanAt != oldDate, "完整扫描未更新时间")

        let before = try await store.source(id: source.id)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: photos.path)
        do {
            _ = try await scanner.scan(source: source)
            throw ColorChecks.Failure(description: "不可读根目录被报告扫描成功")
        } catch let failure as ColorChecks.Failure {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: photos.path)
            throw failure
        } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: photos.path)
        try ColorChecks.check(try await store.source(id: source.id) == before, "根目录权限失败修改来源状态")

        // Complete counts with bounded details.
        var locked: [URL] = []
        defer { for url in locked { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path) } }
        for i in 0..<35 {
            let url = photos.appendingPathComponent("locked-\(i)")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            locked.append(url)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        }
        let limited = try await scanner.scan(source: source)
        try ColorChecks.check(limited.failedDirectories == 35 && limited.failures.count == 30, "失败总数被详情上限截断")

        let emptyRoot = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        let emptySource = SourceRoot(name: "empty", bookmarkData: nil, pathHint: emptyRoot.path)
        try await store.upsertSource(emptySource)
        let empty = try await scanner.scan(source: emptySource)
        try ColorChecks.check(!empty.isPartial && empty.discoveredFiles == 0, "空目录被误报失败")
        try FileManager.default.removeItem(at: emptyRoot)
        do { _ = try await scanner.scan(source: emptySource); throw ColorChecks.Failure(description: "已消失根目录仍报告成功") }
        catch is CocoaError {}
        try ColorChecks.check(try await store.source(id: emptySource.id)?.isOnline == false, "已确认不存在的根目录没有标记离线")

        let batches = root.appendingPathComponent("batches")
        try FileManager.default.createDirectory(at: batches, withIntermediateDirectories: true)
        for i in 0..<401 { try Data("test".utf8).write(to: batches.appendingPathComponent(String(format: "%04d.jpg", i))) }
        let batchSource = SourceRoot(name: "batches", bookmarkData: nil, pathHint: batches.path)
        try await store.upsertSource(batchSource)
        let counter = Counter()
        let batchScanner = DefaultSourceScanner(repository: store, metadataExtractor: Metadata(counter: counter))
        let db = try DatabaseQueue(path: root.appendingPathComponent("Catalog.sqlite").path)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_batch BEFORE INSERT ON mediaAssets WHEN NEW.relativePath = '0200.jpg' BEGIN SELECT RAISE(ABORT, 'injected batch failure'); END") }
        do { _ = try await batchScanner.scan(source: batchSource); throw ColorChecks.Failure(description: "数据库失败没有停止扫描") }
        catch is DatabaseError {}
        try ColorChecks.check(await counter.count == 400, "数据库失败后仍继续解析后续文件")
        try ColorChecks.check(try await store.assets(sourceID: batchSource.id).count == 200, "失败批次未回滚或已提交批次丢失")
        try ColorChecks.check(try await store.source(id: batchSource.id)?.lastScanAt == nil, "失败批次推进扫描时间")
        try await db.write { try $0.execute(sql: "DROP TRIGGER fail_batch") }
        let cancelTask = Task {
            try await batchScanner.scan(source: batchSource) { progress in
                if progress.processed == 200 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { _ = try await cancelTask.value; throw ColorChecks.Failure(description: "扫描取消没有传播") } catch is CancellationError {}
        try ColorChecks.check(try await store.assets(sourceID: batchSource.id).count == 200, "取消提交了尚未完成的批次")
        let cancelMetadata = Task { try await DefaultSourceScanner(repository: store, metadataExtractor: Metadata(cancel: true)).scan(source: batchSource) }
        do { _ = try await cancelMetadata.value; throw ColorChecks.Failure(description: "元数据解析取消没有传播") } catch is CancellationError {}
        try ColorChecks.check(try await store.assets(sourceID: batchSource.id).count == 200, "解析取消后继续提交")
        let cancelledBeforeScan = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await batchScanner.scan(source: batchSource)
        }
        do { _ = try await cancelledBeforeScan.value; throw ColorChecks.Failure(description: "开始前取消被忽略") } catch is CancellationError {}
        let finished = try await batchScanner.scan(source: batchSource)
        try ColorChecks.check(!finished.isPartial && finished.assetIDs.count == 201 && finished.unchangedFiles == 200, "重试没有保留并复用已提交记录")
    }
}
