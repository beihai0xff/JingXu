import AppKit
import SwiftUI
import JingXuCore

struct LibraryKeyboardHandler: NSViewRepresentable {
    let enabled: Bool
    let action: (UInt16, String, Bool, Bool) -> Bool
    func makeNSView(context: Context) -> KeyboardView { KeyboardView() }
    func updateNSView(_ view: KeyboardView, context: Context) {
        view.enabled = enabled; view.action = action
    }
    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) { view.stop() }
}
final class KeyboardView: NSView {
    var enabled = false
    var action: ((UInt16, String, Bool, Bool) -> Bool)?
    private var monitor: Any?
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); stop()
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, self.enabled, let window = self.window, window.isKeyWindow,
                      event.window === window, window.attachedSheet == nil, NSApp.modalWindow == nil,
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
    func leavePreviewLevel() {
        guard !isPreviewTransitioning else { return }
        if colorEditor?.isComposing == true { colorEditor?.cancelComposition() }
        else if colorEditor != nil { finishColorEditing() }
        else if previewAsset != nil { closePreview() }
        else { photoSelection.clear(); isBatchSelecting = false }
    }

    func moveGridFocus(by step: Int, extending: Bool) {
        guard canChangeBrowseScope, !assets.isEmpty else { return }
        let id = selectedAssetID, request = assetRequestID
        let index = id.flatMap { loadedAssets.index(of: $0) }
        if let id, index == nil, let focus = focusedAsset, focus.id == id {
            let query = appliedQuery
            Task {
                await loadBrowsePage(cursor: BrowseCursor(focus), containing: true)
                guard appliedQuery == query, browseError == nil else { return }
                if loadedAssets.contains(id) { moveGridFocus(by: step, extending: extending) }
                else {
                    selectedAssetID = nil; focusedAsset = nil
                    moveGridFocus(by: step, extending: extending)
                }
            }
            return
        }
        let target = index.map { $0 + step } ?? 0
        let needsMore = (target < 0 && hasPreviousPage) || (target >= assets.count && hasNextPage)
        let select = {
            let updated = id.flatMap { self.loadedAssets.index(of: $0) }
            let destination = updated.map { min(self.assets.count - 1, max(0, $0 + step)) } ?? 0
            let item = self.assets[destination]
            if extending { self.clickAsset(item, command: false, shift: true, count: 1) }
            else { self.transitionPreview { self.selectAsset(item); self.syncKeywordDraft() } }
        }
        if needsMore {
            loadMoreAssets(before: target < 0)
            let loading = loadMoreTask
            Task {
                await loading?.value
                guard assetRequestID == request, selectedAssetID == id, !assets.isEmpty else { return }
                select()
            }
        } else { select() }
    }

    func handleLibraryKey(code: UInt16, text: String, shift: Bool, command: Bool) -> Bool {
        if colorEditor?.isComposing == true {
            guard !command else { return false }
            if code == 53 { colorEditor?.cancelComposition(); return true }
            if code == 123 || code == 124 { navigatePreview(code == 123 ? -1 : 1); return true }
            return false
        }
        if command {
            if text == "a", previewAsset == nil { selectAllMatchingPhotos(); return true }
            if text == "z" { performUndo(redo: shift); return true }
            return false
        }
        if code == 53 { leavePreviewLevel(); return true }
        if let rating = Int(text), (0...5).contains(rating) { updateRating(rating, advanceToNext: shift); return true }
        if code == 51 || code == 117 { updateFlag(.rejected, advanceToNext: annotationTargetCount == 1); return true }
        if text == "u", !shift { updateFlag(.none); return true }
        if [123, 124, 125, 126].contains(code) {
            if previewAsset != nil {
                if code == 123 || code == 124 { navigatePreview(code == 123 ? -1 : 1); return true }
                return false
            }
            guard !assets.isEmpty else { return false }
            let step = code == 123 ? -1 : code == 124 ? 1 : code == 125 ? gridColumns : -gridColumns
            moveGridFocus(by: step, extending: shift)
            return true
        }
        if code == 49, let item = selectedAsset, previewAsset == nil { openPreview(item); return true }
        return false
    }
}
