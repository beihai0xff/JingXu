import AppKit
import JingXuCore
import SwiftUI

struct LibraryKeyboardHandler: NSViewRepresentable {
    let enabled: Bool
    var onFocusLost: () -> Void = {}
    let action: (UInt16, String, Bool, Bool, Bool, Bool) -> Bool

    func makeNSView(context: Context) -> KeyboardView { KeyboardView() }

    func updateNSView(_ view: KeyboardView, context: Context) {
        view.enabled = enabled
        view.onFocusLost = onFocusLost
        view.action = action
    }

    static func dismantleNSView(_ view: KeyboardView, coordinator: ()) { view.stop() }
}

final class KeyboardView: NSView {
    var enabled = false
    var onFocusLost: (() -> Void)?
    var action: ((UInt16, String, Bool, Bool, Bool, Bool) -> Bool)?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFocusLost?() }
            }
        )
        observers.append(
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.onFocusLost?() }
            }
        )

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window else { return false }
                let text = event.charactersIgnoringModifiers?.lowercased() ?? ""
                let isKeyUp = event.type == .keyUp

                // Always allow releasing press-and-hold backslash comparison on keyUp.
                if isKeyUp {
                    if event.keyCode == 42 || text == "\\" {
                        return self.action?(
                            event.keyCode,
                            text,
                            event.modifierFlags.contains(.shift),
                            event.modifierFlags.contains(.command),
                            event.isARepeat,
                            true
                        ) ?? false
                    }
                    return false
                }

                guard self.enabled,
                      window.isKeyWindow,
                      window.attachedSheet == nil,
                      NSApp.modalWindow == nil,
                      !(window.firstResponder is NSTextView),
                      !(window.firstResponder is NSTextField),
                      !(window.firstResponder is NSSlider),
                      (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true,
                      event.modifierFlags.intersection([.control, .option]).isEmpty else {
                    return false
                }

                if [51, 117, 7, 42].contains(event.keyCode) && event.isARepeat {
                    return true
                }

                return self.action?(
                    event.keyCode,
                    text,
                    event.modifierFlags.contains(.shift),
                    event.modifierFlags.contains(.command),
                    event.isARepeat,
                    false
                ) ?? false
            }
            return handled ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
    }
}

extension AppModel {
    func leavePreviewLevel() {
        guard !isPreviewTransitioning else { return }
        endActiveOriginalComparison()
        if colorEditor?.isComposing == true { colorEditor?.cancelComposition() }
        else if colorEditor != nil { finishColorEditing() }
        else if previewAsset != nil { closePreview() }
        else { clearPhotoSelection() }
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

    func handleStudioKey(
        code: UInt16,
        text: String,
        shift: Bool,
        command: Bool,
        isRepeat: Bool = false,
        isKeyUp: Bool = false
    ) -> Bool {
        if showsSystemPhotos {
            return handleSystemPhotosKey(
                code: code,
                text: text,
                shift: shift,
                command: command,
                isRepeat: isRepeat,
                isKeyUp: isKeyUp
            )
        }
        return handleLocalLibraryKey(
            code: code,
            text: text,
            shift: shift,
            command: command,
            isRepeat: isRepeat,
            isKeyUp: isKeyUp
        )
    }

    private func handleSystemPhotosKey(
        code: UInt16,
        text: String,
        shift: Bool,
        command: Bool,
        isRepeat: Bool,
        isKeyUp: Bool
    ) -> Bool {
        guard let photos = systemPhotos else { return false }
        let stage = StudioStageMode.resolve(hasPreview: photos.preview != nil, isComparing: false, isEditing: photos.editor != nil)

        if isKeyUp {
            if StudioKeyRouter.route(code: code, text: text, shift: shift, isRepeat: isRepeat, isKeyUp: true, stage: stage, supportsCompare: false) == .endOriginalComparison {
                photos.editor?.endComparison()
                return true
            }
            return false
        }

        guard photos.connected, !photos.isBusy, photos.mutationPlan == nil, photos.analysisPlan == nil, !photos.showsPresets else {
            return false
        }

        if command {
            if text == "a", photos.preview == nil { photos.selectAllPhotos(); return true }
            if text == "z", photos.editor != nil { performUndo(redo: shift); return true }
            return false
        }

        if [123, 124, 125, 126].contains(code) {
            if photos.preview != nil {
                guard photos.editor?.isComposing != true else { return false }
                if code == 123 || code == 124 { photos.navigate(code == 123 ? -1 : 1); return true }
                return false
            }
            photos.moveGridFocus(
                by: code == 123 ? -1 : code == 124 ? 1 : code == 125 ? gridColumns : -gridColumns,
                extending: shift
            )
            return true
        }

        let selCount = photos.preview != nil
            ? 1
            : max(photos.selection.selectedIDs.count, photos.primaryTargetPhotoForPreview != nil ? 1 : 0)

        guard let routed = StudioKeyRouter.route(
            code: code,
            text: text,
            shift: shift,
            isRepeat: isRepeat,
            isKeyUp: false,
            stage: stage,
            selectionCount: selCount,
            hasSimilarGroup: false,
            isComposingCrop: photos.editor?.isComposing == true,
            supportsCompare: false
        ) else {
            return false
        }

        switch routed {
        case .openLoupe:
            photos.openPrimaryTarget(editing: false)
            return true
        case .returnToGrid:
            photos.switchStage(to: .grid)
            return true
        case .enterDevelop:
            photos.switchStage(to: .develop)
            return true
        case .finishDevelopToLoupe:
            photos.finishEditing()
            return true
        case .toggleInspector:
            showsInspector.toggle()
            return true
        case .toggleFilmstrip:
            showsFilmstrip.toggle()
            return true
        case .clearSelection:
            guard !photos.selection.selectedIDs.isEmpty || photos.selection.focusID != nil else { return false }
            photos.selection.clear()
            return true
        case .cancelCrop:
            photos.editor?.cancelComposition()
            return true
        case .beginOriginalComparison:
            photos.editor?.beginComparison()
            return true
        case .endOriginalComparison:
            photos.editor?.endComparison()
            return true
        case .enterCompare, .enterSimilarCompare, .exitCompareToLoupe, .reject, .unreject, .rate:
            return false
        }
    }

    private func handleLocalLibraryKey(
        code: UInt16,
        text: String,
        shift: Bool,
        command: Bool,
        isRepeat: Bool,
        isKeyUp: Bool
    ) -> Bool {
        let stage = stageMode

        if isKeyUp {
            if StudioKeyRouter.route(code: code, text: text, shift: shift, isRepeat: isRepeat, isKeyUp: true, stage: stage) == .endOriginalComparison {
                colorEditor?.endComparison()
                return true
            }
            return false
        }

        guard !isShowingKeywords,
              operationBlockReason(colorEditor?.isComposing == true ? .browse : .annotation) == nil else {
            return false
        }

        if command {
            if colorEditor?.isComposing == true { return false }
            if text == "a", previewAsset == nil { selectAllMatchingPhotos(); return true }
            if text == "z" { performUndo(redo: shift); return true }
            return false
        }

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

        if code == 53, stage == .grid {
            guard !photoSelection.selectedIDs.isEmpty || selectedAssetID != nil else { return false }
            clearPhotoSelection()
            return true
        }

        let selCount: Int = {
            if previewAsset != nil { return photoSelection.selectedIDs.count == 2 ? 2 : 1 }
            if !photoSelection.selectedIDs.isEmpty { return photoSelection.selectedIDs.count }
            return primaryTargetPhotoForPreview != nil ? 1 : 0
        }()
        let hasSimilarGroup = (previewAsset ?? selectedAsset)?.similarGroupID != nil

        guard let routed = StudioKeyRouter.route(
            code: code,
            text: text,
            shift: shift,
            isRepeat: isRepeat,
            isKeyUp: false,
            stage: stage,
            selectionCount: selCount,
            hasSimilarGroup: hasSimilarGroup,
            isComposingCrop: colorEditor?.isComposing == true,
            supportsCompare: true
        ) else {
            return false
        }

        switch routed {
        case .openLoupe:
            switchStage(to: .loupe)
            return true
        case .returnToGrid:
            switchStage(to: .grid)
            return true
        case .enterCompare:
            compareSelected()
            return true
        case .enterSimilarCompare:
            guard let groupID = (previewAsset ?? selectedAsset)?.similarGroupID else { return false }
            compareSimilarGroup(groupID)
            return true
        case .exitCompareToLoupe:
            switchStage(to: .loupe)
            return true
        case .enterDevelop:
            switchStage(to: .develop)
            return true
        case .finishDevelopToLoupe:
            finishColorEditing()
            return true
        case .toggleInspector:
            showsInspector.toggle()
            return true
        case .toggleFilmstrip:
            showsFilmstrip.toggle()
            return true
        case .reject(let advance):
            updateFlag(.rejected, advanceToNext: advance)
            return true
        case .unreject:
            updateFlag(.none)
            return true
        case .rate(let stars, let advance):
            updateRating(stars, advanceToNext: advance)
            return true
        case .clearSelection:
            clearPhotoSelection()
            return true
        case .cancelCrop:
            colorEditor?.cancelComposition()
            return true
        case .beginOriginalComparison:
            colorEditor?.beginComparison()
            return true
        case .endOriginalComparison:
            colorEditor?.endComparison()
            return true
        }
    }
}
