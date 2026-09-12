import AppKit
import SwiftUI
import JingXuCore

struct LibraryKeyboardHandler: NSViewRepresentable {
    let enabled: Bool
    let requiresCanvasFocus: Bool
    let action: (UInt16, String, Bool, Bool) -> Bool
    func makeNSView(context: Context) -> KeyboardView { KeyboardView() }
    func updateNSView(_ view: KeyboardView, context: Context) {
        view.enabled = enabled; view.requiresCanvasFocus = requiresCanvasFocus; view.action = action
    }
    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) { view.stop() }
}
final class KeyboardView: NSView {
    var enabled = false
    var requiresCanvasFocus = false
    var action: ((UInt16, String, Bool, Bool) -> Bool)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.enabled, let window = self.window, window.isKeyWindow,
                      event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
                      (!self.requiresCanvasFocus || window.firstResponder is PreviewCanvasView),
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField), !(window.firstResponder is NSSlider),
                      (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
                      event.modifierFlags.intersection([.control, .option]).isEmpty else { return false }
                if [51, 117].contains(event.keyCode) && event.isARepeat { return true }
                return self.action?(event.keyCode, event.charactersIgnoringModifiers?.lowercased() ?? "",
                    event.modifierFlags.contains(.shift), event.modifierFlags.contains(.command)) ?? false
            }
            return handled ? nil : event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

extension AppModel {
    func handleLibraryKey(code: UInt16, text: String, shift: Bool, command: Bool) -> Bool {
        if command {
            if text == "a", previewAsset == nil { selectVisiblePhotos(); return true }
            if text == "z" { performUndo(redo: shift); return true }
            return false
        }
        if let rating = Int(text), (0...5).contains(rating) { updateRating(rating, advanceToNext: shift); return true }
        if code == 51 || code == 117 { updateFlag(.rejected, advanceToNext: annotationTargetIDs.count == 1); return true }
        if text == "u", !shift { updateFlag(.none); return true }
        if [123, 124, 125, 126].contains(code) {
            if previewAsset != nil {
                if code == 123 || code == 124 { navigatePreview(code == 123 ? -1 : 1); return true }
                return false
            }
            guard !assets.isEmpty else { return false }
            let step = code == 123 ? -1 : code == 124 ? 1 : code == 125 ? gridColumns : -gridColumns
            let index = assets.firstIndex { $0.id == selectedAssetID }
            let target = index.map { min(assets.count - 1, max(0, $0 + step)) } ?? 0
            let item = assets[target]
            if shift { clickAsset(item, command: false, shift: true, count: 1) }
            else { transitionPreview { self.selectAsset(item); self.syncKeywordDraft() } }
            return true
        }
        if code == 49, let item = selectedAsset, previewAsset == nil { openPreview(item); return true }
        return false
    }
}
