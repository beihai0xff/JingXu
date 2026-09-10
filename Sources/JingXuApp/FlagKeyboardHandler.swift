import SwiftUI
import AppKit
import Carbon.HIToolbox
import JingXuCore

// Window-scoped local monitor: text editing and modal UI retain their key events.
struct FlagKeyboardHandler: NSViewRepresentable {
    let enabled: Bool
    var requiresCanvasFocus = false
    var navigate: ((Int) -> Void)? = nil
    let action: (AssetFlag) -> Void
    func makeNSView(context: Context) -> KeyboardView { KeyboardView() }
    func updateNSView(_ view: KeyboardView, context: Context) {
        view.enabled = enabled; view.requiresCanvasFocus = requiresCanvasFocus; view.action = action; view.navigate = navigate
    }
    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) { view.stop() }
}

final class KeyboardView: NSView {
    var enabled = false
    var requiresCanvasFocus = false
    var action: ((AssetFlag) -> Void)?
    var navigate: ((Int) -> Void)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.enabled, let window = self.window, window.isKeyWindow,
                      event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
                      (!self.requiresCanvasFocus || window.firstResponder is PreviewCanvasView),
                      !(window.firstResponder is NSSlider),
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
                      (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
                      event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
                if let navigate = self.navigate, event.keyCode == 123 || event.keyCode == 124 {
                    navigate(event.keyCode == 123 ? -1 : 1)
                    return true
                }
                if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                    // Holding Delete must not reject every photo as selection advances.
                    guard !event.isARepeat else { return true }
                    self.action?(.rejected)
                } else if event.charactersIgnoringModifiers?.lowercased() == "u" {
                    self.action?(.none)
                } else {
                    return false
                }
                return true
            }
            return handled ? nil : event
        }
    }
    func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}
