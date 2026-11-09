import Foundation
import JingXuCore

enum OptimizationSafetyChecks {
    final class Fault: @unchecked Sendable {
        private let lock = NSLock()
        private var active = false
        func enable() { lock.withLock { active = true } }
        func probe(_ url: URL) throws -> FilePresence {
            if lock.withLock({ active }) && url.lastPathComponent == "a.png" { throw POSIXError(.EACCES) }
            return try FilePresenceReader.read(url)
        }
    }
    struct InterruptedMover: ArchiveMover {
        let fault: Fault
        func move(_ from: URL, _ to: URL) throws {
            try SameVolumeArchiveMover().move(from, to)
            fault.enable()
            throw POSIXError(.EIO)
        }
    }
    actor Counter {
        var ids: [String] = []
        func record(_ id: String) { ids.append(id) }
    }
    static func run() async throws {
        try await archive()
        try await export()
    }
    static func archive() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("absent"))
        try ColorChecks.check(try FilePresenceReader.read(link) == .present, "悬空链接必须占用目标")
        try ColorChecks.check(try FilePresenceReader.read(root.appendingPathComponent("missing/child")) == .missing, "计划中的缺失目录无法探测")
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("db.sqlite"))
        let source = SourceRoot(name: "photos", bookmarkData: nil, pathHint: photos.path)
        try await store.upsertSource(source)
        let snapshot = try await ColorChecks.fixture(store: store, source: source, name: "a.png")
        let journal = root.appendingPathComponent("archive.json")
        let normal = ArchiveCoordinator(store: store, journalURL: journal, dateReader: { _ in "2024/2024-01-01" })
        let plan = try await normal.prepare()
        let denied = ArchiveCoordinator(store: store, journalURL: journal, presence: { url in
            if url.path.contains("2024") { throw POSIXError(.EACCES) }
            return try FilePresenceReader.read(url)
        }, dateReader: { _ in "2024/2024-01-01" })
        let deniedPlan = try await denied.prepare()
        try ColorChecks.check(deniedPlan.count == 0 && !deniedPlan.warnings.isEmpty, "计划探测失败误认为缺失")
        let skipped = try await denied.execute(plan, backupURL: root.appendingPathComponent("before.sqlite"))
        try ColorChecks.check(skipped.completed == 0 && !skipped.warnings.isEmpty, "执行前无法确认仍执行移动")
        try ColorChecks.check(try await store.asset(id: snapshot.asset.id)?.relativePath == "a.png", "跳过修改了数据库")
        let fault = Fault()
        let interrupted = ArchiveCoordinator(store: store, journalURL: journal, mover: InterruptedMover(fault: fault),
                                             presence: fault.probe, dateReader: { _ in "2024/2024-01-01" })
        let stopped = try await interrupted.execute(plan, backupURL: root.appendingPathComponent("after.sqlite"))
        try ColorChecks.check(stopped.completed == 0 && !stopped.warnings.isEmpty, "移动后状态不明未暂停")
        let saved = try JSONDecoder().decode(ArchivePlan.self, from: Data(contentsOf: journal))
        try ColorChecks.check(saved.groups[0].state == "moving", "未知位置时改变了恢复方向")
        try ColorChecks.check(try await store.asset(id: snapshot.asset.id)?.relativePath == "a.png", "未知状态提交了数据库")
        try await interrupted.reconcile()
        try ColorChecks.check(try await interrupted.hasPending(), "恢复把权限错误当成来源已不存在")
        try await normal.reconcile()
        try ColorChecks.check(try await store.asset(id: snapshot.asset.id)?.relativePath == plan.groups[0].files[0].to, "恢复授权后无法对账")
        let blockedUndo = try await interrupted.resume(undo: true)
        try ColorChecks.check(blockedUndo.completed == 0, "无法确认撤销目标时仍移动")
        _ = try await normal.resume(undo: true)
        try ColorChecks.check(try await store.asset(id: snapshot.asset.id)?.relativePath == "a.png", "正常撤销失败")
    }
    static func export() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("db.sqlite"))
        let source = SourceRoot(name: "source", bookmarkData: nil, pathHint: root.path)
        try await store.upsertSource(source)
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let records = try (0..<2001).map { index in
            try Data("occupied".utf8).write(to: output.appendingPathComponent("\(index)-调色.png"))
            return MediaAsset(id: "\(index)", sourceID: source.id, relativePath: "\(index).png", fileIdentifier: nil,
                fileName: "\(index).png", uniformType: nil, kind: .photo, fileSize: 0, modifiedAt: Date())
        }
        try await store.upsertAssets(records)
        let counter = Counter()
        let exporter = ColorExportCoordinator(store: store, preflight: { snapshot, _ in await counter.record(snapshot.asset.id) })
        let plan = try await exporter.prepare(assetIDs: records.map(\.id), directory: output, format: .png)
        let occupiedDecodes = await counter.ids
        try ColorChecks.check(plan.items.isEmpty && plan.skipped.count == 2001 && occupiedDecodes.isEmpty, "已占用的 2001 项仍进行解码")
        try ColorChecks.check(try Data(contentsOf: output.appendingPathComponent("0-调色.png")) == Data("occupied".utf8), "预检改变目标")
        let duplicates = ["bad", "good", "later"].enumerated().map { index, name in
            MediaAsset(id: "duplicate-\(index)", sourceID: source.id, relativePath: name + "/same.png", fileIdentifier: nil,
                fileName: "same.png", uniformType: nil, kind: .photo, fileSize: 0, modifiedAt: Date())
        }
        try await store.upsertAssets(duplicates)
        let collision = ColorExportCoordinator(store: store, preflight: { snapshot, _ in
            await counter.record(snapshot.asset.id)
            if snapshot.asset.id == "duplicate-0" { throw CocoaError(.fileReadCorruptFile) }
        })
        let candidates = try await collision.prepare(assetIDs: duplicates.map(\.id), directory: output, format: .png)
        try ColorChecks.check(candidates.items.map(\.id) == ["duplicate-1"] && candidates.skipped.count == 2, "失败候选占用了重名目标")
        try ColorChecks.check(await counter.ids == ["duplicate-0", "duplicate-1"], "重名项仍解码")
        let inaccessible = ColorExportCoordinator(store: store, preflight: { snapshot, _ in await counter.record(snapshot.asset.id) },
            presence: { _ in throw POSIXError(.EIO) })
        let unknown = try await inaccessible.prepare(assetIDs: ["duplicate-1"], directory: output, format: .png)
        let finalDecodes = await counter.ids
        try ColorChecks.check(unknown.items.isEmpty && unknown.skipped.count == 1 && finalDecodes.count == 2, "I/O 错误未提前跳过")
        var invalidName = duplicates[2]; invalidName.fileName = "../invalid.png"
        try await store.upsertAsset(invalidName)
        let invalid = try await collision.prepare(assetIDs: [invalidName.id], directory: output, format: .png)
        let afterInvalid = await counter.ids
        try ColorChecks.check(invalid.items.isEmpty && invalid.skipped.count == 1 && afterInvalid == finalDecodes, "无效输出名仍解码")
    }
}
