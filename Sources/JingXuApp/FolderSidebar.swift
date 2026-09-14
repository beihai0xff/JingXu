import JingXuCore
import SwiftUI

/// A flat visible outline keeps collapsed subtrees out of SwiftUI's view graph.
struct FolderSidebarRow: Identifiable {
    let outline: CatalogFolderOutline
    let source: SourceRoot
    let depth: Int
    var id: CatalogFolderID { outline.id }
    var destination: SidebarDestination {
        outline.isSourceRoot ? .source(source.id) : .folder(id)
    }
}

extension AppModel {
    var visibleFolderRows: [FolderSidebarRow] {
        var rows: [FolderSidebarRow] = []
        func append(_ outline: CatalogFolderOutline, depth: Int) {
            rows.append(FolderSidebarRow(outline: outline, source: outline.source, depth: depth))
            if expandedFolders.contains(outline.id) {
                for child in outline.children { append(child, depth: depth + 1) }
            }
        }
        for root in folderOutline { append(root, depth: 0) }
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
            .opacity(row.outline.children.isEmpty ? 0 : 1)
            .disabled(row.outline.children.isEmpty)
            .accessibilityLabel("\(model.expandedFolders.contains(row.id) ? "折叠" : "展开")\(row.outline.name)")
            Image(systemName: row.source.isOnline ? "folder" : "externaldrive.badge.xmark")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.outline.name).lineLimit(1)
                if row.outline.isSourceRoot && row.depth > 0 {
                    Text("独立来源").font(.caption2).foregroundStyle(.secondary)
                }
                if row.outline.isSourceRoot && !row.source.isOnline { Text("离线").font(.caption2).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            if let node = row.outline.node {
                Text(node.recursiveCount.formatted()).font(.caption).foregroundStyle(.secondary)
                    .help("此来源的图库索引共 \(node.recursiveCount) 项（包含子目录），独立添加的其他来源另计")
            }
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
