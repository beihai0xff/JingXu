import AppKit
import Combine
import JingXuCore
import SwiftUI

@MainActor
final class SystemPhotosModel: ObservableObject {
    let client: any PhotoLibraryClient
    let store: SystemPhotosStore
    let coordinator: SystemPhotosCoordinator
    let previewSession: SystemPhotoPreviewSession
    let localStore: CatalogStore
    private let canBegin: @MainActor () -> Bool
    @Published var connected = false
    @Published var albums: [SystemPhotoAlbum] = []
    @Published var items: [SystemPhoto] = []
    @Published var albumID: String?
    @Published var offset = 0
    @Published var total = 0
    @Published var selection = PhotoSelectionState()
    var focusedPhoto: SystemPhoto?
    var visibleGridID: String?
    var gridColumns = 1
    @Published var gridTrimRevision = 0
    var gridTrimFallbackID: String?
    @Published var gridJumpRevision = 0
    var gridJumpID: String?
    @Published var isSelecting = false
    @Published var isLoadingMore = false
    @Published var browseError: String?
    private var retryBefore = false
    @Published var presetPreview: ColorRenderedImage?
    var preview: SystemPhoto? { previewSession.photo }
    var previewImage: PreviewImage? { previewSession.image }
    var previewIndex: Int { previewSession.index }
    @Published private var requestedIndex: Int?
    var navigationIndex: Int { requestedIndex ?? previewSession.pendingIndex ?? previewIndex }
    var editor: ColorEditSession? { previewSession.editor }
    @Published var isBusy = false
    @Published var isSubmitting = false
    var isNavigating: Bool { requestedIndex != nil || previewSession.isLoading }
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
    private var previewObservation: AnyCancellable?
    private var refreshNeeded = false
    var selectedAlbum: SystemPhotoAlbum? { albums.first { $0.id == albumID } }
    var targetIDs: [String] { preview.map { [$0.id] } ?? selection.selectedIDs.sorted() }
    var hasTargets: Bool { preview != nil || !selection.selectedIDs.isEmpty }
    var blocksLocalOperations: Bool { isBusy || isNavigating || uploadSnapshots != nil }
    var canAct: Bool { connected && !isBusy && !isNavigating && canBegin() && unresolved.isEmpty }
    var canNavigate: Bool { connected && !isBusy && canBegin() && unresolved.isEmpty && editor?.isComposing != true }
    var isIsolated: Bool { ProcessInfo.processInfo.environment["JINGXU_UI_TEST_ROOT"] != nil }

    init(localStore: CatalogStore, canBegin: @escaping @MainActor () -> Bool) throws {
        self.localStore = localStore; self.canBegin = canBegin
        let root = try JingXuPaths.applicationSupport()
        let temporary = root.appendingPathComponent("SystemPhotosWorking")
        try PhotoWorkspace.removeAbandoned(in: temporary)
        if ProcessInfo.processInfo.environment["JINGXU_UI_TEST_ROOT"] != nil {
            client = try IsolatedPhotoLibraryClient.fixtures(root: root.appendingPathComponent("SystemPhotoFixtures"), count: 1_005)
        } else { client = try ApplePhotoLibraryClient(temporaryRoot: temporary) }
        store = try SystemPhotosStore(url: root.appendingPathComponent("SystemPhotos.sqlite"))
        coordinator = SystemPhotosCoordinator(client: client, store: store, localStore: localStore, temporaryRoot: temporary)
        previewSession = SystemPhotoPreviewSession(client: client, store: store)
        previewObservation = previewSession.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
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
        perform { [self] in
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
            connected = false; conflict = message; status = message; navigation?.cancel(); previewSession.cancel()
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
            connected = false
            throw ColorEditError("照片权限已撤销，草稿已保留")
        }
        albums = try await client.albums()
        if let albumID, !albums.contains(where: { $0.id == albumID }) {
            self.albumID = nil; offset = 0; selection.clear(); focusedPhoto = nil; visibleGridID = nil; gridJumpID = nil; items = []
        }
        if let anchorID = visibleGridID ?? items.first?.id,
           let position = items.firstIndex(where: { $0.id == anchorID }),
           let currentIndex = try await client.index(id: anchorID, albumID: albumID) {
            offset = max(0, currentIndex - position)
        }
        var page = try await client.page(albumID: albumID, offset: offset, limit: 200)
        if page.items.isEmpty && offset > 0 { offset = max(0, ((max(1, page.total) - 1) / 200) * 200); page = try await client.page(albumID: albumID, offset: offset, limit: 200) }
        let desiredCount = min(600, max(200, items.count))
        var loaded = page.items
        while !page.items.isEmpty && loaded.count < desiredCount && offset + loaded.count < page.total {
            try Task.checkCancellation()
            page = try await client.page(albumID: albumID, offset: offset + loaded.count, limit: 200)
            loaded += page.items
        }
        items = loaded; total = page.total; browseError = nil
        if let id = selection.focusID {
            if let visible = items.first(where: { $0.id == id }) { focusedPhoto = visible }
            else { focusedPhoto = try await client.photos(ids: [id], albumID: albumID).first }
        }
        let valid = try await client.matchingPhotoIDs(Array(selection.selectedIDs), albumID: albumID)
        selection.retain(validIDs: valid)
        if let preview {
            if let index = try await client.index(id: preview.id, albumID: albumID) { previewSession.updateIndex(index) }
            let current = try await client.photos(ids: [preview.id], albumID: nil).first
            if current != preview {
                if editor != nil || previewSession.hasDraft { conflict = "当前照片已变化或被删除。草稿保留在镜序，保存前请重新载入。" }
                else if let current {
                    try await previewSession.open(at: previewIndex, editing: false) { current }
                } else { _ = await previewSession.close(); status = "当前照片已从系统图库移除" }
            }
        }
        unresolved = try await store.unresolvedWrites()
        try await reloadAnalysis()
    }
    func browse(albumID: String?) {
        perform {
            guard await self.previewSession.close() else { throw ColorEditError("请先处理草稿保存失败") }
            self.presetPreview = nil; self.conflict = nil
            if self.albumID != albumID || self.offset != 0 {
                self.selection.clear(); self.focusedPhoto = nil; self.visibleGridID = nil; self.gridJumpID = nil; self.items = []
            }
            self.albumID = albumID; self.offset = 0; try await self.reload()
        }
    }
    func click(_ photo: SystemPhoto, command: Bool = false, shift: Bool = false, count: Int = 1) {
        guard canAct else { return }
        NSApp.keyWindow?.makeFirstResponder(nil)
        if selection.click(photo.id, photoIDs: items.map(\.id), command: command,
                           shift: shift, checkboxMode: isSelecting, count: count) {
            open(photo, index: offset + (items.firstIndex { $0.id == photo.id } ?? 0))
        }
        focusedPhoto = photo
    }
    func open(_ photo: SystemPhoto, index: Int) {
        transition(at: index) { photo }
    }
    private func transition(at index: Int, resolve: @escaping @MainActor () async throws -> SystemPhoto) {
        guard canNavigate else { return }
        navigation?.cancel(); let generation = UUID(); previewGeneration = generation
        conflict = nil; requestedIndex = index
        navigation = Task {
            defer { if previewGeneration == generation { requestedIndex = nil; navigation = nil; if refreshNeeded { refreshNeeded = false; refresh() } } }
            do {
                try await previewSession.open(at: index, resolve: resolve)
                guard previewGeneration == generation, !Task.isCancelled else { return }
                presetPreview = nil
                let pageOffset = (index / 200) * 200
                if index < offset || index >= offset + items.count {
                    let page = try await client.page(albumID: albumID, offset: pageOffset, limit: 200)
                    try Task.checkCancellation()
                    guard previewGeneration == generation else { return }
                    offset = pageOffset; items = page.items; total = page.total
                    gridJumpID = previewSession.photo?.id; gridJumpRevision += 1
                }
                try await reloadAnalysis()
                status = previewSession.hasDraft ? "本机草稿 · 未保存到系统照片" : "已读取系统照片"
            } catch is CancellationError {} catch { if previewGeneration == generation { self.error = error.localizedDescription } }
        }
    }
    func navigate(_ direction: Int) {
        guard canNavigate, preview != nil else { return }
        let index = navigationIndex + direction
        guard index >= 0 && index < total else { return }
        let album = albumID
        transition(at: index) {
            guard let next = try await self.client.page(albumID: album, offset: index, limit: 1).items.first else {
                throw ColorEditError("目标照片已不在当前相册，请刷新后重试")
            }
            return next
        }
    }
    func retryPreview() {
        guard let index = previewSession.failedIndex else { return }
        let album = albumID
        transition(at: index) {
            guard let photo = try await self.client.page(albumID: album, offset: index, limit: 1).items.first else { throw ColorEditError("照片已移除") }
            return photo
        }
    }
    func closePreview() {
        guard canAct else { return }
        perform {
            self.selection.focusID = self.preview?.id
            guard await self.previewSession.close() else { throw ColorEditError("本机草稿尚未保存") }
            self.presetPreview = nil; self.conflict = nil
            if let id = self.selection.focusID, self.items.contains(where: { $0.id == id }) {
                self.gridJumpID = id; self.gridJumpRevision += 1
            }
        }
    }
    func finishEditing() {
        guard canAct, editor != nil else { return }
        perform {
            try await self.previewSession.finishEditing()
            self.presetPreview = nil
            self.status = "本机草稿已保留；系统照片仅在明确保存后更新"
        }
    }
    func selectAllPhotos() {
        guard canAct else { return }
        perform {
            let ids = try await self.client.photoIDs(albumID: self.albumID)
            self.selection.selectAll(ids)
            self.status = "已选择当前范围的 \(ids.count) 张系统照片"
        }
    }
    func leavePreviewLevel() {
        if isNavigating { cancel() }
        else if editor?.isComposing == true { editor?.cancelComposition() }
        else if editor != nil { finishEditing() }
        else if preview != nil { closePreview() }
        else { selection.clear(); isSelecting = false }
    }
    func moveGridFocus(by step: Int, extending: Bool) {
        guard canAct, !items.isEmpty else { return }
        let id = selection.focusID
        perform {
            if let id, self.items.firstIndex(where: { $0.id == id }) == nil {
                if let absolute = try await self.client.index(id: id, albumID: self.albumID) {
                    let start = (absolute / 200) * 200
                    let page = try await self.client.page(albumID: self.albumID, offset: start, limit: 200)
                    self.offset = start; self.items = page.items; self.total = page.total
                    self.gridJumpID = id; self.gridJumpRevision += 1
                } else { self.selection.focusID = nil; self.focusedPhoto = nil }
            }
            let target = self.items.firstIndex(where: { $0.id == id }).map { $0 + step } ?? 0
            if target < 0 && self.offset > 0 { try await self.appendPage(before: true) }
            else if target >= self.items.count && self.offset + self.items.count < self.total { try await self.appendPage(before: false) }
            let index = self.items.firstIndex { $0.id == id }
            let destination = index.map { min(self.items.count - 1, max(0, $0 + step)) } ?? 0
            let item = self.items[destination]
            if extending {
                _ = self.selection.click(item.id, photoIDs: self.items.map(\.id), command: false, shift: true, checkboxMode: false, count: 1)
            } else { self.selection.selectOnly(item.id) }
            self.focusedPhoto = item
        }
    }
    func openFocusedPhoto() {
        guard canNavigate, let id = selection.focusID else { return }
        let album = albumID
        Task {
            do {
                guard let index = try await client.index(id: id, albumID: album),
                      let photo = try await client.photos(ids: [id], albumID: album).first else {
                    throw ColorEditError("当前照片已不在此范围，请刷新后重试")
                }
                guard selection.focusID == id, albumID == album else { return }
                open(photo, index: index)
            } catch { self.error = error.localizedDescription }
        }
    }
    func retryBrowse() { browseError = nil; loadMore(before: retryBefore) }
    private func appendPage(before: Bool) async throws {
        let nextOffset = before ? max(0, offset - 200) : offset + items.count
        let page = try await client.page(albumID: albumID, offset: nextOffset, limit: before ? offset - nextOffset : 200)
        try Task.checkCancellation()
        guard let window = SystemPhotoBrowseWindow(items: items, offset: offset, page: page,
                                                   pageOffset: nextOffset, before: before, columns: gridColumns) else {
            try await reload(); return
        }
        if focusedPhoto == nil, let id = selection.focusID { focusedPhoto = items.first { $0.id == id } }
        let trimmed = before ? !window.items.contains(where: { $0.id == items.last?.id })
            : !window.items.contains(where: { $0.id == items.first?.id })
        let fallback = before ? items.first?.id : items.last?.id
        withTransaction(Transaction(animation: nil)) {
            items = window.items; offset = window.offset; total = window.total; browseError = nil
        }
        if trimmed { gridTrimFallbackID = fallback; gridTrimRevision += 1 }
    }
    func loadMore(before: Bool = false) {
        guard canAct, preview == nil, !isLoadingMore,
              before ? offset > 0 : offset + items.count < total else { return }
        perform {
            self.isLoadingMore = true
            defer { self.isLoadingMore = false }
            do {
                try await self.appendPage(before: before)
            } catch is CancellationError { throw CancellationError() }
            catch { self.retryBefore = before; self.browseError = "载入更多照片失败：\(error.localizedDescription)" }
        }
    }
    func beginEditing() {
        guard let preview, preview.canEdit, editor == nil, canAct else { return }
        perform { try await self.loadEditor(preview) }
    }
    private func loadEditor(_ photo: SystemPhoto) async throws {
        presets = try await localStore.colorPresets()
        try await previewSession.open(at: previewIndex, editing: true) { photo }
        presetPreview = nil
        if case .systemPhoto(let input) = editor?.snapshot.origin, input.usesRenderedBase {
            status = "以其他应用的当前成片为底图；本次编辑前对比不会撤销其效果"
        } else { status = "调整自动保存为本机草稿；点击「保存到系统照片」后更新照片" }
    }
    func saveEdit() {
        guard let editor, canAct, conflict == nil, presetPreview == nil, !editor.isComposing else { return }
        perform {
            try await editor.withSavedSnapshot { snapshot in
                self.isSubmitting = true
                try await self.coordinator.saveEdit(snapshot)
            }
            self.status = "已保存到系统照片，iCloud 同步由系统处理"
            guard let updated = try await self.client.photos(ids: [editor.snapshot.id], albumID: nil).first else { throw ColorEditError("保存后照片暂不可读取") }
            self.conflict = nil
            try await self.loadEditor(updated)
            self.status = "已保存到系统照片，iCloud 同步由系统处理"
        }
    }
    func discardDraft() {
        guard let preview = previewSession.failedPhoto ?? preview, !isBusy, !isNavigating else { return }
        let index = previewSession.failedPhoto != nil ? (previewSession.failedIndex ?? previewIndex) : previewIndex
        let alert = NSAlert()
        alert.messageText = "放弃“\(preview.name)”的本机调色草稿？"
        alert.informativeText = "只删除镜序草稿，系统照片中的现有效果保留。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃草稿并重载")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform {
            if self.preview?.id == preview.id {
                self.editor?.cancelComposition()
                _ = await self.editor?.flush()
                self.editor?.discardDraft()
                guard await self.previewSession.close() else { throw ColorEditError("草稿仍在保存，请稍后重试") }
            }
            try await self.store.discardDraft(id: preview.id)
            guard let current = try await self.client.photos(ids: [preview.id], albumID: nil).first else { throw ColorEditError("照片已从系统图库移除") }
            try await self.previewSession.open(at: index, editing: false) { current }
            self.presetPreview = nil; self.conflict = nil
            self.status = "已放弃本机草稿，显示系统照片"
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
            guard await self.previewSession.close() else { throw ColorEditError("本机草稿尚未保存") }
            self.isSubmitting = true; try await self.coordinator.mutate(plan)
            self.presetPreview = nil; self.conflict = nil
            self.status = "系统照片已处理操作，iCloud 同步由系统负责"
            try await self.reload()
        }
    }
    func prepareAnalysis() {
        guard canAct, hasTargets else { return }
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
    func cancel() { if !isSubmitting { task?.cancel(); navigation?.cancel(); previewSession.cancel() } }
    func prepareFullImage(_ ready: @escaping @MainActor (CGImage) -> Void) {
        guard canAct, editor?.isComposing != true, presetPreview == nil else { return }
        perform { ready(try await self.previewSession.fullImage().image) }
    }
    func updatePreviewDetail(_ transform: CanvasTransform) {
        guard previewSession.needsFullImage(at: transform), !isBusy, conflict == nil else { return }
        let id = preview?.id
        Task {
            do { _ = try await previewSession.fullImage() }
            catch is CancellationError {} catch { if preview?.id == id { self.error = "完整画质读取失败：\(error.localizedDescription)" } }
        }
    }
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
        task?.cancel(); navigation?.cancel(); previewSession.cancel()
        await task?.value; await navigation?.value
        guard await previewSession.close() else { return false }
        preparedUpload = nil; uploadSnapshots = nil
        return true
    }
}
