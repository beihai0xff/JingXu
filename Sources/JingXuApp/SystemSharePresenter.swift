import AppKit
import SwiftUI
import JingXuCore

@MainActor final class SystemSharePresenter: NSObject, PhotoSharePresenting, @MainActor NSSharingServicePickerDelegate, NSSharingServiceDelegate {
    var anchor: NSView?
    private weak var sourceWindow: NSWindow?
    private var picker: NSSharingServicePicker?
    private var service: NSSharingService?
    private var event: (@MainActor (PhotoShareEvent) -> Void)?

    func show(files: [URL], event: @escaping @MainActor (PhotoShareEvent) -> Void) throws {
        guard picker == nil, let anchor, let window = anchor.window, !files.isEmpty else {
            throw ColorEditError("分享窗口不可用，请重新打开分享准备页")
        }
        self.event = event; sourceWindow = window.sheetParent ?? window
        let picker = NSSharingServicePicker(items: files)
        self.picker = picker; picker.delegate = self
        picker.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }
    func dismiss() {
        // The service has no general cancellation API. This only closes our picker.
        picker?.delegate = nil; picker?.close(); picker = nil
        service?.delegate = nil; service = nil; event = nil; anchor = nil; sourceWindow = nil
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, delegateFor sharingService: NSSharingService) -> (any NSSharingServiceDelegate)? {
        guard sharingServicePicker === picker else { return nil }
        service = sharingService
        return self
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        guard sharingServicePicker === picker else { return }
        if let service { self.service = service; event?(.chosen(service.title)) }
        else { event?(.cancelled) }
    }
    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        guard sharingService === service else { return }; event?(.completed)
    }
    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        guard sharingService === service else { return }; event?(.failed(error.localizedDescription))
    }
    func sharingService(_ sharingService: NSSharingService, sourceWindowForShareItems items: [Any], sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>) -> NSWindow? {
        sourceWindow
    }
}

/// AppKit requires showing the picker in a user mouse-down action, not a decode completion.
struct NativeShareButton: NSViewRepresentable {
    let presenter: SystemSharePresenter
    let session: PhotoShareSession
    func makeNSView(context: Context) -> ShareButton {
        let button = ShareButton(title: "系统分享…", target: nil, action: #selector(ShareButton.share))
        button.bezelStyle = .rounded; button.target = button
        button.sendAction(on: .leftMouseDown)
        return button
    }
    func updateNSView(_ button: ShareButton, context: Context) {
        button.presenter = presenter; button.session = session; button.isEnabled = session.canPresent
    }
    @MainActor final class ShareButton: NSButton {
        weak var presenter: SystemSharePresenter?
        weak var session: PhotoShareSession?
        @objc func share() { presenter?.anchor = self; session?.present() }
    }
}
