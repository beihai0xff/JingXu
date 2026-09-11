import AppKit
import SwiftUI

@MainActor
final class ColorApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var terminating = false
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard !terminating else { return .terminateCancel }
        terminating = true; model.isPreviewTransitioning = true
        Task {
            guard await model.prepareShareForExit() else {
                model.isPreviewTransitioning = false; terminating = false
                sender.reply(toApplicationShouldTerminate: false); return
            }
            await model.automationConnection?.shutdown(preservePreference: true)
            let editor = model.colorEditor
            let saved = await editor?.flush() ?? true
            if saved { editor?.dispose() }
            model.isPreviewTransitioning = false; terminating = false
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}

/// Preserve SwiftUI's window delegate and interpose only the close decision.
struct ColorWindowGuard: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> GuardView { let view = GuardView(); view.model = model; return view }
    func updateNSView(_ view: GuardView, context: Context) { view.model = model }
    @MainActor final class GuardView: NSView {
        weak var model: AppModel?
        private var proxy: Delegate?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, proxy == nil else { return }
            let value = Delegate(model: model, original: window.delegate)
            proxy = value; window.delegate = value
        }
    }
    @MainActor final class Delegate: NSObject, NSWindowDelegate {
        weak var model: AppModel?
        weak var original: (any NSWindowDelegate)?
        private var closing = false
        init(model: AppModel?, original: (any NSWindowDelegate)?) { self.model = model; self.original = original }
        override func responds(to selector: Selector!) -> Bool {
            if super.responds(to: selector) { return true }
            return MainActor.assumeIsolated { original?.responds(to: selector) ?? false }
        }
        // Objective-C forwarding returns Any; the assertion guarantees this bridge never crosses threads.
        private struct ForwardedDelegate: @unchecked Sendable { let value: (any NSWindowDelegate)? }
        override func forwardingTarget(for selector: Selector!) -> Any? {
            MainActor.assumeIsolated { ForwardedDelegate(value: original) }.value
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            if closing { return original?.windowShouldClose?(sender) ?? true }
            guard let model, model.colorEditor != nil else { return original?.windowShouldClose?(sender) ?? true }
            model.transitionPreview {
                self.closing = true
                sender.performClose(nil)
            }
            return false
        }
    }
}
