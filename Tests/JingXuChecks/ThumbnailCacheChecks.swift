import Foundation
import JingXuCore

enum ThumbnailCacheChecks {
    static func run() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("source.jpg")
        try Data("source".utf8).write(to: original)
        let fp = try AnalysisFingerprint(url: original)
        let cache = ThumbnailCache(directory: root.appendingPathComponent("cache"), maximumBytes: 100, trimBytes: 60)
        let first = ThumbnailCache.Key(assetID: "photo", kind: "color", revision: 1, fingerprint: fp, pixelSize: 256)
        let second = ThumbnailCache.Key(assetID: "photo", kind: "color", revision: 2, fingerprint: fp, pixelSize: 256)
        let (old, _) = await cache.lookup(first)
        try await cache.invalidate(assetIDs: ["photo"])
        await cache.store(Data(repeating: 1, count: 40), for: first, ticket: old)
        try ColorChecks.check(await cache.lookup(first).1 == nil, "失效前请求重新填回缓存")
        let (fresh, _) = await cache.lookup(first)
        await cache.store(Data(repeating: 1, count: 40), for: first, ticket: fresh)
        let (newer, _) = await cache.lookup(second)
        await cache.store(Data(repeating: 2, count: 40), for: second, ticket: newer)
        await cache.store(Data(repeating: 1, count: 40), for: first, ticket: fresh)
        let previous = await cache.lookup(first).1, current = await cache.lookup(second).1
        try ColorChecks.check(previous == nil && current != nil, "旧修订复活或新修订被删除")
        let reopened = ThumbnailCache(directory: root.appendingPathComponent("cache"), maximumBytes: 100, trimBytes: 60)
        let reopenedData = await reopened.lookup(second).1, reopenedSize = await reopened.diskBytes
        try ColorChecks.check(reopenedData?.count == 40 && reopenedSize == 40, "重启后缓存索引不一致")
        let (staleAfterRestart, _) = await reopened.lookup(first)
        await reopened.store(Data(repeating: 1, count: 40), for: first, ticket: staleAfterRestart)
        try ColorChecks.check(await reopened.lookup(first).1 == nil, "重启后旧修订复活")
        let third = ThumbnailCache.Key(assetID: "other", kind: "original", fingerprint: fp, pixelSize: 512)
        let (ticket, _) = await cache.lookup(third)
        await cache.store(Data(repeating: 3, count: 70), for: third, ticket: ticket)
        try ColorChecks.check(await cache.diskBytes <= 60, "缓存未回收至低水位")
        try await cache.clear()
        await cache.store(Data([1]), for: third, ticket: ticket)
        try ColorChecks.check(await cache.lookup(third).1 == nil, "清理后旧任务写回")
        try ColorChecks.check(ThumbnailCache.pixelSize(170, scale: 1) == 256 && ThumbnailCache.pixelSize(170, scale: 2) == 512 && ThumbnailCache.pixelSize(3000) == 2048, "物理像素分档错误")
        // Cache writes may fail; a freshly generated thumbnail must still be returned.
        let invalid = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: invalid)
        let failedCache = ThumbnailCache(directory: invalid)
        let (failedTicket, _) = await failedCache.lookup(first)
        await failedCache.store(Data([1]), for: first, ticket: failedTicket)
        try ColorChecks.check(await failedCache.lookup(first).1 == nil, "缓存失败被记为成功")
    }
    static func performance() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("source.jpg"); try Data([0]).write(to: file)
        let fp = try AnalysisFingerprint(url: file), cache = ThumbnailCache(directory: root.appendingPathComponent("cache"))
        for i in 0..<5000 {
            let key = ThumbnailCache.Key(assetID: "asset-\(i)", kind: "original", fingerprint: fp, pixelSize: 256)
            let (ticket, _) = await cache.lookup(key); await cache.store(Data([0]), for: key, ticket: ticket)
        }
        let missing = Set((0..<1000).map { "missing-\($0)" })
        var timings: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            try await cache.invalidate(assetIDs: missing)
            let elapsed = start.duration(to: .now).components
            timings.append(Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18)
        }
        let median = timings.sorted()[2]
        print("缓存失效 5000 文件 / 1000 ID，5 次中位数：\(Int(median * 1000)) ms")
        try ColorChecks.check(median < 0.5, "缓存失效超过 500 ms")
        try await cache.invalidate(assetIDs: Set((0..<1000).map { "asset-\($0)" }))
        try ColorChecks.check(await cache.diskBytes == 4000, "按照片清理数量错误")
        let gate = BrowseRefreshGate(), now = ContinuousClock.now
        try ColorChecks.check(await gate.shouldRefresh(completed: 0, total: 10, now: now) == false, "刷新未限速")
        try ColorChecks.check(await gate.shouldRefresh(completed: 1, total: 10, now: now.advanced(by: .seconds(1))), "分析期间没有刷新")
        try ColorChecks.check(await gate.shouldRefresh(completed: 10, total: 10, now: now.advanced(by: .milliseconds(1001))), "结束未强制刷新")
    }
}
