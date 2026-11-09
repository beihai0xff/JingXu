import AppKit
import JingXuCore
import SwiftUI

extension AppModel {
    func updateGridColumns(_ value: Int) {
        let count = max(1, value)
        if gridColumns != count { gridColumns = count; gridLeadingCells = 0 }
    }
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
        let selected = photoSelection.selectedIDs
        let inWindow = loadedAssets.photoIDs.reduce(0) { $0 + (selected.contains($1) ? 1 : 0) }
        let elsewhere = selected.count - inWindow
        return "当前载入 \(assets.count) / 匹配 \(matchingAssetCount) 项" + (selected.isEmpty ? "" : " · 已选 \(selected.count) 张") + (elsewhere > 0 ? "（窗口外 \(elsewhere) 张）" : "")
    }
    func draftQuery(destination: SidebarDestination? = nil, includeSubdirectories: Bool? = nil) -> BrowseQuery {
        var query = BrowseQuery(searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines), minimumRating: minimumRating, flag: flagFilter, sortOrder: sortOrder)
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
        await loadBrowsePage(cursor: changedScope ? nil : assets.first.map(BrowseCursor.init), inclusive: !changedScope,
                             limit: changedScope ? 200 : min(600, max(200, assets.count)))
    }
    func loadBrowsePage(cursor: BrowseCursor? = nil, inclusive: Bool = false, containing: Bool = false, limit: Int = 200) async {
        guard let store else { return }
        loadMoreTask?.cancel(); loadMoreTask = nil; isLoadingMoreAssets = false
        let query = pendingQuery ?? appliedQuery
        let destination = pendingDestination
        let changesQuery = query != appliedQuery || destination != nil
        let request = UUID(); assetRequestID = request
        isLoadingAssets = true; browseError = nil; retryBrowseAction = nil
        defer { if assetRequestID == request { isLoadingAssets = false } }
        do {
            let page: BrowsePage
            if containing, let cursor {
                page = try await store.browsePageContaining(query, anchor: cursor, limit: limit)
            } else {
                page = try await store.browsePage(query, cursor: cursor, inclusive: inclusive, limit: limit, count: true)
            }
            let selected = changesQuery ? [] : Array(photoSelection.selectedIDs)
            let valid = try await store.matchingPhotoIDs(selected, matching: query)
            let previousPreview = previewAsset?.id
            let previousReference = comparisonReference?.id
            let previousFocus = selectedAssetID
            let targets = [previousPreview, previousReference, previousFocus].compactMap { $0 }
            let refreshed = try await store.assetListItems(ids: targets)
            guard assetRequestID == request, !Task.isCancelled else { return }
            appliedQuery = query; pendingQuery = nil; pendingDestination = nil
            if let destination { sidebarSelection = destination }
            includeSubdirectories = query.includeSubdirectories
            persistBrowsePreference()
            if changesQuery {
                photoSelection.clear(); focusedAsset = nil; previewAsset = nil; comparisonReference = nil; clearComparisonPrefetch(); previewItems = []
                gridLeadingCells = 0; gridJumpID = nil
                automationSelectionToken = UUID()
            } else {
                photoSelection.retain(validIDs: valid)
                if previewAsset?.id == previousPreview { previewAsset = refreshed.first { $0.id == previousPreview } }
                if comparisonReference?.id == previousReference { comparisonReference = refreshed.first { $0.id == previousReference } }
                if comparisonReference == nil { clearComparisonPrefetch() }
                focusedAsset = refreshed.first { $0.id == previousFocus }
            }
            let changedCount = matchingAssetCount != (page.total ?? 0)
            resultsChanged = !changesQuery && (resultsChanged || (isWorking && cursor != nil && changedCount))
            if containing { gridLeadingCells = 0 }
            if loadedAssets.replace(page.items) { automationSelectionToken = UUID() }
            matchingAssetCount = page.total ?? 0
            hasPreviousPage = page.hasPrevious; hasNextPage = page.hasNext
            if containing, let anchor = cursor, loadedAssets.contains(anchor.id), previewAsset == nil {
                selectedAssetID = anchor.id
                focusedAsset = assets[loadedAssets.index(of: anchor.id)!]
                gridJumpID = anchor.id; gridJumpRevision += 1
            }
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
                self.browseTask = Task { await self.loadBrowsePage(cursor: cursor, inclusive: inclusive, containing: containing, limit: limit) }
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
    func loadMoreAssets(before: Bool = false) {
        guard !isLoadingAssets, !isLoadingMoreAssets, pendingQuery == nil, previewAsset == nil,
              before ? hasPreviousPage : hasNextPage, let store,
              let cursor = (before ? assets.first : assets.last).map(BrowseCursor.init) else { return }
        let query = appliedQuery, request = assetRequestID
        isLoadingMoreAssets = true
        loadMoreTask = Task { [self] in
            defer { if assetRequestID == request { isLoadingMoreAssets = false; loadMoreTask = nil } }
            do {
                let page = try await store.browsePage(query, cursor: cursor, reverse: before)
                try Task.checkCancellation()
                guard assetRequestID == request, appliedQuery == query else { return }
                let focus = selectedAsset
                let oldCount = assets.count
                let fallback = before ? assets.first?.id : assets.last?.id
                let columns = max(1, gridColumns)
                let removed = withTransaction(Transaction(animation: nil)) {
                    loadedAssets.appendWindow(page.items, before: before, columns: columns)
                }
                let added = assets.count + removed - oldCount
                if before && added > 0 {
                    gridLeadingCells = (gridLeadingCells + columns - added % columns) % columns
                }
                if removed > 0 { gridTrimFallbackID = fallback; gridTrimRevision += 1 }
                if focusedAsset == nil { focusedAsset = focus }
                if before {
                    hasPreviousPage = page.hasPrevious
                    if removed > 0 { hasNextPage = true }
                } else {
                    hasNextPage = page.hasNext
                    if removed > 0 { hasPreviousPage = true }
                }
                matchingAssetCount = page.total ?? matchingAssetCount
                browseError = nil; retryBrowseAction = nil
            } catch is CancellationError {} catch {
                guard assetRequestID == request else { return }
                browseError = "载入更多照片失败，已载入照片和选择已保留：\(error.localizedDescription)"
                retryBrowseAction = { [weak self] in self?.loadMoreAssets(before: before) }
            }
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
        if membershipChanged { await reloadAssets(); return }
        let request = assetRequestID
        let changed = Set(ids)
        let targets = Set(loadedAssets.loadedIDs(in: changed))
            .union(previewItems.map(\.id).filter { changed.contains($0) })
            .union([previewAsset?.id, comparisonReference?.id, focusedAsset?.id].compactMap { $0 }.filter { changed.contains($0) })
        guard !targets.isEmpty else { return }
        do {
            let rows = try await store.assetListItems(ids: Array(targets))
            guard request == assetRequestID else { return }
            let items = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
            if loadedAssets.update(rows) { automationSelectionToken = UUID() }
            previewItems = previewItems.map { items[$0.id] ?? $0 }
            if let id = previewAsset?.id { previewAsset = items[id] ?? previewAsset }
            if let id = comparisonReference?.id { comparisonReference = items[id] ?? comparisonReference }
            if let id = focusedAsset?.id { focusedAsset = items[id] }
            if rows.count != targets.count { await reloadAssets() }
        } catch { errorMessage = "标注已保存，但界面刷新失败：\(error.localizedDescription)" }
    }
    func refreshAnalysisResults(ids: [String]) async {
        guard !ids.isEmpty else { return }
        await refreshChangedAssets(ids: ids, membershipChanged: appliedQuery.collection == .review || appliedQuery.similarGroupID != nil)
    }
    func resolveColorTargets() async throws -> [AssetListItem] {
        guard let store else { throw ColorEditError("图库未打开") }
        let token = automationSelectionToken, ids = colorTargetIDs
        let rows = try await store.assetListItems(ids: ids)
        guard token == automationSelectionToken, rows.count == ids.count, rows.allSatisfy({ $0.kind == .photo }) else { throw ColorEditError("选择或照片已变化，请重新选择") }
        return rows
    }
}
