import AppKit
import Combine
import JingXuCore

@MainActor
final class SystemPhotosModel: ObservableObject {
    let client: any PhotoLibraryClient
    let store: SystemPhotosStore
    let coordinator: SystemPhotosCoordinator
    let editingRepository: SystemPhotoEditingRepository
    let localStore: CatalogStore
    private let canBegin: @MainActor () -> Bool
    @Published var connected = false
    @Published var albums: [SystemPhotoAlbum] = []
    @Published var items: [SystemPhoto] = []
    @Published var albumID: String?
    @Published var offset = 0
    @Published var total = 0
    @Published var selection = PhotoSelectionState()
    @Published var preview: SystemPhoto?
    @Published var previewImage: PreviewImage?
    @Published var previewIndex = 0
    @Published var editor: ColorEditSession?
    @Published var isBusy = false
    @Published var isSubmitting = false
    @Published var isNavigating = false
    @Published var status = "连接系统照片后，可访问已授权的图库；iCloud 同步由系统负责。"
    @Published var error: String?
    @Published var conflict: String?
    @Published var mutationPlan: SystemPhotoMutationPlan?
    @Published var analysisPlan: SystemPhotoAnalysisJob?
    @Published var job: SystemPhotoAnalysisJob?
    @Published var analysis: AnalysisResult?
    @Published var unresolved: [SystemPhotoWriteRecord] = []
    @Published var inspectedWrite: SystemPhotoWriteRecord?
    @Published var uploadSnapshots: [ColorEditSnapshot]?
    @Published var preparedUpload: SystemPhotoUpload?
    @Published var uploadMode: PhotoShareMode = .original
    @Published var uploadAlbumID: String?
    @Published var presets: [ColorPreset] = []
    @Published var showsPresets = false
    @Published var copiedPatch: ColorPatch?
    private var task: Task<Void, Never>?
    private var navigation: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var editorObservation: AnyCancellable?
    private var refreshNeeded = false
    var selectedAlbum: SystemPhotoAlbum? { albums.first { $0.id == albumID } }
    var targetIDs: [String] { preview.map { [$0.id] } ?? selection.selectedIDs.sorted() }
    var blocksLocalOperations: Bool { isBusy || isNavigating || uploadSnapshots != nil }
    var canAct: Bool { connected && !isBusy && !isNavigating && canBegin() && unresolved.isEmpty }
    var isIsolated: Bool { ProcessInfo.processInfo.environment["JINGXU_UI_TEST_ROOT"] != nil }

    init(localStore: CatalogStore, canBegin: @escaping @MainActor () -> Bool) throws {
        self.localStore = localStore; self.canBegin = canBegin
        let root = try JingXuPaths.applicationSupport()
        let temporary = root.appendingPathComponent("SystemPhotosWorking")
        try PhotoWorkspace.removeAbandoned(in: temporary)
        if ProcessInfo.processInfo.environment["JINGXU_UI_TEST_ROOT"] != nil {
            client = try IsolatedPhotoLibraryClient.fixtures(root: root.appendingPathComponent("SystemPhotoFixtures"))
        } else { client = try ApplePhotoLibraryClient(temporaryRoot: temporary) }
        store = try SystemPhotosStore(url: root.appendingPathComponent("SystemPhotos.sqlite"))
        coordinator = SystemPhotosCoordinator(client: client, store: store, localStore: localStore, temporaryRoot: temporary)
        editingRepository = SystemPhotoEditingRepository(store: store, client: client)
    }
    private func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !isBusy, !isNavigating, canBegin() else { return }
        isBusy = true
        task = Task {
            defer {
                isBusy = false; isSubmitting = false; task = nil
                if refreshNeeded { refreshNeeded = false; refresh() }
            }
            do { try await work() }
            catch is CancellationError { status = "已取消准备或暂停分析；已提交的系统操作不受影响" }
            catch { self.error = error.localizedDescription }
            do { unresolved = try await store.unresolvedWrites() } catch { self.error = error.localizedDescription }
        }
    }
    func connect() {
        perform {
            let authorization = await self.client.authorization(request: true)
            guard authorization.canRead else { throw ColorEditError("请在系统设置 → 隐私与安全性 → 照片中允许镜序读写照片") }
            self.connected = true; self.conflict = nil
            await self.client.observe { [weak self] event in Task { @MainActor in self?.libraryChanged(event) } }
            self.job = try await self.store.jobs().first { $0.isResumable }
            try await self.reload()
            self.status = self.isIsolated ? "隔离测试图库 · 不连接真实系统照片或 iCloud" :
                (authorization == .limited ? "已连接获准访问的部分系统照片，iCloud 同步由系统处理" : "已连接系统照片；请在「照片」设置中确认 iCloud 照片已开启")
        }
    }
    private func libraryChanged(_ event: SystemPhotoChange) {
        switch event {
        case .unavailable(let message):
            connected = false; conflict = message; status = message; navigation?.cancel()
            if !isSubmitting { task?.cancel() }
        case .changed:
            if isBusy || isNavigating { refreshNeeded = true } else { refresh() }
        }
    }
    func refresh() {
        guard connected else { return }
        perform { try await self.reload() }
    }
    private func reload() async throws {
        guard await client.authorization(request: false).canRead else {
            connected = false; previewImage = nil
            throw ColorEditError("照片权限已撤销，草稿已保留")
        }
        albums = try await client.albums()
        if let albumID, !albums.contains(where: { $0.id == albumID }) { self.albumID = nil; offset = 0; selection.clear() }
        var page = try await client.page(albumID: albumID, offset: offset, limit: 200)
        if page.items.isEmpty && offset > 0 { offset = max(0, ((max(1, page.total) - 1) / 200) * 200); page = try await client.page(albumID: albumID, offset: offset, limit: 200) }
        items = page.items; total = page.total
        let valid = try await client.photos(ids: selection.selectedIDs.sorted(), albumID: albumID)
        selection.retain(validIDs: Set(valid.map(\.id)))
        if let preview {
            if let index = try await client.index(id: preview.id, albumID: albumID) { previewIndex = index }
            let current = try await client.photos(ids: [preview.id], albumID: nil).first
            if current != preview {
                if editor != nil { conflict = "当前照片已变化或被删除。草稿保留在镜序，保存前请重新载入。" }
                else if let current {
                    self.preview = current
                    previewImage = try await client.image(id: current.id, pixelSize: Int.max)
                } else { self.preview = nil; previewImage = nil; status = "当前照片已从系统图库移除" }
            }
        }
        unresolved = try await store.unresolvedWrites()
        try await reloadAnalysis()
    }
    func browse(albumID: String?, offset: Int = 0) {
        perform {
            guard await self.flushAndCloseEditor() else { throw ColorEditError("请先处理草稿保存失败") }
            self.preview = nil; self.previewImage = nil; self.conflict = nil
            if self.albumID != albumID { self.selection.clear() }
            self.albumID = albumID; self.offset = offset; try await self.reload()
        }
    }
    func click(_ photo: SystemPhoto, count: Int = 1) {
        guard canAct else { return }
        let flags = NSEvent.modifierFlags
        if selection.click(photo.id, photoIDs: items.map(\.id), command: flags.contains(.command),
                           shift: flags.contains(.shift), count: count) {
            open(photo, index: offset + (items.firstIndex { $0.id == photo.id } ?? 0))
        }
    }
    func open(_ photo: SystemPhoto, index: Int) {
        guard !isBusy, !isNavigating, canBegin() else { return }
        navigation?.cancel(); let generation = UUID(); previewGeneration = generation
        isNavigating = true; conflict = nil
        let continueEditing = editor != nil
        navigation = Task {
            defer { if previewGeneration == generation { isNavigating = false; navigation = nil; if refreshNeeded { refreshNeeded = false; refresh() } } }
            do {
                guard await flushAndCloseEditor() else { throw ColorEditError("本机草稿保存失败，未切换照片") }
                let image = try await client.image(id: photo.id, pixelSize: Int.max)
                try Task.checkCancellation()
                guard previewGeneration == generation else { return }
                preview = photo; previewIndex = index; previewImage = image
                let pageOffset = (index / 200) * 200
                if pageOffset != offset {
                    let page = try await client.page(albumID: albumID, offset: pageOffset, limit: 200)
                    try Task.checkCancellation()
                    offset = pageOffset; items = page.items; total = page.total
                }
                try await reloadAnalysis()
                if continueEditing && photo.canEdit { try await loadEditor(photo) }
            } catch is CancellationError {} catch { if previewGeneration == generation { self.error = error.localizedDescription } }
        }
    }
    func navigate(_ direction: Int) {
        guard !isBusy, !isNavigating, preview != nil else { return }
        let index = previewIndex + direction
        guard index >= 0 && index < total else { return }
        Task {
            do {
                if let next = try await client.page(albumID: albumID, offset: index, limit: 1).items.first { open(next, index: index) }
            } catch { self.error = error.localizedDescription }
        }
    }
    func closePreview() { browse(albumID: albumID, offset: (previewIndex / 200) * 200) }
    func beginEditing() {
        guard let preview, preview.canEdit, editor == nil, canAct else { return }
        perform { try await self.loadEditor(preview) }
    }
    private func loadEditor(_ photo: SystemPhoto) async throws {
        let input = try await client.editingInput(photo: photo)
        do {
            let snapshot = try await editingRepository.open(input)
            let session = try ColorEditSession(repository: editingRepository, snapshot: snapshot, saved: {})
            editor = session
            editorObservation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            session.start()
            status = input.usesRenderedBase ? "以其他应用的当前成片为底图；本次编辑前对比不会撤销其效果" : "调整自动保存为本机草稿；点击「保存到系统照片」后更新照片"
        } catch { await client.releaseEditingInput(token: input.token); throw error }
    }
    private func flushAndCloseEditor() async -> Bool {
        guard let editor else { return true }
        editor.cancelComposition()
        guard await editor.flush() else { return false }
        await disposeEditor()
        return true
    }
    private func disposeEditor() async {
        guard let editor else { return }
        editor.dispose()
        if case .systemPhoto(let input) = editor.snapshot.origin { await client.releaseEditingInput(token: input.token) }
        self.editor = nil; editorObservation = nil
    }
    func saveEdit() {
        guard let editor, canAct, conflict == nil, !editor.isComposing else { return }
        perform {
            try await editor.withSavedSnapshot { snapshot in
                self.isSubmitting = true
                try await self.coordinator.saveEdit(snapshot)
            }
            self.status = "已保存到系统照片，iCloud 同步由系统处理"
            guard let updated = try await self.client.photos(ids: [editor.snapshot.id], albumID: nil).first else { throw ColorEditError("保存后照片暂不可读取") }
            _ = await self.flushAndCloseEditor()
            self.preview = updated; self.conflict = nil
            self.previewImage = try await self.client.image(id: updated.id, pixelSize: Int.max)
            try await self.loadEditor(updated)
        }
    }
    func discardDraft() {
        guard let preview, !isBusy, !isNavigating else { return }
        let alert = NSAlert()
        alert.messageText = "放弃“\(preview.name)”的本机调色草稿？"
        alert.informativeText = "只删除镜序草稿，系统照片中的现有效果保留。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃草稿并重载")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform {
            self.editor?.cancelComposition()
            _ = await self.editor?.flush()
            self.editor?.discardDraft()
            await self.disposeEditor()
            try await self.store.discardDraft(id: preview.id)
            guard let current = try await self.client.photos(ids: [preview.id], albumID: nil).first else { throw ColorEditError("照片已从系统图库移除") }
            self.preview = current; self.conflict = nil
            self.previewImage = try await self.client.image(id: current.id, pixelSize: Int.max)
            if current.canEdit { try await self.loadEditor(current) }
        }
    }
    func beginComposition() {
        guard canAct else { return }
        perform {
            if self.editor == nil, let preview = self.preview { try await self.loadEditor(preview) }
            try await self.editor?.beginComposition()
        }
    }
    func applyComposition() {
        guard let editor, !isBusy else { return }
        perform { if !(await editor.applyComposition()) { throw ColorEditError("构图未保存，请检查草稿提示") } }
    }
    func prepareMutation(_ operation: SystemPhotoMutation, album: SystemPhotoAlbum? = nil) {
        guard canAct else { return }
        let ids = targetIDs
        perform {
            let photos: [SystemPhoto]
            switch operation {
            case .createAlbum, .renameAlbum, .deleteAlbum: photos = []
            default:
                photos = try await self.client.photos(ids: ids, albumID: self.albumID)
                guard photos.count == ids.count, !photos.isEmpty else { throw ColorEditError("选择已变化，请重新选择") }
            }
            self.mutationPlan = SystemPhotoMutationPlan(operation: operation, photos: photos, album: album)
        }
    }
    func confirmMutation() {
        guard let plan = mutationPlan, canAct else { return }
        mutationPlan = nil
        perform {
            guard await self.flushAndCloseEditor() else { throw ColorEditError("本机草稿尚未保存") }
            self.isSubmitting = true; try await self.coordinator.mutate(plan)
            self.preview = nil; self.previewImage = nil; self.conflict = nil
            self.status = "系统照片已处理操作，iCloud 同步由系统负责"
            try await self.reload()
        }
    }
    func prepareAnalysis() {
        guard canAct, !targetIDs.isEmpty else { return }
        guard job?.isResumable != true else { error = "请先继续当前分析，或明确结束任务后重新选择"; return }
        let ids = targetIDs
        perform {
            let photos = try await self.client.photos(ids: ids, albumID: self.albumID)
            guard photos.count == ids.count else { throw ColorEditError("所选照片已变化，请重新选择") }
            self.analysisPlan = SystemPhotoAnalysisJob(photos: photos)
        }
    }
    func analyze(_ job: SystemPhotoAnalysisJob) {
        guard canAct else { return }
        analysisPlan = nil
        perform {
            self.job = job
            try await self.coordinator.analyze(job) { [weak self] value, name in
                await MainActor.run {
                    self?.job = value
                    self?.status = "分析 \(value.completed.count)/\(value.photos.count) · 未完成 \(value.failures.count) · \(name)"
                }
            }
            try await self.reloadAnalysis()
        }
    }
    func endAnalysis() {
        guard let job, !isBusy, !isNavigating else { return }
        let alert = NSAlert()
        alert.messageText = "结束当前分析任务？"
        alert.informativeText = "保留已完成结果和未完成记录，之后可重新选择照片分析。"
        alert.addButton(withTitle: "继续保留"); alert.addButton(withTitle: "结束任务")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform { try await self.store.endJob(id: job.id); self.job = nil }
    }
    private func reloadAnalysis() async throws {
        if let preview { analysis = try await store.analysis(id: preview.id) } else { analysis = nil }
    }
    func review(_ state: SuggestionState) {
        guard let preview, canAct else { return }
        perform { try await self.store.review(id: preview.id, state: state); try await self.reloadAnalysis() }
    }
    func prepareUpload() {
        guard let snapshots = uploadSnapshots, canAct else { return }
        let mode = uploadMode, album = albums.first { $0.id == uploadAlbumID }
        perform {
            self.preparedUpload = try await self.coordinator.prepareUpload(snapshots: snapshots, mode: mode, album: album) { done, total in
                await MainActor.run { self.status = "准备上传 \(done)/\(total)" }
            }
            self.status = "文件准备完成，请核对固定清单并确认加入系统照片"
        }
    }
    func confirmUpload() {
        guard let plan = preparedUpload, canAct else { return }
        perform {
            self.isSubmitting = true; try await self.coordinator.upload(plan)
            self.preparedUpload = nil; self.uploadSnapshots = nil
            self.status = "已加入系统照片，iCloud 同步由系统处理"
            try await self.reload()
        }
    }
    func cancelUpload() {
        guard !isSubmitting else { return }
        if isBusy { task?.cancel(); return }
        preparedUpload = nil; uploadSnapshots = nil
    }
    func cancel() { if !isSubmitting { task?.cancel(); navigation?.cancel() } }
    func showPresets() {
        guard canAct, editor != nil else { return }
        perform { self.presets = try await self.localStore.colorPresets(); self.showsPresets = true }
    }
    func applyPreset(_ patch: ColorPatch) {
        guard let editor, canAct else { return }
        do { editor.apply(try patch.applying(to: editor.adjustments, groups: Set(ColorGroup.allCases), isRAW: editor.isRAW)); showsPresets = false }
        catch { self.error = error.localizedDescription }
    }
    func savePreset(name: String) {
        guard let editor, canAct else { return }
        perform {
            try await self.localStore.saveColorPreset(ColorPreset(name: name, patch: ColorPatch(editor.adjustments)))
            self.presets = try await self.localStore.colorPresets()
        }
    }
    func acknowledge(_ record: SystemPhotoWriteRecord) {
        guard !isBusy, let id = UUID(uuidString: record.id) else { return }
        let alert = NSAlert()
        alert.messageText = "已在系统照片中核对这次提交？"
        alert.informativeText = "此操作只结束待核对记录，不会重新提交照片或撤销系统操作。\n" + record.names.prefix(10).joined(separator: "\n")
        alert.addButton(withTitle: "继续核对"); alert.addButton(withTitle: "已核对，结束记录")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform { try await self.store.finishWrite(id: id, state: "acknowledged"); self.unresolved = try await self.store.unresolvedWrites() }
    }
    func prepareForExit() async -> Bool {
        if isSubmitting { error = "系统照片正在提交，请等待处理结果后再关闭"; return false }
        task?.cancel(); navigation?.cancel()
        await task?.value; await navigation?.value
        guard await flushAndCloseEditor() else { return false }
        preparedUpload = nil; uploadSnapshots = nil
        return true
    }
}
