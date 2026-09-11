import AppKit
import Combine
import Foundation
import JingXuCore

extension AppModel {
    var colorTargetIDs: [String] {
        if let item = previewAsset { return [item.id] }
        if isBatchSelecting { return assets.filter { batchSelection.contains($0.id) && $0.kind == .photo }.map(\.id) }
        return selectedAsset.map { $0.kind == .photo ? [$0.id] : [] } ?? []
    }
    var canStartColorAction: Bool {
        !isWorking && !isPreviewTransitioning && colorBatchPlan == nil && colorExportPlan == nil &&
        archivePlan == nil && deletionPlan == nil && missingAssetPlan == nil && sourceMergePlan == nil && qualityReanalysisPlan == nil &&
        !isShowingImport && !isShowingAlbumCreator && !isShowingColorExport
    }
    func beginColorEditing() {
        guard colorEditor == nil, canStartColorAction, let item = previewAsset, let store else { return }
        startOperation {
            do {
                let snapshot = try await store.colorSnapshot(assetID: item.id)
                let session = try self.makeColorSession(snapshot)
                self.attachColorSession(session)
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
    /// Navigation remains synchronous for browsing, but editing must drain pending writes first.
    func transitionPreview(_ action: @escaping @MainActor () -> Void) {
        guard !isPreviewTransitioning, !automationOwnsOperation else { return }
        guard let editor = colorEditor else { action(); return }
        isPreviewTransitioning = true
        Task {
            guard await editor.flush() else { isPreviewTransitioning = false; return }
            editor.dispose(); colorEditor = nil; colorEditorObservation = nil
            action()
            isPreviewTransitioning = false
        }
    }
    func finishColorEditing() { transitionPreview {} }
    func makeColorSession(_ snapshot: ColorEditSnapshot) throws -> ColorEditSession {
        guard let store else { throw ColorEditError("图库未打开") }
        return try ColorEditSession(store: store, snapshot: snapshot) { [weak self] in await self?.reloadAssets() }
    }
    func attachColorSession(_ session: ColorEditSession) {
        colorEditor = session
        colorEditorObservation = session.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        session.start()
    }
    func discardStaleColor() {
        guard let editor = colorEditor, let store, !editor.isSaving, !isPreviewTransitioning else { return }
        let alert = NSAlert()
        alert.messageText = "放弃此照片的旧调整？"
        alert.informativeText = "请先重新扫描来源。将备份图库并清除当前照片的旧调色记录，原片保持不变。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "备份并重新开始")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        isPreviewTransitioning = true
        Task {
            defer { isPreviewTransitioning = false }
            do {
                try await checkDeletionRecovery()
                try await store.backup(to: backupURL())
                _ = try await store.discardStaleColorAdjustments(assetID: editor.snapshot.asset.id)
                editor.dispose(); colorEditor = nil; colorEditorObservation = nil
                await reloadAssets()
                isPreviewTransitioning = false
                beginColorEditing()
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func copyColorAdjustments() {
        guard canStartColorAction else { return }
        if let colorEditor { copiedColorPatch = ColorPatch(colorEditor.adjustments); statusText = "已复制调色参数"; return }
        guard let id = colorTargetIDs.first, let store else { return }
        Task {
            do { copiedColorPatch = ColorPatch(try await store.colorSnapshot(assetID: id).adjustments); statusText = "已复制调色参数" }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func showColorPresets() {
        guard canStartColorAction, !colorTargetIDs.isEmpty else { return }
        Task {
            do { try await checkDeletionRecovery(); colorPresets = try await store?.colorPresets() ?? []; isShowingColorPresets = true }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func saveColorPreset(name: String, patch: ColorPatch, id: String = UUID().uuidString) async throws {
        guard let store, canStartColorAction else { throw ColorEditError("当前有其他操作，无法保存预设") }
        try await checkDeletionRecovery()
        try await store.saveColorPreset(ColorPreset(id: id, name: name, patch: patch))
        colorPresets = try await store.colorPresets()
    }
    func deleteColorPreset(_ preset: ColorPreset) async throws {
        guard let store, canStartColorAction else { throw ColorEditError("当前有其他操作，无法删除预设") }
        try await checkDeletionRecovery(); try await store.deleteColorPreset(id: preset.id)
        colorPresets = try await store.colorPresets()
    }
    func previewColorPatch(_ patch: ColorPatch, groups: Set<ColorGroup>) async throws -> ColorRenderedImage {
        guard let store, let id = colorTargetIDs.first else { throw ColorEditError("请选择一张照片用于试用预览") }
        let snapshot = try await store.colorSnapshot(assetID: id)
        let original = try colorEditor?.adjustments ?? snapshot.adjustments
        let values = try patch.applying(to: original, groups: groups, isRAW: snapshot.isRAW)
        return try await ColorImageRenderer.shared.render(snapshot, adjustments: values, maximumDimension: 1024)
    }
    func applyColorPatch(_ patch: ColorPatch, groups: Set<ColorGroup>) {
        guard canStartColorAction, let store else { return }
        if let editor = colorEditor {
            do { editor.apply(try patch.applying(to: editor.adjustments, groups: groups, isRAW: editor.isRAW)); isShowingColorPresets = false }
            catch { errorMessage = error.localizedDescription }
            return
        }
        let ids = colorTargetIDs
        isShowingColorPresets = false
        startOperation {
            do { self.colorBatchPlan = try await store.prepareColorBatch(assetIDs: ids, patch: patch, groups: groups) }
            catch { self.errorMessage = error.localizedDescription }
        }
    }
    func confirmColorBatch(_ plan: ColorBatchPlan) {
        colorBatchPlan = nil
        guard let store else { return }
        startOperation {
            do {
                self.colorUndoPlan = try await store.applyColorBatch(plan, backupURL: self.backupURL())
                await self.reloadAssets(); self.statusText = "已对 \(plan.items.count) 张照片应用调色"
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
    func undoColorBatch() {
        guard let plan = colorUndoPlan, let store else { return }
        startOperation {
            do {
                _ = try await store.applyColorBatch(plan, backupURL: self.backupURL())
                self.colorUndoPlan = nil; await self.reloadAssets(); self.statusText = "已撤销批量调色"
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
    func showColorExport() {
        guard canStartColorAction, !colorTargetIDs.isEmpty else { return }
        transitionPreview { self.isShowingColorExport = true }
    }
    func prepareColorExport(format: ColorExportFormat) {
        guard let coordinator = colorExportCoordinator else { return }
        let panel = NSOpenPanel()
        panel.title = "选择成片导出目录"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        let ids = colorTargetIDs
        isShowingColorExport = false
        startOperation {
            do { self.colorExportPlan = try await coordinator.prepare(assetIDs: ids, directory: directory, format: format) }
            catch { self.errorMessage = error.localizedDescription }
        }
    }
    func confirmColorExport(_ plan: ColorExportPlan) {
        colorExportPlan = nil
        guard let coordinator = colorExportCoordinator else { return }
        startOperation {
            do {
                let report = try await coordinator.execute(plan) { done, total in
                    await MainActor.run { self.statusText = "正在导出成片 \(done)/\(total)" }
                }
                self.statusText = "已导出 \(report.written.count) 张成片"
                self.errorMessage = "成功 \(report.written.count)，跳过 \(report.skipped.count)，失败 \(report.failed.count)\(report.cancelled ? "；已取消后续导出" : "")\n" + (report.skipped + report.failed).joined(separator: "\n")
            } catch { self.errorMessage = error.localizedDescription }
        }
    }
}
