import Foundation

/// The grid's loaded rows and their lookup index change together. Explicit selection
/// remains separate and may contain photos outside this list.
public struct LoadedAssetList: Sendable {
    public private(set) var items: [AssetListItem] = []
    public private(set) var photoIDs: [String] = []
    private var positions: [String: Int] = [:]
    public init() {}
    public func contains(_ id: String) -> Bool { positions[id] != nil }
    public func index(of id: String) -> Int? { positions[id] }
    public func loadedIDs(in ids: Set<String>) -> [String] { ids.filter { positions[$0] != nil } }

    /// Returns whether an already-loaded file's identity changed.
    @discardableResult public mutating func replace(_ rows: [AssetListItem]) -> Bool {
        let changed = rows.contains { row in
            positions[row.id].map { items[$0].fileVersion != row.fileVersion } ?? false
        }
        items = rows; positions = [:]; photoIDs = []
        for (index, row) in rows.enumerated() {
            positions[row.id] = index
            if row.kind == .photo { photoIDs.append(row.id) }
        }
        return changed
    }

    public mutating func append(_ rows: [AssetListItem], before: Bool = false) {
        var seen = Set<String>()
        let additional = rows.filter { positions[$0.id] == nil && seen.insert($0.id).inserted }
        if before { replace(additional + items); return }
        for row in additional {
            positions[row.id] = items.count; items.append(row)
            if row.kind == .photo { photoIDs.append(row.id) }
        }
    }

    /// Keep only the nearby grid rows. The opposite edge can be fetched again
    /// from its remaining cursor; selection is owned separately by the caller.
    @discardableResult public mutating func appendWindow(_ rows: [AssetListItem], before: Bool,
                                                          capacity: Int = 600, columns: Int = 1) -> Int {
        append(rows, before: before)
        let overflow = items.count - capacity
        guard overflow > 0 else { return 0 }
        let width = max(1, columns)
        let removed = min(items.count - 1, ((overflow + width - 1) / width) * width)
        replace(before ? Array(items.dropLast(removed)) : Array(items.dropFirst(removed)))
        return removed
    }

    @discardableResult public mutating func update(_ rows: [AssetListItem]) -> Bool {
        var changed = false
        for row in rows {
            guard let index = positions[row.id] else { continue }
            if items[index].fileVersion != row.fileVersion { changed = true }
            // A kind change can only arrive through a rescan and full replacement.
            items[index] = row
        }
        return changed
    }
}
