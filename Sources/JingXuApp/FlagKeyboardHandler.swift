import SwiftUI
import AppKit
import JingXuCore

// Window-scoped local monitor: text editing and modal UI retain their key events.
struct FlagKeyboardHandler: NSViewRepresentable {
    let enabled: Bool
    let action: (AssetFlag) -> Void
    func makeNSView(context: Context) -> KeyboardView { KeyboardView() }
    func updateNSView(_ view: KeyboardView, context: Context) { view.enabled = enabled; view.action = action }
    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) { view.stop() }
}

final class KeyboardView: NSView {
    var enabled = false
    var action: ((AssetFlag) -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.enabled, let window = self.window, window.isKeyWindow,
                      event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
                      let key = event.charactersIgnoringModifiers?.lowercased(), key == "x" || key == "u" else { return false }
                self.action?(key == "x" ? .rejected : .none)
                return true
            }
            return handled ? nil : event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
