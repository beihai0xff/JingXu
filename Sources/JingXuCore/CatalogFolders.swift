import Foundation
import GRDB

/// Identity is byte-exact, just like SQLite's BINARY path index. Swift String's
/// canonical-equivalence equality must not collapse distinct indexed paths.
public struct CatalogFolderID: Hashable, Sendable {
    public let sourceID: String
    public let relativeDirectory: String

    public init(sourceID: String, relativeDirectory: String = "") {
        self.sourceID = sourceID
        self.relativeDirectory = relativeDirectory
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sourceID == rhs.sourceID && lhs.relativeDirectory.utf8.elementsEqual(rhs.relativeDirectory.utf8)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sourceID)
        hasher.combine(Data(relativeDirectory.utf8))
    }

    public var parent: Self? {
        guard !relativeDirectory.isEmpty else { return nil }
        let path = relativeDirectory.lastIndex(of: "/").map { String(relativeDirectory[..<$0]) } ?? ""
        return Self(sourceID: sourceID, relativeDirectory: path)
    }
}

public struct CatalogFolderNode: Identifiable, Sendable {
    public let id: CatalogFolderID
    public let directCount: Int
    public let recursiveCount: Int
    public let children: [CatalogFolderNode]
    public var name: String { id.relativeDirectory.split(separator: "/").last.map(String.init) ?? "" }

    public func node(_ id: CatalogFolderID) -> Self? {
        if self.id == id { return self }
        guard self.id.sourceID == id.sourceID else { return nil }
        for child in children { if let found = child.node(id) { return found } }
        return nil
    }

    public func nearestSurvivingAncestor(of id: CatalogFolderID) -> CatalogFolderID? {
        var candidate: CatalogFolderID? = id
        while let current = candidate {
            if node(current) != nil { return current }
            candidate = current.parent
        }
        return nil
    }
}

public enum CatalogFolderError: Error, LocalizedError {
    case missingSource, invalidDirectory
    public var errorDescription: String? {
        switch self {
        case .missingSource: "目录查询必须指定来源，未执行全图库查询。"
        case .invalidDirectory: "目录必须是来源内的相对目录，不能包含空路径段、上级跳转或绝对路径。"
        }
    }
}

extension CatalogStore {
    /// No filesystem access, thumbnails, annotations or analysis blobs. Runs on
    /// the catalog actor, including aggregation; never on the UI actor.
    public func folderTree() throws -> [CatalogFolderNode] {
        try dbPool.read { db in
            struct Entry {
                var direct = 0
                var total = 0
                var children = Set<CatalogFolderID>()
            }
            let sourceIDs = try String.fetchAll(db, sql: "SELECT id FROM sourceRoots ORDER BY name, id")
            var entries = Dictionary(uniqueKeysWithValues: sourceIDs.map { (CatalogFolderID(sourceID: $0), Entry()) })
            let rows = try Row.fetchCursor(db, sql: "SELECT sourceID, relativePath FROM mediaAssets")
            while let row = try rows.next() {
                try Task.checkCancellation()
                let path: String = row["relativePath"]
                let sourceID: String = row["sourceID"]
                let directory = path.lastIndex(of: "/").map { String(path[..<$0]) } ?? ""
                var id = CatalogFolderID(sourceID: sourceID, relativeDirectory: directory)
                entries[id, default: Entry()].direct += 1
                while true {
                    entries[id, default: Entry()].total += 1
                    guard let parent = id.parent else { break }
                    entries[parent, default: Entry()].children.insert(id)
                    id = parent
                }
            }
            func build(_ id: CatalogFolderID) throws -> CatalogFolderNode {
                try Task.checkCancellation()
                let entry = entries[id] ?? Entry()
                let children = entry.children.sorted {
                    let order = $0.relativeDirectory.localizedStandardCompare($1.relativeDirectory)
                    return order == .orderedSame
                        ? $0.relativeDirectory.utf8.lexicographicallyPrecedes($1.relativeDirectory.utf8)
                        : order == .orderedAscending
                }
                return CatalogFolderNode(id: id, directCount: entry.direct, recursiveCount: entry.total,
                                         children: try children.map(build))
            }
            return try sourceIDs.map { try build(CatalogFolderID(sourceID: $0)) }
        }
    }
}
