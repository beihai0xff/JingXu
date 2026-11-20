import AppKit
import JingXuCore
import SwiftUI

struct LocalLoupeStage: View {
    @EnvironmentObject private var model: AppModel
    let item: AssetListItem
    @Environment(\.displayScale) private var displayScale

    @State private var image: CGImage?
    @State private var imageAssetID: String?
    @State private var nativeSize = CGSize.zero
    @State private var originalPreview: PreviewImage?
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var retry = 0
    @State private var command = 0
    @State private var action = "fit"
    @State private var loadGeneration = UUID()

    private var activeImage: CGImage? {
        model.colorPresetPreview?.image ?? model.colorEditor?.result?.image ?? image
    }

    private var activeNativeSize: CGSize {
        model.colorPresetPreview?.nativeSize ?? model.colorEditor?.result?.nativeSize ?? nativeSize
    }

    var body: some View {
        ZStack {
            if let draft = model.colorEditor?.composition {
                CompositionCanvas(draft: draft)
            } else {
                ZoomScroll(
                    image: activeImage,
                    assetID: item.id,
                    nativeSize: activeNativeSize,
                    action: action,
                    command: command,
                    onExit: model.leavePreviewLevel
                )
                .overlay {
                    stageStatusOverlay
                }
            }
        }
        .overlay(alignment: .top) {
            topComparisonPill
        }
        .overlay(alignment: .bottom) {
            if model.colorEditor?.isComposing != true {
                loupeFloatingBar
            }
        }
        .darkroomStageSurface()
        .onExitCommand {
            guard !model.isPreviewTransitioning else { return }
            model.leavePreviewLevel()
        }
        .onDisappear {
            loadGeneration = UUID()
            image = nil
            originalPreview = nil
            nativeSize = .zero
            imageAssetID = nil
        }
        .onChange(of: model.colorEditor?.result.map { ObjectIdentifier($0.image) }) { _, _ in
            guard let result = model.colorEditor?.result else { return }
            image = result.image
            nativeSize = result.nativeSize
            imageAssetID = item.id
            originalPreview = nil
        }
        .task(id: "\(item.id)-\(item.fileVersion)-\(item.colorRevision)-\(retry)-\(model.colorEditor != nil)") {
            guard model.colorEditor == nil else { return }
            let generation = UUID()
            loadGeneration = generation
            isLoading = true
            loadError = nil
            if imageAssetID != item.id {
                image = nil
                originalPreview = nil
                nativeSize = .zero
                imageAssetID = item.id
                let placeholder = try? await model.thumbnail(for: item, pixelSize: 1024, scale: displayScale)
                guard !Task.isCancelled, loadGeneration == generation else { return }
                image = placeholder?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                nativeSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
            }
            do {
                let result = try await model.loadOriginal(item)
                guard !Task.isCancelled, loadGeneration == generation else { return }
                originalPreview = result
                image = result.image
                nativeSize = result.nativeSize
                isLoading = false
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                isLoading = false
                loadError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var stageStatusOverlay: some View {
        if model.colorEditor != nil {
            if model.colorEditor?.result == nil && model.colorEditor?.renderError == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在解码原片…").font(.caption).foregroundStyle(DarkroomPalette.textPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(DarkroomPalette.panelSurface.opacity(0.92), in: Capsule())
            }
        } else if let loadError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(DarkroomPalette.warningAmber)
                Text("原片载入失败").font(.headline).foregroundStyle(DarkroomPalette.textPrimary)
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(DarkroomPalette.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 10) {
                    Button("重试") { retry += 1 }
                        .buttonStyle(.borderedProminent)
                    Button("重新授权…") { model.reauthorizeThumbnailSource(item) }
                        .buttonStyle(.bordered)
                }
                .controlSize(.small)
            }
            .padding(20)
            .frame(maxWidth: 360)
            .background(DarkroomPalette.panelSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1))
        } else if isLoading && image == nil {
            ProgressView().controlSize(.small).allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var topComparisonPill: some View {
        if model.colorEditor?.comparing == true {
            Text(model.colorEditor?.snapshot.usesRenderedBase == true ? "本次编辑前底图 · 松开恢复成片" : "原片对比中 · 松开恢复成片")
                .font(.caption.weight(.semibold))
                .foregroundStyle(DarkroomPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.accentColor.opacity(0.88), in: Capsule())
                .padding(.top, 12)
                .allowsHitTesting(false)
        } else if model.colorPresetPreview != nil {
            Text("预设预览中（未保存）")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(DarkroomPalette.warningAmber, in: Capsule())
                .padding(.top, 12)
                .allowsHitTesting(false)
        }
    }

    private var loupeFloatingBar: some View {
        HStack(spacing: 10) {
            // Zoom cluster
            HStack(spacing: 6) {
                Button("适应") { action = "fit"; command += 1 }
                Button("100%") { action = "actual"; command += 1 }
                Button { action = "out"; command += 1 } label: { Image(systemName: "minus") }
                    .accessibilityLabel("缩小")
                Button { action = "in"; command += 1 } label: { Image(systemName: "plus") }
                    .accessibilityLabel("放大")
                if originalPreview?.isEmbedded == true && model.colorEditor == nil {
                    Text("嵌入预览")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DarkroomPalette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(DarkroomPalette.elevatedControl, in: Capsule())
                        .help("按原片尺寸显示；细节受 RAW 内嵌预览分辨率限制")
                }
            }

            if model.colorEditor == nil {
                Divider().frame(height: 16).overlay(DarkroomPalette.subtleDivider)

                // Culling cluster (Loupe mode only)
                HStack(spacing: 5) {
                    ForEach(1...5, id: \.self) { value in
                        Button { model.updateRating(item.rating == value ? 0 : value) } label: {
                            Image(systemName: value <= item.rating ? "star.fill" : "star")
                                .foregroundStyle(value <= item.rating ? Color.yellow : DarkroomPalette.textSecondary)
                        }
                        .accessibilityLabel("\(value) 星")
                    }

                    Button {
                        model.updateFlag(item.flag == .rejected ? .none : .rejected)
                    } label: {
                        Label(
                            item.flag == .rejected ? "取消淘汰" : "淘汰",
                            systemImage: item.flag == .rejected ? "arrow.uturn.backward.circle" : "xmark.circle"
                        )
                        .foregroundStyle(item.flag == .rejected ? DarkroomPalette.rejectCoral : DarkroomPalette.textPrimary)
                    }
                    .disabled(model.operationBlockReason(.annotation) != nil)
                    .help("快捷键 X / Delete 淘汰并下一张，U 取消淘汰")

                    if let groupID = item.similarGroupID {
                        Button("组对比", systemImage: "rectangle.split.2x1") {
                            model.compareSimilarGroup(groupID)
                        }
                        .disabled(model.operationBlockReason(.browse) != nil)
                        .help("对比此相似连拍组（C）")
                    }
                }
            }

            Divider().frame(height: 16).overlay(DarkroomPalette.subtleDivider)

            HStack(spacing: 8) {
                if let editor = model.colorEditor {
                    Button(editor.comparing ? "松开恢复" : "按住 \\ 对比原图") {}
                        .buttonStyle(OriginalComparisonButtonStyle { pressed in
                            if pressed { editor.beginComparison() } else { editor.endComparison() }
                        })
                        .disabled(!editor.usable || model.isWorking)
                }

                Button {
                    model.showsFilmstrip.toggle()
                } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                        .foregroundStyle(model.showsFilmstrip ? Color.accentColor : DarkroomPalette.textSecondary)
                }
                .accessibilityLabel("切换胶片栏")
                .help(model.showsFilmstrip ? "隐藏胶片栏（F）" : "显示胶片栏（F）")
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background {
            Capsule(style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(Capsule(style: .continuous).fill(DarkroomPalette.floatingHUDFill))
                .overlay(Capsule(style: .continuous).strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1))
        }
        .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
        .padding(.bottom, 12)
    }
}

struct SystemPhotoLoupeStage: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var photos: SystemPhotosModel
    let photo: SystemPhoto

    @State private var canvasCommand = 0
    @State private var canvasAction = "fit"

    private var displayedImage: CGImage? {
        photos.presetPreview?.image ?? photos.editor?.result?.image ?? photos.previewImage?.image
    }

    private var displayedNativeSize: CGSize {
        photos.presetPreview?.nativeSize ?? photos.editor?.result?.nativeSize ?? photos.previewImage?.nativeSize ?? .zero
    }

    var body: some View {
        ZStack {
            if let draft = photos.editor?.composition {
                CompositionCanvas(draft: draft)
            } else {
                ZoomScroll(
                    image: displayedImage,
                    assetID: photo.id,
                    nativeSize: displayedNativeSize,
                    action: canvasAction,
                    command: canvasCommand,
                    onExit: photos.leavePreviewLevel,
                    onTransformChange: photos.updatePreviewDetail
                )
            }
        }
        .overlay(alignment: .top) {
            VStack(spacing: 6) {
                if photos.editor?.comparing == true {
                    Text(photos.editor?.snapshot.usesRenderedBase == true ? "本次编辑前底图 · 松开恢复成片" : "原片对比中 · 松开恢复成片")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(DarkroomPalette.textPrimary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.88), in: Capsule())
                }
                if photos.previewSession.failedIndex != nil {
                    HStack(spacing: 8) {
                        Text("照片未切换，当前画面与草稿已保留").font(.caption)
                        Button("重试读取") { photos.retryPreview() }.buttonStyle(.bordered).controlSize(.mini)
                        if photos.previewSession.failedPhoto != nil {
                            Button("放弃目标草稿并重载…") { photos.discardDraft() }.buttonStyle(.bordered).controlSize(.mini)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(DarkroomPalette.panelSurface.opacity(0.95), in: Capsule())
                    .disabled(!photos.canAct)
                }
                if let conflict = photos.conflict {
                    HStack(spacing: 8) {
                        Text(conflict).font(.caption).foregroundStyle(DarkroomPalette.warningAmber)
                        Button("放弃草稿并重载…") { photos.discardDraft() }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                            .disabled(!photos.canAct)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(DarkroomPalette.panelSurface.opacity(0.95), in: Capsule())
                }
                if photos.isNavigating || photos.previewSession.isLoadingFullImage {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(photos.isNavigating ? "正在读取照片或恢复草稿…" : "正在准备 100% 完整画质…")
                            .font(.caption)
                            .foregroundStyle(DarkroomPalette.textSecondary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(DarkroomPalette.panelSurface.opacity(0.92), in: Capsule())
                }
            }
            .padding(.top, 12)
        }
        .overlay(alignment: .bottom) {
            if photos.editor?.isComposing != true {
                HStack(spacing: 10) {
                    Button("适应") { canvasAction = "fit"; canvasCommand += 1 }
                    Button("100%") {
                        photos.prepareFullImage { _ in canvasAction = "actual"; canvasCommand += 1 }
                    }
                    .disabled(!photos.canAct)
                    Button { canvasAction = "out"; canvasCommand += 1 } label: { Image(systemName: "minus") }
                        .accessibilityLabel("缩小")
                    Button { canvasAction = "in"; canvasCommand += 1 } label: { Image(systemName: "plus") }
                        .accessibilityLabel("放大")

                    Divider().frame(height: 16).overlay(DarkroomPalette.subtleDivider)

                    Text("\(photos.previewIndex + 1) / \(photos.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(DarkroomPalette.textSecondary)

                    if let editor = photos.editor {
                        Divider().frame(height: 16).overlay(DarkroomPalette.subtleDivider)
                        Button(editor.comparing ? "松开恢复" : "按住 \\ 对比") {}
                            .buttonStyle(OriginalComparisonButtonStyle { pressed in
                                if pressed { editor.beginComparison() } else { editor.endComparison() }
                            })
                            .disabled(!editor.usable || photos.isBusy)
                    }

                    Divider().frame(height: 16).overlay(DarkroomPalette.subtleDivider)

                    Button {
                        model.showsFilmstrip.toggle()
                    } label: {
                        Image(systemName: "rectangle.bottomthird.inset.filled")
                            .foregroundStyle(model.showsFilmstrip ? Color.accentColor : DarkroomPalette.textSecondary)
                    }
                    .accessibilityLabel("切换胶片栏")
                    .help(model.showsFilmstrip ? "隐藏胶片栏（F）" : "显示胶片栏（F）")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule(style: .continuous).fill(DarkroomPalette.floatingHUDFill))
                        .overlay(Capsule(style: .continuous).strokeBorder(DarkroomPalette.subtleDivider, lineWidth: 1))
                }
                .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                .padding(.bottom, 12)
            }
        }
        .darkroomStageSurface()
    }
}

struct ZoomScroll: NSViewRepresentable {
    let image: CGImage?
    let assetID: String
    let nativeSize: CGSize
    let action: String
    let command: Int
    let onExit: () -> Void
    var onTransformChange: ((CanvasTransform) -> Void)? = nil

    func makeNSView(context: Context) -> PhotoScrollView { PhotoScrollView() }

    func updateNSView(_ view: PhotoScrollView, context: Context) {
        view.photo.onExit = onExit
        view.photo.onTransformChange = onTransformChange
        view.photo.setImage(image, assetID: assetID, nativeSize: nativeSize)
        if view.lastCommand != command {
            view.lastCommand = command
            view.photo.perform(action)
        }
    }

    static func dismantleNSView(_ view: PhotoScrollView, coordinator: ()) {
        view.photo.clearImage()
        view.photo.onExit = nil
        view.photo.onTransformChange = nil
    }
}

final class PhotoScrollView: NSScrollView {
    let photo = PreviewCanvasView()
    var lastCommand = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = false
        hasHorizontalScroller = false
        allowsMagnification = false
        backgroundColor = NSColor(srgbRed: 20.0 / 255.0, green: 20.0 / 255.0, blue: 22.0 / 255.0, alpha: 1.0)
        documentView = photo
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }

    override func layout() {
        super.layout()
        let viewport = NSRect(origin: .zero, size: contentSize)
        if photo.frame != viewport { photo.frame = viewport }
    }

    override func magnify(with event: NSEvent) { photo.magnify(with: event) }
    override func scrollWheel(with event: NSEvent) { photo.scrollWheel(with: event) }
}
