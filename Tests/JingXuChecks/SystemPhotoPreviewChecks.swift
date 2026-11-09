import Foundation
import GRDB
import JingXuCore

enum SystemPhotoPreviewChecks {
    actor Gate {
        var entered = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            entered = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }
    @MainActor static func run() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("large.png")
        let image = try QualityV2Checks.image(width: 3000, height: 2000) { x, y in
            (UInt8(40 + x % 80), UInt8(30 + y % 90), 50, 255)
        }
        try QualityV2Checks.write(image, to: original, type: .png)
        let photos = (0..<3).map { SystemPhoto(id: "p\($0)", name: "p\($0).png", modifiedAt: Date(timeIntervalSince1970: 1), width: 3000, height: 2000) }
        let client = IsolatedPhotoLibraryClient(root: root, photos: photos.map { ($0, original) })
        let databaseURL = root.appendingPathComponent("photos.sqlite")
        let store = try SystemPhotosStore(url: databaseURL)
        let session = SystemPhotoPreviewSession(client: client, store: store)
        try await session.open(at: 0) { photos[0] }
        try ColorChecks.check(session.image?.image.width == 2048 && session.image?.nativeSize.width == 3000, "小图覆盖了真实像素尺寸")
        try ColorChecks.check(await client.requestedImages.allSatisfy { $0.pixelSize == 2048 }, "普通打开请求了原尺寸")
        let full = try await session.fullImage()
        try ColorChecks.check(full.image.width == 3000 && full.nativeSize.width == 3000, "完整画质请求未恢复原尺寸")
        try await session.open(at: 0, editing: true) { photos[0] }
        guard let editor = session.editor else { throw ColorChecks.Failure(description: "没有进入编辑") }
        try ColorChecks.check(editor.displayQuality == .preview && editor.result?.image.width == 2048, "编辑自动渲染了全尺寸")
        var adjustment = ColorAdjustments(); adjustment.exposure = 0.8
        editor.apply(adjustment)
        try ColorChecks.check(await editor.flush(), "测试草稿保存失败")

        // Failed candidate input leaves the same editor and its undo history alive.
        await client.setPreviewReadHook { stage, id in
            if stage == .editingInput && id == "p1" { throw CocoaError(.fileReadNoPermission) }
        }
        do { try await session.open(at: 1) { photos[1] }; throw ColorChecks.Failure(description: "应当读取失败") }
        catch is CocoaError {}
        try ColorChecks.check(session.editor === editor && session.photo?.id == "p0", "目标失败销毁了当前会话")
        editor.undo()
        try ColorChecks.check(editor.adjustments.exposure == 0, "目标失败清空了撤销历史")
        editor.redo()
        try ColorChecks.check(await editor.flush(), "重做保存失败")

        // Save failure is checked before any candidate read.
        let db = try DatabaseQueue(path: databaseURL.path)
        try await db.write { try $0.execute(sql: "CREATE TRIGGER fail_draft BEFORE INSERT ON drafts BEGIN SELECT RAISE(ABORT, 'disk full'); END") }
        adjustment.exposure = 1; editor.apply(adjustment)
        let readsBefore = await client.requestedEditingInputs.count
        do { try await session.open(at: 1) { photos[1] }; throw ColorChecks.Failure(description: "应当保存失败") }
        catch is ColorEditError {}
        try ColorChecks.check(session.editor === editor && editor.adjustments.exposure == 1, "保存失败丢失内存调整")
        try ColorChecks.check(await client.requestedEditingInputs.count == readsBefore, "保存失败后仍读取目标")
        try await db.write { try $0.execute(sql: "DROP TRIGGER fail_draft") }
        try ColorChecks.check(await editor.flush(), "解除失败后不能保存")
        try db.close()

        _ = try await session.fullImage()
        editor.beginComparison()
        try await eventually { !editor.isRendering }
        let comparisonShare = try await session.fullImage()
        try ColorChecks.check(!editor.comparing && (try ColorChecks.brightness(comparisonShare.image)) > 100,
                              "分享复用了编辑前对比画面")

        await client.setPreviewReadHook(nil)
        try await session.finishEditing()
        try ColorChecks.check(session.editor == nil && session.hasDraft && session.image?.image.width == 3000, "完成编辑未保留已请求的完整草稿预览")
        let draftBrightness = try ColorChecks.brightness(session.image!.image)
        try ColorChecks.check(await session.close(), "关闭失败")
        let restarted = SystemPhotoPreviewSession(client: client, store: try SystemPhotosStore(url: databaseURL))
        try await restarted.open(at: 0) { photos[0] }
        try ColorChecks.check(restarted.hasDraft && restarted.editor == nil, "重启后没有默认显示本机草稿")
        try ColorChecks.check(abs(try ColorChecks.brightness(restarted.image!.image) - draftBrightness) < 0.1, "重启后显示了系统原图")
        let shared = try await restarted.fullImage()
        try ColorChecks.check(shared.image.width == 3000 && (try ColorChecks.brightness(shared.image)) > 100, "草稿分享使用小图或未调整版本")

        await client.setPreviewReadHook { stage, id in
            if stage == .image && id == "p1" { throw CocoaError(.fileReadCorruptFile) }
        }
        do { try await restarted.open(at: 1) { photos[1] }; throw ColorChecks.Failure(description: "应当预览读取失败") }
        catch is CocoaError {}
        try ColorChecks.check(restarted.photo?.id == "p0" && restarted.hasDraft && restarted.image?.image.width == 3000,
                              "目标预览失败替换了当前完整草稿")

        // A late cancelled B cannot commit over C. The second candidate waits for B cleanup.
        let gate = Gate()
        await client.setPreviewReadHook { stage, id in if stage == .image && id == "p1" { await gate.wait() } }
        let b = Task { try await restarted.open(at: 1) { photos[1] } }
        try await eventually { await gate.entered }
        let c = Task { try await restarted.open(at: 2) { photos[2] } }
        try await eventually { restarted.pendingIndex == 2 }
        await gate.release()
        do { try await b.value; throw ColorChecks.Failure(description: "过期请求未取消") } catch is CancellationError {}
        try await c.value
        try ColorChecks.check(restarted.photo?.id == "p2" && restarted.index == 2, "过期完成覆盖目标")
        try ColorChecks.check(await client.cancelledPreviewReads == 1, "取消未传播到客户端")
        await client.setPreviewReadHook(nil)

        try await client.changeExternally(id: "p0")
        let changed = try await client.photos(ids: ["p0"], albumID: nil)[0]
        do { try await restarted.open(at: 0) { changed }; throw ColorChecks.Failure(description: "冲突草稿被套用") }
        catch is ColorEditError {}
        try ColorChecks.check(restarted.photo?.id == "p2" && restarted.failedPhoto?.id == "p0", "冲突没有保留当前画面和目标")
        try ColorChecks.check(try await store.draft(id: "p0") != nil, "冲突删除了草稿")
        try ColorChecks.check(await restarted.close(), "退出失败")
        try ColorChecks.check(await client.activeInputCount == 0, "候选或当前输入泄漏")
        let created = await client.createdInputCount, released = await client.releasedInputCount
        try ColorChecks.check(created == released, "编辑输入没有配对释放")
        try ColorChecks.check(await client.mutations == 0, "浏览或草稿操作更新了系统照片")
        try await orientedCrop(root: root)
    }

    @MainActor static func orientedCrop(root: URL) async throws {
        let file = root.appendingPathComponent("portrait.png")
        let image = try QualityV2Checks.image(width: 128, height: 80) { _, _ in (60, 80, 100, 255) }
        try QualityV2Checks.write(image, to: file, type: .png, orientation: 6)
        let photo = SystemPhoto(id: "portrait", name: "portrait.png", width: 80, height: 128)
        let client = IsolatedPhotoLibraryClient(root: root, photos: [(photo, file)])
        let session = SystemPhotoPreviewSession(client: client, store: try SystemPhotosStore(url: root.appendingPathComponent("portrait.sqlite")))
        try await session.open(at: 0) { photo }
        try ColorChecks.check(session.image?.nativeSize == CGSize(width: 80, height: 128), "方向后的真实尺寸错误")
        try await session.open(at: 0, editing: true) { photo }
        var values = ColorAdjustments(); values.crop = CropAdjustment(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        session.editor?.apply(values)
        let full = try await session.fullImage()
        try ColorChecks.check(full.nativeSize == CGSize(width: 40, height: 64) && full.image.width == 40 && full.image.height == 64,
                              "100% 或分享没有使用方向及裁剪后的真实像素")
        let closed = await session.close(), activeInputs = await client.activeInputCount
        try ColorChecks.check(closed && activeInputs == 0, "方向检查未释放输入")
    }
    @MainActor static func eventually(_ condition: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<1000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw ColorChecks.Failure(description: "等待预览检查状态超时")
    }
}
