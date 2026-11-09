import Combine
import CoreGraphics
import Foundation

/// Owns one displayed photo and at most one candidate. A failed transition never
/// destroys the displayed editor, its history, or the input needed to retry saving.
@MainActor
public final class SystemPhotoPreviewSession: ObservableObject {
    @Published public private(set) var photo: SystemPhoto?
    @Published public private(set) var image: PreviewImage?
    @Published public private(set) var editor: ColorEditSession?
    @Published public private(set) var index = 0
    @Published public private(set) var pendingIndex: Int?
    @Published public private(set) var isLoading = false
    @Published public private(set) var isLoadingFullImage = false
    @Published public private(set) var hasDraft = false
    @Published public private(set) var failedPhoto: SystemPhoto?
    @Published public private(set) var failedIndex: Int?
    private let client: any PhotoLibraryClient
    private let store: SystemPhotosStore
    private let repository: SystemPhotoEditingRepository
    private var input: SystemPhotoEditInput?
    private var displaySnapshot: ColorEditingSnapshot?
    private var observation: AnyCancellable?
    private var loading: Task<Void, Error>?
    private var fullLoading: Task<PreviewImage, Error>?
    private var generation = UUID()
    private var fullPrepared = false
    private var fullEditVersion: UUID?

    public init(client: any PhotoLibraryClient, store: SystemPhotosStore) {
        self.client = client; self.store = store
        repository = SystemPhotoEditingRepository(store: store, client: client)
    }

    public func open(at index: Int, editing: Bool? = nil,
                     resolve: @escaping @MainActor () async throws -> SystemPhoto) async throws {
        try Task.checkCancellation()
        let previous = loading, previousFull = fullLoading
        previous?.cancel(); previousFull?.cancel()
        let request = UUID(); generation = request
        let editing = editing ?? (editor != nil)
        pendingIndex = index; isLoading = true; failedPhoto = nil; failedIndex = nil
        let work = Task { @MainActor [self] in
            // Serialize candidate ownership, including clients which finish after cancellation.
            _ = await previous?.result; _ = await previousFull?.result
            var candidateInput: SystemPhotoEditInput?
            var candidateEditor: ColorEditSession?
            var target: SystemPhoto?
            defer {
                if self.generation == request { self.isLoading = false; self.pendingIndex = nil; self.loading = nil }
            }
            do {
                try Task.checkCancellation()
                if self.generation == request { self.fullLoading = nil; self.isLoadingFullImage = false }
                if let editor = self.editor, !(await editor.flush()) {
                    throw ColorEditError(editor.saveError ?? "本机草稿保存失败，未切换照片")
                }
                try Task.checkCancellation()
                let next = try await resolve(); target = next
                let draft = try await self.store.draft(id: next.id)
                let nextImage: PreviewImage
                var snapshot: ColorEditingSnapshot?
                if draft != nil || (editing && next.canEdit) {
                    let input = try await self.client.editingInput(photo: next)
                    candidateInput = input
                    try Task.checkCancellation()
                    let opened = try await self.repository.open(input)
                    snapshot = opened
                    let rendered = try await ColorImageRenderer.shared.render(opened, adjustments: opened.adjustments, maximumDimension: 2048)
                    nextImage = Self.preview(rendered)
                    if editing && next.canEdit {
                        candidateEditor = try ColorEditSession(repository: self.repository, snapshot: opened,
                            displayQuality: .preview, initialResult: rendered, saved: { [weak self] in
                                if self?.photo?.id == next.id { self?.hasDraft = true }
                            })
                    }
                } else {
                    nextImage = try await self.client.image(id: next.id, pixelSize: 2048)
                }
                try await self.client.validate(photo: next)
                try Task.checkCancellation()
                guard self.generation == request else { throw CancellationError() }
                let oldEditor = self.editor, oldInput = self.input
                self.photo = next; self.index = index; self.image = nextImage
                self.input = candidateInput; self.displaySnapshot = snapshot; self.editor = candidateEditor
                self.hasDraft = draft != nil; self.fullPrepared = Self.isFull(nextImage); self.fullEditVersion = nil
                self.observeEditor()
                candidateInput = nil; candidateEditor = nil
                oldEditor?.dispose()
                if let oldInput {
                    await self.client.releaseEditingInput(token: oldInput.token)
                    await ColorImageRenderer.shared.release(input: oldInput.renderInput)
                }
            } catch {
                candidateEditor?.dispose()
                if let candidateInput {
                    await self.client.releaseEditingInput(token: candidateInput.token)
                    await ColorImageRenderer.shared.release(input: candidateInput.renderInput)
                }
                if self.generation == request && !(error is CancellationError) {
                    self.failedPhoto = target; self.failedIndex = index
                }
                throw error
            }
        }
        loading = work
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    private func observeEditor() {
        observation = editor?.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    public func updateIndex(_ value: Int) { index = value }
    public func cancel() { loading?.cancel(); fullLoading?.cancel() }

    public func finishEditing() async throws {
        guard !isLoading, let editor else { return }
        fullLoading?.cancel(); _ = await fullLoading?.result
        editor.cancelComposition()
        try await editor.withSavedSnapshot { snapshot in
            let rendered = try await ColorImageRenderer.shared.render(snapshot, adjustments: snapshot.adjustments,
                maximumDimension: editor.displayQuality == .preview ? 2048 : nil)
            try Task.checkCancellation()
            self.image = Self.preview(rendered); self.displaySnapshot = snapshot
            self.hasDraft = snapshot.revision > 0; self.fullPrepared = Self.isFull(self.image!)
        }
        editor.dispose(); self.editor = nil; observation = nil; fullEditVersion = nil
    }

    public func fullImage() async throws -> PreviewImage {
        try Task.checkCancellation()
        guard !isLoading, let photo else { throw ColorEditError("请等待照片切换完成") }
        if let fullLoading { return try await fullLoading.value }
        if let editor, fullEditVersion == editor.editVersion, let result = editor.result,
           !editor.isRendering, !editor.comparing, Self.isFull(Self.preview(result)) {
            return Self.preview(result)
        }
        if editor == nil && fullPrepared, let image { return image }
        let request = generation
        isLoadingFullImage = true
        let work = Task { @MainActor in
            defer {
                if self.generation == request { self.fullLoading = nil; self.isLoadingFullImage = false }
            }
            let full: PreviewImage
            if let editor = self.editor {
                full = Self.preview(try await editor.fullResolution())
            } else if let snapshot = self.displaySnapshot {
                try await self.repository.validateEditingSnapshot(snapshot)
                full = Self.preview(try await ColorImageRenderer.shared.render(snapshot, adjustments: snapshot.adjustments))
            } else { full = try await self.client.image(id: photo.id, pixelSize: Int.max) }
            try await self.client.validate(photo: photo)
            try Task.checkCancellation()
            guard self.generation == request else { throw CancellationError() }
            self.image = full; self.fullPrepared = true; self.fullEditVersion = self.editor?.editVersion
            return full
        }
        fullLoading = work
        return try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    public func needsFullImage(at transform: CanvasTransform) -> Bool {
        guard !transform.fitted, !isLoading, !isLoadingFullImage else { return false }
        let bitmap = editor?.result?.image ?? image?.image
        let native = editor?.result?.nativeSize ?? image?.nativeSize ?? .zero
        guard let bitmap, native.width > 0, native.height > 0 else { return false }
        let available = min(CGFloat(bitmap.width) / native.width, CGFloat(bitmap.height) / native.height)
        return available < 1 && transform.physicalZoom > available
    }

    /// Clearing display resources always waits for any in-flight draft commit.
    @discardableResult public func close() async -> Bool {
        generation = UUID(); cancel()
        _ = await loading?.result; _ = await fullLoading?.result
        loading = nil; fullLoading = nil; isLoading = false; isLoadingFullImage = false; pendingIndex = nil
        if let editor, !(await editor.flush()) { return false }
        editor?.dispose(); editor = nil; observation = nil
        if let input {
            await client.releaseEditingInput(token: input.token)
            await ColorImageRenderer.shared.release(input: input.renderInput)
        }
        input = nil; displaySnapshot = nil; photo = nil; image = nil
        fullPrepared = false; fullEditVersion = nil; hasDraft = false; failedPhoto = nil; failedIndex = nil
        return true
    }

    private static func isFull(_ image: PreviewImage) -> Bool {
        image.nativeSize.width > 0 && image.nativeSize.height > 0 &&
            CGFloat(image.image.width) >= image.nativeSize.width && CGFloat(image.image.height) >= image.nativeSize.height
    }
    private static func preview(_ value: ColorRenderedImage) -> PreviewImage {
        PreviewImage(image: value.image, nativeSize: value.nativeSize, isEmbedded: false, access: nil)
    }
}
