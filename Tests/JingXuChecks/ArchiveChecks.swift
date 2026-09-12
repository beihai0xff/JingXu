import Foundation
import JingXuCore

enum ArchiveChecks {
    struct Failure: Error { var line: Int = 0 }
    static func check(_ value: Bool, line: Int = #line) throws { if !value { throw Failure(line: line) } }
    struct FailingMover: ArchiveMover {
        func move(_ from: URL, _ to: URL) throws {
            if from.pathExtension == "xmp" { throw CocoaError(.fileWriteNoPermission) }
            try SameVolumeArchiveMover().move(from, to)
        }
    }
    static func run() async throws {
        try check(ArchiveDate.folder(exif: "2024:02:29 23:59:59") == "2024/2024-02-29")
        try check(ArchiveDate.folder(exif: "2023:02:29 23:59:59") == nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveChecks-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("catalog.sqlite"))
        let source = SourceRoot(name: "photos", bookmarkData: nil, pathHint: photos.path)
        try await store.upsertSource(source)
        var originals: [MediaAsset] = []
        for name in ["a.arw", "a.jpg", "movie.mov", "unknown.jpg"] {
            let url = photos.appendingPathComponent(name)
            try Data(name.utf8).write(to: url)
            let fp = try AnalysisFingerprint(url: url)
            let asset = MediaAsset(sourceID: source.id, relativePath: name, fileIdentifier: fp.identifier,
                                   fileName: name, uniformType: nil, kind: name.hasSuffix("mov") ? .video : .photo,
                                   fileSize: fp.size, modifiedAt: fp.modifiedAt, rawPairKey: "a")
            originals.append(try await store.upsertAsset(asset))
        }
        try Data("sidecar".utf8).write(to: photos.appendingPathComponent("a.xmp"))
        try Data("explicit".utf8).write(to: photos.appendingPathComponent("a.arw.xmp"))
        let occupied = photos.appendingPathComponent("2024/2024-02-29/a.arw")
        try FileManager.default.createDirectory(at: occupied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("existing target".utf8).write(to: occupied)
        var annotation = try await store.annotation(for: originals[0].id)
        annotation.rating = 5; annotation.flag = .rejected; annotation.keywords = ["保留关键词"]
        try await store.seedAnnotation(annotation)
        let album = Album(name: "归档前相册")
        try await store.saveAlbum(album)
        try await store.add(assetID: originals[0].id, toAlbum: album.id)
        let analysis = AnalysisResult(assetID: originals[0].id, sharpnessScore: 0.5,
                                      shadowClipping: 0.1, highlightClipping: 0.2, suggestionState: .ignored)
        try await store.saveAnalysis(analysis)
        let journal = root.appendingPathComponent("archive.json")
        let reader: @Sendable (URL) -> String? = { $0.lastPathComponent == "unknown.jpg" ? nil : "2024/2024-02-29" }
        let coordinator = ArchiveCoordinator(store: store, journalURL: journal, dateReader: reader)
        let plan = try await coordinator.prepare()
        try check(plan.count == 4 && plan.groups.count == 1)
        try check(plan.groups[0].files.allSatisfy { ($0.to as NSString).lastPathComponent.hasPrefix("a-1.") })
        // Backup failure must leave every original untouched.
        let backup = root.appendingPathComponent("backup.sqlite")
        try Data().write(to: backup)
        do { _ = try await coordinator.execute(plan, backupURL: backup); throw Failure() }
        catch is Failure { throw Failure() } catch {}
        try check(FileManager.default.fileExists(atPath: photos.appendingPathComponent("a.arw").path))
        let failed = ArchiveCoordinator(store: store, journalURL: journal, mover: FailingMover(), dateReader: reader)
        let failure = try await failed.execute(plan, backupURL: root.appendingPathComponent("backup2.sqlite"))
        try check(!failure.warnings.isEmpty)
        try check(FileManager.default.fileExists(atPath: photos.appendingPathComponent("a.arw").path))
        // A fresh coordinator represents a restart and resumes the durable plan.
        let report = try await coordinator.resume()
        try check(report.completed == 4)
        let moved = try await store.asset(id: originals[0].id)!
        try check(moved.relativePath == "2024/2024-02-29/a-1.arw")
        try check(try Data(contentsOf: occupied) == Data("existing target".utf8))
        try check(try FileHasher.sha256(of: photos.appendingPathComponent(moved.relativePath)) == plan.groups[0].files[0].hash)
        let kept = try await store.annotation(for: moved.id)
        try check(kept.rating == 5 && kept.flag == .rejected)
        try check(kept.keywords == ["保留关键词"])
        try check(try await store.assets(AssetQuery(albumID: album.id)).map(\.id) == [moved.id])
        try check(try await store.analysis(for: moved.id)?.suggestionState == .ignored)
        try check(abs(moved.importedAt.timeIntervalSince(originals[0].importedAt)) < 0.001)
        try check(FileManager.default.fileExists(atPath: photos.appendingPathComponent("movie.mov").path))
        try check(try await coordinator.prepare().count == 0)
        let undo = try await coordinator.resume(undo: true)
        try check(undo.completed == 4)
        try check(try await store.asset(id: moved.id)?.relativePath == "a.arw")
        // A replaced file is never moved, even after a plan was confirmed.
        let replacementPlan = try await coordinator.prepare()
        try Data("replacement".utf8).write(to: photos.appendingPathComponent("a.arw"), options: .atomic)
        let replaced = try await coordinator.execute(replacementPlan, backupURL: root.appendingPathComponent("backup3.sqlite"))
        try check(!replaced.warnings.isEmpty)
        try check(FileManager.default.fileExists(atPath: photos.appendingPathComponent("a.arw").path))
        // The primitive rejects existing targets without modifying either file.
        let from = photos.appendingPathComponent("unknown.jpg"), to = photos.appendingPathComponent("movie.mov")
        do { try SameVolumeArchiveMover().move(from, to); throw Failure() }
        catch is Failure { throw Failure() } catch {}
        try check(try Data(contentsOf: to) == Data("movie.mov".utf8))
    }

    static func scaleAndRecovery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ArchiveScale-\(UUID())")
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("db.sqlite"))
        let source = SourceRoot(name: "photos", bookmarkData: nil, pathHint: photos.path)
        try await store.upsertSource(source)
        var records: [MediaAsset] = []
        for i in 0..<2001 {
            let name = "\(i).jpg", file = photos.appendingPathComponent("\(i).jpg")
            try Data([UInt8(i % 255)]).write(to: file)
            let fp = try AnalysisFingerprint(url: file)
            records.append(MediaAsset(sourceID: source.id, relativePath: name, fileIdentifier: fp.identifier,
                                      fileName: name, uniformType: nil, kind: .photo, fileSize: fp.size, modifiedAt: fp.modifiedAt))
        }
        try await store.upsertAssets(records)
        let journal = root.appendingPathComponent("archive.json")
        let coordinator = ArchiveCoordinator(store: store, journalURL: journal, dateReader: { _ in "2020/2020-01-01" })
        var plan = try await coordinator.prepare()
        try check(plan.count == 2001)
        let confirmed = plan
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await coordinator.execute(confirmed, backupURL: root.appendingPathComponent("backup.sqlite"))
        }
        let report = try await cancelled.value
        let pending = try await coordinator.hasPending()
        try check(report.completed == 0 && pending)
        // Simulate process death after a rename and before the DB transaction.
        plan.groups = [plan.groups[0]]
        plan.groups[0].state = "moving"
        let file = plan.groups[0].files[0]
        let destination = photos.appendingPathComponent(file.to)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try SameVolumeArchiveMover().move(photos.appendingPathComponent(file.from), destination)
        try JSONEncoder().encode(plan).write(to: journal, options: .atomic)
        let recovered = try await coordinator.resume()
        try check(recovered.completed == 1)
        try check(try await store.asset(id: file.asset!.id)?.relativePath == file.to)
        // Occupied undo destination must never be replaced.
        try Data("foreign".utf8).write(to: photos.appendingPathComponent(file.from))
        let undo = try await coordinator.resume(undo: true)
        try check(!undo.warnings.isEmpty)
        try check(try Data(contentsOf: photos.appendingPathComponent(file.from)) == Data("foreign".utf8))
        try check(FileManager.default.fileExists(atPath: destination.path))
        let nested = photos.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try await store.upsertSource(SourceRoot(name: "nested", bookmarkData: nil, pathHint: nested.path))
        let overlap = try await coordinator.prepare()
        try check(overlap.count == 0 && !overlap.warnings.isEmpty)
    }
}
