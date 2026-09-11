import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import JingXuCore

enum PhotoShareChecks {
    static func check(_ value: Bool, _ reason: String) throws { try ColorChecks.check(value, reason) }
    static func index(_ url: URL, store: CatalogStore, source: SourceRoot, kind: MediaKind = .photo) async throws -> String {
        let fp = try AnalysisFingerprint(url: url)
        let asset = MediaAsset(sourceID: source.id, relativePath: FileIdentity.relativePath(of: url, under: URL(fileURLWithPath: source.pathHint)),
            fileIdentifier: fp.identifier, fileName: url.lastPathComponent, uniformType: nil, kind: kind,
            fileSize: fp.size, modifiedAt: fp.modifiedAt)
        _ = try await store.upsertAsset(asset)
        return asset.id
    }
    static func fixture(_ root: URL) async throws -> (CatalogStore, SourceRoot, PhotoShareCoordinator) {
        let store = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        let pictures = root.appendingPathComponent("pictures")
        try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
        let source = SourceRoot(name: "synthetic", bookmarkData: nil, pathHint: pictures.path)
        try await store.upsertSource(source)
        return (store, source, PhotoShareCoordinator(store: store, cacheRoot: root.appendingPathComponent("Sharing")))
    }
    static func uiFixtures() async throws -> URL {
        let root = try ColorChecks.root()
        let (store, source, _) = try await fixture(root)
        for name in ["蓝色.png", "旅行 01.png", "旅行 02.png", "人像.png"] {
            _ = try await ColorChecks.fixture(store: store, source: source, name: name)
        }
        return root
    }
    static func selection() throws {
        let photos = ["a", "b", "c", "d", "e"]
        var s = PhotoSelectionState()
        s.click("b", photoIDs: photos); s.click("d", photoIDs: photos, command: true)
        try check(s.orderedIDs(in: photos) == ["b", "d"] && s.focusID == "d", "⌘ 添加或焦点错误")
        s.click("d", photoIDs: photos, command: true)
        try check(s.selectedIDs == ["b"] && s.focusID == "d", "⌘ 移除不能把焦点扩大成批量标记")
        s.click("a", photoIDs: photos, shift: true)
        try check(s.orderedIDs(in: photos) == ["a", "b", "c", "d"] && s.anchorID == "d", "反向 Shift 连选错误")
        s.click("e", photoIDs: photos, command: true)
        s.click("c", photoIDs: photos, command: true, shift: true)
        try check(s.orderedIDs(in: photos) == photos, "⌘Shift 未追加范围")
        s.click("video", photoIDs: photos, command: true)
        try check(s.selectedIDs == Set(photos), "视频进入照片选择")
        s.click("video", photoIDs: photos)
        try check(s.selectedIDs.isEmpty && s.focusID == "video", "视频单击应只改变焦点")
        s.click("c", photoIDs: photos, shift: true)
        try check(s.selectedIDs == ["c"], "无有效锚点未退回当前照片")
        s.reconcile(visibleIDs: photos, photoIDs: photos, resetAnchor: true)
        s.click("a", photoIDs: photos, shift: true)
        try check(s.orderedIDs(in: photos) == ["a", "b", "c"], "锚点失效未使用有效焦点")
        s.reconcile(visibleIDs: ["b", "video"], photoIDs: ["b"])
        try check(s.selectedIDs == ["b"] && s.focusID == nil && s.anchorID == nil, "筛选后保留了失效选择或锚点")
        s.click("b", photoIDs: photos, checkboxMode: true)
        let afterFirst = s
        try check(!s.click("b", photoIDs: photos, checkboxMode: true, count: 2) && s == afterFirst, "勾选模式双击重复切换")
        s.click("c", photoIDs: photos)
        try check(s.click("c", photoIDs: photos, count: 2), "普通双击不能进入单图")
        try check(!s.click("c", photoIDs: photos, command: true, count: 2), "修饰双击打开了单图")
        let ids = (0..<2000).map { "p\($0)" }
        s.selectAll(ids)
        try check(s.orderedIDs(in: ids + ["p0", "not-visible"]) == ids, "共享目标未按网格顺序去重或越界")
        s.clear()
        try check(s.selectedIDs.isEmpty && s.focusID == nil && s.anchorID == nil, "切换目录未清空")
    }

    static func originals() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, source, coordinator) = try await fixture(root)
        let folder = URL(fileURLWithPath: source.pathHint)
        var ids: [String] = [], urls: [URL] = []
        // Deliberately not decodable: original sharing must not invoke ImageIO.
        for name in ["a.ARW", "a.jpg", "b.HEIC", "movie.MOV"] {
            let url = folder.appendingPathComponent(name)
            try Data("untouched original \(name)".utf8).write(to: url)
            ids.append(try await index(url, store: store, source: source, kind: name == "movie.MOV" ? .video : .photo))
            urls.append(url)
        }
        try Data("sidecar".utf8).write(to: folder.appendingPathComponent("a.xmp"))
        let hashes = try urls.map { try FileHasher.sha256(of: $0) }
        let plan = try await coordinator.plan(assetIDs: [ids[2], ids[0], ids[2], ids[3], "missing"], mode: .original)
        let ready = try await coordinator.prepare(plan)
        try check(ready.files.map(\.assetID) == [ids[2], ids[0]] && ready.files.map(\.url) == [urls[2], urls[0]],
                  "原片顺序、去重、配对文件隔离或 URL 直传失败")
        try check(ready.cacheDirectory == nil && ready.issues.count == 2, "原片发生了复制或静默忽略失败")
        try check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Sharing").path), "原片生成了成片缓存")
        try check(try urls.map { try FileHasher.sha256(of: $0) } == hashes, "原片内容被改变")
        try await coordinator.finish(id: ready.id, cacheDirectory: nil, handedToSystem: false)

        // Duplicate catalog roots still only hand the exact same path to the service once.
        var duplicateSource = source; duplicateSource.id = UUID().uuidString
        try await store.upsertSource(duplicateSource)
        let duplicateID = try await index(urls[0], store: store, source: duplicateSource)
        let duplicate = try await coordinator.prepare(coordinator.plan(assetIDs: [ids[0], duplicateID], mode: .original))
        try check(duplicate.files.count == 1 && duplicate.issues.count == 1, "重复路径交付两次")
        try await coordinator.finish(id: duplicate.id, cacheDirectory: nil, handedToSystem: false)

        let replacedPlan = try await coordinator.plan(assetIDs: [ids[0], ids[1]], mode: .original)
        try Data("replacement, different identity".utf8).write(to: urls[0], options: .atomic)
        let replaced = try await coordinator.prepare(replacedPlan)
        try check(replaced.files.map(\.assetID) == [ids[1]] && replaced.issues.count == 1, "被替换文件仍被分享")
        try await coordinator.finish(id: replaced.id, cacheDirectory: nil, handedToSystem: false)

        // Simulate a replacement of an earlier item while a later item is being prepared.
        let lastCheckPlan = try await coordinator.plan(assetIDs: [ids[1], ids[2]], mode: .original)
        let earlyURL = urls[1]
        let finalCheck = try await coordinator.prepare(lastCheckPlan) { done, _ in
            if done == 2 { try? Data("late replacement".utf8).write(to: earlyURL, options: .atomic) }
        }
        try check(finalCheck.files.map(\.assetID) == [ids[2]], "准备完未复核前面照片的身份")
        try await coordinator.finish(id: finalCheck.id, cacheDirectory: nil, handedToSystem: false)
        var offline = source; offline.isOnline = false
        try await store.upsertSource(offline)
        let absent = try await coordinator.prepare(coordinator.plan(assetIDs: [ids[2]], mode: .original))
        try check(absent.files.isEmpty && !absent.issues.isEmpty, "离线来源被交付")
        try await coordinator.finish(id: absent.id, cacheDirectory: nil, handedToSystem: false)
        offline.isOnline = true; offline.bookmarkData = Data("invalid authorization".utf8)
        try await store.upsertSource(offline)
        let unauthorized = try await coordinator.prepare(coordinator.plan(assetIDs: [ids[2]], mode: .original))
        try check(unauthorized.files.isEmpty && !unauthorized.issues.isEmpty, "无效授权被忽略")
        try await coordinator.finish(id: unauthorized.id, cacheDirectory: nil, handedToSystem: false)
    }

    static func rendering() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, source, coordinator) = try await fixture(root)
        let folder = URL(fileURLWithPath: source.pathHint)
        let image = try QualityV2Checks.image(width: 3072, height: 1536) { _, _ in (75, 105, 135, 255) }
        var ids: [String] = [], originals: [URL] = []
        for (name, type) in [("same.jpg", UTType.jpeg), ("same.heic", .heic)] {
            let url = folder.appendingPathComponent(name)
            guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
                throw ColorChecks.Failure(description: "系统没有 JPEG/HEIC 测试编码器")
            }
            CGImageDestinationAddImage(dest, image, [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 31.2, kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 121.5, kCGImagePropertyGPSLongitudeRef: "E"],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:07:20 10:11:12"]
            ] as CFDictionary)
            try check(CGImageDestinationFinalize(dest), "合成带 GPS 素材写入失败")
            ids.append(try await index(url, store: store, source: source)); originals.append(url)
        }
        let hashes = try originals.map { try FileHasher.sha256(of: $0) }
        let base = try await store.colorSnapshot(assetID: ids[0])
        var adjustment = ColorAdjustments(); adjustment.exposure = 0.5
        let saved = try await store.saveColorAdjustments(adjustment, snapshot: base)
        var annotation = try await store.annotation(for: ids[0]); annotation.rating = 4; annotation.keywords = ["私人测试"]
        try await store.saveAnnotation(annotation)
        annotation = try await store.annotation(for: ids[0])
        let beforeCount = try await store.matchingAssetCount(AssetQuery())
        let full = try await coordinator.prepare(coordinator.plan(assetIDs: ids, mode: .jpeg))
        try check(full.files.count == 2 && full.issues.isEmpty, "JPEG/HEIC 成片准备失败：\(full.issues)")
        try check(full.files.map { $0.url.lastPathComponent } == ["same-调色.jpg", "same-调色-2.jpg"], "同名成片覆盖或未统一编号")
        for file in full.files {
            guard let src = CGImageSourceCreateWithURL(file.url as CFURL, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
                throw ColorChecks.Failure(description: "成片不能解码")
            }
            try check(decoded.width == 1536 && decoded.height == 3072, "原尺寸或 EXIF 方向错误")
            try check((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1, "成片未归一化方向")
            let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            try check(abs((gps?[kCGImagePropertyGPSLatitude] as? Double ?? 0) - 31.2) < 0.01 &&
                      abs((gps?[kCGImagePropertyGPSLongitude] as? Double ?? 0) - 121.5) < 0.01, "成片丢失 GPS")
            if file.assetID == ids[0] { try check(try ColorChecks.brightness(decoded) > 115, "未应用已冻结调色") }
        }
        let small = try await coordinator.prepare(coordinator.plan(assetIDs: [ids[0]], mode: .jpeg, maximumDimension: 2048))
        let smallImage = try await ImagePreviewLoader().load(url: small.files[0].url)
        try check(smallImage.image.width == 1024 && smallImage.image.height == 2048, "缩小成片尺寸不正确")
        let tiny = try await ColorChecks.fixture(store: store, source: source, name: "tiny.png", orientation: 6)
        let tinyReady = try await coordinator.prepare(coordinator.plan(assetIDs: [tiny.asset.id], mode: .jpeg, maximumDimension: 2048))
        let tinyImage = try await ImagePreviewLoader().load(url: tinyReady.files[0].url)
        try check(tinyImage.image.width == 80 && tinyImage.image.height == 128, "小图被放大")
        try check(try originals.map { try FileHasher.sha256(of: $0) } == hashes, "分享修改原片")
        try check(try await store.annotation(for: ids[0]) == annotation, "分享改变标注")
        try check(try await store.colorSnapshot(assetID: ids[0]).record == saved.record, "分享改变调色记录")
        try check(try await store.matchingAssetCount(AssetQuery()) == beforeCount + 1, "分享缓存被加入图库")
        for ready in [full, small, tinyReady] {
            try await coordinator.finish(id: ready.id, cacheDirectory: ready.cacheDirectory, handedToSystem: false)
            try check(!FileManager.default.fileExists(atPath: ready.cacheDirectory!.path), "未交付成片没有立即清理")
        }
    }

    static func failures() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, source, real) = try await fixture(root)
        let a = try await ColorChecks.fixture(store: store, source: source, name: "good.png")
        let b = try await ColorChecks.fixture(store: store, source: source, name: "fail.png")
        let fake = PhotoShareCoordinator(store: store, cacheRoot: root.appendingPathComponent("Sharing")) { snapshot, _, target in
            if snapshot.asset.fileName == "fail.png" { throw CocoaError(.fileWriteOutOfSpace) }
            try Data("synthetic encoded output".utf8).write(to: target)
        }
        let partial = try await fake.prepare(fake.plan(assetIDs: [a.asset.id, b.asset.id], mode: .jpeg))
        try check(partial.files.count == 1 && partial.issues.count == 1, "磁盘空间错误未逐项报告")
        try await fake.finish(id: partial.id, cacheDirectory: partial.cacheDirectory, handedToSystem: false)
        let raw = try await ColorChecks.fixture(store: store, source: source, name: "unsupported.arw")
        let invalid = try await real.prepare(real.plan(assetIDs: [raw.asset.id], mode: .jpeg))
        try check(invalid.files.isEmpty && !invalid.issues.isEmpty, "RAW 解码错误未隔离")
        try await real.finish(id: invalid.id, cacheDirectory: invalid.cacheDirectory, handedToSystem: false)
        let stalePlan = try await fake.plan(assetIDs: [a.asset.id], mode: .jpeg)
        var edits = ColorAdjustments(); edits.exposure = 1
        _ = try await store.saveColorAdjustments(edits, snapshot: a)
        let stale = try await fake.prepare(stalePlan)
        try check(stale.files.isEmpty && !stale.issues.isEmpty, "分享未冻结调整修订")
        try await fake.finish(id: stale.id, cacheDirectory: stale.cacheDirectory, handedToSystem: false)

        let blocking = PhotoShareCoordinator(store: store, cacheRoot: root.appendingPathComponent("Sharing")) { _, _, target in
            try Data("partial".utf8).write(to: target)
            throw CancellationError()
        }
        do {
            _ = try await blocking.prepare(blocking.plan(assetIDs: [b.asset.id], mode: .jpeg))
            throw ColorChecks.Failure(description: "取消没有传播")
        } catch is CancellationError {}
        try check(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Sharing").path).isEmpty, "取消留下缓存半成品")
        let blockedRoot = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blockedRoot)
        let denied = PhotoShareCoordinator(store: store, cacheRoot: blockedRoot)
        do {
            _ = try await denied.prepare(denied.plan(assetIDs: [b.asset.id], mode: .jpeg))
            throw ColorChecks.Failure(description: "不可写缓存根目录被接受")
        } catch is CocoaError {}
        // The no-overwrite guard must not remove an existing plan directory.
        let collisionPlan = try await fake.plan(assetIDs: [b.asset.id], mode: .jpeg)
        let collision = root.appendingPathComponent("Sharing/share-\(collisionPlan.id.uuidString)")
        try FileManager.default.createDirectory(at: collision, withIntermediateDirectories: true)
        let sentinel = collision.appendingPathComponent("keep")
        try Data("keep".utf8).write(to: sentinel)
        do { _ = try await fake.prepare(collisionPlan); throw ColorChecks.Failure(description: "已有缓存被覆盖") }
        catch is ColorEditError {}
        try check(try Data(contentsOf: sentinel) == Data("keep".utf8), "失败路径删除了既有缓存")
        let gate = Gate()
        let cancellable = PhotoShareCoordinator(store: store, cacheRoot: root.appendingPathComponent("Sharing")) { _, _, target in
            try Data("partial".utf8).write(to: target)
            await gate.enter()
        }
        let pending = try await cancellable.plan(assetIDs: [b.asset.id], mode: .jpeg)
        let task = Task { try await cancellable.prepare(pending) }
        await gate.waitUntilEntered()
        do { _ = try await cancellable.prepare(pending); throw ColorChecks.Failure(description: "并发准备没有被拒绝") }
        catch is ColorEditError {}
        task.cancel(); await gate.release()
        do { _ = try await task.value; throw ColorChecks.Failure(description: "渲染期间取消未生效") }
        catch is CancellationError {}
        let pendingDirectory = root.appendingPathComponent("Sharing/share-\(pending.id.uuidString)")
        try check(!FileManager.default.fileExists(atPath: pendingDirectory.path), "任务取消留下未交付文件")
    }

    actor Gate {
        private var entered = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var continuation: CheckedContinuation<Void, Never>?
        func enter() async {
            entered = true; waiters.forEach { $0.resume() }; waiters = []
            await withCheckedContinuation { continuation = $0 }
        }
        func waitUntilEntered() async {
            if entered { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    @MainActor final class Presenter: PhotoSharePresenting {
        var callbacks: [@MainActor (PhotoShareEvent) -> Void] = []
        var calls = 0, dismissals = 0
        var fail = false
        func show(files: [URL], event: @escaping @MainActor (PhotoShareEvent) -> Void) throws {
            calls += 1
            if fail { throw ColorEditError("injected picker failure") }
            callbacks.append(event)
        }
        func dismiss() { dismissals += 1 }
    }
    @MainActor static func lifecycle() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, source, coordinator) = try await fixture(root)
        let photo = try await ColorChecks.fixture(store: store, source: source, name: "a.png")
        // Retain callbacks even after dismissal for stale-callback testing.
        let presenter = Presenter()
        let sharing = PhotoShareSession(presenter: presenter)
        func install(_ mode: PhotoShareMode, ids: [String]? = nil) async throws -> URL? {
            let prepared = try await coordinator.prepare(coordinator.plan(assetIDs: ids ?? [photo.asset.id], mode: mode))
            try sharing.install(prepared, coordinator: coordinator)
            return prepared.cacheDirectory
        }
        _ = try await install(.original)
        try check(sharing.blocksFileChanges && sharing.requiresExitConfirmation && sharing.canPresent, "待分享原片未持有操作／退出保护")
        sharing.present(); sharing.present()
        try check(presenter.calls == 1 && sharing.phase == .choosing, "重复点击打开多次 picker")
        let old = presenter.callbacks.last!
        old(.cancelled); await sharing.waitForCleanup()
        try check(!sharing.isActive && !sharing.blocksFileChanges && !sharing.requiresExitConfirmation, "picker 取消没有释放状态")
        for event in [PhotoShareEvent.completed, .failed("failed"), .cancelled] {
            _ = try await install(.original)
            sharing.present(); presenter.callbacks.last?(.chosen("测试服务"))
            try check(sharing.phase == .sharing && sharing.blocksFileChanges, "选择服务时过早释放原片")
            presenter.callbacks.last?(event); presenter.callbacks.last?(event)
            await sharing.waitForCleanup()
            try check(sharing.phase == .finished && sharing.prepared == nil && !sharing.blocksFileChanges, "重复终态或失败锁住了文件操作")
        }
        _ = try await install(.original)
        old(.completed); old(.cancelled)
        try check(sharing.phase == .ready && sharing.blocksFileChanges, "过期回调结束了新会话")
        sharing.present(); presenter.callbacks.last?(.chosen("无回调服务"))
        try check(sharing.requiresExitConfirmation, "缺失回调时退出未受保护")
        sharing.end(); await sharing.waitForCleanup()
        try check(!sharing.isActive && sharing.message.contains("不能撤回"), "手动结束错误宣称可以停止外部发送")
        presenter.fail = true
        _ = try await install(.original); sharing.present(); await sharing.waitForCleanup()
        try check(!sharing.isActive && !sharing.blocksFileChanges && sharing.message.contains("无法打开"), "picker 抛错未释放")
        presenter.fail = false
        _ = try await install(.original, ids: [photo.asset.id, "missing"])
        try check(!sharing.canPresent, "部分失败未经同意就可分享")
        sharing.acceptsPartial = true
        try check(sharing.canPresent, "确认成功项后仍不能分享")
        sharing.discardPreparation(); await sharing.waitForCleanup()
        try check(sharing.phase == .idle && !sharing.isActive, "重新准备没有释放旧清单")
        _ = try await install(.original, ids: ["missing"])
        sharing.acceptsPartial = true
        try check(!sharing.canPresent, "全部失败仍打开 picker")
        sharing.end(); await sharing.waitForCleanup()
        let cache = try await install(.jpeg)!
        try check(!sharing.blocksFileChanges && !sharing.requiresExitConfirmation, "成片错误地长期锁定原文件")
        sharing.present(); presenter.callbacks.last?(.chosen("测试服务"))
        try await coordinator.cleanupExpired(now: Date().addingTimeInterval(3 * 86400))
        try check(FileManager.default.fileExists(atPath: cache.path), "活动会话缓存被清理")
        presenter.callbacks.last?(.completed); await sharing.waitForCleanup()
        try await coordinator.cleanupExpired(now: Date().addingTimeInterval(86300))
        try check(FileManager.default.fileExists(atPath: cache.path), "交付系统的缓存未保留 24 小时")
        try await coordinator.cleanupExpired(now: Date().addingTimeInterval(2 * 86400))
        try check(!FileManager.default.fileExists(atPath: cache.path), "过期缓存没有清理")
        let cancelledCache = try await install(.jpeg)!
        sharing.present(); presenter.callbacks.last?(.cancelled); await sharing.waitForCleanup()
        try check(!FileManager.default.fileExists(atPath: cancelledCache.path), "picker 取消的未交付缓存未立即清理")
    }
}
