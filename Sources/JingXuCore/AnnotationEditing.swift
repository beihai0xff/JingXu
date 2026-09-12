import Foundation
import GRDB

public enum KeywordEdit: Sendable, Equatable {
    case append([String]), remove([String]), replace([String])
    public static func parse(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    func applying(to keywords: [String]) -> [String] {
        switch self {
        case .append(let values): return keywords + values
        case .remove(let values): return keywords.filter { !Set(values).contains($0) }
        case .replace(let values): return values
        }
    }
}
public struct AnnotationPatch: Sendable {
    public var rating: Int?
    public var flag: AssetFlag?
    public var keywords: KeywordEdit?
    public var albumID: String?
    public var albumMember: Bool
    public init(rating: Int? = nil, flag: AssetFlag? = nil, keywords: KeywordEdit? = nil,
                albumID: String? = nil, albumMember: Bool = true) {
        self.rating = rating; self.flag = flag; self.keywords = keywords
        self.albumID = albumID; self.albumMember = albumMember
    }
}
public struct AnnotationChangeSet: Sendable {
    public struct Change: Sendable {
        public let before: UserAnnotation
        public let after: UserAnnotation
        public let albumBefore: Bool
        public let albumAfter: Bool
    }
    public let patch: AnnotationPatch
    public let changes: [Change]
    public var ids: [String] { changes.map { $0.after.assetID } }
}

extension CatalogStore {
    public func applyAnnotations(ids: [String], patch: AnnotationPatch) throws -> AnnotationChangeSet {
        try dbPool.write { db in
            if let album = patch.albumID, try Album.fetchOne(db, key: album) == nil { throw ColorEditError("相册已不存在") }
            var changes: [AnnotationChangeSet.Change] = []
            for id in Set(ids).sorted() {
                try Task.checkCancellation()
                guard let asset = try MediaAsset.fetchOne(db, key: id), asset.kind == .photo else { throw CatalogAnnotationError.assetMissing }
                let before = try UserAnnotation.fetchOne(db, key: id) ?? UserAnnotation(assetID: id)
                var after = before
                if let rating = patch.rating { after.rating = min(5, max(0, rating)) }
                if let flag = patch.flag { after.flag = flag }
                if let keywords = patch.keywords { after.keywords = keywords.applying(to: before.keywords) }
                let wasMember = try Self.albumMember(db, album: patch.albumID, asset: id)
                let isMember = patch.albumID == nil ? wasMember : patch.albumMember
                guard before.rating != after.rating || before.flag != after.flag || before.keywords != after.keywords || wasMember != isMember else { continue }
                after.updatedAt = Date(); try after.save(db)
                try Self.writeMembership(db, album: patch.albumID, asset: id, member: isMember)
                changes.append(.init(before: before, after: after, albumBefore: wasMember, albumAfter: isMember))
            }
            return AnnotationChangeSet(patch: patch, changes: changes)
        }
    }
    /// Checks only fields owned by this command. Independent edits survive undo.
    public func invertAnnotations(_ set: AnnotationChangeSet) throws -> AnnotationChangeSet {
        try dbPool.write { db in
            if let album = set.patch.albumID, try Album.fetchOne(db, key: album) == nil { throw ColorEditError("相册已不存在，无法撤销") }
            var inverse: [AnnotationChangeSet.Change] = []
            for change in set.changes {
                try Task.checkCancellation()
                let id = change.after.assetID
                guard try MediaAsset.fetchOne(db, key: id) != nil else { throw CatalogAnnotationError.assetMissing }
                let current = try UserAnnotation.fetchOne(db, key: id) ?? UserAnnotation(assetID: id)
                let member = try Self.albumMember(db, album: set.patch.albumID, asset: id)
                guard (set.patch.rating == nil || current.rating == change.after.rating),
                      (set.patch.flag == nil || current.flag == change.after.flag),
                      (set.patch.keywords == nil || current.keywords == change.after.keywords),
                      (set.patch.albumID == nil || member == change.albumAfter) else { throw ColorEditError("标注已被后续操作改变，未覆盖新值；本次撤销未执行") }
                var restored = current
                if set.patch.rating != nil { restored.rating = change.before.rating }
                if set.patch.flag != nil { restored.flag = change.before.flag }
                if set.patch.keywords != nil { restored.keywords = change.before.keywords }
                restored.updatedAt = Date(); try restored.save(db)
                try Self.writeMembership(db, album: set.patch.albumID, asset: id, member: change.albumBefore)
                inverse.append(.init(before: current, after: restored, albumBefore: member, albumAfter: change.albumBefore))
            }
            return AnnotationChangeSet(patch: set.patch, changes: inverse)
        }
    }
    private static func albumMember(_ db: Database, album: String?, asset: String) throws -> Bool {
        guard let album else { return false }
        return try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM albumAssets WHERE albumID = ? AND assetID = ?)", arguments: [album, asset]) ?? false
    }
    private static func writeMembership(_ db: Database, album: String?, asset: String, member: Bool) throws {
        guard let album else { return }
        if member { try db.execute(sql: "INSERT INTO albumAssets(albumID, assetID, addedAt) VALUES (?, ?, ?) ON CONFLICT(albumID, assetID) DO NOTHING", arguments: [album, asset, Date()]) }
        else { try db.execute(sql: "DELETE FROM albumAssets WHERE albumID = ? AND assetID = ?", arguments: [album, asset]) }
    }
}
