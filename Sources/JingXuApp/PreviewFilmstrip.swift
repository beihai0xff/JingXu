import SwiftUI
import AppKit
import JingXuCore

/// Kept outside the per-photo preview identity so scrolling and thumbnails survive navigation.
struct PreviewFilmstrip: View {
    @EnvironmentObject private var model: AppModel
    let items: [AssetListItem]
    let currentID: String

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 6) {
                    ForEach(items) { item in
                        Button { model.selectPreview(id: item.id) } label: {
                            FilmstripCell(item: item, selected: item.id == currentID)
                        }
                        .buttonStyle(.plain)
                        .focusable(false)
                        .disabled(!model.previewNavigationEnabled)
                        .accessibilityLabel("\(item.fileName)\(item.id == currentID ? "，当前照片" : "")")
                        .help(item.fileName)
                        .id(item.id)
                    }
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }
            .onAppear { proxy.scrollTo(currentID, anchor: .center) }
            .onChange(of: currentID) { _, id in proxy.scrollTo(id, anchor: .center) }
            .onChange(of: items.map(\.id)) { _, _ in proxy.scrollTo(currentID, anchor: .center) }
        }
        .frame(height: 72)
        .background(Color(nsColor: .controlBackgroundColor))
        .accessibilityIdentifier("preview-filmstrip")
    }
}

private struct FilmstripCell: View {
    @EnvironmentObject private var model: AppModel
    let item: AssetListItem
    let selected: Bool
    @State private var thumbnail: NSImage?
    @State private var loading = true

    var body: some View {
        ZStack(alignment: .center) {
            Color.black
            if let thumbnail {
                FittedThumbnail(image: thumbnail)
            } else if loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "photo.badge.exclamationmark")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 72, height: 48).clipped()
        .overlay(alignment: .topTrailing) {
            if item.flag == .rejected {
                Image(systemName: "xmark")
                    .font(.caption2.bold()).padding(3)
                    .background(Color.red, in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white).padding(3)
            }
        }
        .overlay(alignment: .topLeading) {
            if item.isColorEdited { Image(systemName: "slider.horizontal.3").font(.caption2).padding(3).background(.purple).help("已调色") }
        }
        .overlay(alignment: .bottom) {
            if item.rating > 0 {
                Text(String(repeating: "★", count: min(5, item.rating)))
                    .font(.system(size: 9)).foregroundStyle(.yellow)
                    .padding(.horizontal, 3).background(.black.opacity(0.65))
            }
        }
        .padding(4)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .task(id: "\(item.id)-\(item.fileVersion)-\(item.colorRevision)") {
            thumbnail = nil
            loading = true
            let result = await model.thumbnail(for: item, pixelSize: 192)
            guard !Task.isCancelled else { return }
            thumbnail = result; loading = false
        }
        .onDisappear { thumbnail = nil }
    }
}
