import Foundation
import GRDB
import JingXuCore

extension CatalogStore {
    func seedAnnotation(_ value: UserAnnotation) throws {
        try setRating(value.rating, for: value.assetID)
        try setFlag(value.flag, for: value.assetID)
        try setKeywords(value.keywords, for: value.assetID)
    }
}

enum AnnotationChecks {
    static func run() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        let source = SourceRoot(name: "fixture", bookmarkData: nil, pathHint: root.path)
        try await store.upsertSource(source)
        let asset = try await store.upsertAsset(MediaAsset(sourceID: source.id, relativePath: "a.jpg", fileIdentifier: nil,
            fileName: "a.jpg", uniformType: nil, kind: .photo, fileSize: 1, modifiedAt: Date()))
        // Concurrent commands must preserve every independently edited field.
        for _ in 0..<50 {
            try await store.seedAnnotation(UserAnnotation(assetID: asset.id))
            async let rating = store.setRating(5, for: asset.id)
            async let flag = store.setFlag(.rejected, for: asset.id)
            async let keywords = store.setKeywords([" 保留 ", "保留", "", "旅行"], for: asset.id)
            _ = try await (rating, flag, keywords)
            let result = try await store.annotation(for: asset.id)
            try ColorChecks.check(result.rating == 5 && result.flag == .rejected && result.keywords == ["保留", "旅行"], "并发标注丢失字段")
        }
        let cleared = try await store.setFlag(.none, for: asset.id)
        try ColorChecks.check(cleared.rating == 5 && cleared.keywords == ["保留", "旅行"] && cleared.flag == .none, "清除旗标覆盖其他字段")
        try ColorChecks.check(try await store.setRating(-1, for: asset.id).rating == 0, "评分下界错误")
        try ColorChecks.check(try await store.setRating(9, for: asset.id).rating == 5, "评分上界错误")
        let db = try DatabaseQueue(path: root.appendingPathComponent("Catalog.sqlite").path)
        let before = try await store.annotation(for: asset.id)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER reject_annotation BEFORE UPDATE ON annotations BEGIN SELECT RAISE(ABORT, 'injected'); END") }
        do { try await store.setKeywords(["失败写入"], for: asset.id); throw ColorChecks.Failure(description: "注入写入失败未传播") }
        catch is DatabaseError {}
        try ColorChecks.check(try await store.annotation(for: asset.id) == before, "失败标注未回滚")
        for command in 0..<3 {
            do {
                switch command {
                case 0: try await store.setRating(1, for: "missing")
                case 1: try await store.setFlag(.rejected, for: "missing")
                default: try await store.setKeywords(["missing"], for: "missing")
                }
                throw ColorChecks.Failure(description: "不存在的照片仍保存标注")
            } catch CatalogAnnotationError.assetMissing {}
        }
    }
}
