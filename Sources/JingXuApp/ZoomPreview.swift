import SwiftUI
import AppKit
import JingXuCore

struct ZoomPreview: View {
    @EnvironmentObject var model: AppModel
    let item: AssetListItem
    @Binding var showsFilmstrip: Bool
    @Binding var showsInspector: Bool
    @State private var image: CGImage?
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
                Button { model.closePreview() } label: {
                    Label("返回网格", systemImage: "square.grid.2x2")
                        .labelStyle(.iconOnly)
                }.help("返回网格（Esc）")
                Divider().frame(height: 16)
                Button { model.navigatePreview(-1) } label: {
                    Label("上一张", systemImage: "chevron.left").labelStyle(.iconOnly)
                }.disabled(!model.canNavigatePreview(-1)).help("上一张（←）")
                Text("\((model.previewFilmstrip.firstIndex { $0.id == item.id } ?? 0) + 1) / \(model.previewFilmstrip.count)")
                    .monospacedDigit().font(.caption).foregroundStyle(.secondary)
                    .help(item.fileName)
                Button { model.navigatePreview(1) } label: {
                    Label("下一张", systemImage: "chevron.right").labelStyle(.iconOnly)
                }.disabled(!model.canNavigatePreview(1)).help("下一张（→）")
                if item.flag == .rejected {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red).accessibilityLabel("已淘汰").help("已淘汰（U 取消）")
                }
                Spacer()
                if originalPreview?.isEmbedded == true {
                    Text("嵌入预览").font(.caption).foregroundStyle(.secondary)
                        .help("当前显示文件内嵌预览，100% 按预览图像像素显示")
                }
                Button("适应") { action = "fit"; command += 1 }.help("适应窗口，完整显示照片")
                Button("100%") { action = "actual"; command += 1 }
                    .help("按屏幕物理像素查看")
                Button { action = "out"; command += 1 } label: {
                    Label("缩小", systemImage: "minus").labelStyle(.iconOnly)
                }.help("缩小")
                Button { action = "in"; command += 1 } label: {
                    Label("放大", systemImage: "plus").labelStyle(.iconOnly)
                }.help("放大")
                Divider().frame(height: 16)
                Button { showsFilmstrip.toggle() } label: {
                    Label("胶片栏", systemImage: "rectangle.bottomthird.inset.filled")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(showsFilmstrip ? Color.accentColor : Color.primary)
                }.help(showsFilmstrip ? "隐藏胶片栏" : "显示胶片栏")
                Button { showsInspector.toggle() } label: {
                    Label("照片信息", systemImage: "info.circle")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(showsInspector ? Color.accentColor : Color.primary)
                }.help(showsInspector ? "隐藏照片信息" : "显示照片信息")
            }
            .buttonStyle(.borderless).controlSize(.small)
            .padding(.horizontal, 12).frame(height: 36)
            .background(Color(nsColor: .controlBackgroundColor))
            ZoomScroll(image: image, action: action, command: command, onExit: { model.closePreview() })
                .overlay {
                    if let loadError {
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
        .onExitCommand { model.closePreview() }
        .onDisappear { loadGeneration = UUID(); image = nil; originalPreview = nil }
        .task(id: "\(item.id)-\(retry)") {
            let generation = UUID()
            loadGeneration = generation
            image = nil; originalPreview = nil; isLoading = true; loadError = nil
            let placeholder = await model.thumbnail(for: item, pixelSize: 1024)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            image = placeholder?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            do {
                let result = try await model.loadOriginal(item)
                guard !Task.isCancelled, loadGeneration == generation else { return }
                originalPreview = result
                image = result.image
                isLoading = false
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                isLoading = false
                loadError = error.localizedDescription
            }
        }
    }
}

private struct ZoomScroll: NSViewRepresentable {
    let image: CGImage?
    let action: String
    let command: Int
    let onExit: () -> Void
    func makeNSView(context: Context) -> PhotoScrollView { PhotoScrollView() }
    func updateNSView(_ view: PhotoScrollView, context: Context) {
        view.photo.onExit = onExit
        view.photo.setImage(image)
        if view.lastCommand != command { view.lastCommand = command; view.photo.perform(action) }
    }
    static func dismantleNSView(_ view: PhotoScrollView, coordinator: ()) {
        view.photo.setImage(nil)
        view.photo.onExit = nil
    }
}

private final class PhotoScrollView: NSScrollView {
    let photo = PreviewCanvasView()
    var lastCommand = -1
    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = false; hasHorizontalScroller = false
        allowsMagnification = false
        backgroundColor = .black
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
