import Foundation

public struct QualityReanalysisPlan: Identifiable, Sendable {
    public let id = UUID().uuidString
    public let title: String
    public let assetIDs: [String]
    public init(title: String, assetIDs: [String]) {
        self.title = title
        var seen = Set<String>()
        self.assetIDs = assetIDs.filter { seen.insert($0).inserted }
    }
}

public struct QualityJobPayload: Codable, Sendable {
    public var title: String
    public var backupPath: String
    public var backupSHA256: String
    public var total: Int
    public var algorithmVersion: Int = 2
}

public struct QualityJobSnapshot: Identifiable, Sendable {
    public var job: BackgroundJob
    public var total: Int
    public var completed: Int
    public var failed: Int
    public var id: String { job.id }
    public var isResumable: Bool { [.queued, .paused, .failed].contains(job.state) }
}

/// The app's operation gate excludes scanning/source/deletion work. This actor also excludes two runners.
public actor QualityReanalysisCoordinator {
    private let store: CatalogStore
    private let analyzer: AnalysisCoordinator
    private var activeJob: String?
    private var cancelRequested = false

    public init(store: CatalogStore, analyzer: AnalysisCoordinator? = nil) {
        self.store = store; self.analyzer = analyzer ?? AnalysisCoordinator(repository: store)
    }

    public func prepare(_ plan: QualityReanalysisPlan, backupDirectory: URL) async throws -> String {
        guard activeJob == nil else { throw CatalogUpgradeError.blocked("已有质量重算任务运行中") }
        cancelRequested = false
        guard !plan.assetIDs.isEmpty else { throw CocoaError(.validationMissingMandatoryProperty) }
        let backupURL = backupDirectory.appendingPathComponent("quality-v2-\(plan.id).sqlite")
        return try await store.createQualityJob(plan, backupURL: backupURL)
    }

    public func requestCancel() { cancelRequested = true }

    public func run(jobID: String, progress: AnalysisProgressHandler? = nil) async throws {
        guard activeJob == nil else { throw CatalogUpgradeError.blocked("已有质量重算任务运行中") }
        activeJob = jobID
        if !Task.isCancelled { cancelRequested = false }
        defer { activeJob = nil; cancelRequested = false }
        var eligible = false
        var completed = 0, total = 0
        do {
            guard let snapshot = try await store.qualityJobs().first(where: { $0.id == jobID }), snapshot.isResumable else {
                throw CatalogUpgradeError.blocked("任务不存在或已结束，不能继续")
            }
            eligible = true
            guard let payload = try? JSONDecoder().decode(QualityJobPayload.self, from: Data(snapshot.job.payloadJSON.utf8)),
                  payload.algorithmVersion == DefaultQualityAnalyzer.algorithmVersion,
                  try FileHasher.sha256(of: URL(fileURLWithPath: payload.backupPath)) == payload.backupSHA256
            else { throw CatalogUpgradeError.blocked("重算备份缺失、校验失败或任务版本不兼容，未开始") }
            try await store.setQualityJobState(jobID, state: .running)
            completed = snapshot.completed; total = snapshot.total
            while let next = try await store.nextQualityJobItem(jobID) {
                try Task.checkCancellation()
                if cancelRequested { throw CancellationError() }
                let name = try await store.asset(id: next.assetID)?.fileName ?? "已移除的照片"
                await progress?(AnalysisProgress(total: snapshot.total, completed: completed, currentFile: name))
                let finishedCount = completed, plannedCount = total
                let success = try await analyzer.analyzeOne(assetID: next.assetID) {
                    // Publish only committed writes, including when the queue receipt later fails.
                    await progress?(AnalysisProgress(total: plannedCount, completed: finishedCount, currentFile: name, changedAssetIDs: [next.assetID]))
                }
                let reason = success ? nil : (try await store.analysis(for: next.assetID)?.analysisError ?? "照片已移除或不可用")
                try await store.finishQualityJobItem(jobID, ordinal: next.ordinal, error: reason)
                completed += 1
            }
            try Task.checkCancellation()
            if cancelRequested { throw CancellationError() }
            // Grouping remains informational and does not rewrite quality results or user review.
            let ids = try await store.qualityJobAssetIDs(jobID)
            let finishedCount = completed, plannedCount = total
            try await analyzer.groupSimilarBursts(assetIDs: ids) { changed in
                await progress?(AnalysisProgress(total: plannedCount, completed: finishedCount, currentFile: "整理相似连拍", changedAssetIDs: changed))
            }
            try await store.setQualityJobState(jobID, state: .completed)
            await progress?(AnalysisProgress(total: total, completed: completed, currentFile: "", isFinished: true))
        } catch is CancellationError {
            await progress?(AnalysisProgress(total: total, completed: completed, currentFile: "", isFinished: true))
            if eligible { try await store.setQualityJobState(jobID, state: cancelRequested ? .cancelled : .paused) }
        } catch {
            await progress?(AnalysisProgress(total: total, completed: completed, currentFile: "", isFinished: true))
            if eligible { try await store.setQualityJobState(jobID, state: .failed, error: error.localizedDescription) }
            throw error
        }
    }
}
