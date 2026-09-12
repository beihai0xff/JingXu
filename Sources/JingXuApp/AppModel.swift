@preconcurrency import AppKit
import Combine
import CryptoKit
import Foundation
import JingXuCore
import JingXuAutomation

enum SidebarDestination: Hashable {
    case smart(SmartCollection)
    case source(String)
    case folder(CatalogFolderID)
    case album(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [SourceRoot] = [] { didSet { if oldValue != sources { automationSelectionToken = UUID() } } }
    @Published var albums: [Album] = []
    @Published var assets: [AssetListItem] = [] {
        didSet {
            let previous = Dictionary(uniqueKeysWithValues: oldValue.map { ($0.id, $0.fileVersion) })
            if assets.contains(where: { previous[$0.id] != nil && previous[$0.id] != $0.fileVersion }) { automationSelectionToken = UUID() }
        }
    }
    @Published var sidebarSelection: SidebarDestination? = .smart(.all)
    @Published var folderRoots: [CatalogFolderNode] = []
    @Published var expandedFolders = Set<CatalogFolderID>()
    @Published var includeSubdirectories: Bool
    @Published var matchingAssetCount = 0
    @Published var isLoadingAssets = false
    var assetRequestID = UUID()
    var folderRequestID = UUID()
    private let browsingDefaults: UserDefaults
    @Published var photoSelection = PhotoSelectionState() { didSet { if oldValue != photoSelection { automationSelectionToken = UUID() } } }
    var selectedAssetID: String? {
        get { photoSelection.focusID }
        set { photoSelection.focusID = newValue }
    }
    var selectedPhotoIDs: [String] { photoSelection.selectedIDs.sorted() }
    @Published var isBatchSelecting = false { didSet { if oldValue != isBatchSelecting { automationSelectionToken = UUID() } } }
    var automationSelectionToken = UUID()
    var automationOwnsOperation = false
    var automationDirectoryPanel: NSOpenPanel?
    @Published var automationConnection: AutomationConnection?

    func clickAsset(_ item: AssetListItem, command: Bool, shift: Bool, count: Int) {
        guard canChangeBrowseScope, NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return }
        if keywordDraft != keywordSaved {
            transitionPreview { self.clickAsset(item, command: command, shift: shift, count: count) }
            return
        }
        let open = photoSelection.click(item.id, photoIDs: assets.filter { $0.kind == .photo }.map(\.id),
                                        command: command, shift: shift, checkboxMode: isBatchSelecting, count: count)
        NSApp.keyWindow?.makeFirstResponder(nil)
        if open { openPreview(item) }
        syncKeywordDraft()
    }

    func selectVisiblePhotos() {
        guard canChangeBrowseScope else { return }
        transitionPreview {
            self.photoSelection.selectAll(self.assets.filter { $0.kind == .photo }.map(\.id))
            self.syncKeywordDraft()
        }
    }
    func clearPhotoSelection() {
        guard canChangeBrowseScope else { return }
        transitionPreview { self.photoSelection.clear(); self.syncKeywordDraft() }
    }
    func changeCheckboxMode(_ enabled: Bool) {
        guard canChangeBrowseScope else { return }
        isBatchSelecting = enabled

    }
    @Published var isShowingPhotoShare = false
    @Published var shareDraft: [AssetListItem] = []
    @Published var sharePreparationProgress = ""
    let systemSharePresenter = SystemSharePresenter()
    lazy var photoShareSession = PhotoShareSession(presenter: systemSharePresenter)
    var photoShareCoordinator: PhotoShareCoordinator?
    var sharePreparationTask: Task<Void, Never>?
    private var shareObservation: AnyCancellable?
    var appliedQuery = BrowseQuery()
    var pendingQuery: BrowseQuery?
    var pendingDestination: SidebarDestination?
    var browseTask: Task<Void, Never>?
    var searchTask: Task<Void, Never>?
    @Published var browseError: String?
    var retryBrowseAction: (@MainActor () -> Void)?
    @Published var hasPreviousPage = false
    @Published var hasNextPage = false
    @Published var resultsChanged = false
    @Published var previewItems: [AssetListItem] = []
    @Published var previewHasPrevious = false
    @Published var previewHasNext = false
    @Published var comparisonReference: AssetListItem?
    var comparisonReturnQuery: BrowseQuery?
    var comparisonPrefetchTask: Task<Void, Never>?
    var prefetchedComparison: PreviewImage?
    var prefetchedComparisonKey: String?
    var comparisonPrefetchGeneration = UUID()
    @Published var isPreparingSelection = false
    @Published var operationResults: [String] = []
    @Published var gridColumns = 1
    @Published var keywordDraft = ""
    var keywordTargetID: String?
    var keywordSaved = ""
    @Published var isShowingKeywords = false
    @Published var isSavingAnnotation = false
    let annotationUndoManager = UndoManager()
    var undoTask: Task<Void, Never>?
    var keywordSaveTask: Task<Bool, Never>?
    @Published var thumbnailReloadID = UUID()

    @Published var searchText = ""
    @Published var minimumRating = 0
    @Published var flagFilter: AssetFlag?
    @Published var gridSize: CGFloat = 170
    @Published var isWorking = false
    @Published var statusText = "准备就绪" {
        didSet {
            if !isWorking && !statusText.isEmpty && operationResults.first != statusText {
                operationResults.insert(statusText, at: 0)
                if operationResults.count > 20 { operationResults.removeLast() }
            }
        }
    }
    @Published var errorMessage: String?
    @Published var isShowingImport = false
    @Published var isShowingAlbumCreator = false
    @Published var importProgress: ImportProgress?
    @Published var lastScanReport: ScanReport?
    @Published var scanProgress: ScanProgress?
    @Published var analysisProgress: AnalysisProgress?
    @Published var qualityReanalysisPlan: QualityReanalysisPlan?
    @Published var qualityJobs: [QualityJobSnapshot] = []
    @Published var isReanalyzing = false
    @Published var deletionPlan: DeletionPlan?
    @Published var missingAssetPlan: MissingAssetPlan?
    @Published var archivePlan: ArchivePlan?
    @Published var archivePending = false
    private var archiveCoordinator: ArchiveCoordinator?
    @Published var isDeleting = false
    @Published var sourceMergePlan: SourceMergePlan?
    private let histogramProvider = HistogramProvider()
    private var deletionCoordinator: DeletionCoordinator?
    @Published var colorEditor: ColorEditSession?
    @Published var colorPresets: [ColorPreset] = []
    @Published var copiedColorPatch: ColorPatch?
    @Published var isShowingColorPresets = false
    @Published var colorBatchPlan: ColorBatchPlan?
    @Published var colorExportPlan: ColorExportPlan?
    @Published var isShowingColorExport = false
    @Published var colorUndoPlan: ColorBatchPlan?
    @Published var isPreviewTransitioning = false
    var colorExportCoordinator: ColorExportCoordinator?
    var colorThumbnails: ColorThumbnailProvider?
    var colorEditorObservation: AnyCancellable?
    @Published var previewAsset: AssetListItem? { didSet { if oldValue?.id != previewAsset?.id { automationSelectionToken = UUID() } } }

    let volumeMonitor = VolumeMonitor()

    var store: CatalogStore?
    private var scanner: DefaultSourceScanner?
    var importer: ImportCoordinator?
    var analysisCoordinator: AnalysisCoordinator?
    private var reanalysisCoordinator: QualityReanalysisCoordinator?
    var thumbnailProvider: DefaultThumbnailProvider?
    private var xmpExporter: DefaultXMPExporter?
    @Published var xmpPlan: XMPExportPlan?
    @Published var importPlan: ImportPlan?
    @Published var lastImportReport: ImportReport?
    @Published var isShowingImportReport = false
    @Published var isAnalyzingNewAssets = false
    private var operationTask: Task<Void, Never>?
    @Published var startupFailure: String?
    @Published var isStarting = true
    private var upgradeCoordinator: CatalogUpgradeCoordinator?

    var catalogLocation: String { (try? JingXuPaths.databaseURL().path) ?? "无法访问 Application Support" }
    var upgradeBackupLocation: String {
        (try? JingXuPaths.databaseURL()).map { CatalogUpgradeCoordinator.backupDirectory(for: $0).path } ?? "无法访问备份目录"
    }

    var selectedAsset: AssetListItem? {
        assets.first { $0.id == selectedAssetID }
    }

    init() {
        if let root = ProcessInfo.processInfo.environment["JINGXU_UI_TEST_ROOT"] {
            let id = SHA256.hash(data: Data(URL(fileURLWithPath: root).standardizedFileURL.path.utf8))
                .map { String(format: "%02x", $0) }.joined()
            browsingDefaults = UserDefaults(suiteName: "app.jingxu.ui-test.\(id)")!
        } else { browsingDefaults = .standard }
        includeSubdirectories = browsingDefaults.object(forKey: "BrowseIncludesSubdirectories") as? Bool ?? true
        shareObservation = photoShareSession.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        annotationUndoManager.levelsOfUndo = 50
        annotationUndoManager.groupsByEvent = false
        Task { await initializeCatalog() }
    }

    func initializeCatalog() async {
        guard store == nil else { return }
        isStarting = true; isWorking = true; startupFailure = nil
        do {
            let peers = NSRunningApplication.runningApplications(withBundleIdentifier: "app.jingxu.desktop")
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
            guard peers.isEmpty else { throw CatalogUpgradeError.blocked("检测到另一个镜序实例，请先退出旧版再重试。") }
            let coordinator: CatalogUpgradeCoordinator
            if let existing = upgradeCoordinator { coordinator = existing }
            else {
                coordinator = CatalogUpgradeCoordinator(databaseURL: try JingXuPaths.databaseURL())
                upgradeCoordinator = coordinator
            }
            let store = try await coordinator.open()
            let scanner = DefaultSourceScanner(repository: store)
            self.store = store
            self.archiveCoordinator = ArchiveCoordinator(store: store, journalURL: try JingXuPaths.applicationSupport().appendingPathComponent("archive.json"))
            try await self.archiveCoordinator?.reconcile()
            self.archivePending = try await self.archiveCoordinator?.hasPending() ?? false
            self.deletionCoordinator = DeletionCoordinator(store: store, journalURL: try JingXuPaths.databaseURL().deletingLastPathComponent().appendingPathComponent("deletions.json"))
            self.scanner = scanner
            self.importer = ImportCoordinator(repository: store, scanner: DefaultSourceScanner(repository: store, failureDetailLimit: .max))
            self.analysisCoordinator = AnalysisCoordinator(repository: store)
            self.reanalysisCoordinator = QualityReanalysisCoordinator(store: store, analyzer: self.analysisCoordinator)
            let thumbnailCache = ThumbnailCache(directory: try JingXuPaths.thumbnailCache())
            self.thumbnailProvider = DefaultThumbnailProvider(cache: thumbnailCache)
            self.xmpExporter = DefaultXMPExporter(repository: store)
            self.colorExportCoordinator = ColorExportCoordinator(store: store)
            self.photoShareCoordinator = PhotoShareCoordinator(store: store, cacheRoot: try JingXuPaths.applicationSupport().appendingPathComponent("Sharing"))
            do { try await self.photoShareCoordinator?.cleanupExpired() }
            catch { self.statusText = "分享缓存清理失败：\(error.localizedDescription)" }
            self.colorThumbnails = ColorThumbnailProvider(cache: thumbnailCache)
            self.colorPresets = try await store.colorPresets()
            let testID = ProcessInfo.processInfo.environment["JINGXU_UI_TEST_ROOT"].map {
                SHA256.hash(data: Data(URL(fileURLWithPath: $0).standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
            }
            let defaults = testID.map {
                UserDefaults(suiteName: "app.jingxu.ui-test.\($0)")!
            } ?? .standard
            let credentialService = testID.map {
                "app.jingxu.desktop.mcp.ui-test.\($0)"
            } ?? "app.jingxu.desktop.mcp"
            self.automationConnection = AutomationConnection(defaults: defaults, credentialService: credentialService) { [weak self] in
                guard let self, let store = self.store else { throw ColorEditError("图库未打开") }
                return ColorAutomationController(host: self, store: store, exporter: self.colorExportCoordinator)
            }
        } catch {
            store = nil
            scanner = nil
            importer = nil
            analysisCoordinator = nil
            reanalysisCoordinator = nil
            thumbnailProvider = nil
            xmpExporter = nil
            deletionCoordinator = nil
            archiveCoordinator = nil
            colorExportCoordinator = nil
            colorThumbnails = nil
            colorPresets = []
            startupFailure = "初始化图库失败：\(error.localizedDescription)"
            isStarting = false; isWorking = false
            return
        }
        do {
            do {
                let journal = try JingXuPaths.databaseURL().deletingLastPathComponent().appendingPathComponent("deletions.json")
                if FileManager.default.fileExists(atPath: journal.path) {
                    let entries = try JSONDecoder().decode([DeletionJournalEntry].self, from: Data(contentsOf: journal))
                    let pendingIDs = Set(entries.filter { $0.state == "moved" || $0.state == "moving" }.flatMap { $0.relatedIDs ?? [$0.asset.id] })
                    if !pendingIDs.isEmpty { try await thumbnailProvider?.invalidate(assetIDs: pendingIDs) }
                }
                let warnings = try await deletionCoordinator?.recover() ?? []
                if !warnings.isEmpty { errorMessage = warnings.joined(separator: "\n") }
            } catch { errorMessage = "恢复删除记录失败：\(error.localizedDescription)" }
            do {
                try await store?.recoverImportJobs()
                lastImportReport = try await store?.latestImportReport()
                try await store?.recoverQualityJobs()
                qualityJobs = try await store?.qualityJobs() ?? []
            } catch { errorMessage = "读取重算进度失败：\(error.localizedDescription)" }
            await reloadAll()
            isWorking = false
            isStarting = false
        }
    }

    func restoreUpgradeBackup() {
        guard store == nil, !isStarting, let upgradeCoordinator else { return }
        let panel = NSOpenPanel()
        panel.title = "选择包含 manifest.json 的升级备份文件夹"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.directoryURL = URL(fileURLWithPath: upgradeBackupLocation)
        guard panel.runModal() == .OK, let backup = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "恢复升级前图库？"
        alert.informativeText = "\(backup.path)\n备份之后的图库变更会回退。当前数据库及日志会先保全，原照片不会修改。恢复完成后本版本将检查图库格式；旧格式需使用匹配的旧版镜序打开；如需回退程序版本，请退出后使用匹配版本。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "保全当前数据并恢复")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        isStarting = true
        Task {
            do {
                let peers = NSRunningApplication.runningApplications(withBundleIdentifier: "app.jingxu.desktop")
                    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
                guard peers.isEmpty else { throw CatalogUpgradeError.blocked("请先退出其他镜序实例。") }
                let access = backup.startAccessingSecurityScopedResource()
                defer { if access { backup.stopAccessingSecurityScopedResource() } }
                try await upgradeCoordinator.restore(from: backup)
                startupFailure = "备份已恢复。可重试启动，或退出并使用匹配版本。"
            } catch { startupFailure = "恢复未完成：\(error.localizedDescription)" }
            isStarting = false
        }
    }

    deinit {
        operationTask?.cancel()
    }

    func reloadAll() async {
        guard let store else { return }
        let request = UUID(); folderRequestID = request
        do {
            async let loadedSources = store.sources()
            async let loadedAlbums = store.albums()
            async let loadedFolders = store.folderTree()
            let (newSources, newAlbums, newFolders) = try await (loadedSources, loadedAlbums, loadedFolders)
            guard folderRequestID == request else { return }
            let knownSources = Set(sources.map(\.id))
            sources = newSources; albums = newAlbums; folderRoots = newFolders
            for source in sources where !knownSources.contains(source.id) {
                expandedFolders.insert(CatalogFolderID(sourceID: source.id))
            }
            reconcileFolderSelection()
            await reloadAssets()
        } catch {
            guard folderRequestID == request else { return }
            errorMessage = "读取图库失败：\(error.localizedDescription)"
        }
    }

    var selectedFolderID: CatalogFolderID? {
        switch sidebarSelection {
        case .source(let id): CatalogFolderID(sourceID: id)
        case .folder(let id): id
        default: nil
        }
    }

    var selectedFolder: CatalogFolderNode? {
        guard let id = selectedFolderID else { return nil }
        return folderRoots.first(where: { $0.id.sourceID == id.sourceID })?.node(id)
    }

    var selectedFolderPath: String? {
        guard let id = selectedFolderID, let source = sources.first(where: { $0.id == id.sourceID }) else { return nil }
        return source.pathHint + (id.relativeDirectory.isEmpty ? "" : "/" + id.relativeDirectory)
    }

    var directoryHasNoDirectFiles: Bool {
        selectedFolder != nil && !includeSubdirectories && selectedFolder?.directCount == 0
    }

    var canChangeBrowseScope: Bool {
        // SwiftUI's disabled state must only depend on observable model state.
        // Clearing an alert can render before AppKit detaches its sheet; reading
        // attachedSheet here would leave the sidebar disabled with no later update.
        !isStarting && !isSavingAnnotation && !isPreparingSelection && !isLoadingAssets && !automationOwnsOperation && canInteractWithLibrary &&
        !isShowingColorPresets && errorMessage == nil
    }

    func selectSidebar(_ destination: SidebarDestination?) {
        guard let destination, destination != sidebarSelection, canChangeBrowseScope,
              NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return }
        transitionPreview {
            self.applyBrowseScope(destination)
            Task { await self.reloadAssets() }
        }
    }

    func setIncludeSubdirectories(_ value: Bool) {
        guard selectedFolderID != nil, value != includeSubdirectories, canChangeBrowseScope,
              NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil else { return }
        transitionPreview {
            self.applyBrowseScope(self.sidebarSelection, includeSubdirectories: value)
            Task { await self.reloadAssets() }
        }
    }

    /// Called only after a successful preview-save transition, or by a completed
    /// catalog operation which already owns the operation gate and has no editor.
    func applyBrowseScope(_ destination: SidebarDestination?, includeSubdirectories value: Bool? = nil) {
        pendingDestination = destination
        pendingQuery = draftQuery(destination: destination, includeSubdirectories: value)
    }

    private func reconcileFolderSelection() {
        guard let id = selectedFolderID else { return }
        let nearest = folderRoots.first(where: { $0.id.sourceID == id.sourceID })?.nearestSurvivingAncestor(of: id)
        guard nearest != id else { return }
        let destination: SidebarDestination = nearest.map {
            $0.relativeDirectory.isEmpty ? .source($0.sourceID) : .folder($0)
        } ?? .smart(.all)
        if colorEditor == nil { applyBrowseScope(destination) }
        else {
            transitionPreview {
                self.applyBrowseScope(destination)
                Task { await self.reloadAssets() }
            }
        }
    }

    func prepareMissingAssetCleanup() {
        guard let store else { return }
        let query = currentQuery()
        startOperation {
            self.statusText = "正在检查当前范围的失效索引…"
            do { self.missingAssetPlan = try await store.prepareMissingAssetCleanup(query) }
            catch { self.errorMessage = "检查未完成：\(error.localizedDescription)" }
        }
    }

    func persistBrowsePreference() { browsingDefaults.set(includeSubdirectories, forKey: "BrowseIncludesSubdirectories") }

    func confirmMissingAssetCleanup(_ plan: MissingAssetPlan) {
        missingAssetPlan = nil
        guard let store else { return }
        startOperation {
            self.isDeleting = true
            defer { self.isDeleting = false }
            do {
                self.annotationUndoManager.removeAllActions()
                let report = try await store.cleanupMissingAssets(plan, backupURL: self.backupURL())
                if let id = self.previewAsset?.id, report.removedIDs.contains(id) { self.dismissPreview() }
                if let id = self.selectedAssetID, report.removedIDs.contains(id) { self.selectedAssetID = nil }
                do { try await self.thumbnailProvider?.invalidate(assetIDs: report.removedIDs) }
                catch { self.errorMessage = "索引已清理，但缩略图缓存清理失败：\(error.localizedDescription)" }
                await self.reloadAll()
                self.statusText = "已移除 \(report.removedIDs.count) 项失效索引，跳过 \(report.skipped.count) 项；原文件未改动，图库已备份"
                if !report.skipped.isEmpty { self.errorMessage = self.statusText + "\n" + report.skipped.prefix(30).joined(separator: "\n") }
            } catch { self.errorMessage = "清理未执行或已回滚：\(error.localizedDescription)" }
        }
    }

    func prepareDeletion() {
        guard !isWorking, let deletionCoordinator else { return }
        let query = currentQuery()
        startOperation {
            do { self.deletionPlan = try await deletionCoordinator.prepare(query) }
            catch { self.errorMessage = error.localizedDescription }
        }
    }

    func confirmDeletion(_ plan: DeletionPlan) {
        deletionPlan = nil
        guard let deletionCoordinator else { return }
        startOperation {
            self.dismissPreview()
            self.isDeleting = true
            defer { self.isDeleting = false }
            do {
                self.annotationUndoManager.removeAllActions()
                let report = try await deletionCoordinator.execute(plan) { done, total in
                    await MainActor.run { self.statusText = "正在移到废纸篓 \(done)/\(total)" }
                }
                try await self.thumbnailProvider?.invalidate(assetIDs: Set(plan.files.map(\.id)))
                await self.reloadAll()
                self.errorMessage = "成功 \(report.deleted)，跳过 \(report.skipped)，失败 \(report.failures.count)\(report.cancelled ? "；已取消后续项目" : "")\n" + (report.failures + report.skipReasons).prefix(30).joined(separator: "\n")
            } catch {
                try? await self.thumbnailProvider?.invalidate(assetIDs: Set(plan.files.map(\.id)))
                await self.reloadAll()
                self.errorMessage = "清理未完成：\(error.localizedDescription)"
            }
        }
    }

    func openPreview(_ item: AssetListItem) {
        guard item.kind == .photo, !isDeleting else { return }
        transitionPreview {
            self.presentPreview(item)
        }
    }
    func presentPreview(_ item: AssetListItem) {
        previewAsset = item
        previewItems = assets.filter { $0.kind == .photo }
        previewHasPrevious = hasPreviousPage; previewHasNext = hasNextPage
        NSApp.mainWindow?.makeFirstResponder(nil)
        Task { await refreshPreviewWindow() }
    }
    func selectAsset(_ item: AssetListItem) {
        guard !automationOwnsOperation else { return }
        photoSelection.selectOnly(item.id, isPhoto: item.kind == .photo)
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    func closePreview() {
        transitionPreview {
            let anchor = self.previewAsset.map(BrowseCursor.init)
            self.dismissPreview()
            if let anchor { Task { await self.loadBrowsePage(cursor: anchor, inclusive: true); self.syncKeywordDraft() } }
        }
    }
    /// Used after drafts have drained. File operations refresh the grid themselves.
    func dismissPreview() {
        comparisonReference = nil; clearComparisonPrefetch(); previewAsset = nil; previewItems = []
        previewHasPrevious = false; previewHasNext = false
    }
    var previewNavigationEnabled: Bool {
        previewAsset != nil && !isPreparingSelection && canInteractWithLibrary && !isLoadingAssets && !isSavingAnnotation && !isShowingPhotoShare && !automationOwnsOperation && !isPreviewTransitioning && !isDeleting && !isShowingImport && !isShowingAlbumCreator &&
        !isShowingColorPresets && !isShowingColorExport && colorBatchPlan == nil && colorExportPlan == nil &&
        deletionPlan == nil && sourceMergePlan == nil && qualityReanalysisPlan == nil && xmpPlan == nil && errorMessage == nil
    }
    func canNavigatePreview(_ direction: Int) -> Bool {
        guard previewNavigationEnabled, let item = previewAsset else { return false }
        let navigation = PreviewNavigation(photoIDs: previewItems.map(\.id))
        return navigation.neighbor(of: item.id, direction: direction) != nil || (direction < 0 ? previewHasPrevious : previewHasNext)
    }
    func navigatePreview(_ direction: Int) {
        guard previewNavigationEnabled, let item = previewAsset, let store else { return }
        transitionPreview {
            self.isPreviewTransitioning = true
            Task {
                defer { self.isPreviewTransitioning = false }
                do {
                    let cursor = BrowseCursor(item)
                    let page = try await store.browsePage(self.appliedQuery, cursor: cursor, reverse: direction < 0, photosOnly: true, limit: 2)
                    var candidates = direction < 0 ? Array(page.items.reversed()) : page.items
                    if candidates.first?.id == self.comparisonReference?.id { candidates.removeFirst() }
                    if let next = candidates.first { self.previewAsset = next; await self.refreshPreviewWindow() }
                    else { self.statusText = "已到当前范围边界" }
                } catch { self.errorMessage = "切图失败：\(error.localizedDescription)" }
            }
        }
    }
    var previewFilmstrip: [AssetListItem] { previewItems }
    func selectPreview(id: String) {
        guard previewNavigationEnabled, let item = previewItems.first(where: { $0.id == id }), id != comparisonReference?.id else { return }
        transitionPreview { self.previewAsset = item; Task { await self.refreshPreviewWindow() } }
    }
    func flagFromMenu(_ flag: AssetFlag) {
        guard NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil,
              !isShowingImport, !isShowingAlbumCreator else { return }
        guard NSApp.keyWindow?.title == "镜序" else { return }
        updateFlag(flag, advanceToNext: flag == .rejected && annotationTargetIDs.count == 1)
    }
    func loadOriginal(_ item: AssetListItem) async throws -> PreviewImage {
        guard let store, let asset = try await store.asset(id: item.id),
              let source = try await store.source(id: asset.sourceID) else { throw CocoaError(.fileNoSuchFile) }
        if item.colorRevision > 0 {
            let snapshot = try await store.colorSnapshot(assetID: item.id)
            let result = try await ColorImageRenderer.shared.render(snapshot, adjustments: snapshot.adjustments)
            return PreviewImage(image: result.image, nativeSize: result.nativeSize, isEmbedded: false, access: nil)
        }
        let root = try BookmarkStore.resolve(source).url
        let access = PreviewAccessLease(url: root)
        return try await ImagePreviewLoader().load(url: root.appendingPathComponent(asset.relativePath), access: access)
    }

    func histogram(for item: AssetListItem) async throws -> HistogramResult {
        guard let store, let asset = try await store.asset(id: item.id),
              let source = try await store.source(id: asset.sourceID) else { throw CocoaError(.fileReadNoSuchFile) }
        let root = try BookmarkStore.resolve(source).url
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        return try await histogramProvider.histogram(asset: asset, url: root.appendingPathComponent(asset.relativePath))
    }

    var hasUserFilters: Bool { !appliedQuery.searchText.isEmpty || appliedQuery.minimumRating > 0 || appliedQuery.flag != nil }
    func clearFilters() {
        searchText = ""; minimumRating = 0; flagFilter = nil
        requestFilters()
    }

    func checkDeletionRecovery() async throws {
        guard !photoShareSession.blocksFileChanges else { throw ColorEditError("原片分享尚未结束，请先完成分享或结束本次分享会话") }
        if try await archiveCoordinator?.hasPending() == true {
            throw NSError(domain: "JingXu", code: 4, userInfo: [NSLocalizedDescriptionKey: "有未完成的归档，请先使用恢复／撤销归档入口处理。"])
        }
        let warnings = try await deletionCoordinator?.recover() ?? []
        if !warnings.isEmpty { throw NSError(domain: "JingXu", code: 3, userInfo: [NSLocalizedDescriptionKey: warnings.joined(separator: "\n")]) }
    }
    func backupURL() throws -> URL {
        try JingXuPaths.applicationSupport().appendingPathComponent("Backups/\(UUID().uuidString).sqlite")
    }
    func removeSource(_ source: SourceRoot) {
        guard let store else { return }
        startOperation {
            self.isDeleting = true
            defer { self.isDeleting = false }
            do {
                let count = try await store.assets(sourceID: source.id).count
                let alert = NSAlert()
                alert.messageText = "移除来源“\(source.name)”？"
                alert.informativeText = "\(source.pathHint)\n共 \(count) 项索引。将清理该来源的索引、评分、标签、调色及相册成员关系，不删除硬盘照片。执行前会备份图库。"
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移除来源")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                try await self.checkDeletionRecovery()
                self.dismissPreview()
                self.annotationUndoManager.removeAllActions()
                let ids = try await store.removeSource(id: source.id, backupURL: self.backupURL())
                try await self.thumbnailProvider?.invalidate(assetIDs: ids)
                if self.selectedFolderID?.sourceID == source.id { self.applyBrowseScope(.smart(.all)) }
                await self.reloadAll()
                self.statusText = "来源已移除，原照片未改动；图库备份保存在 Backups"
            } catch { self.errorMessage = "移除失败：\(error.localizedDescription)"; await self.reloadAll() }
        }
    }
    func deleteAlbum(_ album: Album) {
        guard let store else { return }
        startOperation {
            self.isDeleting = true
            defer { self.isDeleting = false }
            let alert = NSAlert()
            alert.messageText = "删除相册“\(album.name)”？"
            alert.informativeText = "只删除相册及成员关系，不删除照片索引、评分、标签或原文件。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除相册")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            do {
                try await self.checkDeletionRecovery()
                self.annotationUndoManager.removeAllActions()
                try await store.deleteAlbum(id: album.id)
                if self.sidebarSelection == .album(album.id) { self.applyBrowseScope(.smart(.all)) }
                await self.reloadAll()
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
    func prepareSourceMerge() {
        guard let store else { return }
        startOperation {
            do {
                try await self.checkDeletionRecovery()
                self.sourceMergePlan = try await store.prepareSourceMerge()
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
    func confirmSourceMerge(_ plan: SourceMergePlan) {
        sourceMergePlan = nil
        guard let store else { return }
        startOperation {
            self.isDeleting = true
            defer { self.isDeleting = false }
            do {
                try await self.checkDeletionRecovery()
                self.dismissPreview()
                self.annotationUndoManager.removeAllActions()
                let report = try await store.mergeSources(plan, backupURL: self.backupURL())
                try await self.thumbnailProvider?.invalidate(assetIDs: report.invalidatedIDs)
                self.applyBrowseScope(.smart(.all))
                await self.reloadAll()
                self.errorMessage = "已合并 \(report.mergedGroups) 组来源。原文件未改动。\n" + report.skipped.joined(separator: "\n")
            } catch { self.errorMessage = "合并失败：\(error.localizedDescription)"; await self.reloadAll() }
        }
    }

    func chooseAndAddFolder() {
        guard operationBlockReason(.files) == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要索引的照片文件夹"
        panel.prompt = "添加文件夹"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFolder(url)
    }

    func addFolder(_ url: URL) {
        guard let store, let scanner, analysisCoordinator != nil else { return }
        startOperation {
            self.lastScanReport = nil
            do {
                let source = try await store.registerSource(at: url)
                let report = try await scanner.scan(source: source) { [weak self] progress in
                    await MainActor.run {
                        self?.scanProgress = progress
                        self?.statusText = "正在索引 \(progress.processed)/\(progress.discovered)：\(progress.currentFile)"
                    }
                }
                await MainActor.run { self.scanProgress = nil; self.lastScanReport = report }
                await self.reloadAll()
                try await self.analyzeNewAssets(sourceID: report.sourceID)
                await self.reloadAll()
            } catch is CancellationError {
                await Task { await self.reloadAll() }.value
                await MainActor.run { self.statusText = "操作已取消" }
            } catch {
                await Task { await self.reloadAll() }.value
                await MainActor.run { self.errorMessage = "索引失败：\(error.localizedDescription)" }
            }
        }
    }

    func rescanSelectedSource() {
        guard let sourceID = selectedFolderID?.sourceID,
              let source = sources.first(where: { $0.id == sourceID }) else {
            statusText = "请先在侧栏选择来源或目录；重新扫描会检查整个来源"
            return
        }
        addFolderFromExistingSource(source)
    }

    private func addFolderFromExistingSource(_ source: SourceRoot) {
        guard let scanner, analysisCoordinator != nil else { return }
        startOperation {
            self.lastScanReport = nil
            do {
                let report = try await scanner.scan(source: source) { [weak self] progress in
                    await MainActor.run { self?.scanProgress = progress }
                }
                await MainActor.run { self.scanProgress = nil; self.lastScanReport = report }
                await self.reloadAll()
                try await self.analyzeNewAssets(sourceID: report.sourceID)
                await self.reloadAll()
            } catch is CancellationError {
                await Task { await self.reloadAll() }.value
                self.statusText = "操作已取消"
            } catch {
                await Task { await self.reloadAll() }.value
                await MainActor.run { self.errorMessage = "重新扫描失败：\(error.localizedDescription)" }
            }
        }
    }

    func cancelCurrentOperation() {
        if sharePreparationTask != nil { cancelPhotoShare(); return }
        if automationOwnsOperation { automationConnection?.cancelCurrentJob(); return }
        if isReanalyzing {
            Task { await reanalysisCoordinator?.requestCancel(); operationTask?.cancel() }
        } else { operationTask?.cancel() }
    }

    var resumableQualityJob: QualityJobSnapshot? { qualityJobs.first { $0.isResumable } }

    func prepareQualityReanalysis(legacyOnly: Bool = false, assetID: String? = nil) {
        guard let store else { return }
        let query = legacyOnly ? BrowseQuery() : currentQuery()
        startOperation {
            do {
                if try await store.qualityJobs().contains(where: { $0.isResumable }) {
                    self.errorMessage = "请先继续或取消已有质量重算任务"
                    return
                }
                let ids: [String]
                if let assetID { ids = [assetID] }
                else { ids = try await store.analysisCandidates(query, legacyOnly: legacyOnly) }
                self.qualityReanalysisPlan = QualityReanalysisPlan(
                    title: assetID != nil ? "重新分析这张照片" : (legacyOnly ? "重新分析全部旧结果" : "重新分析当前范围"), assetIDs: ids)
            } catch { self.errorMessage = "无法准备重算：\(error.localizedDescription)" }
        }
    }

    func confirmQualityReanalysis(_ plan: QualityReanalysisPlan) {
        guard let reanalysisCoordinator else { return }
        qualityReanalysisPlan = nil
        startOperation {
            self.isReanalyzing = true
            defer { self.isReanalyzing = false }
            do {
                self.statusText = "正在创建重算前在线备份…"
                let directory = try JingXuPaths.databaseURL().deletingLastPathComponent().appendingPathComponent("Backups/Analysis", isDirectory: true)
                let id = try await reanalysisCoordinator.prepare(plan, backupDirectory: directory)
                try await self.runQualityJob(id)
            } catch { self.errorMessage = "重算未完成：\(error.localizedDescription)" }
            await self.refreshQualityJobs()
        }
    }

    func resumeQualityReanalysis() {
        guard let job = resumableQualityJob else { return }
        startOperation {
            self.isReanalyzing = true
            defer { self.isReanalyzing = false }
            do { try await self.runQualityJob(job.id) }
            catch { self.errorMessage = "继续重算失败：\(error.localizedDescription)" }
            await self.refreshQualityJobs()
        }
    }

    func pauseQualityReanalysis() { if isReanalyzing { operationTask?.cancel() } }

    func cancelPausedQualityJob() {
        guard let job = resumableQualityJob, let store else { return }
        startOperation {
            do { try await store.setQualityJobState(job.id, state: .cancelled) }
            catch { self.errorMessage = "取消任务失败：\(error.localizedDescription)" }
            await self.refreshQualityJobs()
        }
    }

    private func runQualityJob(_ id: String) async throws {
        try await reanalysisCoordinator?.run(jobID: id) { [weak self] progress in
            await MainActor.run {
                self?.analysisProgress = progress
                self?.statusText = "质量重算 \(progress.completed)/\(progress.total) · \(progress.currentFile)"
            }
        }
    }

    private func refreshQualityJobs() async {
        do {
            qualityJobs = try await store?.qualityJobs() ?? []
            if let job = qualityJobs.first {
                let state = job.job.state == .completed ? "完成" : (job.job.state == .cancelled ? "已取消" : "已暂停／待继续")
                statusText = "重算\(state)：\(job.completed)/\(job.total)，失败 \(job.failed) 项"
            }
        } catch { errorMessage = "读取重算进度失败：\(error.localizedDescription)" }
        await reloadAssets()
    }

    func resolveSuggestion(accepted: Bool, assetID: String) {
        guard !isDeleting else { return }
        guard let store else { return }
        Task {
            do {
                _ = try await store.saveQualityReview(assetID: assetID, state: accepted ? .accepted : .ignored)
                await reloadAssets()
            } catch { errorMessage = "审核结果保存失败：\(error.localizedDescription)" }
        }
    }

    func createAlbum(named name: String) {
        guard let store else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Task {
            do {
                let album = Album(name: trimmed)
                try await store.saveAlbum(album)
                albums = try await store.albums()
                applyBrowseScope(.album(album.id))
                await reloadAssets()
            } catch { errorMessage = "创建相册失败：\(error.localizedDescription)" }
        }
    }

    func addSelectedAsset(to album: Album) {
        applyAnnotation(.init(albumID: album.id), title: "添加到相册")
    }

    func exportSelectedXMP() {
        guard colorEditor == nil, !colorTargetIDs.isEmpty, let xmpExporter else { return }
        let ids = colorTargetIDs
        startOperation { [self] in
            do { xmpPlan = try await xmpExporter.prepare(assetIDs: ids) }
            catch { errorMessage = "XMP 预检失败：\(error.localizedDescription)" }
        }
    }
    func confirmXMP() {
        guard let plan = xmpPlan, let xmpExporter else { return }
        xmpPlan = nil
        startOperation { [self] in
            do {
                let report = try await xmpExporter.execute(plan)
                statusText = report.summary
                if !report.failed.isEmpty { errorMessage = report.summary + "\n" + report.failed.joined(separator: "\n") }
            } catch { errorMessage = "XMP 导出失败：\(error.localizedDescription)" }
        }
    }

    func thumbnail(for item: AssetListItem, pixelSize: Int, scale: CGFloat = 2) async throws -> NSImage {
        guard let store, let thumbnailProvider,
              let asset = try await store.asset(id: item.id),
              let source = try await store.source(id: asset.sourceID) else { throw ColorEditError("照片或来源已不存在，请重新扫描") }
        guard source.isOnline else { throw ColorEditError("来源离线，请连接磁盘后重试") }
        let data: Data
        if item.colorRevision > 0, let colorThumbnails {
            let snapshot = try await store.colorSnapshot(assetID: item.id)
            data = try await colorThumbnails.thumbnail(snapshot, pixelSize: pixelSize, scale: scale)
        } else {
            let root = try BookmarkStore.resolve(source)
            guard !root.isStale else { throw ColorEditError("来源授权已失效，请重新授权") }
            let lease = PreviewAccessLease(url: root.url)
            defer { withExtendedLifetime(lease) {} }
            data = try await thumbnailProvider.thumbnailData(for: asset.id,
                url: root.url.appendingPathComponent(asset.relativePath), pixelSize: pixelSize, scale: scale)
        }
        try Task.checkCancellation()
        guard let image = NSImage(data: data) else { throw ColorEditError("无法解码缩略图") }
        return image
    }

    func revealSelectedInFinder(assetID: String? = nil) {
        guard let selectedAssetID = assetID ?? previewAsset?.id ?? selectedAssetID, let store else { return }
        Task {
            guard let asset = try? await store.asset(id: selectedAssetID),
                  let source = try? await store.source(id: asset.sourceID),
                  let root = try? BookmarkStore.resolve(source).url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(asset.relativePath)])
        }
    }

    func clearThumbnailCache() {
        Task {
            do {
                try await thumbnailProvider?.clearDiskCache()
                thumbnailReloadID = UUID()
                statusText = "缩略图缓存已清理，将按需重建"
            } catch { errorMessage = "清理缓存失败：\(error.localizedDescription)" }
        }
    }

    func startOperation(_ work: @escaping @MainActor @Sendable () async -> Void) {
        guard operationBlockReason(.files) == nil else { return }
        guard xmpPlan == nil, !isWorking, importPlan == nil, !isShowingImportReport, colorEditor == nil, !isPreviewTransitioning, colorBatchPlan == nil, colorExportPlan == nil, !isShowingColorPresets, !isShowingColorExport, archivePlan == nil, deletionPlan == nil, missingAssetPlan == nil, sourceMergePlan == nil, qualityReanalysisPlan == nil else { return }
        isWorking = true
        operationTask = Task {
            defer {
                isWorking = false
                if operationResults.first != statusText { operationResults.insert(statusText, at: 0); operationResults = Array(operationResults.prefix(20)) }
                importProgress = nil; scanProgress = nil; analysisProgress = nil
            }
            do {
                guard await flushKeywords() else { return }
                try await checkDeletionRecovery()
                try Task.checkCancellation()
                await work()
            } catch { errorMessage = "后台操作未开始：\(error.localizedDescription)" }
        }
    }

    func prepareArchive() {
        guard let archiveCoordinator, let store else { return }
        startOperation {
            do {
                guard !(try await store.qualityJobs()).contains(where: { $0.job.state != .completed && $0.job.state != .cancelled }) else {
                    throw NSError(domain: "JingXu", code: 5, userInfo: [NSLocalizedDescriptionKey: "请先完成或取消待处理的质量重算任务。"])
                }
                self.statusText = "正在读取拍摄日期并校验归档文件…"
                self.archivePlan = try await archiveCoordinator.prepare()
            } catch { self.errorMessage = error.localizedDescription }
        }
    }

    func prepareBatchMove() {
        guard canStartColorAction, !selectedPhotoIDs.isEmpty, let archiveCoordinator, let store else { return }
        let panel = NSOpenPanel()
        panel.title = "选择移动目标目录（同一磁盘）"
        panel.message = "移动已选照片及明确关联的 XMP。RAW/JPEG 配对须全部选中。不会覆盖已有文件。"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let selected = Set(selectedPhotoIDs)
        startOperation {
            do {
                guard !(try await store.qualityJobs()).contains(where: { $0.job.state != .completed && $0.job.state != .cancelled }) else {
                    throw NSError(domain: "JingXu", code: 5, userInfo: [NSLocalizedDescriptionKey: "请先完成或取消待处理的质量重算任务。"])
                }
                self.statusText = "正在校验批量移动清单…"
                self.archivePlan = try await archiveCoordinator.prepare(selectedIDs: selected, destination: destination)
            } catch { self.errorMessage = "无法准备移动：\(error.localizedDescription)" }
        }
    }

    func confirmArchive() {
        guard !fileOperationsBlockedByShare else { return }
        guard let plan = archivePlan, let store, let archiveCoordinator else { return }
        // The picker grants write access; never silently replace an existing root with a different folder.
        do {
            for source in Dictionary(grouping: plan.groups.flatMap { [$0.source] + ($0.destination.map { [$0] } ?? []) }, by: \.id).values.compactMap(\.first) {
                let panel = NSOpenPanel()
                panel.title = "授权移动来源中的照片：\(source.name)"
                panel.message = "请选择原来源目录：\(source.pathHint)"
                panel.canChooseDirectories = true; panel.canChooseFiles = false
                panel.directoryURL = URL(fileURLWithPath: source.pathHint)
                guard panel.runModal() == .OK, let url = panel.url else { return }
                let identity = try SourceIdentity.resolve(url)
                let expected = plan.groups.first(where: { $0.source.id == source.id })?.identity ?? plan.groups.first(where: { $0.destination?.id == source.id })?.destinationIdentity
                guard let expected, identity.matches(expected) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let bookmark = try BookmarkStore.makeBookmark(for: url)
                for i in archivePlan!.groups.indices where archivePlan!.groups[i].source.id == source.id {
                    archivePlan!.groups[i].source.bookmarkData = bookmark
                }
                for i in archivePlan!.groups.indices where archivePlan!.groups[i].destination?.id == source.id {
                    archivePlan!.groups[i].destination?.bookmarkData = bookmark
                }
            }
        } catch { errorMessage = "授权失败：\(error.localizedDescription)"; return }
        guard let authorized = archivePlan else { return }
        archivePlan = nil
        startOperation {
            self.isDeleting = true
            self.previewAsset = nil
            defer { self.isDeleting = false }
            do {
                for source in Dictionary(grouping: authorized.groups, by: { $0.source.id }).values.compactMap({ $0.first?.source }) {
                    try await store.upsertSource(source)
                }
                self.annotationUndoManager.removeAllActions()
                let report = try await archiveCoordinator.execute(authorized, backupURL: self.backupURL())
                self.statusText = report.summary
                if !report.warnings.isEmpty { self.errorMessage = report.summary }
                try await self.thumbnailProvider?.invalidate(assetIDs: Set(authorized.groups.flatMap(\.files).compactMap { $0.asset?.id }))
            } catch { self.errorMessage = "归档未完成：\(error.localizedDescription)" }
            self.archivePending = (try? await archiveCoordinator.hasPending()) ?? true
            await self.reloadAll()
        }
    }

    func resumeArchive(undo: Bool) {
        guard operationBlockReason(.files) == nil else { return }
        guard xmpPlan == nil, !isWorking, importPlan == nil, !isShowingImportReport, colorEditor == nil, !isPreviewTransitioning, colorBatchPlan == nil, colorExportPlan == nil, !isShowingColorPresets, !isShowingColorExport, archivePlan == nil, let archiveCoordinator else { return }
        let alert = NSAlert()
        alert.messageText = undo ? "撤销最近一次归档？" : "继续未完成的归档？"
        alert.informativeText = "会根据日志复核文件并移动，绝不覆盖。冲突将保留并报告。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: undo ? "撤销归档" : "继续归档")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        isWorking = true; isDeleting = true; previewAsset = nil
        operationTask = Task {
            do {
                let warnings = try await deletionCoordinator?.recover() ?? []
                guard warnings.isEmpty else { throw CocoaError(.fileLocking) }
                for source in try await archiveCoordinator.recoverySources() {
                    let panel = NSOpenPanel()
                    panel.title = "重新授权归档来源：\(source.name)"
                    panel.message = source.pathHint
                    panel.canChooseDirectories = true; panel.canChooseFiles = false
                    panel.directoryURL = URL(fileURLWithPath: source.pathHint)
                    guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
                    try await archiveCoordinator.authorize(url, sourceID: source.id)
                }
                let report = try await archiveCoordinator.resume(undo: undo)
                statusText = report.summary
                if !report.warnings.isEmpty { errorMessage = report.summary }
                try await thumbnailProvider?.clearDiskCache()
            } catch { errorMessage = "归档恢复失败：\(error.localizedDescription)" }
            archivePending = (try? await archiveCoordinator.hasPending()) ?? true
            await reloadAll()
            isWorking = false; isDeleting = false
        }
    }
}

@MainActor
final class VolumeMonitor: NSObject, ObservableObject {
    @Published private(set) var volumes: [URL] = []

    override init() {
        super.init()
        refresh()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(volumeChanged), name: NSWorkspace.didMountNotification, object: nil)
        center.addObserver(self, selector: #selector(volumeChanged), name: NSWorkspace.didUnmountNotification, object: nil)
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func volumeChanged() {
        refresh()
    }

    func refresh() {
        volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeIsRemovableKey, .volumeLocalizedNameKey],
            options: [.skipHiddenVolumes]
        )?.filter { url in
            (try? url.resourceValues(forKeys: [.volumeIsRemovableKey]).volumeIsRemovable) == true
        } ?? []
    }
}
