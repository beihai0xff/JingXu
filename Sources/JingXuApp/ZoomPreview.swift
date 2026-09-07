import SwiftUI
import AppKit
import JingXuCore

@MainActor
final class PreviewWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var assetID: String?
    var activeAssetID: String? { window?.isKeyWindow == true ? assetID : nil }
    func show(item: AssetListItem, model: AppModel) {
        close()
        assetID = item.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = item.fileName
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: ZoomPreview(item: item).environmentObject(model))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
    func close() { window?.close(); window = nil }
    func windowWillClose(_ notification: Notification) { window?.contentView = nil }
}

private struct ZoomPreview: View {
    @EnvironmentObject var model: AppModel
    let item: AssetListItem
    @State private var image: NSImage?
    @State private var message = "正在载入原图…"
    @State private var retry = 0
    @State private var command = 0
    @State private var action = "fit"
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("适应窗口") { action = "fit"; command += 1 }
                Button("100%") { action = "actual"; command += 1 }
                Button("−") { action = "out"; command += 1 }
                Button("+") { action = "in"; command += 1 }
                Spacer()
                Text(message).font(.caption).lineLimit(2)
                Button("重试") { retry += 1 }
            }.padding(10)
            ZoomScroll(image: image, action: action, command: command)
        }
        .onExitCommand { model.closePreview() }
        .background(FlagKeyboardHandler(enabled: !model.isDeleting && model.deletionPlan == nil && model.sourceMergePlan == nil && model.errorMessage == nil) { flag in
            model.updateFlag(flag, assetID: item.id)
        })
        .task(id: retry) {
            let placeholder = await model.thumbnail(for: item, pixelSize: 1024)
            guard !Task.isCancelled else { return }
            image = placeholder
            do {
                let result = try await model.loadOriginal(item)
                guard !Task.isCancelled else { return }
                image = NSImage(cgImage: result.image, size: NSSize(width: result.image.width, height: result.image.height))
                message = "\(result.isEmbedded ? "嵌入预览 · " : "")\(result.image.width) × \(result.image.height)"
            } catch is CancellationError {} catch { message = "载入失败：\(error.localizedDescription)" }
        }
    }
}

private struct ZoomScroll: NSViewRepresentable {
    let image: NSImage?
    let action: String
    let command: Int
    func makeNSView(context: Context) -> PhotoScrollView { PhotoScrollView() }
    func updateNSView(_ view: PhotoScrollView, context: Context) {
        if view.photo.image !== image { view.photo.image = image; view.fit() }
        if view.lastCommand != command { view.lastCommand = command; view.perform(action) }
    }
}

private final class PhotoScrollView: NSScrollView {
    let photo = PanImageView()
    var lastCommand = -1
    var fitted = true
    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true; hasHorizontalScroller = true
        allowsMagnification = true; minMagnification = 0.01; maxMagnification = 16
        backgroundColor = .black
        photo.imageScaling = .scaleAxesIndependently
        documentView = photo
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) unavailable") }
    override func layout() { super.layout(); if fitted { fit() } }
    func fit() {
        guard let image = photo.image else { return }
        fitted = true
        let frame = NSRect(origin: .zero, size: image.size)
        if photo.frame != frame { photo.frame = frame }
        let scale = min(contentSize.width / max(1, image.size.width), contentSize.height / max(1, image.size.height))
        let target = PreviewScale.bounded(scale)
        if abs(magnification - target) > 0.0001 { magnification = target }
    }
    func perform(_ action: String) {
        if action == "fit" { fit(); return }
        fitted = false
        let scale = window?.backingScaleFactor ?? 2
        let target = action == "actual" ? PreviewScale.actualPixels(backingScale: scale) : magnification * (action == "in" ? 1.5 : 1 / 1.5)
        magnification = PreviewScale.bounded(target)
    }
    override func magnify(with event: NSEvent) { fitted = false; super.magnify(with: event) }
    override func keyDown(with event: NSEvent) { if event.keyCode == 53 { window?.close() } else { super.keyDown(with: event) } }
}

private final class PanImageView: NSImageView {
    private var anchor = NSPoint.zero
    private var initial = NSPoint.zero
    override func mouseDown(with event: NSEvent) {
        guard let scroll = enclosingScrollView as? PhotoScrollView else { return }
        if event.clickCount == 2 { scroll.perform(scroll.fitted ? "actual" : "fit"); return }
        anchor = event.locationInWindow; initial = scroll.contentView.bounds.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        let now = event.locationInWindow
        scroll.contentView.scroll(to: NSPoint(x: initial.x - (now.x - anchor.x) / scroll.magnification, y: initial.y - (now.y - anchor.y) / scroll.magnification))
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
