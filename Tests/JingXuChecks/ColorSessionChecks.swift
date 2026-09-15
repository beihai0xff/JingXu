import Foundation
import GRDB
import JingXuCore

extension ColorChecks {
    @MainActor
    static func editing() async throws {
        try histogramDragging()
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

        editor.redo(); try check(await editor.flush(), "拖动重做保存失败")
        try check(editor.adjustments.exposure == 1.5, "拖动重做未恢复终值")
        let reopened = try ColorEditSession(store: store, snapshot: await store.colorSnapshot(assetID: first.asset.id), saved: {})
        try check(reopened.adjustments.exposure == 1.5, "重开未恢复拖动结果")
        reopened.dispose()
        editor.beginGesture(); editor.endGesture()
        editor.undo(); try check(await editor.flush(), "无变化手势之后撤销失败")
        try check(editor.adjustments.exposure == 0.5, "无变化手势产生额外撤销记录")

        let database = try DatabaseQueue(path: databaseURL.path)
        try await database.write { try $0.execute(sql: "CREATE TRIGGER fail_session BEFORE UPDATE ON colorEdits BEGIN SELECT RAISE(ABORT, 'session write failure'); END") }
        editor.beginGesture()
        editor.change(.contrast, value: 25)
        editor.endGesture()
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
        let beforeComparison = editor.result!
        let comparisonRevision = editor.snapshot.revision
        let comparisonVersion = editor.editVersion
        editor.beginComparison()
        try await eventually { !editor.isRendering }
        let unadjusted = try await ColorImageRenderer.shared.render(editor.snapshot, adjustments: ColorAdjustments())
        try check(try SRGBPixels(editor.result!.image).rgba == SRGBPixels(unadjusted.image).rgba && editor.adjustments.exposure == 1, "原图对比未使用相同解码或改变了参数")

        editor.endComparison()
        try check(!editor.comparing && editor.result?.image === beforeComparison.image, "松开对比未立即恢复成片")
        try await eventually { !editor.isRendering }
        try check(editor.editVersion == comparisonVersion && editor.snapshot.revision == comparisonRevision && !editor.isDirty,
                  "原图对比改变调整或保存修订")
        for _ in 0..<10 { editor.beginComparison(); editor.endComparison() }
        try await eventually { !editor.isRendering }
        try check(!editor.comparing && (try SRGBPixels(editor.result!.image).rgba) == (try SRGBPixels(expected.image).rgba),
                  "快速按下松开后原图结果覆盖成片")
        editor.beginComparison()
        editor.change(.exposure, value: -2)
        try check(!editor.comparing, "修改参数未结束原图对比")
        try check(await editor.flush(), "切图前草稿保存失败")
        editor.dispose()
        let disposedValues = editor.adjustments
        editor.beginGesture(); editor.change(.exposure, value: 5); editor.endGesture()
        try check(editor.adjustments == disposedValues, "退出会话仍接受迟到手势")
        let next = try ColorEditSession(store: store, snapshot: second, saved: {})
        next.start()
        try await eventually { next.result != nil && !next.isRendering }
        try check(editor.result == nil && next.snapshot.asset.id == second.asset.id, "快速切图后旧结果泄露或图像未释放")
        next.beginComparison()
        next.dispose()
        next.endComparison(); next.beginComparison()
        try check(!next.comparing && next.result == nil, "退出会话后对比手势恢复了旧图")
    }

    private static func histogramDragging() throws {
        for (index, parameter) in HistogramDrag.parameters.enumerated() {
            try check(HistogramDrag.parameter(at: Double(index * 100), width: 500) == parameter, "直方图分区边界错误")
            let drag = HistogramDrag(startX: Double(index * 100 + 50), width: 500, initialValue: 0)!
            let scale = parameter == .exposure ? 5.0 : 100.0
            try check(drag.value(translation: 500) == scale && drag.value(translation: -500) == -scale, "拖动方向或灵敏度错误")
            try check(drag.parameter == parameter, "跨区拖动改变参数")
            try check(drag.value(translation: 100_000) == parameter.range(isRAW: false).upperBound, "拖动未限制上界")
            try check(drag.value(translation: -100_000) == parameter.range(isRAW: false).lowerBound, "拖动未限制下界")
        }
        try check(HistogramDrag.parameter(at: 500, width: 500) == .whites, "最右边界错误")
        try check(HistogramDrag.parameter(at: 0, width: 0) == nil && HistogramDrag.parameter(at: .nan, width: 500) == nil &&
            HistogramDrag(startX: 0, width: .infinity, initialValue: 0) == nil, "无效尺寸未拒绝")
        let exposure = HistogramDrag(startX: 250, width: 500, initialValue: 0.5)!
        try check(exposure.value(translation: 1.4) == 0.51 && exposure.value(translation: .nan) == 0.5, "曝光精度或无效位移错误")
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
