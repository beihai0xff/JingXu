import Foundation
import GRDB
import JingXuCore

enum SystemPhotosChecks {
    private struct Fixture {
        let root: URL
        let local: CatalogStore
        let store: SystemPhotosStore
        let client: IsolatedPhotoLibraryClient
        let coordinator: SystemPhotosCoordinator
        let snapshot: ColorEditSnapshot
        let photos: [SystemPhoto]
        var database: URL { root.appendingPathComponent("SystemPhotos.sqlite") }
    }
    private static func fixture(count: Int = 4) async throws -> Fixture {
        let root = try ColorChecks.root()
        let local = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        let source = SourceRoot(name: "系统照片测试来源", bookmarkData: nil, pathHint: root.path)
        try await local.upsertSource(source)
        let snapshot = try await ColorChecks.fixture(store: local, source: source, name: "original.png")
        let url = root.appendingPathComponent("original.png")
        let photos = (0..<count).map { index in
            SystemPhoto(id: "photo-\(index)", name: "照片-\(index).png", modifiedAt: Date(timeIntervalSince1970: 10),
                capturedAt: Date(timeIntervalSince1970: Double(index)), width: 128, height: 80, isLivePhoto: index == count - 1)
        }
        let client = IsolatedPhotoLibraryClient(root: root, photos: photos.map { ($0, url) })
        let store = try SystemPhotosStore(url: root.appendingPathComponent("SystemPhotos.sqlite"))
        let coordinator = SystemPhotosCoordinator(client: client, store: store, localStore: local,
            temporaryRoot: root.appendingPathComponent("Working"), analyzer: DefaultQualityAnalyzer(featureExtractor: { _ in nil }))
        return Fixture(root: root, local: local, store: store, client: client, coordinator: coordinator, snapshot: snapshot, photos: photos)
    }
    private static func check(_ value: Bool, _ reason: String) throws { try ColorChecks.check(value, reason) }
    private static func fails(isolation: isolated (any Actor)? = #isolation, _ work: () async throws -> Void) async throws {
        do { try await work() } catch { return }
        throw ColorChecks.Failure(description: "预期失败的系统照片操作却成功了")
    }
    static func run() async throws {
        try await pagingAndAlbums()
        try await uploadsAndReceipts()
        try await editingAndConflicts()
        try await analysisAndCancellation()
        try await isolationAndCleanup()
    }

    private static func pagingAndAlbums() async throws {
        let f = try await fixture(count: 2_005); defer { try? FileManager.default.removeItem(at: f.root) }
        await f.client.setAuthorization(.denied)
        try check(await f.client.authorization(request: true) == .denied, "拒绝权限没有保留")
        try await fails { _ = try await f.client.page(albumID: nil, offset: 0, limit: 200) }
        await f.client.setAuthorization(.authorized)
        await f.client.setAuthorization(.limited)
        try check(await f.client.authorization(request: false).canRead, "部分照片授权被当成完全拒绝")
        await f.client.setAuthorization(.authorized)
        var selection = PhotoSelectionState()
        for offset in stride(from: 0, to: 2_005, by: 200) {
            let page = try await f.client.page(albumID: nil, offset: offset, limit: 900)
            try check(page.items.count == min(200, 2_005 - offset) && page.total == 2_005, "系统照片分页未限制为 200")
            selection.selectAll(page.items.map(\.id))
        }
        let selected = try await f.client.photos(ids: selection.selectedIDs.sorted(), albumID: nil)
        try check(selected.count == 2_005, "跨页显式选择丢失")
        let boundary = try await f.client.page(albumID: nil, offset: 200, limit: 1).items[0]
        try check(try await f.client.index(id: boundary.id, albumID: nil) == 200, "单图跨页导航位置错误")
        try await f.coordinator.mutate(SystemPhotoMutationPlan(operation: .createAlbum("独立相册")))
        let album = try await f.client.albums()[0]
        let fixed = SystemPhotoMutationPlan(operation: .addToAlbum(id: album.id), photos: selected, album: album)
        selection.clear()
        try await f.coordinator.mutate(fixed)
        var current = try await f.client.albums()[0]
        try check(current.count == 2_005, "固定选择被界面当前页或后续选择覆盖")
        let subset = Array(selected.prefix(2))
        try await f.coordinator.mutate(SystemPhotoMutationPlan(operation: .removeFromAlbum(id: album.id), photos: subset, album: current))
        try check(try await f.client.photos(ids: subset.map(\.id), albumID: nil).count == 2, "移出相册删除了照片")
        try check(try await f.client.photos(ids: subset.map(\.id), albumID: album.id).isEmpty, "相册移出未更新范围")
        current = try await f.client.albums()[0]
        let staleDelete = SystemPhotoMutationPlan(operation: .deleteAlbum(id: album.id), album: current)
        try await f.coordinator.mutate(SystemPhotoMutationPlan(operation: .renameAlbum(id: album.id, name: "改名"), album: current))
        try await fails { try await f.coordinator.mutate(staleDelete) }
        current = try await f.client.albums()[0]
        try await f.coordinator.mutate(SystemPhotoMutationPlan(operation: .deleteAlbum(id: album.id), album: current))
        try check(try await f.client.page(albumID: nil, offset: 0, limit: 200).total == 2_005, "删除相册删除了图库照片")
        let deletion = SystemPhotoMutationPlan(operation: .deletePhotos, photos: subset)
        try await f.coordinator.mutate(deletion)
        try check(try await f.client.index(id: subset[0].id, albumID: nil) == nil, "删除后预览仍保留错误位置")
        try check(try await f.client.page(albumID: nil, offset: 0, limit: 200).total == 2_003, "删除范围不等于固定清单")
        try check(try FileHasher.sha256(of: f.root.appendingPathComponent("original.png")).count == 64, "系统删除接触了本地原片")
        let count = await f.client.mutations
        try await fails { try await f.coordinator.mutate(deletion) }
        try check(await f.client.mutations == count, "重复删除清单执行了两次")
    }

    private static func uploadsAndReceipts() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = f.root.appendingPathComponent("original.png"), digest = try FileHasher.sha256(of: source)
        try await f.coordinator.mutate(SystemPhotoMutationPlan(operation: .createAlbum("接收相册")))
        let album = try await f.client.albums()[0]
        var plan: SystemPhotoUpload? = try await f.coordinator.prepareUpload(snapshots: [f.snapshot], mode: .original, album: album)
        try check(plan!.files[0].url.pathExtension == "png" && FileHasher.sha256(of: plan!.files[0].url) == digest, "原片上传发生转码")
        let temporary = plan!.workspace.directory
        try await f.coordinator.upload(plan!)
        try check(try await f.client.page(albumID: album.id, offset: 0, limit: 200).total == 1, "创建照片未加入目标相册")
        let count = await f.client.mutations
        try await fails { try await f.coordinator.upload(plan!) }
        try check(await f.client.mutations == count, "重复上传未被提交记录拦截")
        plan = nil
        try check(!FileManager.default.fileExists(atPath: temporary.path), "上传临时文件未随清单释放")
        var values = ColorAdjustments(); values.exposure = 1
        let edited = try await f.local.saveColorAdjustments(values, snapshot: f.snapshot)
        let jpeg = try await f.coordinator.prepareUpload(snapshots: [edited], mode: .jpeg, album: nil)
        try check(jpeg.files[0].url.pathExtension == "jpg", "成片未使用 JPEG")
        let prepared = try await ImagePreviewLoader().load(url: jpeg.files[0].url)
        let original = try await ImagePreviewLoader().load(url: source)
        try check(try ColorChecks.brightness(prepared.image) > ColorChecks.brightness(original.image), "上传成片未复用调色")
        values.exposure = -1
        _ = try await f.local.saveColorAdjustments(values, snapshot: edited)
        try await fails { try await f.coordinator.upload(jpeg) }
        let originalPlan = try await f.coordinator.prepareUpload(snapshots: [edited], mode: .original, album: nil)
        await f.client.setAuthorization(.denied)
        try await fails { try await f.coordinator.upload(originalPlan) }
        await f.client.setAuthorization(.authorized)
        let unknown = try await f.coordinator.prepareUpload(snapshots: [edited], mode: .original, album: nil)
        await f.client.failAfterNextCommit("模拟结果回读中断")
        try await fails { try await f.coordinator.upload(unknown) }
        let records = try await f.store.unresolvedWrites()
        try check(records.count == 1 && records[0].createdIDs.count == 1 && records[0].state == "unknown", "未知提交未保留创建标识")
        let reopened = try SystemPhotosStore(url: f.database)
        let restarted = SystemPhotosCoordinator(client: f.client, store: reopened, localStore: f.local, temporaryRoot: f.root)
        let blocked = try await restarted.prepareUpload(snapshots: [edited], mode: .original, album: nil)
        try await fails { try await restarted.upload(blocked) }
        try await reopened.finishWrite(id: unknown.id, state: "acknowledged")
        let database = try DatabaseQueue(path: f.database.path)
        try await database.write { try $0.execute(sql: "CREATE TRIGGER full_disk BEFORE INSERT ON writes BEGIN SELECT RAISE(ABORT, 'database or disk is full'); END") }
        let before = await f.client.mutations
        try await fails { try await restarted.upload(blocked) }
        try check(await f.client.mutations == before, "本机记录写入失败后仍提交到系统")
        try await database.write { try $0.execute(sql: "DROP TRIGGER full_disk; CREATE TRIGGER fail_receipt BEFORE UPDATE OF state ON writes WHEN NEW.state = 'completed' BEGIN SELECT RAISE(ABORT, 'disk full after commit'); END") }
        try await fails { try await restarted.upload(blocked) }
        try check(try await reopened.unresolvedWrites().count == 1, "系统提交后日志失败被标成可重试失败")
        try await database.write { try $0.execute(sql: "DROP TRIGGER fail_receipt") }
        try await reopened.finishWrite(id: blocked.id, state: "acknowledged")
        let replaced = try await restarted.prepareUpload(snapshots: [edited], mode: .original, album: nil)
        try Data("replaced source".utf8).write(to: source, options: .atomic)
        try await fails { try await restarted.upload(replaced) }
        try check(digest != FileHasher.sha256(of: source), "替换源文件测试未生效")
    }

    @MainActor private static func editingAndConflicts() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let photo = f.photos[0], original = f.root.appendingPathComponent("original.png"), digest = try FileHasher.sha256(of: original)
        let repository = SystemPhotoEditingRepository(store: f.store, client: f.client)
        let input = try await f.client.editingInput(photo: photo)
        let editor = try ColorEditSession(repository: repository, snapshot: await repository.open(input), saved: {})
        editor.change(.exposure, value: 0.7)
        try check(await editor.flush(), "本机系统照片草稿无法保存")
        try check(await f.client.mutations == 0, "滑动参数直接写入了 PhotoKit")
        let draft = try await f.store.draft(id: photo.id)
        try check(draft?.adjustments.exposure == 0.7, "系统照片草稿丢失")
        let secondInput = try await f.client.editingInput(photo: photo)
        let reopened = try await repository.open(secondInput)
        try check(reopened.adjustments.exposure == 0.7, "重开本机草稿不一致")
        await f.client.releaseEditingInput(token: secondInput.token)
        await f.client.setAuthorization(.denied)
        editor.change(.contrast, value: 12)
        try check(await editor.flush(), "撤销授权导致本机草稿丢失")
        try await fails { try await f.coordinator.saveEdit(editor.snapshot) }
        await f.client.setAuthorization(.authorized)
        let database = try DatabaseQueue(path: f.database.path)
        try await database.write { try $0.execute(sql: "CREATE TRIGGER fail_draft BEFORE INSERT ON drafts BEGIN SELECT RAISE(ABORT, 'disk full'); END") }
        editor.change(.contrast, value: 20)
        try check(!(await editor.flush()) && editor.isDirty, "草稿保存失败没有阻止切图")
        try await database.write { try $0.execute(sql: "DROP TRIGGER fail_draft") }
        try check(await editor.flush(), "草稿失败后无法继续保存")
        try await editor.withSavedSnapshot { frozen in
            let before = editor.adjustments
            editor.resetAll(); editor.undo(); editor.change(.exposure, value: 4)
            try check(editor.adjustments == before, "提交期间手动调整越过冻结修订")
            try await f.coordinator.saveEdit(frozen)
        }
        try check(try await f.store.draft(id: photo.id) == nil, "提交成功未清理相应草稿")
        let updated = try await f.client.photos(ids: [photo.id], albumID: nil)[0]
        let saved = try await f.client.editingInput(photo: updated)
        try check(saved.adjustments == editor.adjustments && updated.id == photo.id, "调色没有更新同一照片或未恢复参数")
        try check(try FileHasher.sha256(of: original) == digest, "调色改写了原片")
        editor.dispose()
        let next = try ColorEditSession(repository: repository, snapshot: await repository.open(saved), saved: {})
        next.change(.exposure, value: 0.3); try check(await next.flush(), "冲突前草稿未保存")
        try await f.client.changeExternally(id: photo.id)
        try await fails { try await f.coordinator.saveEdit(next.snapshot) }
        try check(try await f.store.draft(id: photo.id)?.adjustments.exposure == 0.3, "外部编辑冲突丢失本机草稿")
        let external = try await f.client.photos(ids: [photo.id], albumID: nil)[0]
        let externalInput = try await f.client.editingInput(photo: external)
        try await fails { _ = try await repository.open(externalInput) }
        try await fails { _ = try await f.client.editingInput(photo: f.photos.last!) }
        try await f.coordinator.mutate(SystemPhotoMutationPlan(operation: .deletePhotos, photos: [external]))
        try await fails { try await f.coordinator.saveEdit(next.snapshot) }
        next.dispose()
        try check(try await f.store.draft(id: photo.id) != nil, "系统删除导致本机草稿被当缓存清除")

        let otherURL = f.root.appendingPathComponent("other-app.jpg")
        var otherAdjustments = ColorAdjustments(); otherAdjustments.exposure = -1
        try await ColorImageRenderer.shared.encode(f.snapshot, adjustments: otherAdjustments, format: .jpeg, to: otherURL)
        try await f.client.editInAnotherApp(id: f.photos[1].id, renderedURL: otherURL)
        let other = try await f.client.photos(ids: [f.photos[1].id], albumID: nil)[0]
        let base = try await f.client.editingInput(photo: other)
        try check(base.usesRenderedBase && !base.renderInput.isRAW && base.adjustments == ColorAdjustments(), "外部成片底图被当成 RAW 或重复套用调整")
        let baseDigest = try FileHasher.sha256(of: base.renderInput.url)
        var own = ColorAdjustments(); own.contrast = 14
        let draftOnRendered = try await repository.saveColorAdjustments(own, snapshot: repository.open(base))
        try await f.coordinator.saveEdit(draftOnRendered)
        let after = try await f.client.photos(ids: [other.id], albumID: nil)[0]
        let resumed = try await f.client.editingInput(photo: after)
        try check(resumed.usesRenderedBase && resumed.adjustments == own && FileHasher.sha256(of: resumed.renderInput.url) == baseDigest,
            "再次编辑没有保留本次编辑前的成片底图")
        let reset = try await repository.saveColorAdjustments(ColorAdjustments(), snapshot: repository.open(resumed))
        try await f.coordinator.saveEdit(reset)
        try check(try FileHasher.sha256(of: original) == digest, "重置镜序调整损坏 Apple 原片")
    }

    private static func analysisAndCancellation() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let chosen = [f.photos[0], f.photos[1], f.photos[3]]
        await f.client.failDownload(id: chosen[1].id, message: "iCloud 下载失败")
        let job = SystemPhotoAnalysisJob(photos: chosen)
        try await f.coordinator.analyze(job)
        let saved = try await f.store.jobs()[0]
        try check(saved.completed == [chosen[0].id, chosen[2].id] && saved.failures.count == 1, "下载失败被统计为分析完成")
        try check(try await f.store.analysis(id: chosen[1].id) == nil, "下载失败被标为质量正常")
        try check(await f.client.requestedOriginals == chosen.map(\.id), "分析越过确认范围或未串行下载")
        try await f.store.review(id: chosen[0].id, state: .ignored)
        await f.client.failDownload(id: chosen[1].id, message: nil)
        try await f.coordinator.analyze(saved)
        try check(try await f.store.jobs()[0].remaining.isEmpty, "继续分析未补齐失败项")
        try check(await f.client.requestedOriginals == chosen.map(\.id) + [chosen[1].id], "继续分析重复下载已完成原片")
        try await f.coordinator.analyze(SystemPhotoAnalysisJob(photos: [chosen[0]]))
        try check(try await f.store.analysis(id: chosen[0].id)?.suggestionState == .ignored, "重算覆盖了人工审核")
        await f.client.delayDownloads(.seconds(2))
        let paused = SystemPhotoAnalysisJob(photos: [f.photos[2]])
        let before = await f.client.requestedOriginals.count
        let task = Task { try await f.coordinator.analyze(paused) }
        for _ in 0..<100 {
            if await f.client.requestedOriginals.count > before { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await fails { try await f.coordinator.mutate(SystemPhotoMutationPlan(operation: .deletePhotos, photos: [f.photos[2]])) }
        task.cancel()
        do { try await task.value; throw ColorChecks.Failure(description: "分析没有响应取消") } catch is CancellationError {}
        let interrupted = try await f.store.jobs().first { $0.id == paused.id }!
        try check(interrupted.cancelled && interrupted.completed.isEmpty, "取消后没有持久化未完成队列")
        let reopened = try SystemPhotosStore(url: f.database)
        await f.client.delayDownloads(.zero)
        let resumed = SystemPhotosCoordinator(client: f.client, store: reopened, localStore: f.local, temporaryRoot: f.root,
            analyzer: DefaultQualityAnalyzer(featureExtractor: { _ in nil }))
        try await resumed.analyze(interrupted)
        try check(try await reopened.jobs().first { $0.id == paused.id }!.remaining.isEmpty, "重启后无法继续分析")
        let items = [SimilarBurstItem(id: "a", date: Date(timeIntervalSince1970: 1), camera: "A", feature: Data([1])),
                     SimilarBurstItem(id: "b", date: Date(timeIntervalSince1970: 2), camera: "A", feature: Data([2])),
                     SimilarBurstItem(id: "c", date: Date(timeIntervalSince1970: 3), camera: "B", feature: Data([3]))]
        try check(try SimilarBurstGrouping.groups(items, distance: { _, _ in 0.1 }) == [["a", "b"]], "相似分组未复用相机隔离或泄露批次范围")
    }

    private static func isolationAndCleanup() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        var input: ColorRenderInput? = try await f.client.original(photo: f.photos[0])
        let path = input!.workspace!.directory
        input = nil
        try check(!FileManager.default.fileExists(atPath: path.path), "分析原片临时目录未释放")
        let abandonedRoot = f.root.appendingPathComponent("Abandoned")
        let orphan = abandonedRoot.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try PhotoWorkspace.removeAbandoned(in: abandonedRoot)
        try check(!FileManager.default.fileExists(atPath: orphan.path), "重启未回收中断遗留的工作目录")
        let link = f.root.appendingPathComponent("UnsafeWorking")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: abandonedRoot)
        try await fails { try PhotoWorkspace.removeAbandoned(in: link) }
        let edit = try await f.client.editingInput(photo: f.photos[0])
        await f.client.simulateUnavailable()
        try await fails { try await f.client.saveEdit(input: edit, adjustments: ColorAdjustments(), renderedURL: edit.renderInput.url) }
        let previous = ProcessInfo.processInfo.environment["JINGXU_UI_TEST_ROOT"]
        setenv("JINGXU_UI_TEST_ROOT", f.root.path, 1)
        defer { if let previous { setenv("JINGXU_UI_TEST_ROOT", previous, 1) } else { unsetenv("JINGXU_UI_TEST_ROOT") } }
        try await fails { _ = try ApplePhotoLibraryClient(temporaryRoot: f.root) }
        try check(await f.client.mutations == 0, "隔离或图库切换测试访问了真实写入路径")
    }
}
