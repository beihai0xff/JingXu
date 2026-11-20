import AppKit
import JingXuCore
import SwiftUI

/// Kept outside the per-photo preview identity so scrolling and thumbnails survive navigation.
struct PreviewFilmstrip: View {
    @EnvironmentObject private var model: AppModel
    let items: [AssetListItem]
    let currentID: String

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(DarkroomPalette.subtleDivider)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
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
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .onAppear { proxy.scrollTo(currentID, anchor: .center) }
                .onChange(of: currentID) { _, id in proxy.scrollTo(id, anchor: .center) }
                .onChange(of: items.map(\.id)) { _, _ in proxy.scrollTo(currentID, anchor: .center) }
            }
            .frame(height: 64)
        }
        .darkroomPanelSurface()
        .accessibilityIdentifier("preview-filmstrip")
    }
}

private struct FilmstripCell: View {
    let item: AssetListItem
    let selected: Bool

    private var isRejected: Bool { item.flag == .rejected }

    var body: some View {
        PhotoThumbnail(item: item, size: 68, slotBackground: DarkroomPalette.canvasDeep, compact: true)
            .frame(width: 68, height: 46)
            .opacity(isRejected ? 0.42 : 1.0)
            .saturation(isRejected ? 0.45 : 1.0)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(alignment: .topTrailing) {
                if isRejected {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2.5)
                        .background(DarkroomPalette.rejectCoral, in: RoundedRectangle(cornerRadius: 3))
                        .padding(2.5)
                }
            }
            .overlay(alignment: .topLeading) {
                if item.isColorEdited {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2.5)
                        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 3))
                        .padding(2.5)
                }
            }
            .overlay(alignment: .bottom) {
                if item.rating > 0 {
                    Text(String(repeating: "★", count: min(5, item.rating)))
                        .font(.system(size: 8))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.black.opacity(0.65), in: Capsule())
                        .padding(.bottom, 2)
                }
            }
            .padding(2)
            .background(selected ? Color.accentColor.opacity(0.20) : Color.clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : DarkroomPalette.subtleDivider, lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
    }
}

struct SystemPhotoFilmstrip: View {
    @ObservedObject var photos: SystemPhotosModel
    let current: SystemPhoto

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(DarkroomPalette.subtleDivider)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 6) {
                        ForEach(photos.items) { item in
                            Button {
                                photos.open(item, index: photos.offset + (photos.items.firstIndex { $0.id == item.id } ?? 0))
                            } label: {
                                SystemPhotoGridCell(
                                    photo: item,
                                    client: photos.client,
                                    slotFill: DarkroomPalette.canvasDeep,
                                    slotBorder: DarkroomPalette.subtleDivider,
                                    selected: item.id == current.id,
                                    small: true,
                                    showsName: false
                                )
                                .frame(width: 68, height: 48)
                            }
                            .buttonStyle(.plain)
                            .focusable(false)
                            .accessibilityLabel("查看 " + item.name)
                            .id(item.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(height: 64)
                .disabled(!photos.canNavigate)
                .onAppear { proxy.scrollTo(current.id, anchor: .center) }
                .onChange(of: current.id) { _, id in proxy.scrollTo(id, anchor: .center) }
            }
        }
        .darkroomPanelSurface()
    }
}
