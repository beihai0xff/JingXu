import Foundation
import JingXuCore
import GRDB

@MainActor enum ImportChecks {
    private struct Metadata: MetadataExtractor {
        func extract(from url: URL, kind: MediaKind) async -> ExtractedMetadata { .init(width: 32, height: 24) }
    }
    private struct Fixture {
        let root: URL, card: URL, target: URL
        let store: CatalogStore
        var importer: ImportCoordinator { ImportCoordinator(repository: store, scanner: DefaultSourceScanner(repository: store, metadataExtractor: Metadata())) }
        init() throws {
            root = try ColorChecks.root(); card = root.appendingPathComponent("card"); target = root.appendingPathComponent("target")
            try FileManager.default.createDirectory(at: card, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        }
        func write(_ path: String, _ bytes: String) throws {
            let url = card.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(bytes.utf8).write(to: url, options: .atomic)
        }
        func prepare() async throws -> ImportPlan { try await importer.prepare(from: card, to: target, batchName: "检查") }
    }
    static func groupingAndRetry() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("a/IMG.JPG", "earlier")
        try f.write("b/IMG.JPG", "jpeg"); try f.write("b/IMG.ARW", "raw")
        try f.write("b/IMG.MOV", "video"); try f.write("b/IMG.xmp", "shared"); try f.write("b/IMG.ARW.xmp", "explicit")
        let plan = try await f.prepare()
        try ColorChecks.check(!FileManager.default.fileExists(atPath: plan.destination.path), "预检创建了输出目录")
        let result = try await f.importer.execute(plan)
        try ColorChecks.check(result.outcome == .completed && result.session.completedFiles == 6, "配对及 XMP 未完整复制")
        for name in ["IMG-2.JPG", "IMG-2.ARW", "IMG-2.xmp", "IMG-2.ARW.xmp"] {
            try ColorChecks.check(FileManager.default.fileExists(atPath: result.destination.appendingPathComponent(name).path), "照片组后缀不一致")
        }
        try ColorChecks.check(FileManager.default.fileExists(atPath: result.destination.appendingPathComponent("IMG-3.MOV").path), "同主名视频没有独立复制")
        let second = try await f.importer.execute(try await f.prepare())
        try ColorChecks.check(second.session.skippedFiles == 6 && second.session.completedFiles == 0, "避让后重复导入产生副本")
        // A hole before a later duplicate must not hide the duplicate.
        try FileManager.default.moveItem(at: result.destination.appendingPathComponent("IMG.JPG"), to: result.destination.appendingPathComponent("IMG-4.JPG"))
        let hole = try await f.prepare()
        try ColorChecks.check(hole.duplicateFiles == 6 && hole.bytesToCopy == 0, "空闲原名掩盖了后面的重复组")
        let retry = try await f.importer.prepareRetry(result)
        try ColorChecks.check(retry.destination == result.destination, "重试改变了目标批次目录")
        try ColorChecks.check(try String(contentsOf: f.card.appendingPathComponent("b/IMG.ARW"), encoding: .utf8) == "raw", "导入改写原照片")
        let latest = try await f.store.latestImportReport()
        try ColorChecks.check(latest?.session.id == second.id && latest?.outcome == .completed, "导入结果未持久化")
    }
    static func failuresAndRecovery() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("visible.jpg", "visible"); try f.write("denied/missed.jpg", "missed")
        let denied = f.card.appendingPathComponent("denied")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path) }
        let partial = try await f.importer.execute(try await f.prepare())
        try ColorChecks.check(partial.outcome == .partial && partial.session.completedFiles == 1 && partial.plan.issues.contains(where: { $0.stage == .directory }), "不可读目录被记为完整成功")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: denied.path)
        let recovered = try await f.importer.execute(try await f.importer.prepareRetry(partial))
        try ColorChecks.check(recovered.session.completedFiles == 1 && recovered.session.skippedFiles == 1 && recovered.outcome == .completed, "恢复权限后重试未补齐")
        try f.write("ambiguous/IMG.ARW", "raw"); try f.write("ambiguous/IMG.JPG", "jpeg"); try f.write("ambiguous/IMG.PNG", "png")
        let ambiguous = try await f.prepare()
        try ColorChecks.check(ambiguous.issues.contains(where: { $0.stage == .grouping }) && !ambiguous.groups.contains(where: { $0.id.contains("ambiguous") }), "模糊配对未跳过整组")
        let lowSpace = ImportCoordinator(repository: f.store, scanner: DefaultSourceScanner(repository: f.store), capacity: { _ in 0 })
        do { _ = try await lowSpace.prepare(from: f.card, to: f.target, batchName: "space"); throw ColorChecks.Failure(description: "容量不足未拒绝") }
        catch is CocoaError {}
        for target in [f.card, f.card.appendingPathComponent("denied")] {
            do { _ = try await f.importer.prepare(from: f.card, to: target, batchName: "invalid"); throw ColorChecks.Failure(description: "允许来源目标重叠") }
            catch is ColorEditError {}
        }
        let interrupted = ImportReportForChecks.running(partial)
        try await f.store.saveImportReport(interrupted)
        try await f.store.recoverImportJobs()
        try ColorChecks.check(try await f.store.latestImportReport()?.outcome == .interrupted, "重启后未标记导入中断")
    }
    static func changedFilesAndCommit() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try f.write("IMG.ARW", "raw"); try f.write("IMG.JPG", "jpeg")
        let original = try await f.prepare()
        try f.write("IMG.ARW", "replacement")
        let replaced = try await f.importer.execute(original)
        try ColorChecks.check(replaced.session.completedFiles == 0 && replaced.outcome == .failed, "确认后替换仍复制")
        let plan = try await f.prepare()
        let failing = ImportCoordinator(repository: f.store, scanner: DefaultSourceScanner(repository: f.store, metadataExtractor: Metadata()), beforeCommit: { url in
            if url.pathExtension == "JPG" { throw CocoaError(.fileWriteNoPermission) }
        })
        let interrupted = try await failing.execute(plan)
        try ColorChecks.check(interrupted.session.completedFiles == 1 && interrupted.session.failedFiles == 1 && interrupted.outcome == .partial, "部分提交记录不准确")
        let retry = try await f.importer.execute(try await f.importer.prepareRetry(interrupted))
        try ColorChecks.check(retry.session.completedFiles == 1 && retry.session.skippedFiles == 1, "部分组重试生成重复文件")
        let cancelPlan = try await f.prepare()
        let cancelled = try await Task {
            try await f.importer.execute(cancelPlan) { _ in withUnsafeCurrentTask { $0?.cancel() } }
        }.value
        try ColorChecks.check(cancelled.outcome == .cancelled && cancelled.session.completedFiles == 0, "复制开始前取消未生效")
        try f.write("new.jpg", "new")
        let disappeared = try await f.prepare()
        try FileManager.default.removeItem(at: f.card.appendingPathComponent("new.jpg"))
        let gone = try await f.importer.execute(disappeared)
        try ColorChecks.check(gone.session.failedFiles == 1 && gone.issues.contains(where: { $0.stage == .copy }), "消失文件没有失败记录")
        try f.write("new.jpg", "new")
        let collision = try await f.prepare()
        let competing = ImportCoordinator(repository: f.store, scanner: DefaultSourceScanner(repository: f.store, metadataExtractor: Metadata()), beforeCommit: { url in
            if url.lastPathComponent == "new.jpg" { try Data("external".utf8).write(to: url) }
        })
        let conflict = try await competing.execute(collision)
        try ColorChecks.check(conflict.session.failedFiles == 1 && (try String(contentsOf: conflict.destination.appendingPathComponent("new.jpg"), encoding: .utf8)) == "external", "提交覆盖了竞争文件")
        let link = f.card.appendingPathComponent("link.jpg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: f.card.appendingPathComponent("IMG.JPG"))
        try ColorChecks.check(try await f.prepare().issues.contains(where: { $0.path == "link.jpg" }), "符号链接未报告")
        let db = try DatabaseQueue(path: f.root.appendingPathComponent("Catalog.sqlite").path)
        try await db.write { db in try db.execute(sql: "CREATE TRIGGER fail_import BEFORE INSERT ON importSessions BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        let before = try FileManager.default.contentsOfDirectory(atPath: conflict.destination.path).sorted()
        do { _ = try await f.importer.execute(try await f.prepare()); throw ColorChecks.Failure(description: "数据库失败仍执行") }
        catch is DatabaseError {}
        try ColorChecks.check(try FileManager.default.contentsOfDirectory(atPath: conflict.destination.path).sorted() == before, "日志写入失败后仍改变输出")
    }
    static func completeRange() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        for i in 0..<2001 { try f.write("photo-\(i).jpg", "synthetic-\(i)") }
        let result = try await f.importer.execute(try await f.prepare())
        try ColorChecks.check(result.session.completedFiles == 2001 && result.scanReport?.assetIDs.count == 2001, "导入被界面 2000 项限制截断")
        let retry = try await f.importer.prepareRetry(result)
        try ColorChecks.check(retry.duplicateFiles == 2001, "完整范围重复检测遗漏")
    }
}
private enum ImportReportForChecks {
    static func running(_ report: ImportReport) -> ImportReport {
        var report = report; report.outcome = .running; report.session.status = .running
        // Keep this job newest so latest-result recovery is exercised.
        report.session.createdAt = Date(); return report
    }
}
