import Foundation

/// A monotonic gate shared by progress callbacks; completed work always gets its final refresh.
public actor BrowseRefreshGate {
    private var last = ContinuousClock.now
    public init() {}
    public func shouldRefresh(completed: Int, total: Int, now: ContinuousClock.Instant = .now) -> Bool {
        guard completed == total || last.duration(to: now) >= .seconds(1) else { return false }
        last = now; return true
    }
}
