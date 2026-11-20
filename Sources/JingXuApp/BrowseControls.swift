import AppKit
import SwiftUI
import JingXuCore

struct BrowseSearchField: NSViewRepresentable {
    @Binding var text: String
    let changed: () -> Void
    let submit: () -> Void
    let composing: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "文件名、相机、镜头或标签"
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("browse-search")
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text, (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { field.stringValue = text }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: BrowseSearchField
        init(_ parent: BrowseSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
            if (field.currentEditor() as? NSTextView)?.hasMarkedText() != true { parent.changed() }
            else { parent.composing() }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)), !textView.hasMarkedText() { parent.submit(); return true }
            return false
        }
    }
}

struct PhotoThumbnail: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.displayScale) private var scale
    let item: AssetListItem
    let size: Int
    var aspectMode: GridAspectMode = .aspectFit
    var slotBackground: Color = DarkroomPalette.panelSurface
    var compact = false
    var failureChanged: (Bool) -> Void = { _ in }
    @State private var image: NSImage?
    @State private var failure: String?
    @State private var failureDetail: String?
    @State private var retry = 0
    var body: some View {
        ZStack {
            slotBackground
            if let image {
                if aspectMode == .squareFill && !compact {
                    SquareThumbnail(image: image)
                } else {
                    FittedThumbnail(image: image)
                        .padding(aspectMode == .aspectFit && !compact ? 4 : 0)
                }
            } else if let failure {
                VStack(spacing: 4) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .foregroundStyle(DarkroomPalette.warningAmber)
                    if !compact {
                        Text(item.fileName)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(failure)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        HStack(spacing: 6) {
                            Button("重试") { retry += 1 }.font(.caption2)
                            Button("重新授权…") { model.reauthorizeThumbnailSource(item) }.font(.caption2)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                }
                .padding(6)
                .help(failureDetail ?? failure)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .contextMenu {
            Button("重新载入缩略图") { retry += 1 }
            Button("重新授权来源…") { model.reauthorizeThumbnailSource(item) }
        }
        .task(id: "\(item.id)-\(item.fileVersion)-\(item.colorRevision)-\(size)-\(scale)-\(retry)-\(model.thumbnailReloadID)") {
            image = nil; failure = nil; failureDetail = nil; failureChanged(false)
            do {
                let result = try await model.thumbnail(for: item, pixelSize: size, scale: scale)
                guard !Task.isCancelled else { return }
                image = result
            } catch is CancellationError {} catch {
                guard !Task.isCancelled else { return }
                failureDetail = error.localizedDescription
                failure = (error as NSError).domain == "QLThumbnailErrorDomain"
                    ? "无法生成缩略图，请重试或查看原片"
                    : error.localizedDescription
                failureChanged(true)
            }
        }
        .onDisappear { image = nil; failureChanged(false) }
    }
}

extension AppModel {
    func reauthorizeThumbnailSource(_ item: AssetListItem) {
        guard operationBlockReason(.files) == nil, let source = sources.first(where: { $0.id == item.sourceID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "重新授权：\(source.name)"; panel.message = "请选择原来源目录：\(source.pathHint)"
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url, let store else { return }
        startOperation {
            do {
                guard let data = source.directoryIdentityJSON?.data(using: .utf8) else { throw ColorEditError("来源缺少目录身份，请通过来源扫描重新确认") }
                let expected = try JSONDecoder().decode(SourceIdentity.self, from: data)
                guard try expected.matches(SourceIdentity.resolve(url)) else { throw ColorEditError("所选目录不是原来源") }
                var authorized = source; authorized.bookmarkData = try BookmarkStore.makeBookmark(for: url); authorized.isOnline = true
                try await store.upsertSource(authorized)
                self.automationSelectionToken = UUID()
                await self.reloadAll()
                self.thumbnailReloadID = UUID()
                self.statusText = "来源已授权，请重试载入照片"
            } catch { self.errorMessage = "重新授权失败：\(error.localizedDescription)" }
        }
    }
}
