import Foundation
import GRDB
import JingXuCore

enum WorkflowChecks {
    static func check(_ value: Bool, _ reason: String) throws { try ColorChecks.check(value, reason) }

    static func xmp() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, source, _) = try await PhotoShareChecks.fixture(root)
        let folder = URL(fileURLWithPath: source.pathHint)
        func index(_ name: String) async throws -> String {
            let url = folder.appendingPathComponent(name)
            try Data("original-\(name)".utf8).write(to: url)
            return try await PhotoShareChecks.index(url, store: store, source: source)
        }
        let id = try await index("create.jpg")
        try await store.setRating(4, for: id)
        let exporter = DefaultXMPExporter(repository: store)
        let plan = try await exporter.prepare(assetIDs: [id])
        try check(plan.items.count == 1, "XMP 预检没有固定照片")
        let report = try await exporter.execute(plan)
        try check(report.written.count == 1 && report.failed.isEmpty, "新 XMP 未创建")
        let original = try Data(contentsOf: report.written[0])
        try check(String(decoding: original, as: UTF8.self).contains("Rating=\"4\""), "XMP 未使用冻结标注")
        let again = try await exporter.execute(plan)
        try check(again.skipped.count == 1 && Data(contentsOf: report.written[0]) == original, "重复执行覆盖已有 XMP")

        let collision = try await exporter.prepare(assetIDs: [try await index("pair.ARW"), try await index("pair.jpg")])
        try check(collision.items.isEmpty && collision.skipped.count == 2, "同目标 RAW/JPEG 未全部跳过")
        let raceID = try await index("race.jpg")
        let race = try await exporter.prepare(assetIDs: [raceID])
        let other = Data("other editor".utf8)
        let raced = try await exporter.execute(race) { destination in try other.write(to: destination) }
        try check(raced.written.isEmpty && raced.skipped.count == 1 && Data(contentsOf: race.items[0].destination) == other, "竞争创建的 XMP 被覆盖")

        let linkID = try await index("link.jpg")
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("link.xmp").path, withDestinationPath: "absent")
        try check(try await exporter.prepare(assetIDs: [linkID]).items.isEmpty, "悬空链接未视作已有目标")

        let changedID = try await index("changed.jpg")
        let changed = try await exporter.prepare(assetIDs: [changedID])
        try await store.setKeywords(["new"], for: changedID)
        try check(try await exporter.execute(changed).failed.count == 1, "已改变标注仍导出旧清单")
        let replacedID = try await index("replaced.jpg")
        let replaced = try await exporter.prepare(assetIDs: [replacedID])
        try Data("different bytes".utf8).write(to: folder.appendingPathComponent("replaced.jpg"), options: .atomic)
        try check(try await exporter.execute(replaced).failed.count == 1, "替换后的照片仍使用旧身份")

        let cancelID = try await index("cancel.jpg")
        let cancel = try await exporter.prepare(assetIDs: [cancelID])
        let cancelled = try await exporter.execute(cancel) { _ in throw CancellationError() }
        try check(cancelled.cancelled && cancelled.written.isEmpty, "取消后仍提交 XMP")
        try check(try FileManager.default.contentsOfDirectory(atPath: folder.path).allSatisfy { !$0.hasPrefix(".jingxu-xmp-") }, "取消后遗留临时文件")
    }

    static func annotations() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, source, _) = try await PhotoShareChecks.fixture(root)
        let assets = (0..<401).map { MediaAsset(id: "id-\($0)", sourceID: source.id, relativePath: "\($0).jpg",
            fileIdentifier: nil, fileName: "\($0).jpg", uniformType: nil, kind: .photo, fileSize: 1, modifiedAt: Date()) }
        _ = try await store.upsertAssets(assets)
        let ids = assets.map(\.id)
        let change = try await store.applyAnnotations(ids: ids, patch: .init(rating: 5))
        try check(change.changes.count == 401, "跨页批量标注漏项")
        try await store.setKeywords(["独立编辑"], for: ids[0])
        let redo = try await store.invertAnnotations(change)
        let restored = try await store.annotation(for: ids[0])
        try check(restored.rating == 0 && restored.keywords == ["独立编辑"], "撤销覆盖其他字段")
        _ = try await store.invertAnnotations(redo)
        try check(try await store.annotation(for: ids[0]).rating == 5, "重做评分失败")
        try await store.setRating(3, for: ids.last!)
        do { _ = try await store.invertAnnotations(change); throw ColorChecks.Failure(description: "撤销没有检测字段冲突") }
        catch is ColorEditError {}
        try check(try await store.annotation(for: ids[0]).rating == 5, "撤销冲突未整批回滚")
        do { _ = try await store.applyAnnotations(ids: [ids[0], "missing"], patch: .init(rating: 2)); throw ColorChecks.Failure(description: "缺失目标未拒绝") }
        catch CatalogAnnotationError.assetMissing {}
        try check(try await store.annotation(for: ids[0]).rating == 5, "缺失目标导致部分写入")
        _ = try await store.applyAnnotations(ids: [ids[0]], patch: .init(keywords: .append(KeywordEdit.parse("旅行，人像\n旅行, "))))
        _ = try await store.applyAnnotations(ids: [ids[0]], patch: .init(keywords: .remove(["人像"])))
        try check(try await store.annotation(for: ids[0]).keywords == ["旅行", "独立编辑"], "关键词模式不正确")
        let album = Album(name: "测试"); try await store.saveAlbum(album)
        let added = try await store.applyAnnotations(ids: ids, patch: .init(albumID: album.id))
        try check(try await store.matchingAssetCount(BrowseQuery(albumID: album.id)) == 401, "批量加入相册漏项")
        _ = try await store.invertAnnotations(added)
        try check(try await store.matchingAssetCount(BrowseQuery(albumID: album.id)) == 0, "相册撤销失败")
        let db = try DatabaseQueue(path: root.appendingPathComponent("Catalog.sqlite").path)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_batch BEFORE UPDATE ON annotations WHEN NEW.assetID = 'id-9' BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        do { _ = try await store.applyAnnotations(ids: ids, patch: .init(flag: .rejected)); throw ColorChecks.Failure(description: "事务失败未传播") }
        catch is DatabaseError {}
        try check(try await store.annotation(for: ids[0]).flag == .none, "数据库失败未回滚全批")
    }

    static func pagination() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, source, _) = try await PhotoShareChecks.fixture(root)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        var assets: [MediaAsset] = []
        for i in 0..<100_000 {
            let name = i == 0 ? "100%_literal.jpg" : "same.jpg"
            let kind: MediaKind = i % 100 == 99 ? .video : .photo
            let date = base.addingTimeInterval(Double(i / 10))
            assets.append(MediaAsset(id: String(format: "id-%06d", i), sourceID: source.id,
                relativePath: "\(i).jpg", fileIdentifier: nil, fileName: name, uniformType: nil,
                kind: kind, fileSize: 1, modifiedAt: date))
        }
        _ = try await store.upsertAssets(assets)
        let query = BrowseQuery(sourceID: source.id)
        var seen = Set<String>(), cursor: BrowseCursor?, times: [Double] = []
        var previousLast: AssetListItem?
        while true {
            let start = ContinuousClock.now
            let page = try await store.browsePage(query, cursor: cursor, count: true)
            let duration = start.duration(to: .now).components
            times.append(Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15)
            try check(page.items.count <= 200, "分页超过 200 项")
            try check(page.total == 100_000, "分页截断匹配总数")
            for item in page.items { try check(seen.insert(item.id).inserted, "游标分页重复照片") }
            if let first = page.items.first, let previousLast {
                let backwards = try await store.browsePage(query, cursor: BrowseCursor(first), reverse: true, limit: 1)
                try check(backwards.items.last?.id == previousLast.id, "反向分页跳过边界")
            }
            previousLast = page.items.last
            if !page.hasNext { break }
            cursor = page.items.last.map(BrowseCursor.init)
        }
        try check(seen.count == 100_000, "大图库分页漏项")
        let literals = try await store.browsePage(BrowseQuery(searchText: "%_"))
        try check(literals.items.map(\.id) == [assets[0].id], "搜索将百分号或下划线解释为通配符")
        let ids = [assets[0].id, assets[2001].id, assets[99_999].id]
        try check(try await store.assetListItems(ids: ids).count == 3, "按 ID 解析跨页目标漏项")
        let first = try await store.browsePage(query)
        let anchor = first.items[50]
        _ = try await store.applyAnnotations(ids: [anchor.id], patch: .init(flag: .rejected))
        let next = try await store.browsePage(BrowseQuery(sourceID: source.id, flag: AssetFlag.none), cursor: BrowseCursor(anchor), photosOnly: true, limit: 1)
        try check(next.items.first?.id != anchor.id, "筛选隐藏的锚点无法前进")
        let emptyTail = try await store.browsePage(BrowseQuery(sourceID: source.id, flag: .rejected), cursor: BrowseCursor(anchor))
        try check(emptyTail.items.isEmpty && emptyTail.hasPrevious && !emptyTail.hasNext, "空白末页丢失返回入口")
        let unicode = [
            MediaAsset(id: "unicode-a", sourceID: source.id, relativePath: "unicode-a.jpg", fileIdentifier: nil, fileName: "é.jpg", uniformType: nil, kind: .photo, fileSize: 1, modifiedAt: base),
            MediaAsset(id: "unicode-z", sourceID: source.id, relativePath: "unicode-z.jpg", fileIdentifier: nil, fileName: "e\u{301}.jpg", uniformType: nil, kind: .photo, fileSize: 1, modifiedAt: base)
        ]
        _ = try await store.upsertAssets(unicode)
        let ordered = try await store.assetListItems(ids: unicode.map(\.id))
        try check(ordered.map(\.id) == ["unicode-z", "unicode-a"], "跨页目标排序与 SQLite 字节序不一致")
        let p95 = times.sorted()[Int(Double(times.count - 1) * 0.95)]
        print("100,000 项游标分页：\(times.count) 页，P95 \(String(format: "%.1f", p95)) ms")
        try check(p95 <= 200, "常规来源分页超过 200 ms 目标")
    }

    static func uiFixtures() async throws -> URL {
        let root = try ColorChecks.root()
        let (store, initialSource, _) = try await PhotoShareChecks.fixture(root)
        var source = initialSource
        source.directoryIdentityJSON = String(decoding: try JSONEncoder().encode(SourceIdentity.resolve(URL(fileURLWithPath: source.pathHint))), as: UTF8.self)
        try await store.upsertSource(source)
        var snapshots: [ColorEditSnapshot] = []
        for index in 0..<405 {
            snapshots.append(try await ColorChecks.fixture(store: store, source: source, name: String(format: "照片-%03d.png", index), orientation: index.isMultiple(of: 3) ? 6 : 1))
        }
        for snapshot in snapshots.prefix(4) {
            try await store.saveAnalysis(AnalysisResult(assetID: snapshot.asset.id, sharpnessScore: 0, shadowClipping: 0, highlightClipping: 0))
        }
        try await store.saveSimilarGroup("workflow-fixture", assetIDs: snapshots.prefix(4).map { $0.asset.id })
        let corrupt = URL(fileURLWithPath: source.pathHint).appendingPathComponent("损坏样本.jpg")
        try Data("invalid jpeg".utf8).write(to: corrupt)
        _ = try await PhotoShareChecks.index(corrupt, store: store, source: source)
        return root
    }

    actor Calls {
        var count = 0
        func render() async throws -> Data { count += 1; try await Task.sleep(for: .milliseconds(100)); return Data([7]) }
    }
    static func coalescing() async throws {
        let requests = ThumbnailRequests(), calls = Calls()
        let cancelled = Task { try await requests.data(key: "same") { try await calls.render() } }
        let retained = Task { try await requests.data(key: "same") { try await calls.render() } }
        try await Task.sleep(for: .milliseconds(20)); cancelled.cancel()
        do { _ = try await cancelled.value; throw ColorChecks.Failure(description: "订阅取消未传播") } catch is CancellationError {}
        try check(try await retained.value == Data([7]), "一个订阅取消了其他订阅")
        try check(await calls.count == 1, "相同缩略图请求未合并")
    }
}
