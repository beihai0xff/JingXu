import Foundation
import GRDB
import JingXuCore

enum CatalogFormatChecks {
    static func run() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        for version in [0, 99] {
            let url = root.appendingPathComponent("old-\(version).sqlite")
            let db = try DatabaseQueue(path: url.path)
            try await db.write { db in
                try db.execute(sql: "CREATE TABLE user_data(value TEXT); INSERT INTO user_data VALUES ('preserve'); PRAGMA user_version = \(version)")
                if version == 0 { try db.execute(sql: "CREATE TABLE grdb_migrations(identifier TEXT); INSERT INTO grdb_migrations VALUES ('v4-quality-assessment')") }
            }
            try db.close()
            let before = try FileHasher.sha256(of: url)
            do { _ = try CatalogStore(databaseURL: url); throw ColorChecks.Failure(description: "旧格式或未来格式图库被打开") } catch is CatalogUpgradeError {}
            try ColorChecks.check(try FileHasher.sha256(of: url) == before, "拒绝旧图库时修改了原数据库")
        }
        let missing = root.appendingPathComponent("missing.sqlite")
        try Data().write(to: missing.appendingPathExtension("initialized"))
        do { _ = try CatalogStore(databaseURL: missing); throw ColorChecks.Failure(description: "丢失数据库被空库替换") } catch is CatalogUpgradeError {}
        try ColorChecks.check(!FileManager.default.fileExists(atPath: missing.path), "创建了替代空库")
        let lockURL = root.appendingPathComponent("locked.sqlite")
        let lease = try CatalogLease(databaseURL: lockURL)
        do { _ = try CatalogLease(databaseURL: lockURL); throw ColorChecks.Failure(description: "双实例同时取得图库锁") } catch is CatalogUpgradeError {}
        withExtendedLifetime(lease) {}
        let catalog = root.appendingPathComponent("Catalog.sqlite")
        let backup = root.appendingPathComponent("backup")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        do {
            let store = try CatalogStore(databaseURL: catalog)
            try await store.saveAlbum(Album(id: "keep", name: "保留相册"))
            try await store.backup(to: backup.appendingPathComponent("Catalog.sqlite"))
            try await store.saveAlbum(Album(id: "later", name: "备份后相册"))
        }
        let db = try DatabaseQueue(path: catalog.path)
        let hasHistory = try await db.read { try $0.tableExists("grdb_migrations") }
        try ColorChecks.check(!hasHistory, "新库仍保留历史迁移链")
        try db.close()
        let manifest: [String: Any] = ["databasePath": catalog.path, "migrations": [], "targetVersion": "test",
            "createdAt": Date().timeIntervalSinceReferenceDate, "databaseHash": try FileHasher.sha256(of: backup.appendingPathComponent("Catalog.sqlite"))]
        try JSONSerialization.data(withJSONObject: manifest).write(to: backup.appendingPathComponent("manifest.json"))
        let preserved = root.appendingPathComponent("Backups/interrupted")
        try FileManager.default.createDirectory(at: preserved, withIntermediateDirectories: true)
        try JSONEncoder().encode(["backup": backup.path, "preserved": preserved.path]).write(to: root.appendingPathComponent("restore-state.json"))
        do { _ = try CatalogStore(databaseURL: catalog); throw ColorChecks.Failure(description: "恢复尚未完成就打开图库") } catch is CatalogUpgradeError {}
        let coordinator = CatalogUpgradeCoordinator(databaseURL: catalog)
        try await coordinator.restore(from: backup)
        let restored = try await coordinator.open()
        try ColorChecks.check(try await restored.albums().map(\.id) == ["keep"], "恢复没有保留备份相册")
        try ColorChecks.check(FileManager.default.fileExists(atPath: preserved.appendingPathComponent("Catalog.sqlite").path), "恢复没有保全当前数据库")
    }
}
