import Foundation
import GRDB
import Darwin

/// One-way conversion of the verified 0.2.x v4 catalog. Never rebuilds asset rows.
enum LegacyCatalogMigration {
    static let history = ["v1-create-catalog", "v2-file-identity-index", "v3-source-directory-identity", "v4-quality-assessment"]

    static func upgrade(_ url: URL, reader: DatabaseQueue) throws {
        let expected = try DatabaseQueue()
        defer { try? expected.close() }
        try CatalogStore.createCurrentSchema(expected)
        let signatures = try expected.read { db in
            try Dictionary(uniqueKeysWithValues: tables(db).filter { !["colorEdits", "colorPresets"].contains($0) }.map { ($0, try columns(db, $0)) })
        }
        try reader.read { db in
            guard try Int.fetchOne(db, sql: "PRAGMA application_id") == 0,
                  try Int.fetchOne(db, sql: "PRAGMA user_version") == 0,
                  try db.tableExists("grdb_migrations"),
                  try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier") == history,
                  Set(try tables(db)) == Set(signatures.keys).union(["grdb_migrations"]),
                  try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master WHERE type = 'trigger'") == 0 else {
                throw CatalogUpgradeError.blocked("未识别的图库格式或旧迁移链。仅支持完整 v4 旧库转换；原库和日志未修改。")
            }
            for (table, signature) in signatures {
                guard try columns(db, table) == signature else {
                    throw CatalogUpgradeError.blocked("旧图库 \(table) 结构不匹配，已停止迁移。")
                }
            }
        }
        try CatalogUpgradeCoordinator.validate(reader)
        let parent = url.deletingLastPathComponent()
        let backup = CatalogUpgradeCoordinator.backupDirectory(for: url).appendingPathComponent("legacy-v4-\(UUID())")
        do {
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            let snapshot = backup.appendingPathComponent("Catalog.sqlite")
            let writer = try DatabaseQueue(path: snapshot.path)
            try reader.backup(to: writer)
            try writer.writeWithoutTransaction { try $0.execute(sql: "PRAGMA journal_mode = DELETE") }
            try CatalogUpgradeCoordinator.validate(writer)
            try writer.close()
            var manifest = UpgradeManifest(databasePath: url.standardizedFileURL.path, migrations: history,
                targetVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
                createdAt: Date(), databaseHash: try FileHasher.sha256(of: snapshot))
            for name in ["deletions.json", "archive.json"] {
                let original = parent.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: original.path) {
                    let data = try Data(contentsOf: original)
                    _ = try JSONSerialization.jsonObject(with: data)
                    let copy = backup.appendingPathComponent(name)
                    try data.write(to: copy, options: .withoutOverwriting)
                    let hash = try FileHasher.sha256(of: copy)
                    if name == "deletions.json" { manifest.journalHash = hash } else { manifest.archiveHash = hash }
                }
            }
            manifest.includesArchive = true
            try JSONEncoder().encode(manifest).write(to: backup.appendingPathComponent("manifest.json"), options: .atomic)
            // Flush the independent backup and manifest before modifying the live database.
            for file in try FileManager.default.contentsOfDirectory(at: backup, includingPropertiesForKeys: nil) {
                let handle = try FileHandle(forWritingTo: file)
                defer { try? handle.close() }
                try handle.synchronize()
            }
            for directory in [backup, backup.deletingLastPathComponent()] {
                let fd = Darwin.open(directory.path, O_RDONLY)
                guard fd >= 0 else { throw POSIXError(.EIO) }
                defer { Darwin.close(fd) }
                guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
            }
        } catch {
            throw CatalogUpgradeError.blocked("迁移前备份失败，未迁移。备份位置：\(backup.path)。\(error.localizedDescription)")
        }
        do {
            let writer = try DatabaseQueue(path: url.path)
            defer { try? writer.close() }
            try writer.write { db in
                try CatalogStore.createColorTables(db)
                try db.execute(sql: "PRAGMA application_id = \(CatalogUpgradeCoordinator.applicationID)")
                try db.execute(sql: "PRAGMA user_version = \(CatalogUpgradeCoordinator.schemaVersion)")
                guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok",
                      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                    throw CatalogUpgradeError.blocked("迁移后检查失败，事务已回滚。")
                }
            }
        } catch {
            throw CatalogUpgradeError.blocked("图库迁移失败。原库位置：\(url.path)，备份：\(backup.path)。\(error.localizedDescription)")
        }
    }

    private static func tables(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    }
    private static func columns(_ db: Database, _ table: String) throws -> [String] {
        try db.columns(in: table).map { "\($0.name)|\($0.type)|\($0.isNotNull)|\($0.primaryKeyIndex)" }.sorted()
    }
}
