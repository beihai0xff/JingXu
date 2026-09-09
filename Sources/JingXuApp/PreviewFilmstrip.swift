import SwiftUI
import AppKit
import JingXuCore

/// Kept outside the per-photo preview identity so scrolling and thumbnails survive navigation.
struct PreviewFilmstrip: View {
    @EnvironmentObject private var model: AppModel
    let items: [AssetListItem]
    let currentID: String

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text("胶片栏")
                Text("\((items.firstIndex { $0.id == currentID } ?? 0) + 1) / \(items.count)")
                    .monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Text("点击缩略图 · ← / → 切图").foregroundStyle(.secondary)
            }.font(.caption).padding(.horizontal, 12).padding(.top, 6)
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
            }.frame(height: 132)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
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
        VStack(spacing: 4) {
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
            }.frame(width: 96, height: 64).clipped()
            .overlay(alignment: .topTrailing) {
                if item.flag == .rejected || item.flag == .picked {
                    Image(systemName: item.flag == .rejected ? "xmark" : "checkmark")
                        .font(.caption2.bold()).padding(3)
                        .background(item.flag == .rejected ? Color.red : Color.green, in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white).padding(3)
                }
            }
            Text(item.fileName).font(.system(size: 10)).lineLimit(1).truncationMode(.middle)
            Text(item.rating > 0 ? String(repeating: "★", count: min(5, item.rating)) : " ")
                .font(.system(size: 9)).foregroundStyle(.yellow)
        }
        .frame(width: 96).padding(4)
        .background(selected ? Color.accentColor.opacity(0.22) : Color.clear)
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.2), lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .task(id: item.id) {
            thumbnail = nil
            loading = true
            let result = await model.thumbnail(for: item, pixelSize: 192)
            guard !Task.isCancelled else { return }
            thumbnail = result; loading = false
        }
        .onDisappear { thumbnail = nil }
    }
}
