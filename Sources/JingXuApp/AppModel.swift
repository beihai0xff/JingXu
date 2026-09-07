@preconcurrency import AppKit
import Combine
import Foundation
import JingXuCore

enum SidebarDestination: Hashable {
    case smart(SmartCollection)
    case source(String)
    case album(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published var sources: [SourceRoot] = []
    @Published var albums: [Album] = []
    @Published var assets: [AssetListItem] = []
    @Published var sidebarSelection: SidebarDestination? = .smart(.all)
    @Published var selectedAssetID: String?
    @Published var searchText = ""
    @Published var minimumRating = 0
    @Published var flagFilter: AssetFlag?
    @Published var gridSize: CGFloat = 170
    @Published var isWorking = false
    @Published var statusText = "准备就绪"
    @Published var errorMessage: String?
    @Published var isShowingImport = false
    @Published var isShowingAlbumCreator = false
    @Published var importProgress: ImportProgress?
    @Published var scanProgress: ScanProgress?
    @Published var analysisProgress: AnalysisProgress?
    @Published var deletionPlan: DeletionPlan?
    @Published var isDeleting = false
    @Published var sourceMergePlan: SourceMergePlan?
    private let histogramProvider = HistogramProvider()
    private var deletionCoordinator: DeletionCoordinator?
    @Published var previewAsset: AssetListItem?
    private var previewNavigation = PreviewNavigation(photoIDs: [])

    let volumeMonitor = VolumeMonitor()

    private var store: CatalogStore?
    private var scanner: DefaultSourceScanner?
    private var importer: ImportCoordinator?
    private var analysisCoordinator: AnalysisCoordinator?
    private var thumbnailProvider: DefaultThumbnailProvider?
    private var xmpExporter: DefaultXMPExporter?
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
            self.deletionCoordinator = DeletionCoordinator(store: store, journalURL: try JingXuPaths.databaseURL().deletingLastPathComponent().appendingPathComponent("deletions.json"))
            self.scanner = scanner
            self.importer = ImportCoordinator(repository: store, scanner: scanner)
            self.analysisCoordinator = AnalysisCoordinator(repository: store)
            self.thumbnailProvider = try DefaultThumbnailProvider(cacheDirectory: JingXuPaths.thumbnailCache())
            self.xmpExporter = DefaultXMPExporter(repository: store)
        } catch {
            store = nil
            scanner = nil
            importer = nil
            analysisCoordinator = nil
            thumbnailProvider = nil
            xmpExporter = nil
            deletionCoordinator = nil
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
                    if !pendingIDs.isEmpty { try thumbnailProvider?.invalidate(assetIDs: pendingIDs) }
                }
                let warnings = try await deletionCoordinator?.recover() ?? []
                if !warnings.isEmpty { errorMessage = warnings.joined(separator: "\n") }
            } catch { errorMessage = "恢复删除记录失败：\(error.localizedDescription)" }
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
        alert.informativeText = "\(backup.path)\n备份之后的图库变更会回退。当前数据库及日志会先保全，原照片不会修改。恢复完成后本版本将重新检查并迁移图库；如需回退程序版本，请退出后使用匹配版本。"
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
        do {
            async let loadedSources = store.sources()
            async let loadedAlbums = store.albums()
            sources = try await loadedSources
            albums = try await loadedAlbums
            await reloadAssets()
        } catch {
            errorMessage = "读取图库失败：\(error.localizedDescription)"
        }
    }

    func reloadAssets() async {
        guard let store else { return }
        let query = currentQuery()
        do {
            assets = try await store.assets(query)
            previewNavigation.refresh(photoIDs: assets.filter { $0.kind == .photo }.map(\.id))
            if let id = previewAsset?.id, let refreshed = assets.first(where: { $0.id == id }) {
                previewAsset = refreshed
                self.selectedAssetID = id
            }
            if let selectedAssetID, !assets.contains(where: { $0.id == selectedAssetID }) {
                self.selectedAssetID = nil
            }
            statusText = "显示 \(assets.count) 项"
        } catch { errorMessage = "载入照片失败：\(error.localizedDescription)" }
    }

    private func currentQuery() -> AssetQuery {
        var query = AssetQuery(
            searchText: searchText,
            minimumRating: minimumRating,
            flag: flagFilter,
            limit: 2_000
        )
        switch sidebarSelection {
        case .smart(let collection): query.collection = collection
        case .source(let id): query.sourceID = id
        case .album(let id): query.albumID = id
        case nil: break
        }
        return query
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
        closePreview()
        startOperation {
            self.isDeleting = true
            defer { self.isDeleting = false }
            do {
                let report = try await deletionCoordinator.execute(plan) { done, total in
                    await MainActor.run { self.statusText = "正在移到废纸篓 \(done)/\(total)" }
                }
                try self.thumbnailProvider?.invalidate(assetIDs: Set(plan.files.map(\.id)))
                await self.reloadAll()
                self.errorMessage = "成功 \(report.deleted)，跳过 \(report.skipped)，失败 \(report.failures.count)\(report.cancelled ? "；已取消后续项目" : "")\n" + (report.failures + report.skipReasons).prefix(30).joined(separator: "\n")
            } catch {
                try? self.thumbnailProvider?.invalidate(assetIDs: Set(plan.files.map(\.id)))
                await self.reloadAll()
                self.errorMessage = "清理未完成：\(error.localizedDescription)"
            }
        }
    }

    func openPreview(_ item: AssetListItem) {
        guard item.kind == .photo, !isDeleting else { return }
        selectAsset(item)
        previewNavigation = PreviewNavigation(photoIDs: assets.filter { $0.kind == .photo }.map(\.id))
        previewAsset = item
    }
    func selectAsset(_ item: AssetListItem) {
        selectedAssetID = item.id
        // A non-focusable SwiftUI grid cell otherwise leaves the search field editing.
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
    func closePreview() {
        previewAsset = nil
        previewNavigation = PreviewNavigation(photoIDs: [])
    }
    var previewNavigationEnabled: Bool {
        previewAsset != nil && !isDeleting && !isShowingImport && !isShowingAlbumCreator &&
        deletionPlan == nil && sourceMergePlan == nil && errorMessage == nil
    }
    func canNavigatePreview(_ direction: Int) -> Bool {
        guard previewNavigationEnabled, let id = previewAsset?.id else { return false }
        return previewNavigation.neighbor(of: id, direction: direction) != nil
    }
    func navigatePreview(_ direction: Int) {
        guard previewNavigationEnabled, let current = previewAsset?.id,
              let id = previewNavigation.neighbor(of: current, direction: direction),
              let item = assets.first(where: { $0.id == id && $0.kind == .photo }) else { return }
        selectAsset(item)
        previewAsset = item
    }
    func flagFromMenu(_ flag: AssetFlag) {
        guard NSApp.modalWindow == nil, NSApp.keyWindow?.attachedSheet == nil,
              !isShowingImport, !isShowingAlbumCreator else { return }
        guard NSApp.keyWindow?.title == "镜序" else { return }
        if let id = previewAsset?.id { updateFlag(flag, assetID: id) }
        else { updateFlag(flag) }
    }
    func loadOriginal(_ item: AssetListItem) async throws -> PreviewImage {
        guard let store, let asset = try await store.asset(id: item.id),
              let source = try await store.source(id: asset.sourceID) else { throw CocoaError(.fileNoSuchFile) }
        let root = try BookmarkStore.resolve(source).url
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        return try await ImagePreviewLoader().load(url: root.appendingPathComponent(asset.relativePath))
    }

    func histogram(for item: AssetListItem) async throws -> HistogramResult {
        guard let store, let asset = try await store.asset(id: item.id),
              let source = try await store.source(id: asset.sourceID) else { throw CocoaError(.fileReadNoSuchFile) }
        let root = try BookmarkStore.resolve(source).url
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        return try await histogramProvider.histogram(asset: asset, url: root.appendingPathComponent(asset.relativePath))
    }

    var hasUserFilters: Bool { !searchText.isEmpty || minimumRating > 0 || flagFilter != nil }
    func clearFilters() {
        searchText = ""; minimumRating = 0; flagFilter = nil
        Task { await reloadAssets() }
    }

    private func checkDeletionRecovery() async throws {
        let warnings = try await deletionCoordinator?.recover() ?? []
        if !warnings.isEmpty { throw NSError(domain: "JingXu", code: 3, userInfo: [NSLocalizedDescriptionKey: warnings.joined(separator: "\n")]) }
    }
    private func backupURL() throws -> URL {
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
                alert.informativeText = "\(source.pathHint)\n共 \(count) 项索引。将清理该来源的索引、评分、标签及相册成员关系，不删除硬盘照片。执行前会备份图库。"
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移除来源")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
                try await self.checkDeletionRecovery()
                self.closePreview()
                let ids = try await store.removeSource(id: source.id, backupURL: self.backupURL())
                try self.thumbnailProvider?.invalidate(assetIDs: ids)
                if self.sidebarSelection == .source(source.id) { self.sidebarSelection = .smart(.all) }
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
                try await store.deleteAlbum(id: album.id)
                if self.sidebarSelection == .album(album.id) { self.sidebarSelection = .smart(.all) }
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
                self.closePreview()
                let report = try await store.mergeSources(plan, backupURL: self.backupURL())
                try self.thumbnailProvider?.invalidate(assetIDs: report.invalidatedIDs)
                self.sidebarSelection = .smart(.all)
                await self.reloadAll()
                self.errorMessage = "已合并 \(report.mergedGroups) 组来源。原文件未改动。\n" + report.skipped.joined(separator: "\n")
            } catch { self.errorMessage = "合并失败：\(error.localizedDescription)"; await self.reloadAll() }
        }
    }

    func chooseAndAddFolder() {
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
        guard let store, let scanner, let analysisCoordinator else { return }
        startOperation {
            do {
                let source = try await store.registerSource(at: url)
                let report = try await scanner.scan(source: source) { [weak self] progress in
                    await MainActor.run {
                        self?.scanProgress = progress
                        self?.statusText = "正在索引 \(progress.processed)/\(progress.discovered)：\(progress.currentFile)"
                    }
                }
                await MainActor.run { self.scanProgress = nil }
                try await analysisCoordinator.analyzePending(sourceID: report.sourceID) { [weak self] progress in
                    await MainActor.run {
                        self?.analysisProgress = progress
                        self?.statusText = "正在分析 \(progress.completed)/\(progress.total)：\(progress.currentFile)"
                    }
                }
                await MainActor.run { self.analysisProgress = nil }
                await self.reloadAll()
            } catch is CancellationError {
                await MainActor.run { self.statusText = "操作已取消" }
            } catch {
                await MainActor.run { self.errorMessage = "索引失败：\(error.localizedDescription)" }
            }
        }
    }

    func importMedia(from source: URL, to destination: URL, batchName: String) {
        guard let importer, let analysisCoordinator else { return }
        isShowingImport = false
        startOperation {
            do {
                let report = try await importer.importMedia(from: source, to: destination, batchName: batchName) { [weak self] progress in
                    await MainActor.run {
                        self?.importProgress = progress
                        self?.statusText = "正在导入 \(progress.completedFiles + progress.skippedFiles)/\(progress.totalFiles)：\(progress.currentFile)"
                    }
                }
                await MainActor.run { self.importProgress = nil }
                if let sourceID = report.scanReport?.sourceID {
                    try await analysisCoordinator.analyzePending(sourceID: sourceID) { [weak self] progress in
                        await MainActor.run {
                            self?.analysisProgress = progress
                            self?.statusText = "正在分析 \(progress.completed)/\(progress.total)：\(progress.currentFile)"
                        }
                    }
                }
                await MainActor.run { self.analysisProgress = nil }
                await self.reloadAll()
            } catch is CancellationError {
                await MainActor.run { self.statusText = "导入已取消，已复制的文件保持完整" }
            } catch {
                await MainActor.run { self.errorMessage = "导入失败：\(error.localizedDescription)" }
            }
        }
    }

    func rescanSelectedSource() {
        guard case .source(let sourceID) = sidebarSelection,
              let source = sources.first(where: { $0.id == sourceID }) else {
            statusText = "请先在侧栏选择一个来源"
            return
        }
        addFolderFromExistingSource(source)
    }

    private func addFolderFromExistingSource(_ source: SourceRoot) {
        guard let scanner, let analysisCoordinator else { return }
        startOperation {
            do {
                let report = try await scanner.scan(source: source) { [weak self] progress in
                    await MainActor.run { self?.scanProgress = progress }
                }
                await MainActor.run { self.scanProgress = nil }
                try await analysisCoordinator.analyzePending(sourceID: report.sourceID) { [weak self] progress in
                    await MainActor.run { self?.analysisProgress = progress }
                }
                await MainActor.run { self.analysisProgress = nil }
                await self.reloadAll()
            } catch {
                await MainActor.run { self.errorMessage = "重新扫描失败：\(error.localizedDescription)" }
            }
        }
    }

    func cancelCurrentOperation() {
        operationTask?.cancel()
    }

    func updateRating(_ rating: Int) {
        guard !isDeleting else { return }
        guard let selectedAssetID, let store else { return }
        Task {
            do {
                var annotation = try await store.annotation(for: selectedAssetID)
                annotation.rating = rating
                try await store.saveAnnotation(annotation)
                await reloadAssets()
            } catch { errorMessage = "保存评分失败：\(error.localizedDescription)" }
        }
    }

    func updateFlag(_ flag: AssetFlag) {
        guard let selectedAssetID else { return }
        updateFlag(flag, assetID: selectedAssetID)
    }
    func updateFlag(_ flag: AssetFlag, assetID: String) {
        guard !isDeleting, sourceMergePlan == nil, deletionPlan == nil, let store else { return }
        Task {
            do {
                guard let asset = try await store.asset(id: assetID), asset.kind == .photo, !isDeleting else { return }
                var annotation = try await store.annotation(for: assetID)
                annotation.flag = flag
                try await store.saveAnnotation(annotation)
                await reloadAssets()
                statusText = "\(asset.fileName)：\(flag.displayName)"
            } catch { errorMessage = "保存旗标失败：\(error.localizedDescription)" }
        }
    }

    func updateKeywords(_ keywords: [String]) {
        guard !isDeleting else { return }
        guard let selectedAssetID, let store else { return }
        Task {
            do {
                var annotation = try await store.annotation(for: selectedAssetID)
                annotation.keywords = keywords
                try await store.saveAnnotation(annotation)
                await reloadAssets()
            } catch { errorMessage = "保存标签失败：\(error.localizedDescription)" }
        }
    }

    func resolveSuggestion(accepted: Bool) {
        guard !isDeleting else { return }
        guard let selectedAssetID, let store else { return }
        Task {
            do {
                if var analysis = try await store.analysis(for: selectedAssetID) {
                    analysis.suggestionState = accepted ? .accepted : .ignored
                    try await store.saveAnalysis(analysis)
                }
                if accepted {
                    var annotation = try await store.annotation(for: selectedAssetID)
                    annotation.flag = .rejected
                    try await store.saveAnnotation(annotation)
                }
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
                sidebarSelection = .album(album.id)
                await reloadAssets()
            } catch { errorMessage = "创建相册失败：\(error.localizedDescription)" }
        }
    }

    func addSelectedAsset(to album: Album) {
        guard let selectedAssetID, let store else { return }
        Task {
            do {
                try await store.add(assetID: selectedAssetID, toAlbum: album.id)
                statusText = "已添加到“\(album.name)”"
            } catch { errorMessage = "添加到相册失败：\(error.localizedDescription)" }
        }
    }

    func exportSelectedXMP() {
        guard let selectedAssetID, let xmpExporter else { return }
        Task {
            do {
                let report = try await xmpExporter.export(assetIDs: [selectedAssetID], conflictPolicy: .skip)
                if !report.skipped.isEmpty {
                    errorMessage = "XMP 已存在，未覆盖。可在检查器中确认替换。"
                } else if let failure = report.failed.values.first {
                    errorMessage = "XMP 导出失败：\(failure)"
                } else {
                    statusText = "XMP 已导出"
                }
            } catch { errorMessage = "XMP 导出失败：\(error.localizedDescription)" }
        }
    }

    func replaceSelectedXMP() {
        guard let selectedAssetID, let xmpExporter else { return }
        Task {
            do {
                let report = try await xmpExporter.export(assetIDs: [selectedAssetID], conflictPolicy: .replace)
                statusText = report.written.isEmpty ? "没有写入 XMP" : "XMP 已替换"
            } catch { errorMessage = "XMP 导出失败：\(error.localizedDescription)" }
        }
    }

    func thumbnail(for item: AssetListItem, pixelSize: Int) async -> NSImage? {
        guard let store, let thumbnailProvider,
              let asset = try? await store.asset(id: item.id),
              let source = try? await store.source(id: asset.sourceID) else { return nil }
        do {
            let root = try BookmarkStore.resolve(source).url
            let didAccess = root.startAccessingSecurityScopedResource()
            defer { if didAccess { root.stopAccessingSecurityScopedResource() } }
            let data = try await thumbnailProvider.thumbnailData(
                for: asset.id,
                url: root.appendingPathComponent(asset.relativePath),
                pixelSize: pixelSize,
                scale: NSScreen.main?.backingScaleFactor ?? 2
            )
            return NSImage(data: data)
        } catch {
            return nil
        }
    }

    func revealSelectedInFinder() {
        guard let selectedAssetID, let store else { return }
        Task {
            guard let asset = try? await store.asset(id: selectedAssetID),
                  let source = try? await store.source(id: asset.sourceID),
                  let root = try? BookmarkStore.resolve(source).url else { return }
            NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent(asset.relativePath)])
        }
    }

    func clearThumbnailCache() {
        do {
            try thumbnailProvider?.clearDiskCache()
            statusText = "缩略图缓存已清理，将按需重建"
        } catch { errorMessage = "清理缓存失败：\(error.localizedDescription)" }
    }

    private func startOperation(_ work: @escaping @MainActor @Sendable () async -> Void) {
        guard !isWorking, deletionPlan == nil, sourceMergePlan == nil else { return }
        isWorking = true
        operationTask = Task {
            do {
                try await checkDeletionRecovery()
                try Task.checkCancellation()
                await work()
            } catch { errorMessage = "后台操作未开始：\(error.localizedDescription)" }
            isWorking = false
            importProgress = nil
            scanProgress = nil
            analysisProgress = nil
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
