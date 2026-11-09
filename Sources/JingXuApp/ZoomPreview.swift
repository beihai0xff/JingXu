import SwiftUI
import AppKit
import JingXuCore

struct ZoomPreview: View {
    @EnvironmentObject var model: AppModel
    let item: AssetListItem
    @Binding var showsFilmstrip: Bool
    @Binding var showsInspector: Bool
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
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("返回", systemImage: "chevron.left") {
                    model.leavePreviewLevel()
                }.help(model.colorEditor == nil ? "返回图库（Esc）" : "完成编辑并返回单图")
                Divider().frame(height: 16)
                Button { model.navigatePreview(-1) } label: { Image(systemName: "chevron.left") }
                    .disabled(!model.canNavigatePreview(-1)).accessibilityLabel("上一张")
                Text(item.fileName).lineLimit(1).font(.callout).foregroundStyle(.secondary).help(item.fileName)
                Button { model.navigatePreview(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(!model.canNavigatePreview(1)).accessibilityLabel("下一张")
                Spacer(minLength: 8)
                Button(model.colorEditor == nil ? "编辑" : "完成编辑", systemImage: model.colorEditor == nil ? "slider.horizontal.3" : "checkmark") {
                    if model.colorEditor == nil { model.beginColorEditing() } else { model.finishColorEditing() }
                }.buttonStyle(.borderedProminent).disabled(!model.canStartColorAction)
                Button("导出", systemImage: "square.and.arrow.down") { model.showColorExport() }.disabled(!model.canExportColor)
                Button { model.showPhotoShare() } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(!model.canShowPhotoShare).help("分享当前照片").accessibilityLabel("分享照片")
                if model.colorEditor == nil {
                    Button { showsInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                        .help(showsInspector ? "隐藏照片详情" : "显示照片详情").accessibilityLabel("照片详情")
                }
            }.buttonStyle(.borderless).controlSize(.small)
                .padding(.horizontal, 16).frame(height: 52)
                .background(Color(nsColor: .controlBackgroundColor))
            if let draft = model.colorEditor?.composition {
                CompositionCanvas(draft: draft)
            } else {
                ZoomScroll(image: model.colorPresetPreview?.image ?? model.colorEditor?.result?.image ?? image, assetID: item.id,
                    nativeSize: model.colorPresetPreview?.nativeSize ?? model.colorEditor?.result?.nativeSize ?? nativeSize,
                    action: action, command: command, onExit: model.leavePreviewLevel)
                    .overlay {
                        if model.colorEditor != nil {
                            if model.colorEditor?.result == nil && model.colorEditor?.renderError == nil {
                                ProgressView("正在解码原片…").padding().background(.regularMaterial)
                            }
                        } else if let loadError {
                            VStack(spacing: 10) {
                                Text("载入失败").font(.headline)
                                Text(loadError).font(.caption).multilineTextAlignment(.center)
                                Button("重试") { retry += 1 }
                            }
                            .padding(20).frame(maxWidth: 360)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        } else if isLoading {
                            ProgressView().controlSize(.small).allowsHitTesting(false)
                        }
                    }
            }
            HStack(spacing: 10) {
                Button("适应") { action = "fit"; command += 1 }
                Button("100%") { action = "actual"; command += 1 }
                Button { action = "out"; command += 1 } label: { Image(systemName: "minus") }.accessibilityLabel("缩小")
                Button { action = "in"; command += 1 } label: { Image(systemName: "plus") }.accessibilityLabel("放大")
                if originalPreview?.isEmbedded == true {
                    Text("嵌入预览").font(.caption).foregroundStyle(.secondary)
                        .help("按原片尺寸显示；细节受内嵌预览分辨率限制")
                }
                Spacer()
                if model.colorEditor == nil {
                    ForEach(1...5, id: \.self) { value in
                        Button { model.updateRating(item.rating == value ? 0 : value) } label: {
                            Image(systemName: value <= item.rating ? "star.fill" : "star")
                                .foregroundStyle(value <= item.rating ? Color.accentColor : .secondary)
                        }.accessibilityLabel("\(value) 星")
                    }
                    Button(item.flag == .rejected ? "取消淘汰" : "淘汰", systemImage: "xmark.circle") {
                        model.updateFlag(item.flag == .rejected ? .none : .rejected)
                    }.disabled(model.operationBlockReason(.annotation) != nil)
                }
                Button { showsFilmstrip.toggle() } label: { Image(systemName: "rectangle.bottomthird.inset.filled") }
                    .accessibilityLabel("切换胶片栏").help(showsFilmstrip ? "隐藏胶片栏" : "显示胶片栏")
            }.buttonStyle(.borderless).controlSize(.small).padding(.horizontal, 16).frame(height: 42)
                .disabled(model.colorEditor?.isComposing == true)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .onExitCommand {
            guard !model.isPreviewTransitioning else { return }
            model.leavePreviewLevel()
        }
        .onDisappear { loadGeneration = UUID(); image = nil; originalPreview = nil; nativeSize = .zero; imageAssetID = nil }
        .onChange(of: model.colorEditor?.result.map { ObjectIdentifier($0.image) }) { _, _ in
            guard let result = model.colorEditor?.result else { return }
            image = result.image; nativeSize = result.nativeSize; imageAssetID = item.id; originalPreview = nil
        }
        .task(id: "\(item.id)-\(item.fileVersion)-\(item.colorRevision)-\(retry)-\(model.colorEditor != nil)") {
            guard model.colorEditor == nil else { return }
            let generation = UUID()
            loadGeneration = generation
            isLoading = true; loadError = nil
            if imageAssetID != item.id {
                image = nil; originalPreview = nil; nativeSize = .zero; imageAssetID = item.id
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
        if view.lastCommand != command { view.lastCommand = command; view.photo.perform(action) }
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
        hasVerticalScroller = false; hasHorizontalScroller = false
        allowsMagnification = false
        backgroundColor = .windowBackgroundColor
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
