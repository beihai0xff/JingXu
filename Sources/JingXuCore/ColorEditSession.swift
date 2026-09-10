import Combine
import Foundation

@MainActor
public final class ColorEditSession: ObservableObject {
    @Published public private(set) var snapshot: ColorEditSnapshot
    @Published public private(set) var adjustments: ColorAdjustments
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
    public func beginGesture() { isDragging = true; if gestureStart == nil { gestureStart = adjustments } }
    public func endGesture() {
        if let initial = gestureStart, initial != adjustments { history.push(initial) }
        gestureStart = nil; isDragging = false
        render(interactive: false)
        autoSave?.cancel()
        autoSave = Task { _ = await flush() }
    }
    public func change(_ parameter: ColorParameter, value: Double) {
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
    public func undo() { endGestureIfNeeded(); if let value = history.undo(adjustments) { apply(value, track: false) } }
    public func redo() { endGestureIfNeeded(); if let value = history.redo(adjustments) { apply(value, track: false) } }
    public func apply(_ value: ColorAdjustments, track: Bool = true) {
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
        autoSave?.cancel(); autoSave = nil
        guard !isSaving, let saved = try? snapshot.adjustments else { return }
        adjustments = saved; saveError = nil; history = ColorEditHistory(); gestureStart = nil
        comparing = false; render(interactive: false)
    }
    public func dispose() {
        disposed = true; autoSave?.cancel(); rendering?.cancel(); generation = UUID(); result = nil
        Task { await ColorImageRenderer.shared.release() }
    }
}
