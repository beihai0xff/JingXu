import Foundation

/// Coalesces committed changes. Completion, failure and cancellation drain the buffer.
public actor BrowseRefreshGate {
    private var last = ContinuousClock.now
    private var pending = Set<String>()
    public init() {}
    public func ingest(_ progress: AnalysisProgress, now: ContinuousClock.Instant = .now) -> [String] {
        pending.formUnion(progress.changedAssetIDs)
        guard progress.isFinished || last.duration(to: now) >= .seconds(1) else { return [] }
        last = now
        let ids = Array(pending); pending.removeAll(keepingCapacity: true)
        return ids
    }
}
