import Foundation
import GRDB
import JingXuCore

enum LegacyMigrationChecks {
    static func snapshot(_ url: URL) throws -> [String: [String]] {
        var config = Configuration(); config.readonly = true
        let reader = try DatabaseQueue(path: url.path, configuration: config)
        defer { try? reader.close() }
        return try reader.read { db in
            var result: [String: [String]] = [:]
            for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT IN ('colorEdits','colorPresets')") {
                let quote: (String) -> String = { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                let fields = try db.columns(in: table).map { "quote(\(quote($0.name)))" }.joined(separator: ",")
                result[table] = try String.fetchAll(db, sql: "SELECT json_array(\(fields)) FROM \(quote(table))").sorted()
            }
            return result
        }
    }

    static func verifyCopy(_ url: URL) async throws {
        let before = try snapshot(url)
        let coordinator = CatalogUpgradeCoordinator(databaseURL: url)
        let store = try await coordinator.open()
        try ColorChecks.check(try snapshot(url) == before, "迁移改变了原始记录")
        _ = try await store.assets(BrowseQuery())
        let backups = try FileManager.default.contentsOfDirectory(at: CatalogUpgradeCoordinator.backupDirectory(for: url), includingPropertiesForKeys: nil)
        try ColorChecks.check(!backups.isEmpty, "缺少迁移备份")
        var config = Configuration(); config.readonly = true
        let db = try DatabaseQueue(path: url.path, configuration: config)
        try await db.read { db in
            try ColorChecks.check(try db.tableExists("colorEdits") && db.tableExists("colorPresets"), "未创建调色表")
            try ColorChecks.check(try Int.fetchOne(db, sql: "PRAGMA application_id") == CatalogUpgradeCoordinator.applicationID, "新标识缺失")
        }
        try db.close()
    }

    static func fixture(_ url: URL) async throws {
        do {
            let store = try CatalogStore(databaseURL: url)
            try await store.saveAlbum(Album(id: "legacy-album", name: "旧相册"))
        }
        let db = try DatabaseQueue(path: url.path)
        try await db.write { db in
            try db.execute(sql: "DROP TABLE colorEdits; DROP TABLE colorPresets; PRAGMA application_id = 0; PRAGMA user_version = 0; CREATE TABLE grdb_migrations(identifier TEXT NOT NULL PRIMARY KEY)")
            for id in ["v1-create-catalog", "v2-file-identity-index", "v3-source-directory-identity", "v4-quality-assessment"] {
                try db.execute(sql: "INSERT INTO grdb_migrations VALUES (?)", arguments: [id])
            }
        }
        try db.close()
    }

    static func run() async throws {
        let root = try ColorChecks.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Catalog.sqlite")
        try await fixture(url)
        let archive = Data("{\"groups\":[]}".utf8)
        try archive.write(to: root.appendingPathComponent("archive.json"))
        // A read-only connection remains open while committed WAL data is backed up.
        let writer = try DatabaseQueue(path: url.path)
        try await writer.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO albums VALUES ('wal-album','WAL',0,0)")
        }
        try await verifyCopy(url)
        try writer.close()
        try ColorChecks.check(try Data(contentsOf: root.appendingPathComponent("archive.json")) == archive, "改变了归档日志")
        let backup = try FileManager.default.contentsOfDirectory(at: CatalogUpgradeCoordinator.backupDirectory(for: url), includingPropertiesForKeys: nil).first!
        try ColorChecks.check(try snapshot(backup.appendingPathComponent("Catalog.sqlite")) == snapshot(url), "备份遗漏 WAL 数据")
        let coordinator = CatalogUpgradeCoordinator(databaseURL: url)
        try await coordinator.restore(from: backup)
        try ColorChecks.check(try snapshot(url) == snapshot(backup.appendingPathComponent("Catalog.sqlite")), "恢复改变记录")
        _ = try await coordinator.open()
        // Backup failure must not convert schema or rows.
        let blockedRoot = root.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
        let blocked = blockedRoot.appendingPathComponent("Catalog.sqlite")
        try await fixture(blocked)
        try Data().write(to: blockedRoot.appendingPathComponent("Backups"))
        let before = try snapshot(blocked)
        do { _ = try CatalogStore(databaseURL: blocked); throw ColorChecks.Failure(description: "备份失败仍迁移") } catch is CatalogUpgradeError {}
        try ColorChecks.check(try snapshot(blocked) == before, "备份失败后原库变化")
    }
}
