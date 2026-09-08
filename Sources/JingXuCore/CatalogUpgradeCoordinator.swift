import Foundation
import GRDB
import Darwin

public struct UpgradeManifest: Codable, Sendable {
    public var databasePath: String
    public var migrations: [String]
    public var targetVersion: String
    public var createdAt: Date
    public var databaseHash: String
    public var journalHash: String?
}

public enum CatalogUpgradeError: LocalizedError {
    case blocked(String)
    public var errorDescription: String? {
        switch self { case .blocked(let reason): return reason }
    }
}

/// Held for the entire app session, not merely while migrating.
public final class CatalogLease: @unchecked Sendable {
    private let descriptor: Int32
    public init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = databaseURL.path + ".lock"
        descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw CatalogUpgradeError.blocked("无法创建图库锁，请检查目录权限。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw CatalogUpgradeError.blocked("图库正由另一个镜序实例使用，请先退出旧版。")
        }
    }
    deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

public actor CatalogUpgradeCoordinator {
    public static let migrations = ["v1-create-catalog", "v2-file-identity-index", "v3-source-directory-identity", "v4-quality-assessment"]
    private let databaseURL: URL
    private var lease: CatalogLease?
    private weak var openedStore: CatalogStore?
    public init(databaseURL: URL) { self.databaseURL = databaseURL }

    public func open() throws -> CatalogStore {
        if lease == nil { lease = try CatalogLease(databaseURL: databaseURL) }
        if let openedStore { return openedStore }
        let store = try CatalogStore(databaseURL: databaseURL)
        openedStore = store
        return store
    }

    public static func validate(_ reader: any DatabaseReader) throws {
        try reader.read { db in
            guard try String.fetchOne(db, sql: "PRAGMA integrity_check") == "ok",
                  try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty else {
                throw CatalogUpgradeError.blocked("图库完整性检查失败，已停止写入。请从备份恢复。")
            }
        }
    }

    public static func backupDirectory(for databaseURL: URL) -> URL {
        databaseURL.deletingLastPathComponent().appendingPathComponent("Backups/Upgrades", isDirectory: true)
    }

    /// Called before opening a write connection or executing any migration.
    static func prepare(_ databaseURL: URL) throws {
        let fm = FileManager.default
        let parent = databaseURL.deletingLastPathComponent()
        if fm.fileExists(atPath: parent.appendingPathComponent("restore-state.json").path) {
            throw CatalogUpgradeError.blocked("上次恢复尚未结束。请在恢复界面重新选择同一份备份，完成恢复后再启动。")
        }
        guard fm.fileExists(atPath: databaseURL.path) else {
            if fm.fileExists(atPath: databaseURL.path + "-wal") || fm.fileExists(atPath: databaseURL.appendingPathExtension("initialized").path) {
                throw CatalogUpgradeError.blocked("原图库文件缺失，已阻止创建空图库。请检查路径或恢复备份。")
            }
            return
        }
        var configuration = Configuration(); configuration.readonly = true
        let old: DatabaseQueue
        do { old = try DatabaseQueue(path: databaseURL.path, configuration: configuration) }
        catch { throw CatalogUpgradeError.blocked("无法只读检查图库 \(databaseURL.path)：\(error.localizedDescription)") }
        defer { try? old.close() }
        let applied = try old.read { db -> [String] in
            guard try db.tableExists("grdb_migrations") else { throw CatalogUpgradeError.blocked("无法识别现有数据库，未执行迁移。") }
            return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
        guard Array(migrations.prefix(applied.count)) == applied else {
            throw CatalogUpgradeError.blocked("图库版本比本程序更新或迁移历史异常，禁止降级写入。")
        }
        try validate(old)
        guard applied != migrations else { return }
        let backup = backupDirectory(for: databaseURL).appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        let snapshot = backup.appendingPathComponent("Catalog.sqlite")
        let writer = try DatabaseQueue(path: snapshot.path)
        try old.backup(to: writer)
        try writer.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA journal_mode = DELETE") }
        try validate(writer)
        try writer.close()
        let journal = parent.appendingPathComponent("deletions.json")
        var journalHash: String?
        if fm.fileExists(atPath: journal.path) {
            let data = try Data(contentsOf: journal)
            _ = try JSONDecoder().decode([DeletionJournalEntry].self, from: data)
            let target = backup.appendingPathComponent("deletions.json")
            try data.write(to: target, options: .atomic)
            journalHash = try FileHasher.sha256(of: target)
        }
        let manifest = UpgradeManifest(databasePath: databaseURL.standardizedFileURL.path, migrations: applied,
            targetVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", createdAt: Date(), databaseHash: try FileHasher.sha256(of: snapshot), journalHash: journalHash)
        try JSONEncoder().encode(manifest).write(to: backup.appendingPathComponent("manifest.json"), options: .atomic)
    }

    public func restore(from backup: URL) throws {
        guard openedStore == nil else { throw CatalogUpgradeError.blocked("请先关闭图库连接，再恢复备份。") }
        if lease == nil { lease = try CatalogLease(databaseURL: databaseURL) }
        let fm = FileManager.default
        let parent = databaseURL.deletingLastPathComponent()
        let state = parent.appendingPathComponent("restore-state.json")
        let manifestData = try Data(contentsOf: backup.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(UpgradeManifest.self, from: manifestData)
        let snapshot = backup.appendingPathComponent("Catalog.sqlite")
        guard manifest.databasePath == databaseURL.standardizedFileURL.path,
              try FileHasher.sha256(of: snapshot) == manifest.databaseHash else {
            throw CatalogUpgradeError.blocked("备份不属于当前图库，或备份校验失败。")
        }
        let journalBackup = backup.appendingPathComponent("deletions.json")
        if let hash = manifest.journalHash {
            guard try FileHasher.sha256(of: journalBackup) == hash else { throw CatalogUpgradeError.blocked("删除日志备份校验失败。") }
        }
        var config = Configuration(); config.readonly = true
        let check = try DatabaseQueue(path: snapshot.path, configuration: config)
        try Self.validate(check); try check.close()
        // Persist the recovery intent before touching any live database files.
        if fm.fileExists(atPath: state.path) {
            let prior = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: state))
            guard let priorPath = prior["backup"], URL(fileURLWithPath: priorPath).resolvingSymlinksInPath().standardizedFileURL.path == backup.resolvingSymlinksInPath().standardizedFileURL.path else {
                throw CatalogUpgradeError.blocked("请先使用上次选择的备份完成恢复：\(prior["backup"] ?? "未知")")
            }
        } else {
            let preserved = parent.appendingPathComponent("Backups/Recovery-\(UUID().uuidString)")
            try fm.createDirectory(at: preserved, withIntermediateDirectories: true)
            try JSONEncoder().encode(["backup": backup.standardizedFileURL.path, "preserved": preserved.path]).write(to: state, options: .atomic)
        }
        let intent = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: state))
        guard let preservedPath = intent["preserved"] else { throw CatalogUpgradeError.blocked("恢复记录损坏。") }
        let preserved = URL(fileURLWithPath: preservedPath)
        guard preserved.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL == parent.appendingPathComponent("Backups").resolvingSymlinksInPath().standardizedFileURL else {
            throw CatalogUpgradeError.blocked("恢复保全目录不在图库备份目录内，已停止。")
        }
        for name in [databaseURL.lastPathComponent, databaseURL.lastPathComponent + "-wal", databaseURL.lastPathComponent + "-shm", "deletions.json"] {
            let live = parent.appendingPathComponent(name)
            let saved = preserved.appendingPathComponent(name)
            if fm.fileExists(atPath: live.path), !fm.fileExists(atPath: saved.path) { try fm.copyItem(at: live, to: saved) }
        }
        // An atomic data write leaves either the old or complete restored file; intent stays until validation succeeds.
        let data = try Data(contentsOf: snapshot)
        for suffix in ["-wal", "-shm"] {
            let url = URL(fileURLWithPath: databaseURL.path + suffix)
            if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        }
        try data.write(to: databaseURL, options: .atomic)
        let journal = parent.appendingPathComponent("deletions.json")
        if manifest.journalHash != nil { try Data(contentsOf: journalBackup).write(to: journal, options: .atomic) }
        else if fm.fileExists(atPath: journal.path) { try fm.removeItem(at: journal) }
        let restored = try DatabaseQueue(path: databaseURL.path, configuration: config)
        try Self.validate(restored); try restored.close()
        try fm.removeItem(at: state)
    }
}
