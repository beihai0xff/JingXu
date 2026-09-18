import Foundation
import GRDB

public struct SystemPhotoDraft: Codable, Sendable {
    public let photoID: String
    public let contentVersion: String
    public let adjustments: ColorAdjustments
    public let revision: Int
}

public struct SystemPhotoWriteRecord: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let names: [String]
    public var createdIDs: [String]
    public var state: String
    public var detail: String?
    public let targetIDs: [String]
    public let submittedAt: Date
}

/// Photos-owned media never enters Catalog.sqlite or its filesystem deletion queries.
public actor SystemPhotosStore {
    private nonisolated let db: DatabasePool
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        db = try DatabasePool(path: url.path)
        try db.write { db in
            let version = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
            guard version == 0 || version == 1 else { throw ColorEditError("系统照片数据库格式不支持，已保留原库") }
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS drafts (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS analysis (id TEXT PRIMARY KEY, payload BLOB NOT NULL, sourceVersion TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS reviews (id TEXT PRIMARY KEY, state TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, payload BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS writes (id TEXT PRIMARY KEY, payload BLOB NOT NULL, state TEXT NOT NULL);
                PRAGMA user_version = 1;
                """)
        }
    }
    public func draft(id: String) throws -> SystemPhotoDraft? {
        try db.read { db in
            try Data.fetchOne(db, sql: "SELECT payload FROM drafts WHERE id = ?", arguments: [id])
                .map { try JSONDecoder().decode(SystemPhotoDraft.self, from: $0) }
        }
    }
    public func saveDraft(id: String, version: String, adjustments: ColorAdjustments, expectedRevision: Int) throws -> SystemPhotoDraft {
        try db.write { db in
            let current = try Data.fetchOne(db, sql: "SELECT payload FROM drafts WHERE id = ?", arguments: [id])
                .map { try JSONDecoder().decode(SystemPhotoDraft.self, from: $0) }
            guard (current?.revision ?? 0) == expectedRevision,
                  current == nil || current?.contentVersion == version else {
                throw ColorEditError("系统照片草稿已变化，请重新载入；旧草稿已保留")
            }
            let value = SystemPhotoDraft(photoID: id, contentVersion: version, adjustments: adjustments, revision: expectedRevision + 1)
            try db.execute(sql: "INSERT OR REPLACE INTO drafts VALUES (?, ?)", arguments: [id, try JSONEncoder().encode(value)])
            return value
        }
    }
    public func discardDraft(id: String) throws {
        try db.write { try $0.execute(sql: "DELETE FROM drafts WHERE id = ?", arguments: [id]) }
    }
    public func validateDraft(_ snapshot: ColorEditingSnapshot) throws {
        guard case .systemPhoto(let input) = snapshot.origin else { throw ColorEditError("不是系统照片草稿") }
        let current = try draft(id: snapshot.id)
        guard (current?.revision ?? 0) == snapshot.revision,
              current == nil || (current?.contentVersion == input.contentVersion && current?.adjustments == snapshot.adjustments) else {
            throw ColorEditError("本机草稿已变化，请重新确认保存")
        }
    }
    public func saveAnalysis(_ result: AnalysisResult, sourceVersion: String) throws {
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO analysis VALUES (?, ?, ?)",
                                     arguments: [result.assetID, try JSONEncoder().encode(result), sourceVersion]) }
    }
    public func analysis(id: String) throws -> AnalysisResult? {
        try db.read { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM analysis WHERE id = ?", arguments: [id]) else { return nil }
            var result = try JSONDecoder().decode(AnalysisResult.self, from: data)
            if let state = try String.fetchOne(db, sql: "SELECT state FROM reviews WHERE id = ?", arguments: [id]),
               let review = SuggestionState(rawValue: state) { result.suggestionState = review }
            return result
        }
    }
    public func review(id: String, state: SuggestionState) throws {
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO reviews VALUES (?, ?)", arguments: [id, state.rawValue]) }
    }
    public func setSimilarGroups(_ groups: [[String]], ids: [String]) throws {
        var membership: [String: String] = [:]
        for group in groups { let id = UUID().uuidString; for photoID in group { membership[photoID] = id } }
        try db.write { db in
            for id in ids {
                guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM analysis WHERE id = ?", arguments: [id]) else { continue }
                var value = try JSONDecoder().decode(AnalysisResult.self, from: data)
                let group = membership[id]
                value.similarGroupID = group
                value.issues = value.issues.filter { $0 != .similarBurst } + (group == nil ? [] : [.similarBurst])
                try db.execute(sql: "UPDATE analysis SET payload = ? WHERE id = ?", arguments: [try JSONEncoder().encode(value), id])
            }
        }
    }
    public func saveJob(_ job: SystemPhotoAnalysisJob) throws {
        try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO jobs VALUES (?, ?)", arguments: [job.id, try JSONEncoder().encode(job)]) }
    }
    public func jobs() throws -> [SystemPhotoAnalysisJob] {
        try db.read { try Data.fetchAll($0, sql: "SELECT payload FROM jobs ORDER BY rowid DESC")
            .map { try JSONDecoder().decode(SystemPhotoAnalysisJob.self, from: $0) } }
    }
    public func endJob(id: String) throws {
        guard var job = try jobs().first(where: { $0.id == id }) else { throw ColorEditError("分析任务不存在") }
        job.ended = true; try saveJob(job)
    }
    public func beginWrite(id: UUID, title: String, names: [String], targetIDs: [String] = []) throws {
        try db.write { db in
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM writes WHERE state IN ('submitting', 'unknown')") == 0 else {
                throw ColorEditError("上次系统照片提交结果尚未确认，请先在系统照片中核对")
            }
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM writes WHERE id = ?", arguments: [id.uuidString]) == 0 else {
                throw ColorEditError("该清单已提交，请勿重复操作")
            }
            let record = SystemPhotoWriteRecord(id: id.uuidString, title: title, names: names, createdIDs: [], state: "submitting",
                                                targetIDs: targetIDs, submittedAt: Date())
            try db.execute(sql: "INSERT INTO writes VALUES (?, ?, ?)", arguments: [record.id, try JSONEncoder().encode(record), record.state])
        }
    }
    // Called synchronously inside PhotoKit's change block, before Photos commits its creation requests.
    public nonisolated func recordCreated(id: UUID, ids: [String]) throws {
        try db.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM writes WHERE id = ?", arguments: [id.uuidString]) else {
                throw ColorEditError("提交记录缺失")
            }
            var record = try JSONDecoder().decode(SystemPhotoWriteRecord.self, from: data)
            record.createdIDs = ids
            try db.execute(sql: "UPDATE writes SET payload = ? WHERE id = ?", arguments: [try JSONEncoder().encode(record), record.id])
        }
    }
    public func finishWrite(id: UUID, state: String, detail: String? = nil) throws {
        try db.write { db in
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM writes WHERE id = ?", arguments: [id.uuidString]) else {
                throw ColorEditError("提交记录缺失")
            }
            var record = try JSONDecoder().decode(SystemPhotoWriteRecord.self, from: data)
            record.state = state; record.detail = detail
            try db.execute(sql: "UPDATE writes SET payload = ?, state = ? WHERE id = ?",
                           arguments: [try JSONEncoder().encode(record), state, record.id])
        }
    }
    public func unresolvedWrites() throws -> [SystemPhotoWriteRecord] {
        try db.read { try Data.fetchAll($0, sql: "SELECT payload FROM writes WHERE state IN ('submitting', 'unknown')")
            .map { try JSONDecoder().decode(SystemPhotoWriteRecord.self, from: $0) } }
    }
    public func completeEdit(writeID: UUID, photoID: String, revision: Int) throws {
        try db.write { db in
            let draft = try Data.fetchOne(db, sql: "SELECT payload FROM drafts WHERE id = ?", arguments: [photoID])
                .map { try JSONDecoder().decode(SystemPhotoDraft.self, from: $0) }
            guard (draft?.revision ?? 0) == revision else { throw ColorEditError("保存期间草稿已变化，已保留新的草稿") }
            guard let data = try Data.fetchOne(db, sql: "SELECT payload FROM writes WHERE id = ?", arguments: [writeID.uuidString]) else {
                throw ColorEditError("提交记录缺失")
            }
            var record = try JSONDecoder().decode(SystemPhotoWriteRecord.self, from: data)
            record.state = "completed"
            try db.execute(sql: "UPDATE writes SET payload = ?, state = ? WHERE id = ?",
                           arguments: [try JSONEncoder().encode(record), record.state, record.id])
            try db.execute(sql: "DELETE FROM drafts WHERE id = ?", arguments: [photoID])
        }
    }
}

public actor SystemPhotoEditingRepository: ColorEditingRepository {
    private let store: SystemPhotosStore
    private let client: any PhotoLibraryClient
    public init(store: SystemPhotosStore, client: any PhotoLibraryClient) { self.store = store; self.client = client }
    public func open(_ input: SystemPhotoEditInput) async throws -> ColorEditingSnapshot {
        if let draft = try await store.draft(id: input.photo.id) {
            guard draft.contentVersion == input.contentVersion else {
                throw ColorEditError("照片在其他设备或应用中发生变化，旧草稿已保留；请明确放弃旧草稿后重新编辑")
            }
            return ColorEditingSnapshot(systemPhoto: input, adjustments: draft.adjustments, revision: draft.revision)
        }
        return ColorEditingSnapshot(systemPhoto: input, adjustments: input.adjustments, revision: 0)
    }
    public func saveColorAdjustments(_ adjustments: ColorAdjustments, snapshot: ColorEditingSnapshot) async throws -> ColorEditingSnapshot {
        guard case .systemPhoto(let input) = snapshot.origin else { throw ColorEditError("不匹配的照片来源") }
        try adjustments.validate(isRAW: snapshot.isRAW)
        try snapshot.input.revalidate()
        // Drafts survive loss of network/permission and external edits. The original version is
        // retained and checked on reopen/commit; local autosave never claims a Photos write.
        let draft = try await store.saveDraft(id: snapshot.id, version: input.contentVersion,
                                             adjustments: adjustments, expectedRevision: snapshot.revision)
        return ColorEditingSnapshot(systemPhoto: input, adjustments: adjustments, revision: draft.revision)
    }
    public func validateEditingSnapshot(_ snapshot: ColorEditingSnapshot) async throws {
        guard case .systemPhoto(let input) = snapshot.origin else { throw ColorEditError("不匹配的照片来源") }
        try snapshot.input.revalidate(); try await client.validate(photo: input.photo)
    }
}
