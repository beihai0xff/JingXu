import Darwin
import Foundation
import JingXuCore

/// Run each scenario in a fresh process against one generated fixture. Fixture
/// construction is excluded from process peak memory and first-image timings.
enum BrowsingPerformanceProfile {
    static func fixture() async throws -> URL {
        let root = try ColorChecks.root()
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Performance.sqlite"))
        let source = SourceRoot(id: "profile", name: "synthetic", bookmarkData: nil, pathHint: root.path)
        try await store.upsertSource(source)
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for start in stride(from: 0, to: 100_000, by: 1_000) {
            let rows = (start..<start + 1_000).map { index in
                MediaAsset(id: "profile-\(index)", sourceID: source.id, relativePath: "\(index).png",
                    fileIdentifier: nil, fileName: "\(index).png", uniformType: "public.png", kind: .photo,
                    fileSize: 1, modifiedAt: base.addingTimeInterval(Double(index)))
            }
            try await store.upsertAssets(rows)
        }
        let image = try QualityV2Checks.image(width: 4000, height: 3000) { x, y in
            (UInt8(x % 180), UInt8(y % 180), 80, 255)
        }
        try QualityV2Checks.write(image, to: root.appendingPathComponent("preview.png"), type: .png)
        try Data("jingxu-synthetic-browsing-profile".utf8).write(to: root.appendingPathComponent("profile.marker"))
        return root
    }

    @MainActor static func run(root: URL, count: Int, wholeRange: Bool) async throws {
        guard [200, 2_000, 10_000].contains(count),
              try String(contentsOf: root.appendingPathComponent("profile.marker"), encoding: .utf8) == "jingxu-synthetic-browsing-profile"
        else { throw ColorChecks.Failure(description: "请先生成独立性能素材，并选择 200、2000 或 10000 项") }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Performance.sqlite"))
        var loaded = LoadedAssetList()
        var cursor: BrowseCursor?
        while loaded.items.count < count {
            let page = try await store.browsePage(BrowseQuery(sourceID: "profile"), cursor: cursor, count: cursor == nil)
            loaded.append(page.items); cursor = page.items.last.map(BrowseCursor.init)
        }
        let photo = SystemPhoto(id: "preview", name: "preview.png", width: 4000, height: 3000)
        let client = IsolatedPhotoLibraryClient(root: root, photos: [(photo, root.appendingPathComponent("preview.png"))])
        let previewStore = try SystemPhotosStore(url: root.appendingPathComponent("Preview.sqlite"))
        let session = SystemPhotoPreviewSession(client: client, store: previewStore)
        let firstImageStart = ContinuousClock.now
        var baselineImage: PreviewImage?
        if wholeRange { baselineImage = try await client.image(id: photo.id, pixelSize: Int.max) }
        else { try await session.open(at: 0) { photo } }
        let firstImage = IncrementalBrowsingChecks.milliseconds(firstImageStart)

        let changed = loaded.items[count / 2].id
        var latencies: [Double] = []
        for _ in 0..<6 {
            let start = ContinuousClock.now
            if wholeRange {
                let rows = try await store.assetListItems(ids: loaded.items.map(\.id))
                // Former per-update full version dictionary and replacement.
                let versions = Dictionary(uniqueKeysWithValues: loaded.items.map { ($0.id, $0.fileVersion) })
                try ColorChecks.check(rows.allSatisfy { versions[$0.id] == $0.fileVersion }, "基线版本变化")
                loaded.replace(rows)
            } else {
                let rows = try await store.assetListItems(ids: loaded.loadedIDs(in: [changed]))
                loaded.update(rows)
            }
            latencies.append(IncrementalBrowsingChecks.milliseconds(start))
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print(String(format: "profile loaded=%d mode=%@ detailRows=%d firstImage=%.2fms refreshFirst=%.2fms refreshWarmMax=%.2fms peak=%.1fMiB",
            count, wholeRange ? "whole" : "changed", wholeRange ? count : 1, firstImage, latencies[0],
            latencies.dropFirst().max()!, Double(usage.ru_maxrss) / 1_048_576))
        withExtendedLifetime(baselineImage) {}
        _ = await session.close()
    }

    static func scrolling(root: URL, bounded: Bool) async throws {
        guard try String(contentsOf: root.appendingPathComponent("profile.marker"), encoding: .utf8) == "jingxu-synthetic-browsing-profile"
        else { throw ColorChecks.Failure(description: "请先生成独立性能素材") }
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Performance.sqlite"))
        let query = BrowseQuery(sourceID: "profile")
        var loaded = LoadedAssetList(), cursor: BrowseCursor?
        var traversed = 0, timings: [Double] = []
        while true {
            let start = ContinuousClock.now
            let page = try await store.browsePage(query, cursor: cursor, count: cursor == nil)
            timings.append(IncrementalBrowsingChecks.milliseconds(start))
            if cursor == nil { loaded.replace(page.items) }
            else if bounded { loaded.appendWindow(page.items, before: false, columns: 3) }
            else { loaded.append(page.items) }
            traversed += page.items.count
            if bounded { try ColorChecks.check(loaded.items.count <= 600, "滚动窗口超过 600 项") }
            if [2_000, 10_000, 100_000].contains(traversed) {
                var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
                print(String(format: "scroll mode=%@ traversed=%d loaded=%d peak=%.1fMiB",
                    bounded ? "window" : "whole", traversed, loaded.items.count,
                    Double(usage.ru_maxrss) / 1_048_576))
            }
            guard page.hasNext else { break }
            cursor = page.items.last.map(BrowseCursor.init)
        }
        try ColorChecks.check(traversed == 100_000, "性能场景未遍历十万项")
        let p95 = timings.sorted()[Int(Double(timings.count - 1) * 0.95)]
        print(String(format: "scroll mode=%@ pages=%d p95=%.2fms", bounded ? "window" : "whole", timings.count, p95))
    }
}
