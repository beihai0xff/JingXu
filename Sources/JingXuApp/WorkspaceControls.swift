import SwiftUI
import JingXuCore

enum PhotoInspectorTab: String, CaseIterable {
    case information = "信息", quality = "质量"
}

struct WorkspaceSwitcher: View {
    let systemPhotos: Bool
    let selectLocal: () -> Void
    let selectSystem: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            workspace("本地图库", selected: !systemPhotos, action: selectLocal)
            workspace("系统照片", selected: systemPhotos, action: selectSystem)
        }
        .padding(3)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12).padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("切换图库")
    }

    private func workspace(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.callout).frame(maxWidth: .infinity).padding(.vertical, 5)
                .background(selected ? Color(nsColor: .controlBackgroundColor) : .clear,
                            in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct GridViewOptions: View {
    @Binding var size: CGFloat
    @Binding var showsFileNames: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("照片视图").font(.headline)
            HStack {
                Text("照片大小")
                Slider(value: $size, in: 100...260).frame(width: 130).accessibilityLabel("照片大小")
            }
            Toggle("显示文件名", isOn: $showsFileNames)
        }
    }
}

struct FilterChip: View {
    let title: String
    let remove: () -> Void
    var body: some View {
        Button(action: remove) {
            HStack(spacing: 5) { Text(title); Image(systemName: "xmark").font(.caption2) }
                .font(.caption).padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 5))
        }.buttonStyle(.plain).foregroundStyle(.tint).accessibilityLabel("移除筛选：\(title)")
    }
}

extension AppModel {
    var libraryTitle: String {
        switch sidebarSelection {
        case .smart(let collection): collection.displayName
        case .source(let id): sources.first { $0.id == id }?.name ?? "文件夹"
        case .folder(let folder): folder.relativeDirectory.split(separator: "/").last.map(String.init) ?? "文件夹"
        case .album(let id): albums.first { $0.id == id }?.name ?? "相册"
        case nil: "全部项目"
        }
    }
}
struct BrowseLoadMore: View {
    let title: String
    let isLoading: Bool
    let canLoad: Bool
    let load: () -> Void
    @State private var isVisible = false

    var body: some View {
        Button(action: load) {
            HStack {
                if isLoading { ProgressView().controlSize(.small) }
                Text(title).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(16)
        }.buttonStyle(.plain).disabled(!canLoad)
            .onAppear { isVisible = true; if canLoad { load() } }
            .onDisappear { isVisible = false }
            .onChange(of: canLoad) { _, ready in if ready && isVisible { load() } }
    }
}

