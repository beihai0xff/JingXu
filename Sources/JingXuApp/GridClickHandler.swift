import AppKit
import SwiftUI

/// Capture modifiers and click count from the actual mouse event, not delayed SwiftUI tap gestures.
struct GridClickHandler: NSViewRepresentable {
    let label: String
    let action: (Bool, Bool, Int) -> Void
    func makeNSView(context: Context) -> ClickView { ClickView() }
    func updateNSView(_ view: ClickView, context: Context) {
        view.action = action; view.setAccessibilityLabel(label)
    }
    @MainActor final class ClickView: NSView {
        var action: ((Bool, Bool, Int) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            // Context menus and scrolling stay with the enclosing SwiftUI cell.
            guard let type = NSApp.currentEvent?.type, type == .leftMouseDown || type == .leftMouseUp else { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {
            guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
            action?(event.modifierFlags.contains(.command), event.modifierFlags.contains(.shift), event.clickCount)
        }
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityPerformPress() -> Bool { action?(false, false, 1); return true }
    }
}
