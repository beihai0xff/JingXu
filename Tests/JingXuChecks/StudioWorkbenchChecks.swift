import AppKit
import CoreGraphics
import Foundation
import JingXuCore
import SwiftUI

@MainActor
enum StudioWorkbenchChecks {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(description: message) }
    }

    static func run() async throws {
        try checkPreferencesAndAppearance()
        try checkStageResolutionAndSidebarMemory()
        try checkSliderGeometry()
        try checkKeyboardMatrix()
        try checkDarkroomCanvasAndSquareThumbnail()
        try checkHoverCheckmarkAndLargeScopeSelection()
    }

    private static func checkPreferencesAndAppearance() throws {
        try check(AppAppearanceMode.defaultValue == .darkroom, "默认外观应为专业暗房深色")
        try check(AppAppearanceMode.darkroom.forcesDarkStage(for: .grid), "暗房模式在网格态应锁定深色")
        try check(!AppAppearanceMode.systemWithDarkroomStage.forcesDarkStage(for: .grid), "跟随系统模式在网格态不应强制深色")
        for stage in [StudioStageMode.loupe, .compare, .develop] {
            try check(AppAppearanceMode.systemWithDarkroomStage.forcesDarkStage(for: stage), "看片与调色舞台必须强制暗房色阶：\(stage)")
        }

        try check(GridAspectMode.defaultValue == .aspectFit, "默认网格画幅应为原比例框")
        try check(GridAspectMode.aspectFit.gridSpacing == 10 && GridAspectMode.squareFill.gridSpacing == 6, "双画幅间距不符合规范")

        let suiteName = "app.jingxu.checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try check(AppAppearanceMode.load(from: defaults) == .darkroom, "未存储时外观默认值错误")
        AppAppearanceMode.systemWithDarkroomStage.save(to: defaults)
        try check(AppAppearanceMode.load(from: defaults) == .systemWithDarkroomStage, "外观偏好未持久化")

        try check(GridAspectMode.load(from: defaults) == .aspectFit, "未存储时画幅默认值错误")
        GridAspectMode.squareFill.save(to: defaults)
        try check(GridAspectMode.load(from: defaults) == .squareFill, "画幅偏好未持久化")
    }

    private static func checkStageResolutionAndSidebarMemory() throws {
        try check(StudioStageMode.resolve(hasPreview: false, isComparing: false, isEditing: false) == .grid, "网格阶段派生错误")
        try check(StudioStageMode.resolve(hasPreview: true, isComparing: false, isEditing: false) == .loupe, "单图阶段派生错误")
        try check(StudioStageMode.resolve(hasPreview: true, isComparing: true, isEditing: false) == .compare, "对比阶段派生错误")
        try check(StudioStageMode.resolve(hasPreview: true, isComparing: false, isEditing: true) == .develop, "调色阶段派生错误")

        var sidebar = StudioSidebarMemory(userPreferredVisible: true)
        try check(sidebar.isSidebarVisible, "初始侧栏应可见")
        sidebar.transition(from: .loupe, to: .develop)
        try check(!sidebar.isSidebarVisible && sidebar.userPreferredVisible, "进入调色应自动收起左栏并保留用户偏好")
        sidebar.setManualVisibility(true, in: .develop)
        try check(sidebar.isSidebarVisible && sidebar.userPreferredVisible, "调色中允许手动临时展开左栏")
        sidebar.setManualVisibility(false, in: .grid)
        try check(!sidebar.isSidebarVisible && !sidebar.userPreferredVisible, "网格态手动收起应更新用户偏好")
        sidebar.transition(from: .grid, to: .develop)
        sidebar.transition(from: .develop, to: .grid)
        try check(!sidebar.isSidebarVisible, "退出调色应恢复进入前的收起状态")
    }

    private static func checkSliderGeometry() throws {
        let exposureZero = DarkroomSliderGeometry(parameter: .exposure, value: 0, isRAW: true)
        try check(abs(exposureZero.thumbFraction - 0.5) < 0.0001, "曝光 0 EV 应居中")
        try check(exposureZero.zeroFraction == 0.5 && exposureZero.fillWidth == 0, "曝光 0 EV 双极填充应为 0")

        let exposurePos = DarkroomSliderGeometry(parameter: .exposure, value: 2.5, isRAW: true)
        try check(abs(exposurePos.thumbFraction - 0.75) < 0.0001, "曝光 +2.5 EV 位置错误")
        try check(abs(exposurePos.fillStart - 0.5) < 0.0001 && abs(exposurePos.fillWidth - 0.25) < 0.0001, "曝光正向填充错误")

        let exposureNeg = DarkroomSliderGeometry(parameter: .exposure, value: -1.0, isRAW: false)
        try check(abs(exposureNeg.thumbFraction - 0.4) < 0.0001, "曝光 -1.0 EV 位置错误")
        try check(abs(exposureNeg.fillStart - 0.4) < 0.0001 && abs(exposureNeg.fillWidth - 0.1) < 0.0001, "曝光负向填充错误")

        let contrast = DarkroomSliderGeometry(parameter: .contrast, value: 0, isRAW: false)
        try check(contrast.value(forFraction: 0.25) == -50, "对比度 25% 位置应映射为 -50")
        try check(contrast.value(forFraction: -0.5) == -100 && contrast.value(forFraction: 1.5) == 100, "越界拖动必须钳制")

        let rawTemp = DarkroomSliderGeometry(parameter: .temperature, value: 6500, isRAW: true)
        try check(rawTemp.zeroFraction == nil, "RAW 绝对色温不应使用中心双极零点")
        try check(rawTemp.value(forFraction: 0) == 2000 && rawTemp.value(forFraction: 1) == 50000, "RAW 色温端点映射错误")
    }

    private static func checkKeyboardMatrix() throws {
        // Grid shortcuts
        try check(StudioKeyRouter.route(code: 49, text: " ", stage: .grid, selectionCount: 1) == .openLoupe, "网格空格应打开单图")
        try check(StudioKeyRouter.route(code: 14, text: "e", stage: .grid, selectionCount: 1) == .openLoupe, "网格 E 应打开单图")
        try check(StudioKeyRouter.route(code: 8, text: "c", stage: .grid, selectionCount: 1) == nil, "仅选 1 张时 C 不应进入双图对比")
        try check(StudioKeyRouter.route(code: 8, text: "c", stage: .grid, selectionCount: 2) == .enterCompare, "选中 2 张时 C 应进入双图对比")
        try check(StudioKeyRouter.route(code: 2, text: "d", stage: .grid, selectionCount: 1) == .enterDevelop, "网格 D 应进入调色")
        try check(StudioKeyRouter.route(code: 34, text: "i", stage: .grid, selectionCount: 1) == .toggleInspector, "网格 I 应切换检查器")
        try check(StudioKeyRouter.route(code: 7, text: "x", stage: .grid, selectionCount: 1) == .reject(advance: true), "单选 X 应淘汰并前进")
        try check(StudioKeyRouter.route(code: 7, text: "x", stage: .grid, selectionCount: 3) == .reject(advance: false), "多选 X 应只标记不前进")
        try check(StudioKeyRouter.route(code: 7, text: "x", isRepeat: true, stage: .grid, selectionCount: 1) == nil, "长按 X 不得连续淘汰")

        // Loupe shortcuts
        try check(StudioKeyRouter.route(code: 49, text: " ", stage: .loupe) == .returnToGrid, "单图空格应返回网格")
        try check(StudioKeyRouter.route(code: 5, text: "g", stage: .loupe) == .returnToGrid, "单图 G 应返回网格")
        try check(StudioKeyRouter.route(code: 14, text: "e", stage: .loupe) == nil, "单图 E 保持在单图")
        try check(StudioKeyRouter.route(code: 3, text: "f", stage: .loupe) == .toggleFilmstrip, "单图 F 应切换胶片栏")
        try check(StudioKeyRouter.route(code: 8, text: "c", stage: .loupe, hasSimilarGroup: true) == .enterSimilarCompare, "相似组单图 C 应打开组对比")
        try check(StudioKeyRouter.route(code: 42, text: "\\", stage: .loupe) == nil, "纯单图态按 \\ 不应触发对比缓冲")

        // Compare shortcuts
        try check(StudioKeyRouter.route(code: 14, text: "e", stage: .compare) == .exitCompareToLoupe, "对比态 E 应回到候选单图")
        try check(StudioKeyRouter.route(code: 8, text: "c", stage: .compare) == .exitCompareToLoupe, "对比态 C 应退出对比回单图")
        try check(StudioKeyRouter.route(code: 5, text: "g", stage: .compare) == .returnToGrid, "对比态 G 应返回网格")
        try check(StudioKeyRouter.route(code: 2, text: "d", stage: .compare) == .enterDevelop, "对比态 D 应将候选转入调色")

        // Develop shortcuts & press-and-hold backslash
        try check(StudioKeyRouter.route(code: 42, text: "\\", stage: .develop) == .beginOriginalComparison, "调色态按下 \\ 应开始原图对比")
        try check(StudioKeyRouter.route(code: 42, text: "\\", isRepeat: true, stage: .develop) == nil, "调色态长按 \\ 重复事件应忽略")
        try check(StudioKeyRouter.route(code: 42, text: "\\", isKeyUp: true, stage: .develop) == .endOriginalComparison, "调色态松开 \\ 应结束原图对比")
        try check(StudioKeyRouter.route(code: 42, text: "\\", stage: .develop, isComposingCrop: true) == nil, "裁剪中禁止触发 \\ 原图对比")
        try check(StudioKeyRouter.route(code: 53, text: "", stage: .develop, isComposingCrop: true) == .cancelCrop, "裁剪中 Esc 应仅取消裁剪")
        try check(StudioKeyRouter.route(code: 2, text: "d", stage: .develop) == .finishDevelopToLoupe, "调色态 D 应完成编辑回到单图")
        try check(StudioKeyRouter.route(code: 5, text: "g", stage: .develop) == .returnToGrid, "调色态 G 应完成编辑并返回网格")
        try check(StudioKeyRouter.route(code: 51, text: "", stage: .develop) == nil, "调色态禁止 Delete 误淘汰")
        try check(StudioKeyRouter.route(code: 7, text: "x", stage: .develop) == nil, "调色态禁止 X 误淘汰")
        try check(StudioKeyRouter.route(code: 34, text: "i", stage: .develop) == nil, "调色态 I 不应覆盖右侧调色面板")
    }

    private static func checkDarkroomCanvasAndSquareThumbnail() throws {
        let canvas = PreviewCanvasView(frame: CGRect(x: 0, y: 0, width: 120, height: 80))
        let captured = try PreviewCanvasChecks.capture(canvas)
        let rgba = Array(try SRGBPixels(captured).rgba.prefix(4))
        // #141416 -> (20, 20, 22, 255)
        try check(abs(Int(rgba[0]) - 20) <= 2 && abs(Int(rgba[1]) - 20) <= 2 && abs(Int(rgba[2]) - 22) <= 2 && rgba[3] == 255,
                  "画布默认背景应为不透明光学中性暗灰 #141416，实际=\(rgba)")

        let wideSize = CGSize(width: 120, height: 60)
        let ctx = CGContext(data: nil, width: 120, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [0, 0.8, 0.2, 1])!)
        ctx.fill(CGRect(origin: .zero, size: wideSize))
        let nsImage = NSImage(cgImage: ctx.makeImage()!, size: wideSize)
        let view = SquareThumbnail(image: nsImage).frame(width: 64, height: 64).background(Color.black)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        guard let squareCG = renderer.cgImage else { throw Failure(description: "正方形缩略图渲染失败") }
        let sqBytes = try SRGBPixels(squareCG).rgba
        // Both top-center (32, 2) and bottom-center (32, 61) must be filled with green, not black bars.
        let topIdx = (2 * 64 + 32) * 4
        let botIdx = (61 * 64 + 32) * 4
        try check(sqBytes[topIdx + 1] > 150 && sqBytes[botIdx + 1] > 150, "1:1 正方形缩略图未铺满槽位")
    }

    private static func checkHoverCheckmarkAndLargeScopeSelection() throws {
        let fullScopeIDs = (0..<2500).map { String(format: "photo-%04d", $0) }
        let cursorWindowIDs = Array(fullScopeIDs.prefix(200))

        var selection = PhotoSelectionState()
        // Hover checkmark toggles individual items without clearing existing batch selection
        selection.click(cursorWindowIDs[2], photoIDs: cursorWindowIDs, checkboxMode: true)
        selection.click(cursorWindowIDs[7], photoIDs: cursorWindowIDs, checkboxMode: true)
        try check(selection.selectedIDs == [cursorWindowIDs[2], cursorWindowIDs[7]], "悬停勾选应累加选择而不清空已有项")

        // Clicking an unselected cell body without modifiers replaces batch selection with single selection
        selection.click(cursorWindowIDs[10], photoIDs: cursorWindowIDs, checkboxMode: false)
        try check(selection.selectedIDs == [cursorWindowIDs[10]], "单击未选项主体应收敛为单选")

        // Select full query (>2,000 items), then uncheck 1 visible item via hover checkmark; off-window items remain intact
        selection.selectAll(fullScopeIDs)
        try check(selection.selectedIDs.count == 2500, "完整查询范围全选应覆盖全部 2500 项")
        selection.reconcile(visibleIDs: cursorWindowIDs, photoIDs: cursorWindowIDs)
        try check(selection.selectedIDs.count == 2500, "200 项游标窗口对账不得丢失窗口外 2300 项选择")
        selection.click(cursorWindowIDs[5], photoIDs: cursorWindowIDs, checkboxMode: true)
        try check(selection.selectedIDs.count == 2499 && !selection.selectedIDs.contains(cursorWindowIDs[5]),
                  "在全选后点击左上角勾选环应仅取消该单张，保留其余 2499 项")
    }
}
