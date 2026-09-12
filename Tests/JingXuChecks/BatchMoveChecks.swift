import Foundation
import JingXuCore

enum BatchMoveChecks {
    static func run() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("BatchMove-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let origin = root.appendingPathComponent("origin")
        let target = root.appendingPathComponent("target")
        for url in [origin, target] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("catalog.sqlite"))
        let source = SourceRoot(name: "origin", bookmarkData: nil, pathHint: origin.path)
        try await store.upsertSource(source)
        var ids = Set<String>()
        for name in ["one.jpg", "pair.arw", "pair.jpg", "keep.jpg"] {
            let file = origin.appendingPathComponent(name)
            try Data(name.utf8).write(to: file)
            let fp = try AnalysisFingerprint(url: file)
            let asset = MediaAsset(sourceID: source.id, relativePath: name, fileIdentifier: fp.identifier,
                                   fileName: name, uniformType: nil, kind: .photo, fileSize: fp.size, modifiedAt: fp.modifiedAt)
            _ = try await store.upsertAsset(asset)
            if name != "keep.jpg" { ids.insert(asset.id) }
        }
        try Data("xmp".utf8).write(to: origin.appendingPathComponent("one.xmp"))
        try Data("occupied".utf8).write(to: target.appendingPathComponent("pair.jpg"))
        let one = try await store.assets(sourceID: source.id).first { $0.fileName == "one.jpg" }!
        var annotation = try await store.annotation(for: one.id)
        annotation.rating = 5; annotation.keywords = ["preserve"]
        try await store.seedAnnotation(annotation)
        let coordinator = ArchiveCoordinator(store: store, journalURL: root.appendingPathComponent("archive.json"))
        let pair = try await store.assets(sourceID: source.id).first { $0.fileName == "pair.arw" }!
        let partial = try await coordinator.prepare(selectedIDs: [pair.id], destination: target)
        try ArchiveChecks.check(partial.count == 0 && !partial.warnings.isEmpty)
        let plan = try await coordinator.prepare(selectedIDs: ids, destination: target)
        try ArchiveChecks.check(plan.count == 4)
        try ArchiveChecks.check(try await store.sources().count == 1) // Planning is read-only.
        let result = try await coordinator.execute(plan, backupURL: root.appendingPathComponent("backup.sqlite"))
        try ArchiveChecks.check(result.completed == 4 && result.warnings.isEmpty)
        let moved = try await store.asset(id: one.id)!
        try ArchiveChecks.check(moved.sourceID != source.id && moved.relativePath == "one.jpg")
        try ArchiveChecks.check(try await store.annotation(for: one.id).keywords == ["preserve"])
        try ArchiveChecks.check(try Data(contentsOf: target.appendingPathComponent("pair.jpg")) == Data("occupied".utf8))
        try ArchiveChecks.check(fm.fileExists(atPath: target.appendingPathComponent("pair-1.arw").path))
        try ArchiveChecks.check(fm.fileExists(atPath: origin.appendingPathComponent("keep.jpg").path))
        let undo = try await coordinator.resume(undo: true)
        try ArchiveChecks.check(undo.completed == 4 && undo.warnings.isEmpty)
        try ArchiveChecks.check(try await store.asset(id: one.id)?.sourceID == source.id)
        // A moved file before DB commit is recovered without moving it twice.
        var interrupted = try await coordinator.prepare(selectedIDs: [one.id], destination: target)
        let group = interrupted.groups[0]
        for file in group.files { try SameVolumeArchiveMover().move(origin.appendingPathComponent(file.from), target.appendingPathComponent(file.to)) }
        interrupted.groups[0].state = "moving"
        try JSONEncoder().encode(interrupted).write(to: root.appendingPathComponent("archive.json"))
        try await coordinator.reconcile()
        try ArchiveChecks.check(try await store.asset(id: one.id)?.sourceID == moved.sourceID)
        try ArchiveChecks.check(try await coordinator.hasPending() == false)
        // Reuse an existing source for its subdirectory; no child source registration.
        let subdirectory = origin.appendingPathComponent("selected")
        try fm.createDirectory(at: subdirectory, withIntermediateDirectories: true)
        let within = try await coordinator.prepare(selectedIDs: [pair.id, try await store.assets(sourceID: source.id).first { $0.fileName == "pair.jpg" }!.id], destination: subdirectory)
        try ArchiveChecks.check(within.groups.first?.destination?.id == source.id)
        try ArchiveChecks.check(within.groups.flatMap(\.files).allSatisfy { $0.to.hasPrefix("selected/") })
        let withinResult = try await coordinator.execute(within, backupURL: root.appendingPathComponent("within-backup.sqlite"))
        try ArchiveChecks.check(withinResult.completed == 2 && withinResult.warnings.isEmpty)
        let folderID = CatalogFolderID(sourceID: source.id, relativeDirectory: "selected")
        let movedTree = try await store.folderTree()
        try ArchiveChecks.check(movedTree.first { $0.id.sourceID == source.id }?.node(folderID)?.directCount == 2)
        try ArchiveChecks.check(try await store.assets(BrowseQuery(sourceID: source.id, relativeDirectory: "selected")).count == 2)
        let withinUndo = try await coordinator.resume(undo: true)
        try ArchiveChecks.check(withinUndo.completed == 2 && withinUndo.warnings.isEmpty)
        let undoneTree = try await store.folderTree()
        try ArchiveChecks.check(undoneTree.first { $0.id.sourceID == source.id }?.node(folderID) == nil)
        try ArchiveChecks.check(fm.fileExists(atPath: subdirectory.path)) // Empty on-disk folders remain untouched.
        let failing = ArchiveCoordinator(store: store, journalURL: root.appendingPathComponent("failure.json"), mover: ArchiveChecks.FailingMover())
        let back = try await coordinator.prepare(selectedIDs: [one.id], destination: origin)
        let rolledBack = try await failing.execute(back, backupURL: root.appendingPathComponent("failure-backup.sqlite"))
        try ArchiveChecks.check(!rolledBack.warnings.isEmpty)
        try ArchiveChecks.check(fm.fileExists(atPath: target.appendingPathComponent("one.jpg").path))
        try ArchiveChecks.check(try await store.asset(id: one.id)?.sourceID == moved.sourceID)
    }
}
