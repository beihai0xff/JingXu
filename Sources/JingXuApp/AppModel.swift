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

    let volumeMonitor = VolumeMonitor()

    private var store: CatalogStore?
    private var scanner: DefaultSourceScanner?
    private var importer: ImportCoordinator?
    private var analysisCoordinator: AnalysisCoordinator?
    private var thumbnailProvider: DefaultThumbnailProvider?
    private var xmpExporter: DefaultXMPExporter?
    private var operationTask: Task<Void, Never>?

    var selectedAsset: AssetListItem? {
        assets.first { $0.id == selectedAssetID }
    }

    init() {
        do {
            let store = try CatalogStore(databaseURL: JingXuPaths.databaseURL())
            let scanner = DefaultSourceScanner(repository: store)
            self.store = store
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
            errorMessage = "初始化图库失败：\(error.localizedDescription)"
        }
        Task { await reloadAll() }
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
        do {
            assets = try await store.assets(query)
            if let selectedAssetID, !assets.contains(where: { $0.id == selectedAssetID }) {
                self.selectedAssetID = nil
            }
            statusText = "显示 \(assets.count) 项"
        } catch {
            errorMessage = "载入照片失败：\(error.localizedDescription)"
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
                let source = SourceRoot(
                    name: url.lastPathComponent,
                    bookmarkData: try? BookmarkStore.makeBookmark(for: url),
                    pathHint: url.path,
                    volumeIdentifier: FileIdentity.volumeIdentifier(for: url)
                )
                try await store.upsertSource(source)
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
        guard let selectedAssetID, let store else { return }
        Task {
            do {
                var annotation = try await store.annotation(for: selectedAssetID)
                annotation.flag = flag
                try await store.saveAnnotation(annotation)
                await reloadAssets()
            } catch { errorMessage = "保存旗标失败：\(error.localizedDescription)" }
        }
    }

    func updateKeywords(_ keywords: [String]) {
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
        operationTask?.cancel()
        isWorking = true
        operationTask = Task {
            await work()
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
