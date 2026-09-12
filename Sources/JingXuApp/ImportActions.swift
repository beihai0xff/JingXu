import Foundation
import JingXuCore

extension AppModel {
    func prepareImport(from source: URL, to destination: URL, batchName: String) {
        guard let importer else { return }
        isShowingImport = false
        startOperation {
            self.statusText = "正在枚举、校验并准备导入清单…"
            do { self.importPlan = try await importer.prepare(from: source, to: destination, batchName: batchName) }
            catch is CancellationError { self.statusText = "预检已取消" }
            catch { self.errorMessage = "导入预检失败：\(error.localizedDescription)" }
        }
    }
    func retryImport() {
        guard let importer, let report = lastImportReport else { return }
        isShowingImportReport = false
        startOperation {
            self.statusText = "正在重新预检原导入范围…"
            do { self.importPlan = try await importer.prepareRetry(report) }
            catch is CancellationError { self.statusText = "预检已取消" }
            catch { self.errorMessage = "无法重新预检：\(error.localizedDescription)；可从导入入口重新选择目录。" }
        }
    }
    func confirmImport() {
        guard let importer, let plan = importPlan else { return }
        importPlan = nil
        startOperation {
            do {
                let report = try await importer.execute(plan) { [weak self] value in
                    await MainActor.run {
                        self?.importProgress = value
                        self?.statusText = "导入 \(value.completedFiles + value.skippedFiles)/\(value.totalFiles)：\(value.currentFile)"
                    }
                }
                self.lastImportReport = report; self.lastScanReport = report.scanReport; self.importProgress = nil
                await self.reloadAll()
                if report.outcome != .cancelled, let source = report.source {
                    try await self.analyzeNewAssets(sourceID: source.id)
                }
                self.statusText = report.outcome.rawValue
            } catch is CancellationError { self.statusText = "分析已取消，导入结果已保留" }
            catch {
                self.lastImportReport = try? await self.store?.latestImportReport()
                self.errorMessage = "导入或后续分析未完成：\(error.localizedDescription)"
            }
        }
    }
    func analyzeNewAssets(sourceID: String) async throws {
        guard let analysisCoordinator else { return }
        isAnalyzingNewAssets = true
        defer { isAnalyzingNewAssets = false; analysisProgress = nil }
        let refresh = BrowseRefreshGate()
        try await analysisCoordinator.analyzePending(sourceID: sourceID) { [weak self] value in
            await MainActor.run { self?.analysisProgress = value }
            if await refresh.shouldRefresh(completed: value.completed, total: value.total) {
                await self?.refreshAnalysisResults()
            }
            await MainActor.run { self?.statusText = "正在分析 \(value.completed)/\(value.total)：\(value.currentFile)" }
        }
        await reloadAssets()
    }
}
