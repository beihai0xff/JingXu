import Foundation

/// Presentation only: source ownership and query identities remain unchanged.
public struct CatalogFolderOutline: Identifiable, Sendable {
    public let id: CatalogFolderID
    public let node: CatalogFolderNode?
    public let source: SourceRoot
    public let name: String
    public let children: [Self]
    public var isSourceRoot: Bool { id.relativeDirectory.isEmpty }

    public static func build(sources: [SourceRoot], roots: [CatalogFolderNode]) -> [Self] {
        final class Entry {
            let id: CatalogFolderID
            let source: SourceRoot
            let name: String
            var node: CatalogFolderNode?
            var children: [Entry] = []
            init(id: CatalogFolderID, source: SourceRoot, name: String, node: CatalogFolderNode? = nil) {
                self.id = id; self.source = source; self.name = name; self.node = node
            }
            func freeze() -> CatalogFolderOutline {
                let sorted = children.sorted {
                    let order = $0.name.localizedStandardCompare($1.name)
                    if order != .orderedSame { return order == .orderedAscending }
                    if !$0.name.utf8.elementsEqual($1.name.utf8) {
                        return $0.name.utf8.lexicographicallyPrecedes($1.name.utf8)
                    }
                    return $0.id.sourceID < $1.id.sourceID
                }
                return CatalogFolderOutline(id: id, node: node, source: source, name: name,
                                            children: sorted.map { $0.freeze() })
            }
        }
        func copy(_ node: CatalogFolderNode, source: SourceRoot) -> Entry {
            let entry = Entry(id: node.id, source: source,
                              name: node.id.relativeDirectory.isEmpty ? URL(fileURLWithPath: source.pathHint).lastPathComponent : node.name,
                              node: node)
            entry.children = node.children.map { copy($0, source: source) }
            return entry
        }
        let entries = sources.compactMap { source in
            roots.first(where: { $0.id.sourceID == source.id }).map { copy($0, source: source) }
        }
        func components(_ entry: Entry) -> [Data] {
            URL(fileURLWithPath: entry.source.pathHint).standardizedFileURL.pathComponents.map { Data($0.utf8) }
        }
        var top: [Entry] = []
        for entry in entries {
            let path = components(entry)
            let ancestors = entries.filter {
                let candidate = components($0)
                return candidate.count < path.count && Array(path.prefix(candidate.count)) == candidate
            }
            guard let parent = ancestors.sorted(by: {
                let a = components($0).count, b = components($1).count
                return a == b ? $0.id.sourceID < $1.id.sourceID : a > b
            }).first else { top.append(entry); continue }
            let names = URL(fileURLWithPath: entry.source.pathHint).standardizedFileURL.pathComponents
            var container = parent
            var relative: [String] = []
            for name in names.dropFirst(components(parent).count).dropLast() {
                relative.append(name)
                let id = CatalogFolderID(sourceID: parent.source.id, relativeDirectory: relative.joined(separator: "/"))
                if let existing = container.children.first(where: { $0.id == id }) { container = existing }
                else {
                    let intermediate = Entry(id: id, source: parent.source, name: name)
                    container.children.append(intermediate); container = intermediate
                }
            }
            container.children.append(entry)
        }
        // Reuse the same natural ordering for top-level and nested directories.
        let holder = Entry(id: CatalogFolderID(sourceID: ""), source: SourceRoot(name: "", bookmarkData: nil, pathHint: "/"), name: "")
        holder.children = top
        return holder.freeze().children
    }
}
