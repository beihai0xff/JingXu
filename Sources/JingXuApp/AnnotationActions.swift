import AppKit
import JingXuCore

@MainActor final class AnnotationUndoEntry {
    var change: AnnotationChangeSet
    let title: String
    init(_ change: AnnotationChangeSet, title: String) { self.change = change; self.title = title }
}

extension AppModel {
    var annotationTargetIDs: [String] { previewAsset.map { [$0.id] } ?? selectedPhotoIDs }
    func syncKeywordDraft() {
        let item = previewAsset ?? selectedAsset
        guard keywordDraft == keywordSaved else { return }
        keywordTargetID = item?.id
        keywordSaved = item?.keywords.joined(separator: ", ") ?? ""
        keywordDraft = keywordSaved
    }
    func flushKeywords() async -> Bool {
        if let task = keywordSaveTask { return await task.value }
        guard keywordDraft != keywordSaved else { return true }
        guard !isSavingAnnotation else { return false }
        isSavingAnnotation = true
        let task = Task {
            while self.keywordDraft != self.keywordSaved {
                guard await self.saveKeywordDraft() else { return false }
            }
            return true
        }
        keywordSaveTask = task
        let result = await task.value
        keywordSaveTask = nil; isSavingAnnotation = false
        return result
    }
    private func saveKeywordDraft() async -> Bool {
        guard keywordDraft != keywordSaved else { return true }
        guard let id = keywordTargetID else { errorMessage = "关键词草稿没有对应照片，草稿已保留"; return false }
        guard let store else { return false }
        let draft = keywordDraft
        do {
            let set = try await store.applyAnnotations(ids: [id], patch: .init(keywords: .replace(KeywordEdit.parse(draft))))
            recordAnnotationUndo(set, title: "修改关键词")
            if keywordTargetID == id { keywordSaved = draft }
            await refreshChangedAssets(ids: [id], membershipChanged: !appliedQuery.searchText.isEmpty)
            return true
        } catch { errorMessage = "关键词保存失败，草稿已保留：\(error.localizedDescription)"; return false }
    }
    func updateKeywords(_ keywords: [String]) {
        applyAnnotation(.init(keywords: .replace(keywords)), title: "替换关键词")
    }
    func updateRating(_ rating: Int, advanceToNext: Bool = false) {
        applyAnnotation(.init(rating: rating), title: "设置评分", advance: advanceToNext)
    }
    func updateFlag(_ flag: AssetFlag, advanceToNext: Bool = false) {
        guard colorEditor == nil else { return }
        applyAnnotation(.init(flag: flag), title: flag.displayName, advance: advanceToNext)
    }
    func updateFlag(_ flag: AssetFlag, assetID: String, advanceToNext: Bool = false) {
        guard colorEditor == nil else { return }
        applyAnnotation(.init(flag: flag), title: flag.displayName, ids: [assetID], advance: advanceToNext)
    }
    func applyAnnotation(_ patch: AnnotationPatch, title: String, ids: [String]? = nil, advance: Bool = false) {
        guard operationBlockReason(.annotation) == nil, let store else { return }
        let targets = ids ?? annotationTargetIDs
        guard !targets.isEmpty, !advance || targets.count == 1 else { return }
        if keywordDraft != keywordSaved || (advance && colorEditor != nil) {
            transitionPreview { self.applyAnnotation(patch, title: title, ids: targets, advance: advance) }
            return
        }
        let anchor = previewAsset ?? selectedAsset
        let query = appliedQuery
        isSavingAnnotation = true
        Task {
            defer { isSavingAnnotation = false; objectWillChange.send() }
            var committed = false
            do {
                let set = try await store.applyAnnotations(ids: targets, patch: patch)
                committed = true
                recordAnnotationUndo(set, title: title)
                let membership = (patch.rating != nil && query.minimumRating > 0) ||
                    (patch.flag != nil && (query.flag != nil || query.collection == .rejected)) ||
                    (patch.keywords != nil && !query.searchText.isEmpty) || (patch.albumID != nil && query.albumID == patch.albumID)
                await refreshChangedAssets(ids: targets, membershipChanged: membership)
                recordResult("\(title)：\(targets.count) 张")
                if patch.keywords != nil, let id = keywordTargetID, targets.contains(id), let row = try await store.assetListItem(id: id) {
                    keywordSaved = row.keywords.joined(separator: ", "); keywordDraft = keywordSaved
                }
                guard advance, let anchor, appliedQuery == query else { return }
                let next = try await store.browsePage(query, cursor: BrowseCursor(anchor), photosOnly: true, limit: 2).items
                    .first { $0.id != comparisonReference?.id }
                if let next {
                    if previewAsset?.id == anchor.id { previewAsset = next; await refreshPreviewWindow() }
                    else if previewAsset == nil && (selectedAssetID == anchor.id || selectedAssetID == nil) {
                        if !assets.contains(where: { $0.id == next.id }) { await loadBrowsePage(cursor: BrowseCursor(next), inclusive: true) }
                        selectAsset(next)
                    }
                } else { statusText += "；已到当前范围末尾" }
            } catch {
                errorMessage = committed ? "\(title)已保存，但后续刷新或切图失败：\(error.localizedDescription)" :
                    "\(title)失败，未提交本次更改：\(error.localizedDescription)"
            }
        }
    }
    func recordAnnotationUndo(_ set: AnnotationChangeSet, title: String) {
        guard !set.changes.isEmpty else { return }
        let entry = AnnotationUndoEntry(set, title: title)
        annotationUndoManager.beginUndoGrouping()
        annotationUndoManager.registerUndo(withTarget: self) { target in target.invertAnnotation(entry) }
        annotationUndoManager.setActionName(title)
        annotationUndoManager.endUndoGrouping()
        objectWillChange.send()
    }
    private func invertAnnotation(_ entry: AnnotationUndoEntry) {
        guard let store, !isSavingAnnotation else { return }
        // Register synchronously while UndoManager is moving the group between stacks.
        annotationUndoManager.registerUndo(withTarget: self) { $0.invertAnnotation(entry) }
        annotationUndoManager.setActionName(entry.title)
        isSavingAnnotation = true
        undoTask = Task {
            defer { isSavingAnnotation = false; undoTask = nil; objectWillChange.send() }
            do {
                entry.change = try await store.invertAnnotations(entry.change)
                await refreshChangedAssets(ids: entry.change.ids, membershipChanged: hasUserFilters || appliedQuery.albumID != nil || appliedQuery.collection == .rejected)
                recordResult("已撤销／重做：\(entry.title)")
                syncKeywordDraft()
            } catch {
                annotationUndoManager.removeAllActions()
                errorMessage = "撤销未执行：\(error.localizedDescription)；已清除失效历史"
            }
        }
    }
    func performUndo(redo: Bool = false) {
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            if redo { editor.undoManager?.redo() } else { editor.undoManager?.undo() }
            return
        }
        guard !isSavingAnnotation, !isPreviewTransitioning, !automationOwnsOperation else { return }
        if let colorEditor { if redo { colorEditor.redo() } else { colorEditor.undo() }; return }
        guard operationBlockReason(.annotation) == nil else { return }
        if keywordDraft != keywordSaved { transitionPreview { self.performUndo(redo: redo) }; return }
        if redo { annotationUndoManager.redo() } else { annotationUndoManager.undo() }
    }
}
