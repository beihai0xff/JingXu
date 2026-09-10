import Foundation
import GRDB
import JingXuCore

extension ColorChecks {
    @MainActor
    static func editing() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("Catalog.sqlite")
        let store = try CatalogStore(databaseURL: databaseURL)
        let source = SourceRoot(name: "session", bookmarkData: nil, pathHint: root.path)
        try await store.upsertSource(source)
        let first = try await fixture(store: store, source: source, name: "first.png")
        let second = try await fixture(store: store, source: source, name: "second.png", gray: 180)
        let editor = try ColorEditSession(store: store, snapshot: first, saved: {})
        editor.start()
        try await eventually { editor.result != nil && !editor.isRendering }

        editor.change(.exposure, value: 0.5)
        try await eventually { !editor.isDirty && !editor.isSaving && editor.snapshot.revision > 0 }
        try check(try await store.colorSnapshot(assetID: first.asset.id).adjustments.exposure == 0.5, "300ms 自动保存未写入图库")
        try check(editor.history.canUndo, "数字输入自动保存后不能撤销")
        editor.undo(); try check(await editor.flush(), "撤销保存失败")
        try check(editor.adjustments.exposure == 0, "数字输入撤销未恢复原值")
        editor.redo(); try check(await editor.flush(), "重做保存失败")
        try check(editor.adjustments.exposure == 0.5, "重做未恢复调整")

        editor.beginGesture()
        editor.change(.exposure, value: 1)
        editor.change(.exposure, value: 1.5)
        editor.endGesture()
        async let flush1 = editor.flush()
        async let flush2 = editor.flush()
        let saves = await [flush1, flush2]
        try check(saves.allSatisfy { $0 } && editor.saveError == nil, "并发保存出现修订冲突")
        editor.undo(); try check(await editor.flush(), "拖动撤销保存失败")
        try check(editor.adjustments.exposure == 0.5, "一次拖动没有合并为一次撤销")

        let database = try DatabaseQueue(path: databaseURL.path)
        try await database.write { try $0.execute(sql: "CREATE TRIGGER fail_session BEFORE UPDATE ON colorEdits BEGIN SELECT RAISE(ABORT, 'session write failure'); END") }
        editor.change(.contrast, value: 25)
        try check(!(await editor.flush()) && editor.isDirty && editor.saveError != nil && editor.adjustments.contrast == 25, "保存失败未保留草稿或阻止离开")
        try await database.write { try $0.execute(sql: "DROP TRIGGER fail_session") }
        try check(await editor.flush(), "保存失败后不能重试")
        try check(try await store.colorSnapshot(assetID: first.asset.id).adjustments.contrast == 25, "重试没有保存草稿")

        try await database.write { try $0.execute(sql: "CREATE TRIGGER fail_session BEFORE UPDATE ON colorEdits BEGIN SELECT RAISE(ABORT, 'session write failure'); END") }
        editor.change(.contrast, value: 60)
        _ = await editor.flush()
        editor.discardDraft()
        try check(editor.adjustments.contrast == 25 && !editor.isDirty && editor.saveError == nil, "明确放弃没有恢复已保存值")
        try await database.write { try $0.execute(sql: "DROP TRIGGER fail_session") }
        try database.close()

        editor.change(.exposure, value: 4)
        editor.change(.exposure, value: -4)
        editor.change(.exposure, value: 1)
        editor.endGesture()
        try check(await editor.flush(), "最新调整保存失败")
        try await eventually { !editor.isRendering && editor.result != nil }
        let expected = try await ColorImageRenderer.shared.render(editor.snapshot, adjustments: editor.adjustments)
        try check(try SRGBPixels(editor.result!.image).rgba == SRGBPixels(expected.image).rgba, "过期渲染覆盖最新请求")
        editor.comparing = true
        try await eventually { !editor.isRendering }
        let unadjusted = try await ColorImageRenderer.shared.render(editor.snapshot, adjustments: ColorAdjustments())
        try check(try SRGBPixels(editor.result!.image).rgba == SRGBPixels(unadjusted.image).rgba && editor.adjustments.exposure == 1, "原图对比未使用相同解码或改变了参数")

        editor.change(.exposure, value: -2)
        try check(await editor.flush(), "切图前草稿保存失败")
        editor.dispose()
        let next = try ColorEditSession(store: store, snapshot: second, saved: {})
        next.start()
        try await eventually { next.result != nil && !next.isRendering }
        try check(editor.result == nil && next.snapshot.asset.id == second.asset.id, "快速切图后旧结果泄露或图像未释放")
        next.dispose()
    }

    @MainActor
    private static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw Failure(description: "等待编辑会话状态超时")
    }
}
