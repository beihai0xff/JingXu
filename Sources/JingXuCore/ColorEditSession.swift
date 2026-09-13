import Combine
import CoreGraphics
import Foundation

@MainActor
public final class ColorEditSession: ObservableObject {
    @Published public private(set) var snapshot: ColorEditSnapshot
    @Published public private(set) var adjustments: ColorAdjustments {
        didSet { if adjustments != oldValue { editVersion = UUID() } }
    }
    public private(set) var editVersion = UUID()
    @Published public private(set) var isExternallyControlled = false
    @Published public private(set) var isComposing = false
    @Published public private(set) var composition: CompositionSession?
    @Published public private(set) var result: ColorRenderedImage?
    @Published public var comparing = false { didSet { render(interactive: false) } }
    @Published public private(set) var renderError: String?
    @Published public private(set) var saveError: String?
    @Published public private(set) var isRendering = false
    @Published public private(set) var isSaving = false
    @Published public private(set) var history = ColorEditHistory()
    private let store: CatalogStore
    private let saved: @MainActor () async -> Void
    private var autoSave: Task<Void, Never>?
    private var rendering: Task<Void, Never>?
    private var saving: Task<Bool, Never>?
    private var generation = UUID()
    private var gestureStart: ColorAdjustments?
    private var isDragging = false
    private var disposed = false
    public var isRAW: Bool { snapshot.isRAW }
    public var isDirty: Bool { (try? snapshot.adjustments) != adjustments }
    public var usable: Bool { result != nil && renderError == nil }

    public init(store: CatalogStore, snapshot: ColorEditSnapshot, saved: @escaping @MainActor () async -> Void) throws {
        self.store = store; self.snapshot = snapshot; self.saved = saved
        adjustments = try snapshot.adjustments
    }
    public func start() { render(interactive: false) }
    public func displayValue(_ parameter: ColorParameter) -> Double {
        if parameter.group == .whiteBalance && adjustments.whiteBalance == .asShot {
            if !isRAW { return 0 }
            return parameter == .temperature ? result?.rawTemperature ?? 6500 : result?.rawTint ?? 0
        }
        return adjustments[parameter]
    }
    public func beginGesture() { guard !isExternallyControlled, !isComposing else { return }; isDragging = true; if gestureStart == nil { gestureStart = adjustments } }
    public func endGesture() {
        guard !isExternallyControlled, !isComposing else { return }
        if let initial = gestureStart, initial != adjustments { history.push(initial) }
        gestureStart = nil; isDragging = false
        render(interactive: false)
        autoSave?.cancel()
        autoSave = Task { _ = await flush() }
    }
    public func change(_ parameter: ColorParameter, value: Double) {
        guard !isExternallyControlled, !isComposing else { return }
        if gestureStart == nil { gestureStart = adjustments }
        if parameter.group == .whiteBalance, adjustments.whiteBalance == .asShot {
            adjustments.temperature = displayValue(.temperature); adjustments.tint = displayValue(.tint)
            adjustments.whiteBalance = isRAW ? .raw : .relative
        }
        adjustments[parameter] = value
        comparing = false
        schedule()
    }
    public func reset(_ parameter: ColorParameter) {
        var value = adjustments
        if parameter.group == .whiteBalance {
            if value.whiteBalance == .asShot { return }
            value[parameter] = isRAW ? (parameter == .temperature ? result?.rawTemperature ?? 6500 : result?.rawTint ?? 0) : 0
        } else { value[parameter] = 0 }
        apply(value)
    }
    public func asShot() { var value = adjustments; value.whiteBalance = .asShot; apply(value) }
    public func resetAll() { apply(ColorAdjustments()) }
    public func undo() { guard !isExternallyControlled, !isComposing else { return }; endGestureIfNeeded(); if let value = history.undo(adjustments) { apply(value, track: false) } }
    public func redo() { guard !isExternallyControlled, !isComposing else { return }; endGestureIfNeeded(); if let value = history.redo(adjustments) { apply(value, track: false) } }
    public func apply(_ value: ColorAdjustments, track: Bool = true) {
        guard !isExternallyControlled, !isComposing else { return }
        guard value != adjustments else { return }
        if track { endGestureIfNeeded(); history.push(adjustments) }
        adjustments = value; comparing = false; schedule()
    }
    private func endGestureIfNeeded() {
        if let initial = gestureStart, initial != adjustments { history.push(initial) }
        gestureStart = nil
    }
    private func schedule() {
        render(interactive: true)
        autoSave?.cancel()
        autoSave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation() } catch { return }
            guard let self else { return }
            if !self.isDragging { self.endGestureIfNeeded() }
            self.render(interactive: false)
            _ = await self.flush()
        }
    }
    public func render(interactive: Bool) {
        guard !disposed else { return }
        rendering?.cancel()
        let token = UUID(); generation = token
        let snapshot = snapshot, values = comparing ? ColorAdjustments() : adjustments
        isRendering = true; renderError = nil
        rendering = Task { [weak self] in
            do {
                if interactive { try await Task.sleep(for: .milliseconds(35)) }
                let small = try await ColorImageRenderer.shared.render(snapshot, adjustments: values, maximumDimension: 2048)
                guard let self, !Task.isCancelled, self.generation == token, !self.disposed else { return }
                self.result = small
                if !interactive {
                    let full = try await ColorImageRenderer.shared.render(snapshot, adjustments: values)
                    guard !Task.isCancelled, self.generation == token, !self.disposed else { return }
                    self.result = full
                }
                self.isRendering = false
            } catch is CancellationError {} catch {
                guard let self, self.generation == token, !self.disposed else { return }
                self.renderError = error.localizedDescription; self.isRendering = false
            }
        }
    }
    /// Coalesces concurrent navigation, timer and termination flushes without cancelling a database commit.
    public func flush() async -> Bool {
        autoSave?.cancel(); autoSave = nil
        if let saving { return await saving.value }
        guard isDirty else { return true }
        isSaving = true
        let task = Task { @MainActor [self] in
            defer { isSaving = false; saving = nil }
            do {
                while isDirty {
                    let values = adjustments, expected = snapshot
                    snapshot = try await store.saveColorAdjustments(values, snapshot: expected)
                    saveError = nil
                    await saved()
                }
                return true
            } catch { saveError = error.localizedDescription; return false }
        }
        saving = task
        return await task.value
    }
    public func discardDraft() {
        guard !isExternallyControlled, !isComposing else { return }
        autoSave?.cancel(); autoSave = nil
        guard !isSaving, let saved = try? snapshot.adjustments else { return }
        adjustments = saved; saveError = nil; history = ColorEditHistory(); gestureStart = nil
        comparing = false; render(interactive: false)
    }
    public func dispose() {
        cancelComposition()
        disposed = true; autoSave?.cancel(); rendering?.cancel(); generation = UUID(); result = nil
        Task { await ColorImageRenderer.shared.release() }
    }

    public enum ExternalChange: Sendable { case set(ColorAdjustments), undo, redo }

    public func beginComposition(detector: @escaping CompositionSession.Detector = { try await CompositionAnalyzer.shared.regions(in: $0) }) async throws {
        guard !disposed, !isComposing, !isExternallyControlled else { throw ColorEditError("编辑会话正在操作") }
        guard saveError == nil else { throw ColorEditError("请先重试保存或放弃未保存调整") }
        endGestureIfNeeded(); isDragging = false; isComposing = true
        rendering?.cancel(); generation = UUID(); isRendering = false
        do {
            guard await flush() else { throw ColorEditError(saveError ?? "保存失败") }
            let expected = snapshot, version = editVersion
            try await store.validateColorSnapshot(expected)
            guard !disposed, isComposing, version == editVersion else { throw CancellationError() }
            let draft = CompositionSession(snapshot: expected, adjustments: adjustments, editVersion: version, detector: detector)
            composition = draft; draft.start()
        } catch { cancelComposition(); throw error }
    }
    public func cancelComposition() {
        guard isComposing else { return }
        composition?.dispose(); composition = nil; isComposing = false
        render(interactive: false)
    }
    public func applyComposition() async -> Bool {
        guard let draft = composition, draft.canApply, !disposed, !isExternallyControlled else { return false }
        draft.isApplying = true
        defer { draft.isApplying = false }
        do {
            try draft.crop.validate()
            try await store.validateColorSnapshot(draft.snapshot)
            guard composition === draft, !disposed, editVersion == draft.editVersion else { throw ColorEditError("照片或调整已变化，请重新打开构图") }
            var values = adjustments; values.crop = draft.crop.normalized
            cancelComposition()
            apply(values)
            // The committed in-memory edit is preserved by the existing save-error recovery UI.
            return await flush()
        } catch {
            if composition === draft { draft.errorMessage = "无法应用：\(error.localizedDescription)" }
            return false
        }
    }

    /// A command and its save form one edit. Manual input cannot overtake the database await.
    public func applyExternal(_ change: ExternalChange, expectedVersion: UUID) async throws {
        guard !disposed, !isExternallyControlled, !isComposing, !isDragging, !isSaving else { throw ColorEditError("调色会话正在操作，请稍后重新读取上下文") }
        guard editVersion == expectedVersion else { throw ColorEditError("调整已变化，请重新读取上下文") }
        guard saveError == nil else { throw ColorEditError("请先在镜序中重试保存或放弃未保存调整") }
        switch change {
        case .set(let values): try values.validate(isRAW: isRAW); apply(values)
        case .undo: undo()
        case .redo: redo()
        }
        isExternallyControlled = true
        defer { isExternallyControlled = false }
        guard await flush() else { throw ColorEditError(saveError ?? "调色保存失败，草稿已保留") }
    }
}
