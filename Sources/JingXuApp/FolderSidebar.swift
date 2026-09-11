import JingXuCore
import SwiftUI

/// A flat visible outline keeps collapsed subtrees out of SwiftUI's view graph.
struct FolderSidebarRow: Identifiable {
    let node: CatalogFolderNode
    let source: SourceRoot
    let depth: Int
    var id: CatalogFolderID { node.id }
    var destination: SidebarDestination {
        depth == 0 ? .source(source.id) : .folder(id)
    }
}

extension AppModel {
    var visibleFolderRows: [FolderSidebarRow] {
        var rows: [FolderSidebarRow] = []
        func append(_ node: CatalogFolderNode, source: SourceRoot, depth: Int) {
            rows.append(FolderSidebarRow(node: node, source: source, depth: depth))
            if expandedFolders.contains(node.id) {
                for child in node.children { append(child, source: source, depth: depth + 1) }
            }
        }
        for source in sources {
            if let root = folderRoots.first(where: { $0.id.sourceID == source.id }) {
                append(root, source: source, depth: 0)
            }
        }
        return rows
    }
}

struct FolderSidebarLabel: View {
    @EnvironmentObject private var model: AppModel
    let row: FolderSidebarRow

    var body: some View {
        HStack(spacing: 5) {
            Button {
                if !model.expandedFolders.insert(row.id).inserted { model.expandedFolders.remove(row.id) }
            } label: {
                Image(systemName: model.expandedFolders.contains(row.id) ? "chevron.down" : "chevron.right")
                    .font(.caption2).frame(width: 12, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .opacity(row.node.children.isEmpty ? 0 : 1)
            .disabled(row.node.children.isEmpty)
            .accessibilityLabel("\(model.expandedFolders.contains(row.id) ? "折叠" : "展开")\(row.depth == 0 ? row.source.name : row.node.name)")
            Image(systemName: row.source.isOnline ? "folder" : "externaldrive.badge.xmark")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.depth == 0 ? row.source.name : row.node.name).lineLimit(1)
                if row.depth == 0 && !row.source.isOnline { Text("离线").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            Text(row.node.recursiveCount.formatted()).font(.caption).foregroundStyle(.secondary)
                .help("图库索引共 \(row.node.recursiveCount) 项（包含子目录），不是实时磁盘文件数，不受筛选影响")
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .accessibilityElement(children: .contain)
        .help(row.source.pathHint + (row.id.relativeDirectory.isEmpty ? "" : "/" + row.id.relativeDirectory))
    }
}

struct FolderScopeBar: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        if let path = model.selectedFolderPath {
            HStack(spacing: 12) {
                Label(path, systemImage: "folder").font(.caption).lineLimit(1).truncationMode(.middle).help(path)
                Spacer(minLength: 0)
                Toggle("包含子目录", isOn: Binding(get: { model.includeSubdirectories }, set: { model.setIncludeSubdirectories($0) }))
                    .toggleStyle(.checkbox)
                    .disabled(!model.canChangeBrowseScope)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
        }
    }
}
