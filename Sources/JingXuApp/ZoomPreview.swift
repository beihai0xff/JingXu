import SwiftUI
import AppKit
import JingXuCore

struct ZoomPreview: View {
    @EnvironmentObject var model: AppModel
    let item: AssetListItem
    @State private var image: CGImage?
    @State private var message = "正在载入原图…"
    @State private var retry = 0
    @State private var command = 0
    @State private var action = "fit"
    @State private var loadGeneration = UUID()
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { model.closePreview() } label: {
                    Label("返回网格", systemImage: "square.grid.2x2")
                }.help("返回网格（Esc）")
                Button("适应窗口") { action = "fit"; command += 1 }
                Button("100%") { action = "actual"; command += 1 }
                Button("−") { action = "out"; command += 1 }
                Button("+") { action = "in"; command += 1 }
                Spacer()
                Button("重试") { retry += 1 }
            }.padding(10)
            HStack {
                Text(item.fileName).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(message).lineLimit(2)
            }.font(.caption).padding(.horizontal, 10).padding(.bottom, 8)
            HStack {
                Button { model.navigatePreview(-1) } label: {
                    Label("上一张", systemImage: "chevron.left")
                }.disabled(!model.canNavigatePreview(-1)).help("上一张（←）")
                Button { model.navigatePreview(1) } label: {
                    Label("下一张", systemImage: "chevron.right")
                }.disabled(!model.canNavigatePreview(1)).help("下一张（→）")
                Spacer()
                Text("← / → 切换图片").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 10).padding(.bottom, 8)
            ZoomScroll(image: image, action: action, command: command, onExit: { model.closePreview() })
        }
        .onExitCommand { model.closePreview() }
        .onDisappear { loadGeneration = UUID(); image = nil }
        .task(id: "\(item.id)-\(retry)") {
            let generation = UUID()
            loadGeneration = generation
            image = nil; message = "正在载入原图…"
            let placeholder = await model.thumbnail(for: item, pixelSize: 1024)
            guard !Task.isCancelled, loadGeneration == generation else { return }
            image = placeholder?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            do {
                let result = try await model.loadOriginal(item)
                guard !Task.isCancelled, loadGeneration == generation else { return }
                image = result.image
                message = "\(result.isEmbedded ? "嵌入预览 · " : "")\(result.image.width) × \(result.image.height)"
            } catch is CancellationError {} catch {
                guard !Task.isCancelled, loadGeneration == generation else { return }
                message = "载入失败：\(error.localizedDescription)"
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
