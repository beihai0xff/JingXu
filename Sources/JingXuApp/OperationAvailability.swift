import AppKit

enum LibraryOperation { case browse, annotation, files, color }

extension AppModel {
    func operationBlockReason(_ operation: LibraryOperation) -> String? {
        if isStarting || startupFailure != nil { return "图库尚未打开" }
        if automationOwnsOperation { return "Codex 正在操作照片" }
        if isLoadingAssets { return "正在更新查询结果" }
        if isSavingAnnotation { return "正在保存标注" }
        if isPreparingSelection { return "正在读取所选照片" }
        if isPreviewTransitioning { return "正在保存并切换照片" }
        if isShowingPhotoShare || photoShareSession.blocksFileChanges { return "请先结束本次分享会话" }
        if isShowingKeywords || importPlan != nil || xmpPlan != nil || isShowingImportReport || isShowingImport || isShowingAlbumCreator ||
            archivePlan != nil || deletionPlan != nil || missingAssetPlan != nil || sourceMergePlan != nil ||
            qualityReanalysisPlan != nil || colorBatchPlan != nil || colorExportPlan != nil || isShowingColorExport || isShowingColorPresets {
            return "请先完成或关闭当前操作清单"
        }
        if isWorking && !(isAnalyzingNewAssets && (operation == .browse || operation == .annotation)) { return "请先完成当前后台任务" }
        if operation == .files && colorEditor != nil { return "请先完成调色" }
        if errorMessage != nil { return "请先处理当前提示" }
        return nil
    }
}
