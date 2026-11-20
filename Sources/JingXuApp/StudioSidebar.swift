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
                if !model.expandedFolders.insert(row.id).inserted {
                    model.expandedFolders.remove(row.id)
                }
            } label: {
                Image(systemName: model.expandedFolders.contains(row.id) ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .frame(width: 12, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .opacity(row.outline.children.isEmpty ? 0 : 1)
            .disabled(row.outline.children.isEmpty)
            .accessibilityLabel("\(model.expandedFolders.contains(row.id) ? "折叠" : "展开")\(row.outline.name)")

            Image(systemName: row.source.isOnline ? "folder" : "externaldrive.badge.xmark")
                .foregroundStyle(row.source.isOnline ? Color.secondary : DarkroomPalette.warningAmber)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.outline.name).lineLimit(1)
                if row.outline.isSourceRoot && row.depth > 0 {
                    Text("独立来源").font(.caption2).foregroundStyle(.secondary)
                }
                if row.outline.isSourceRoot && !row.source.isOnline {
                    Text("离线").font(.caption2).foregroundStyle(DarkroomPalette.warningAmber)
                }
            }

            Spacer(minLength: 0)

            if let node = row.outline.node {
                Text(node.recursiveCount.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help("此来源的图库索引共 \(node.recursiveCount) 项（包含子目录），独立添加的其他来源另计")
            }
        }
        .padding(.leading, CGFloat(row.depth) * 12)
        .accessibilityElement(children: .contain)
        .help(row.source.pathHint + (row.id.relativeDirectory.isEmpty ? "" : "/" + row.id.relativeDirectory))
    }
}

struct StudioSidebar: View {
    @EnvironmentObject private var model: AppModel
    let requestCreateSystemAlbum: () -> Void
    let requestRenameSystemAlbum: (SystemPhotoAlbum) -> Void

    var body: some View {
        VStack(spacing: 0) {
            WorkspaceSwitcher(
                systemPhotos: model.showsSystemPhotos,
                selectLocal: {
                    if model.showsSystemPhotos { model.leaveSystemPhotos() }
                },
                selectSystem: {
                    if !model.showsSystemPhotos { model.openSystemPhotos() }
                }
            )
            .disabled(
                model.showsSystemPhotos
                    ? (model.systemPhotos?.isBusy == true || model.systemPhotos?.isNavigating == true)
                    : !model.canChangeBrowseScope
            )

            if model.showsSystemPhotos, let photos = model.systemPhotos {
                systemSidebarList(photos)
            } else {
                localSidebarList
            }

            Divider().overlay(DarkroomPalette.subtleDivider.opacity(0.6))

            sidebarFooter
        }
    }

    private var localSidebarList: some View {
        List(selection: Binding(
            get: { model.sidebarSelection },
            set: { model.selectSidebar($0) }
        )) {
            Section("智能视图") {
                ForEach([SmartCollection.all, .recent, .review, .rejected]) { collection in
                    Label(collection.displayName, systemImage: collection.systemImage)
                        .tag(SidebarDestination.smart(collection))
                }
            }

            Section("媒体类型") {
                ForEach([SmartCollection.photos, .raw, .videos]) { collection in
                    Label(collection.displayName, systemImage: collection.systemImage)
                        .tag(SidebarDestination.smart(collection))
                }
            }

            Section("文件夹") {
                ForEach(model.visibleFolderRows) { row in
                    if row.outline.node != nil {
                        FolderSidebarLabel(row: row)
                            .tag(row.destination)
                            .contextMenu {
                                if row.outline.isSourceRoot {
                                    Button("重新扫描整个来源…") { model.rescanSelectedSource() }
                                        .disabled(model.operationBlockReason(.files) != nil)
                                    Button("移除来源…", role: .destructive) { model.removeSource(row.source) }
                                        .disabled(model.isWorking || model.fileOperationsBlockedByShare)
                                }
                            }
                    } else {
                        FolderSidebarLabel(row: row)
                    }
                }
                Button {
                    model.chooseAndAddFolder()
                } label: {
                    Label("添加文件夹…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(model.fileOperationsBlockedByShare || model.operationBlockReason(.files) != nil)
            }

            Section("相册") {
                ForEach(model.albums) { album in
                    Label(album.name, systemImage: "rectangle.stack")
                        .tag(SidebarDestination.album(album.id))
                        .contextMenu {
                            Button("删除相册…", role: .destructive) { model.deleteAlbum(album) }
                                .disabled(model.isWorking || model.fileOperationsBlockedByShare)
                        }
                }
                Button {
                    model.isShowingAlbumCreator = true
                } label: {
                    Label("新建相册…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
            }
        }
        .listStyle(.sidebar)
        .disabled(!model.canChangeBrowseScope)
    }

    private func systemSidebarList(_ photos: SystemPhotosModel) -> some View {
        List {
            Section("系统图库") {
                Button {
                    photos.browse(albumID: nil)
                } label: {
                    HStack {
                        Label("所有照片", systemImage: "photo.on.rectangle")
                        Spacer()
                        if photos.albumID == nil && photos.connected {
                            Text("\(photos.total)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
                .listRowBackground(photos.albumID == nil ? Color.accentColor.opacity(0.16) : Color.clear)
            }

            Section("系统相册") {
                ForEach(photos.albums) { album in
                    Button {
                        photos.browse(albumID: album.id)
                    } label: {
                        HStack {
                            Label(album.name, systemImage: "rectangle.stack")
                            Spacer()
                            Text("\(album.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(photos.albumID == album.id ? Color.accentColor.opacity(0.16) : Color.clear)
                    .contextMenu {
                        Button("重命名…") { requestRenameSystemAlbum(album) }
                            .disabled(!album.canRename)
                        Button("删除相册…", role: .destructive) {
                            photos.prepareMutation(.deleteAlbum(id: album.id), album: album)
                        }
                        .disabled(!album.canDelete)
                    }
                }
                Button {
                    requestCreateSystemAlbum()
                } label: {
                    Label("新建相册…", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .disabled(!photos.canAct)
            }
        }
        .listStyle(.sidebar)
        .disabled(photos.isBusy || photos.isNavigating)
    }

    private var sidebarFooter: some View {
        HStack(spacing: 6) {
            if model.showsSystemPhotos, let photos = model.systemPhotos {
                Image(systemName: "icloud")
                    .font(.caption)
                    .foregroundStyle(photos.connected ? Color.accentColor : .secondary)
                Text(photos.isIsolated ? "隔离测试图库 · 零外部写入" : (photos.connected ? "已连接系统照片" : "尚未连接系统照片"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Image(systemName: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(DarkroomPalette.readyGreen)
                Text("本机图库 · 原片零改动")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }
}
