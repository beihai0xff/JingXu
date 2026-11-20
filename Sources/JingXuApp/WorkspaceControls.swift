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
            workspace("本地图库", symbol: "externaldrive", selected: !systemPhotos, action: selectLocal)
            workspace("系统照片", symbol: "icloud", selected: systemPhotos, action: selectSystem)
        }
        .padding(3)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("切换图库")
    }

    private func workspace(_ title: String, symbol: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.caption)
                Text(title).font(.caption.weight(selected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .background(
                selected ? Color.accentColor.opacity(0.20) : Color.clear,
                in: RoundedRectangle(cornerRadius: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct GridViewOptions: View {
    @Binding var size: CGFloat
    @Binding var aspectMode: GridAspectMode
    @Binding var showsFileNames: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("网格视图选项").font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                Text("缩略图画幅").font(.caption).foregroundStyle(.secondary)
                Picker("缩略图画幅", selection: $aspectMode) {
                    ForEach(GridAspectMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbolName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("网格尺寸").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(size)) pt").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $size, in: 100...260)
                    .accessibilityLabel("照片大小")
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

