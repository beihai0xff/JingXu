import Foundation
import JingXuCore

enum IncrementalBrowsingChecks {
    /// Compare the former whole-loaded-range read with the actual incremental path
    /// against the same 100k-row fixture, in one process and on the same machine.
    static func browsing(store: CatalogStore, query: BrowseQuery) async throws {
        let rows = try await store.browsePage(query, limit: 10_000, count: true)
        let selection = Array(rows.items.filter { $0.kind == .photo }.prefix(2_005).map(\.id))
        let valid = try await store.matchingPhotoIDs(selection + ["missing", "id-000099"], matching: query)
        try ColorChecks.check(valid == Set(selection), "ID 查询丢失跨页选择或包含视频")
        var photoSelection = PhotoSelectionState(); photoSelection.selectAll(selection)
        photoSelection.retain(validIDs: valid)
        try ColorChecks.check(photoSelection.selectedIDs.count == 2_005, "完整选择被已载入范围截断")
        _ = try await store.setRating(4, for: selection[0])
        var filtered = query; filtered.minimumRating = 4
        try ColorChecks.check(try await store.matchingPhotoIDs(selection, matching: filtered) == [selection[0]], "ID 查询未使用完整筛选条件")
        var searched = query; searched.searchText = ".jpg"
        let searchedBefore = try await store.matchingPhotoIDs(selection, matching: searched)
        let rating = try await store.applyAnnotations(ids: [selection[0]], patch: .init(rating: 2))
        try ColorChecks.check(rating.affectsMembership(of: filtered) && !rating.affectsMembership(of: searched), "评分触发无关的搜索范围重查")
        try ColorChecks.check(try await store.matchingPhotoIDs(selection, matching: filtered).isEmpty, "评分变化后筛选范围错误")
        let inverse = try await store.invertAnnotations(rating)
        try ColorChecks.check(inverse.affectsMembership(of: filtered) && !inverse.affectsMembership(of: searched), "撤销触发无关的搜索范围重查")
        try ColorChecks.check(try await store.matchingPhotoIDs(selection, matching: searched) == searchedBefore, "无关标注改变搜索成员")
        try ColorChecks.check(try await store.matchingPhotoIDs(selection, matching: filtered) == [selection[0]], "撤销没有恢复评分筛选成员")
        for count in [200, 2_000, 10_000] {
            let page = Array(rows.items.prefix(count))
            var loaded = LoadedAssetList(); loaded.replace(page)
            let changed = page[count / 2].id
            var oldTimes: [Double] = [], newTimes: [Double] = []
            for _ in 0..<6 {
                let oldStart = ContinuousClock.now
                let old = try await store.assetListItems(ids: page.map(\.id))
                oldTimes.append(milliseconds(oldStart))
                try ColorChecks.check(old.count == count, "基线查询不完整")
                let start = ContinuousClock.now
                let ids = loaded.loadedIDs(in: [changed, "not-loaded"])
                let updates = try await store.assetListItems(ids: ids)
                loaded.update(updates)
                newTimes.append(milliseconds(start))
                try ColorChecks.check(ids == [changed] && updates.count == 1, "单张变更读取了整个已载入范围")
            }
            let oldP95 = oldTimes.dropFirst().sorted().last!, newP95 = newTimes.dropFirst().sorted().last!
            print(String(format: "增量刷新 loaded=%d：详情行 %d→1；首次 %.2f→%.2f ms，预热后 P95(5次) %.2f→%.2f ms",
                         count, count, oldTimes[0], newTimes[0], oldP95, newP95))
            // File identity changes invalidate automation; annotations alone do not.
            var modified = page[0]; modified.fileVersion += "-changed"
            try ColorChecks.check(loaded.update([modified]), "文件身份变化未报告")
            modified.rating = 2
            try ColorChecks.check(!loaded.update([modified]), "标注错误地失效文件版本")
            loaded.append(Array(page.prefix(20)))
            try ColorChecks.check(loaded.items.count == count, "重复追加产生重复行")
            if count == 200 {
                loaded.append(Array(rows.items[200..<400]))
                try ColorChecks.check(loaded.index(of: rows.items[399].id) == 399, "追加后索引错位")
                loaded.replace(Array(rows.items[200..<400]))
                loaded.append(Array(rows.items[0..<200]), before: true)
                try ColorChecks.check(loaded.items.map(\.id) == Array(rows.items.prefix(400)).map(\.id), "前插破坏顺序")
                try ColorChecks.check(loaded.photoIDs == loaded.items.filter { $0.kind == .photo }.map(\.id), "照片 ID 列表不同步")
            }
        }
        let next = try await store.browsePage(query, cursor: BrowseCursor(rows.items[199]))
        try ColorChecks.check(next.total == nil && next.items.first?.id == rows.items[200].id, "追加页面仍计数或游标错位")
        _ = try await store.setRating(0, for: selection[0])
    }

    actor Events {
        var values: [AnalysisProgress] = []
        func append(_ value: AnalysisProgress) { values.append(value) }
    }
    struct GroupingAnalyzer: QualityAnalyzer {
        func analyze(assetID: String, at url: URL) async throws -> AnalysisResult {
            var result = AnalysisResult(assetID: assetID, sharpnessScore: 0, shadowClipping: 0, highlightClipping: 0, featurePrint: Data([1]))
            result.fingerprint = try AnalysisFingerprint(url: url)
            return result
        }
        func featureDistance(_ lhs: Data, _ rhs: Data) throws -> Float { 0 }
    }
    static func progress() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("db.sqlite"))
        let source = SourceRoot(name: "analysis", bookmarkData: nil, pathHint: root.path)
        try await store.upsertSource(source)
        let first = try await ColorChecks.fixture(store: store, source: source, name: "a.png")
        let second = try await ColorChecks.fixture(store: store, source: source, name: "b.png")
        let coordinator = AnalysisCoordinator(repository: store, analyzer: QualityV2Checks.DeniedAnalyzer())
        let events = Events(), gate = BrowseRefreshGate(), drained = Events()
        let worker = Task {
            try await coordinator.analyze(assetIDs: [first.asset.id, second.asset.id]) { value in
                await events.append(value)
                let ids = await gate.ingest(value)
                if !ids.isEmpty { await drained.append(.init(total: value.total, completed: value.completed, currentFile: "", changedAssetIDs: ids)) }
                if !value.changedAssetIDs.isEmpty { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do { try await worker.value; throw ColorChecks.Failure(description: "分析未响应取消") } catch is CancellationError {}
        let observed = await events.values, visible = await drained.values
        try ColorChecks.check(observed.last?.isFinished == true && observed.last?.completed == 1, "取消未结束并冲刷进度")
        try ColorChecks.check(Set(visible.flatMap(\.changedAssetIDs)) == [first.asset.id], "取消漏掉已提交结果或带入未处理照片")
        try ColorChecks.check(try await store.analysis(for: first.asset.id)?.analysisError != nil, "失败结果未实际持久化")
        try ColorChecks.check(try await store.analysis(for: second.asset.id) == nil, "取消后处理了下一张")

        let grouped = Events()
        let grouping = AnalysisCoordinator(repository: store, analyzer: GroupingAnalyzer())
        try await grouping.analyze(assetIDs: [first.asset.id, second.asset.id, "missing"]) { await grouped.append($0) }
        let updates = await grouped.values
        try ColorChecks.check(!updates.flatMap(\.changedAssetIDs).contains("missing"), "不存在照片被报告为已提交变化")
        try ColorChecks.check(updates.contains { Set($0.changedAssetIDs) == [first.asset.id, second.asset.id] }, "相似分组没有报告变化 ID")
        try ColorChecks.check(updates.last?.isFinished == true && updates.last?.completed == 3, "分组结束没有最终刷新")
        try ColorChecks.check(try await store.analysis(for: first.asset.id)?.similarGroupID != nil, "分组通知早于实际提交")
    }
    static func milliseconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) * 1000 + Double(value.attoseconds) / 1e15
    }
}
