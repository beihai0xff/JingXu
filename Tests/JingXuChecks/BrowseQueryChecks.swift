import Foundation
import GRDB
import JingXuCore

enum BrowseQueryChecks {
    static func assertIndexes(_ db: Database) throws {
        let names = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'")
        try ColorChecks.check(names.contains("mediaAssets_browseOrder") && names.contains("mediaAssets_sourceBrowseOrder"), "浏览索引未补齐")
        for sourceFilter in [false, true] {
            let sql = "EXPLAIN QUERY PLAN SELECT id FROM mediaAssets \(sourceFilter ? "WHERE sourceID = 'source'" : "") ORDER BY COALESCE(capturedAt, modifiedAt) DESC, fileName ASC, id ASC LIMIT 2000"
            let plan = try Row.fetchAll(db, sql: sql).map { $0["detail"] as String }.joined(separator: "\n")
            try ColorChecks.check(!plan.contains("TEMP B-TREE") && plan.contains(sourceFilter ? "mediaAssets_sourceBrowseOrder" : "mediaAssets_browseOrder"), "浏览排序没有使用匹配索引：\(plan)")
        }
    }

    static func run() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Catalog.sqlite")
        let store = try CatalogStore(databaseURL: url)
        let source = SourceRoot(id: "source", name: "测试", bookmarkData: nil, pathHint: root.path)
        try await store.upsertSource(source)
        let date = Date()
        let paths = ["a/same.jpg", "a/sub/same.jpg", "b/same.jpg", "video.mov", "raw.dng"]
        for (i, path) in paths.enumerated() {
            try await store.upsertAsset(MediaAsset(id: "id-\(i)", sourceID: source.id, relativePath: path, fileIdentifier: nil,
                fileName: i < 3 ? "same.jpg" : path, uniformType: nil, kind: i == 3 ? .video : .photo, fileSize: 10,
                modifiedAt: date, capturedAt: i == 1 ? nil : date))
        }
        try await store.setRating(5, for: "id-0")
        try await store.setFlag(.rejected, for: "id-0")
        try await store.setKeywords(["needle"], for: "id-1")
        var analysis = AnalysisResult(assetID: "id-2", algorithmVersion: 2, sharpnessScore: 0,
            shadowClipping: 0, highlightClipping: 0, issues: [.blurry])
        analysis.assessmentStatus = .suspectedBlur
        try await store.saveAnalysis(analysis)
        let album = Album(id: "album", name: "相册")
        try await store.saveAlbum(album)
        for id in ["id-0", "id-1"] { try await store.add(assetID: id, toAlbum: album.id) }
        let stable = try await store.assets(BrowseQuery()).filter { $0.fileName == "same.jpg" }.map(\.id)
        try ColorChecks.check(stable == ["id-0", "id-1", "id-2"], "同日期同名照片顺序不稳定")
        for collection in [SmartCollection.all, .recent, .photos, .videos, .raw, .review, .rejected] {
            for query in [BrowseQuery(collection: collection), BrowseQuery(collection: collection, searchText: "needle"),
                          BrowseQuery(collection: collection, minimumRating: 3), BrowseQuery(collection: collection, flag: AssetFlag.none),
                          BrowseQuery(collection: collection, flag: .rejected), BrowseQuery(collection: collection, sourceID: source.id, relativeDirectory: "a"),
                          BrowseQuery(collection: collection, albumID: album.id)] {
                let page = try await store.assets(query)
                let total = try await store.matchingAssetCount(query)
                try ColorChecks.check(total == page.count, "精简计数改变了筛选结果：\(query)")
                let paged = try await store.browsePage(query, limit: 1, count: true)
                try ColorChecks.check(paged.total == total && paged.items.count == min(1, total), "分页混入其他范围或截断完整计数")
            }
        }
        let db = try DatabaseQueue(path: url.path)
        try await db.read { try assertIndexes($0) }
        let before = try LegacyMigrationChecks.snapshot(url)
        try await db.write { try $0.execute(sql: "DROP INDEX mediaAssets_browseOrder; DROP INDEX mediaAssets_sourceBrowseOrder") }
        try db.close()
        // Current-format catalogs need no migration/version bump to restore derived indexes.
        for _ in 0..<2 {
            let reopened = try CatalogStore(databaseURL: url)
            _ = try await reopened.assets(BrowseQuery())
            let reader = try DatabaseQueue(path: url.path)
            try await reader.read { db in
                try assertIndexes(db)
                try ColorChecks.check(try Int.fetchOne(db, sql: "PRAGMA user_version") == CatalogUpgradeCoordinator.schemaVersion, "索引改变数据库格式版本")
            }
            try reader.close()
        }
        try ColorChecks.check(try LegacyMigrationChecks.snapshot(url) == before, "补齐索引改变用户记录")
        let legacy = root.appendingPathComponent("legacy.sqlite")
        try await LegacyMigrationChecks.fixture(legacy)
        let legacyDB = try DatabaseQueue(path: legacy.path)
        try await legacyDB.write { try $0.execute(sql: "DROP INDEX mediaAssets_browseOrder; DROP INDEX mediaAssets_sourceBrowseOrder") }
        try legacyDB.close()
        try await LegacyMigrationChecks.verifyCopy(legacy)
        let upgraded = try DatabaseQueue(path: legacy.path)
        try await upgraded.read { try assertIndexes($0) }
        try upgraded.close()
    }
}
