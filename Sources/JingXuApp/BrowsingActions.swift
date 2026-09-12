import AppKit
import JingXuCore

extension AppModel {
    var activeTaskSummary: String? {
        guard isWorking else { return nil }
        if let progress = importProgress { return "导入 \(progress.completedFiles + progress.skippedFiles)/\(progress.totalFiles)：\(progress.currentFile)" }
        if let progress = scanProgress { return "索引 \(progress.processed)/\(progress.discovered)：\(progress.currentFile)" }
        if let progress = analysisProgress { return "分析 \(progress.completed)/\(progress.total)：\(progress.currentFile)" }
        return statusText
    }
    func recordResult(_ value: String) {
        statusText = value
        if operationResults.first != value { operationResults.insert(value, at: 0); operationResults = Array(operationResults.prefix(20)) }
    }
    var browseSummary: String {
        let elsewhere = photoSelection.selectedIDs.subtracting(assets.map(\.id)).count
        return "本页 \(assets.count) 项 · 匹配 \(matchingAssetCount) 项 · 已选 \(selectedPhotoIDs.count) 张" + (elsewhere > 0 ? "（其他页 \(elsewhere) 张）" : "")
    }
    func currentQuery() -> BrowseQuery { appliedQuery }
    func draftQuery(destination: SidebarDestination? = nil, includeSubdirectories: Bool? = nil) -> BrowseQuery {
        var query = BrowseQuery(searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines), minimumRating: minimumRating, flag: flagFilter)
        query.includeSubdirectories = includeSubdirectories ?? self.includeSubdirectories
        switch destination ?? sidebarSelection {
        case .smart(let collection): query.collection = collection
        case .source(let id): query.sourceID = id; query.relativeDirectory = ""
        case .folder(let folder): query.sourceID = folder.sourceID; query.relativeDirectory = folder.relativeDirectory
        case .album(let id): query.albumID = id
        case nil: break
        }
        return query
    }
    func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            do { try await Task.sleep(for: .milliseconds(300)); try Task.checkCancellation() } catch { return }
            requestFilters()
        }
    }
    func requestFilters() {
        guard !isStarting, !automationOwnsOperation, canInteractWithLibrary, !isSavingAnnotation else { return }
        searchTask?.cancel()
        transitionPreview {
            self.pendingQuery = self.draftQuery()
            self.browseTask?.cancel()
            self.browseTask = Task { await self.reloadAssets() }
        }
    }
    func reloadAssets() async {
        let changedScope = pendingQuery != nil
        await loadBrowsePage(cursor: changedScope ? nil : assets.first.map(BrowseCursor.init), inclusive: !changedScope)
    }
    func loadBrowsePage(cursor: BrowseCursor? = nil, reverse: Bool = false, inclusive: Bool = false) async {
        guard let store else { return }
        let query = pendingQuery ?? appliedQuery
        let destination = pendingDestination
        let changesQuery = query != appliedQuery || destination != nil
        let request = UUID(); assetRequestID = request
        isLoadingAssets = true; browseError = nil; retryBrowseAction = nil
        defer { if assetRequestID == request { isLoadingAssets = false } }
        do {
            let page = try await store.browsePage(query, cursor: cursor, reverse: reverse, inclusive: inclusive, count: true)
            let selected = changesQuery ? [] : selectedPhotoIDs
            let valid = try await store.assetListItems(ids: selected, matching: query)
            let previousPreview = previewAsset?.id
            let previousReference = comparisonReference?.id
            let targets = [previousPreview, previousReference].compactMap { $0 }
            let refreshed = try await store.assetListItems(ids: targets)
            guard assetRequestID == request, !Task.isCancelled else { return }
            appliedQuery = query; pendingQuery = nil; pendingDestination = nil
            if let destination { sidebarSelection = destination }
            includeSubdirectories = query.includeSubdirectories
            persistBrowsePreference()
            if changesQuery {
                photoSelection.clear(); previewAsset = nil; comparisonReference = nil; clearComparisonPrefetch(); previewItems = []
                automationSelectionToken = UUID()
            } else {
                photoSelection.retain(validIDs: Set(valid.filter { $0.kind == .photo }.map(\.id)))
                if previewAsset?.id == previousPreview { previewAsset = refreshed.first { $0.id == previousPreview } }
                if comparisonReference?.id == previousReference { comparisonReference = refreshed.first { $0.id == previousReference } }
                if comparisonReference == nil { clearComparisonPrefetch() }
            }
            let changedCount = matchingAssetCount != (page.total ?? 0)
            resultsChanged = !changesQuery && (resultsChanged || (isWorking && cursor != nil && changedCount))
            assets = page.items; matchingAssetCount = page.total ?? 0
            hasPreviousPage = page.hasPrevious; hasNextPage = page.hasNext
            if let anchor = cursor, assets.contains(where: { $0.id == anchor.id }), previewAsset == nil { selectedAssetID = anchor.id }
            if previewAsset != nil { await refreshPreviewWindow() }
            guard assetRequestID == request, !Task.isCancelled else { return }
            syncKeywordDraft()
        } catch is CancellationError {} catch {
            guard assetRequestID == request else { return }
            pendingQuery = nil; pendingDestination = nil
            browseError = "结果更新失败，仍显示上次成功的范围：\(error.localizedDescription)"
            retryBrowseAction = { [weak self] in
                guard let self else { return }
                self.pendingQuery = query; self.pendingDestination = destination
                self.browseTask = Task { await self.loadBrowsePage(cursor: cursor, reverse: reverse, inclusive: inclusive) }
            }
        }
    }
    func retryBrowse() {
        guard canChangeBrowseScope else { return }
        transitionPreview {
            if let retry = self.retryBrowseAction { retry() }
            else { self.browseTask = Task { await self.reloadAssets() } }
        }
    }
    func turnPage(_ direction: Int) {
        guard canChangeBrowseScope else { return }
        transitionPreview {
            let cursor = (direction < 0 ? self.assets.first : self.assets.last).map(BrowseCursor.init)
            self.browseTask?.cancel()
            self.browseTask = Task { await self.loadBrowsePage(cursor: cursor, reverse: direction < 0) }
        }
    }
    func refreshPreviewWindow() async {
        guard let item = previewAsset, let store else { return }
        let query = appliedQuery
        do {
            async let left = store.browsePage(query, cursor: BrowseCursor(item), reverse: true, photosOnly: true, limit: 40)
            async let right = store.browsePage(query, cursor: BrowseCursor(item), photosOnly: true, limit: 40)
            let (before, after) = try await (left, right)
            guard previewAsset?.id == item.id, appliedQuery == query else { return }
            previewItems = before.items + [item] + after.items
            previewHasPrevious = before.hasPrevious; previewHasNext = after.hasNext
            syncKeywordDraft()
        } catch { if previewAsset?.id == item.id { browseError = "胶片栏更新失败：\(error.localizedDescription)" } }
    }
    func refreshChangedAssets(ids: [String], membershipChanged: Bool = false) async {
        guard let store else { return }
        do {
            let rows = try await store.assetListItems(ids: ids)
            let items = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            assets = assets.map { items[$0.id] ?? $0 }
            previewItems = previewItems.map { items[$0.id] ?? $0 }
            if let id = previewAsset?.id { previewAsset = items[id] ?? previewAsset }
            if let id = comparisonReference?.id { comparisonReference = items[id] ?? comparisonReference }
            if membershipChanged { await reloadAssets() }
        } catch { errorMessage = "标注已保存，但界面刷新失败：\(error.localizedDescription)" }
    }
    func refreshAnalysisResults() async {
        await refreshChangedAssets(ids: Array(Set(assets.map(\.id) + previewItems.map(\.id))), membershipChanged: appliedQuery.collection == .review)
    }
    func resolveColorTargets() async throws -> [AssetListItem] {
        guard let store else { throw ColorEditError("图库未打开") }
        let token = automationSelectionToken, ids = colorTargetIDs
        let rows = try await store.assetListItems(ids: ids)
        guard token == automationSelectionToken, rows.count == ids.count, rows.allSatisfy({ $0.kind == .photo }) else { throw ColorEditError("选择或照片已变化，请重新选择") }
        return rows
    }
}
