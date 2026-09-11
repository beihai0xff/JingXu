import Foundation
import GRDB
import JingXuCore

enum FolderBrowsingChecks {
    /// Explicit opt-in UI fixture: the returned root isolates the entire app
    /// catalog, not merely the source photos. Never uses the default library.
    static func uiFixtures() async throws -> URL {
        let root = try ColorChecks.root()
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        let photos = root.appendingPathComponent("目录浏览测试照片")
        let source = SourceRoot(name: "目录浏览测试", bookmarkData: nil, pathHint: photos.path)
        try await store.upsertSource(source)
        let names = ["根目录.png", "旅行/旅途.png", "旅行/第2天/蓝色.png", "旅行/第10天/绿色.png", "旅行精选/红色.png"]
        for (i, name) in names.enumerated() {
            let url = photos.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let image = try QualityV2Checks.image(width: 480, height: 320) { x, y in
                (UInt8((x + i * 30) % 220 + 20), UInt8((y + i * 20) % 220 + 20), UInt8(40 + i * 35), 255)
            }
            try QualityV2Checks.write(image, to: url, type: .png)
            let fp = try AnalysisFingerprint(url: url)
            var file = asset(source, name)
            file.fileIdentifier = fp.identifier; file.fileSize = fp.size; file.modifiedAt = fp.modifiedAt
            file.width = 480; file.height = 320
            _ = try await store.upsertAsset(file)
        }
        try FileManager.default.createDirectory(at: photos.appendingPathComponent("未索引空目录"), withIntermediateDirectories: true)
        return root
    }

    private static func check(_ value: Bool, _ reason: String) throws { try ColorChecks.check(value, reason) }

    private static func asset(_ source: SourceRoot, _ path: String, kind: MediaKind = .photo) -> MediaAsset {
        MediaAsset(sourceID: source.id, relativePath: path, fileIdentifier: nil,
                   fileName: path.split(separator: "/").last.map(String.init) ?? path,
                   uniformType: nil, kind: kind, fileSize: 10, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    static func run() async throws {
        let root = try ColorChecks.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("Catalog.sqlite")
        let store = try CatalogStore(databaseURL: database)
        let source = SourceRoot(name: "来源", bookmarkData: nil, pathHint: root.appendingPathComponent("photos").path)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: source.pathHint).appendingPathComponent("空目录"), withIntermediateDirectories: true)
        let sibling = SourceRoot(name: "来源", bookmarkData: nil, pathHint: root.appendingPathComponent("other").path, isOnline: false)
        let childSource = SourceRoot(name: "旅行", bookmarkData: nil, pathHint: source.pathHint + "/旅行", isOnline: false)
        let emptySource = SourceRoot(name: "空来源", bookmarkData: nil, pathHint: root.appendingPathComponent("empty").path, isOnline: false)
        for value in [source, sibling, childSource, emptySource] { try await store.upsertSource(value) }
        var items = ["root.jpg", "旅行/a.jpg", "旅行/第2天/b.jpg", "旅行/第10天/c.jpg", "旅行精选/d.jpg",
                     "100%_ 原图/a.jpg", "100%_ 原图/👩‍💻/b.jpg", "100XX 原图/not.jpg",
                     "Case/a.jpg", "case/b.jpg", "é/a.jpg", "e\u{301}/b.jpg"].map { asset(source, $0) }
        items.append(asset(source, "旅行/clip.mov", kind: .video))
        items.append(asset(source, "只有视频/clip.mov", kind: .video))
        items.append(asset(sibling, "旅行/offline.jpg"))
        items.append(asset(childSource, "a.jpg"))
        _ = try await store.upsertAssets(items)
        let tree = try await store.folderTree()
        let origin = tree.first { $0.id.sourceID == source.id }!
        func folder(_ path: String) -> CatalogFolderID { CatalogFolderID(sourceID: source.id, relativeDirectory: path) }
        try check(tree.count == 4 && origin.recursiveCount == 14 && origin.directCount == 1, "来源根、直接计数或递归计数错误")
        try check(tree.first { $0.id.sourceID == emptySource.id }?.recursiveCount == 0, "空来源根节点被删除")
        try check(origin.node(folder("空目录")) == nil, "从磁盘扫描了未索引空目录")
        try check(origin.node(folder("旅行"))?.recursiveCount == 4 && origin.node(folder("旅行"))?.directCount == 2, "照片或视频目录计数错误")
        try check(origin.node(folder("旅行"))?.children.map(\.name) == ["第2天", "第10天"], "目录不是自然顺序")
        try check(origin.node(folder("只有视频"))?.directCount == 1, "仅含视频目录被隐藏")
        try check(tree.first { $0.id.sourceID == sibling.id }?.recursiveCount == 1, "离线同名来源被丢弃或合并")
        try check(folder("é") != folder("e\u{301}"), "目录身份错误合并不同原始字符")

        for (path, recursive, expected) in [("", true, 14), ("", false, 1), ("旅行", true, 4), ("旅行", false, 2),
            ("旅行/第2天", false, 1), ("100%_ 原图", true, 2), ("100%_ 原图", false, 1), ("100%_ 原图/👩‍💻", false, 1),
            ("Case", true, 1), ("case", true, 1), ("é", false, 1), ("e\u{301}", false, 1)] {
            let query = AssetQuery(sourceID: source.id, relativeDirectory: path, includeSubdirectories: recursive, limit: 1, offset: 1)
            try check(try await store.matchingAssetCount(query) == expected, "目录范围或不分页计数错误：\(path)")
            var all = query; all.limit = 2000; all.offset = 0
            try check(try await store.assets(all).count == expected, "目录网格范围错误：\(path)")
        }
        for path in ["/旅行", "旅行/", "旅行//第2天", "..", "旅行/../旅行精选", ".", "a\0b"] {
            do {
                _ = try await store.assets(AssetQuery(sourceID: source.id, relativeDirectory: path))
                throw ColorChecks.Failure(description: "非法目录未被拒绝")
            } catch is CatalogFolderError {}
        }
        let unscoped = AssetQuery(relativeDirectory: "旅行")
        for operation in 0..<4 {
            do {
                switch operation {
                case 0: _ = try await store.assets(unscoped)
                case 1: _ = try await store.matchingAssetCount(unscoped)
                case 2: _ = try await store.deletionCandidates(unscoped)
                default: _ = try await store.analysisCandidates(unscoped)
                }
                throw ColorChecks.Failure(description: "缺来源的目录范围退化为全图库")
            } catch is CatalogFolderError {}
        }
        let photo = items.first { $0.relativePath == "旅行/a.jpg" }!
        let other = items.first { $0.relativePath == "旅行精选/d.jpg" }!
        for item in [photo, other] { try await store.saveAnnotation(UserAnnotation(assetID: item.id, rating: 5, flag: .rejected, keywords: ["入选"])) }
        let album = Album(name: "选片"); try await store.saveAlbum(album)
        for item in [photo, other] { try await store.add(assetID: item.id, toAlbum: album.id) }
        let selected = AssetQuery(sourceID: source.id, relativeDirectory: "旅行", includeSubdirectories: false,
                                  albumID: album.id, searchText: "入选", minimumRating: 4, flag: .rejected)
        try check(try await store.assets(selected).map(\.id) == [photo.id], "目录和相册／搜索／评分／旗标组合串范围")
        try check(try await store.matchingAssetCount(selected) == 1, "筛选计数与列表不一致")
        try check(try await store.deletionCandidates(selected).map(\.id) == [photo.id], "淘汰清理串目录")
        try check(try await store.analysisCandidates(selected) == [photo.id], "质量重算串目录")
        try check(try await store.folderTree().first { $0.id.sourceID == source.id }?.recursiveCount == 14, "筛选或标注改变目录树")
        try await store.removeAssetRecords(items.filter { $0.relativePath.hasPrefix("旅行/第2天/") }.map(\.id))
        let updated = try await store.folderTree().first { $0.id.sourceID == source.id }!
        try check(updated.nearestSurvivingAncestor(of: folder("旅行/第2天")) == folder("旅行"), "消失目录未返回最近上级")
        try check(updated.nearestSurvivingAncestor(of: folder("不存在/下级")) == folder(""), "目录完全消失未返回来源根")
        try check(updated.nearestSurvivingAncestor(of: CatalogFolderID(sourceID: "removed")) == nil, "已移除来源回到其他来源")
        let reopened = try CatalogStore(databaseURL: database)
        try check(try await reopened.matchingAssetCount(selected) == 1, "重新打开后目录查询或标注改变")
    }

    static func completeScope() async throws {
        let root = try ColorChecks.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let photos = root.appendingPathComponent("photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: true)
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        let source = try await store.registerSource(at: photos)
        let large = (0..<2_005).map { asset(source, "旅行/missing-\($0).jpg") }
        let excluded = asset(source, "旅行精选/keep.jpg")
        _ = try await store.upsertAssets(large + [excluded])
        for value in large + [excluded] { try await store.saveAnnotation(UserAnnotation(assetID: value.id, flag: .rejected)) }
        let query = AssetQuery(sourceID: source.id, relativeDirectory: "旅行", limit: 2000)
        try check(try await store.assets(query).count == 2000, "网格显示上限改变")
        try check(try await store.matchingAssetCount(query) == 2005, "目录计数被网格截断")
        try check(try await store.deletionCandidates(query).count == 2005, "淘汰候选被网格截断")
        try check(try await store.analysisCandidates(query).count == 2005, "重算候选被网格截断")
        let missing = try await store.prepareMissingAssetCleanup(query)
        try check(missing.files.count == 2005 && !missing.files.contains(where: { $0.id == excluded.id }), "失效索引清理未使用完整目录范围")
        let report = try await store.cleanupMissingAssets(missing, backupURL: root.appendingPathComponent("backup.sqlite"))
        try check(report.removedIDs.count == 2005 && report.skipped.isEmpty, "目录失效清理未完成")
        let tree = try await store.folderTree()
        let origin = tree.first { $0.id.sourceID == source.id }!
        let removed = CatalogFolderID(sourceID: source.id, relativeDirectory: "旅行")
        try check(origin.node(removed) == nil && origin.recursiveCount == 1, "清理后目录或数量未更新")
        try check(try await store.asset(id: excluded.id) != nil, "清理误删相邻目录索引")
        try check(FileManager.default.fileExists(atPath: photos.path), "浏览或清理改变来源目录")
    }
}
