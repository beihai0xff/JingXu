import Foundation
import GRDB

public struct BrowseCursor: Sendable, Equatable, Hashable {
    public let date: Date
    public let name: String
    public let id: String
    public init(_ item: AssetListItem) { date = item.browseDate; name = item.fileName; id = item.id }
}

public struct BrowsePage: Sendable {
    public let items: [AssetListItem]
    public let hasPrevious: Bool
    public let hasNext: Bool
    public let total: Int?
}

extension CatalogStore {
    public func browsePage(_ query: BrowseQuery, cursor: BrowseCursor? = nil, reverse: Bool = false,
                           inclusive: Bool = false, photosOnly: Bool = false, limit: Int = 200,
                           count: Bool = false) throws -> BrowsePage {
        let (sql, args) = try Self.assetQuerySQL(query, rejectedOnly: false, photosOnly: photosOnly,
            limit: limit, cursor: cursor, reverse: reverse, inclusive: inclusive)
        return try dbPool.read { db in
            var items = try AssetListItem.fetchAll(db, sql: sql, arguments: args)
            if reverse { items.reverse() }
            func exists(_ cursor: BrowseCursor?, backwards: Bool, inclusive: Bool = false) throws -> Bool {
                guard let cursor else { return false }
                let (sql, args) = try Self.assetQuerySQL(query, rejectedOnly: false, photosOnly: photosOnly,
                    projection: "a.id", limit: 1, cursor: cursor, reverse: backwards, inclusive: inclusive)
                return try String.fetchOne(db, sql: sql, arguments: args) != nil
            }
            var total: Int?
            if count {
                let (sql, args) = try Self.assetQuerySQL(query, rejectedOnly: false, photosOnly: photosOnly,
                    projection: "COUNT(*)", paginated: false)
                total = try Int.fetchOne(db, sql: sql, arguments: args) ?? 0
            }
            return BrowsePage(items: items, hasPrevious: try exists(items.first.map(BrowseCursor.init) ?? cursor, backwards: true, inclusive: items.isEmpty && !reverse),
                hasNext: try exists(items.last.map(BrowseCursor.init) ?? cursor, backwards: false, inclusive: items.isEmpty && reverse), total: total)
        }
    }

    /// Batches IDs without coupling explicit selections to a loaded page.
    public func assetListItems(ids: [String], matching query: BrowseQuery = BrowseQuery()) throws -> [AssetListItem] {
        let unique = Array(Set(ids)).sorted()
        return try dbPool.read { db in
            var result: [AssetListItem] = []
            for start in stride(from: 0, to: unique.count, by: 400) {
                try Task.checkCancellation()
                let chunk = Array(unique[start..<min(start + 400, unique.count)])
                let (sql, args) = try Self.assetQuerySQL(query, rejectedOnly: false, paginated: false, assetIDs: chunk)
                result += try AssetListItem.fetchAll(db, sql: sql, arguments: args)
            }
            return result.sorted {
                if $0.browseDate != $1.browseDate { return $0.browseDate > $1.browseDate }
                if !$0.fileName.utf8.elementsEqual($1.fileName.utf8) { return $0.fileName.utf8.lexicographicallyPrecedes($1.fileName.utf8) }
                return $0.id.utf8.lexicographicallyPrecedes($1.id.utf8)
            }
        }
    }
}
