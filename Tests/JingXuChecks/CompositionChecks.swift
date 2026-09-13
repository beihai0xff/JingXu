import CoreGraphics
import Foundation
import GRDB
import ImageIO
import JingXuCore
import UniformTypeIdentifiers

enum CompositionChecks {
    static func check(_ value: Bool, _ reason: String) throws { try ColorChecks.check(value, reason) }
    static let crop = CropAdjustment(x: 0.25, y: 0.125, width: 0.5, height: 0.625)
    static func geometry() throws {
        for invalid in [CropAdjustment(x: .nan, y: 0, width: 1, height: 1),
                        CropAdjustment(x: 0, y: 0, width: .infinity, height: 1),
                        CropAdjustment(x: -0.01, y: 0, width: 1, height: 1),
                        CropAdjustment(x: 0, y: 0, width: 0, height: 1),
                        CropAdjustment(x: 0.9, y: 0, width: 0.2, height: 1)] {
            do { try invalid.validate(); throw ColorChecks.Failure(description: "非法裁剪被接受") } catch is ColorEditError {}
        }
        try check(try crop.pixelRect(in: CGSize(width: 128, height: 80)) == CGRect(x: 32, y: 10, width: 64, height: 50), "裁剪像素映射错误")
        let image = CGSize(width: 1600, height: 900)
        let smaller = CropGeometry.resized(.full, corner: 2, delta: CGSize(width: -0.1, height: 0), image: image, ratio: 16.0 / 9)
        try check(smaller.width < 1 && smaller.height < 1, "沿单轴拖动固定比例角无法缩小")
        for ratio in [1.0, 1.5, 4.0 / 3, 16.0 / 9, 9.0 / 16] {
            let changed = CropGeometry.changingRatio(crop, image: image, ratio: ratio)
            try changed.validate()
            try check(abs(changed.width * image.width / (changed.height * image.height) - ratio) < 0.000001, "切换比例错误")
            for corner in 0..<4 {
                for amount in [-2.0, -0.13, 0.0, 0.27, 2.0] {
                    let resized = CropGeometry.resized(changed, corner: corner,
                        delta: CGSize(width: amount, height: -amount / 3), image: image, ratio: ratio)
                    try resized.validate()
                    try check(abs(resized.width * image.width / (resized.height * image.height) - ratio) < 0.000001, "边角拖动破坏比例")
                }
            }
            try CropGeometry.moved(changed, delta: CGSize(width: 5, height: -4)).validate()
        }
        try check(try CompositionAnalyzer.suggest(regions: [], image: image, ratio: 16.0 / 9) == .keepOriginal, "无主体时强行裁剪")
        try check(try CompositionAnalyzer.suggest(regions: [CGRect(x: 0, y: 0, width: 1, height: 1)], image: image, ratio: 16.0 / 9) == .keepOriginal, "整幅主体未保留原图")
        let boundaryFragment = CGRect(x: 0.4, y: 0.72, width: 0.18, height: 0.28)
        try check(try CompositionAnalyzer.suggest(regions: [boundaryFragment], image: image, ratio: 16.0 / 9) == .keepOriginal, "边界主体留白不足仍强行收紧")
        try check(try CompositionAnalyzer.suggest(regions: [boundaryFragment], image: image, ratio: 1) == .cannotFit, "指定比例静默裁掉主体保护边距")
        let people = [CGRect(x: 0.02, y: 0.2, width: 0.2, height: 0.5), CGRect(x: 0.75, y: 0.2, width: 0.2, height: 0.5)]
        try check(try CompositionAnalyzer.suggest(regions: people, image: image, ratio: 9.0 / 16) == .cannotFit, "竖构图裁掉合照人物")
        let subject = CGRect(x: 0.7, y: 0.3, width: 0.15, height: 0.2)
        guard case .crop(let original) = try CompositionAnalyzer.suggest(regions: [subject], image: image, ratio: 16.0 / 9),
              case .crop(let vertical) = try CompositionAnalyzer.suggest(regions: [subject], image: image, ratio: 9.0 / 16) else {
            throw ColorChecks.Failure(description: "单主体未返回推荐")
        }
        try check(original.width * original.height >= 0.5 - 0.000001 && original.rect.contains(subject), "同原图比例未满足保留面积或边缘主体保护")
        try check(vertical.width * vertical.height < 0.5 && vertical.rect.contains(subject), "指定竖比例被 50% 限制或丢失主体")
        var adjustments = ColorAdjustments(); adjustments.crop = crop
        try check(!adjustments.isIdentity && CropAdjustment.full.normalized == nil, "仅裁剪未标记编辑或完整画面未归一")
        let encoded = try JSONEncoder().encode(ColorAdjustments())
        try check(!String(decoding: encoded, as: UTF8.self).contains("crop"), "无裁剪意外写入字段")
        try check(try JSONDecoder().decode(ColorAdjustments.self, from: encoded).crop == nil, "现有调色 JSON 无法读取")
        let patch = ColorPatch(adjustments)
        var target = ColorAdjustments(); target.crop = CropAdjustment(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        try check(try patch.applying(to: target, groups: Set(ColorGroup.allCases), isRAW: false).crop == target.crop, "复制调色传播了源裁剪")
    }

    static func rendering() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, source, _) = try await PhotoShareChecks.fixture(root)
        let renderer = ColorImageRenderer()
        for orientation in 1...8 {
            let snapshot = try await ColorChecks.fixture(store: store, source: source, name: "orientation-\(orientation).png", orientation: orientation)
            let url = URL(fileURLWithPath: source.pathHint).appendingPathComponent(snapshot.asset.fileName)
            let hash = try FileHasher.sha256(of: url)
            var values = ColorAdjustments(); values.exposure = 0.3
            let full = try await renderer.render(snapshot, adjustments: values)
            values.crop = crop
            let rendered = try await renderer.render(snapshot, adjustments: values)
            let rect = try crop.pixelRect(in: full.nativeSize)
            let expected = full.image.cropping(to: rect)!
            try check(rendered.nativeSize == rect.size && rendered.image.width == Int(rect.width), "方向 \(orientation) 裁剪尺寸错误")
            try check(try SRGBPixels(rendered.image).rgba == SRGBPixels(expected).rgba, "方向 \(orientation) 裁剪坐标或像素错误")
            let small = try await renderer.render(snapshot, adjustments: values, maximumDimension: 24)
            try check(small.nativeSize == rect.size && max(small.image.width, small.image.height) == 24, "缩略预览改变原生裁剪尺寸")
            for format in ColorExportFormat.allCases {
                let output = root.appendingPathComponent("out-\(orientation).\(format.fileExtension)")
                try await renderer.encode(snapshot, adjustments: values, format: format, to: output)
                let src = CGImageSourceCreateWithURL(output as CFURL, nil)!, image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
                try check(image.width == expected.width && image.height == expected.height, "裁剪导出尺寸错误")
                let properties = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                try check((properties?[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "裁剪导出仍包含旋转方向")
                if format == .png { try check(try SRGBPixels(image).rgba == SRGBPixels(rendered.image).rgba, "PNG 成片取景与预览不同") }
                if format == .tiff { try check(image.bitsPerComponent == 16, "裁剪丢失 TIFF 精度") }
            }
            let saved = try await store.saveColorAdjustments(values, snapshot: snapshot)
            try check(saved.record?.isEdited == true, "保存裁剪未标记为已编辑")
            let cache = ThumbnailCache(directory: root.appendingPathComponent("thumb-\(orientation)"))
            let thumb = try await ColorThumbnailProvider(cache: cache).thumbnail(saved, pixelSize: 128)
            let src = CGImageSourceCreateWithData(thumb as CFData, nil)!, image = CGImageSourceCreateImageAtIndex(src, 0, nil)!
            try check(image.width == expected.width && image.height == expected.height, "缩略图未应用裁剪")
            try check(try FileHasher.sha256(of: url) == hash, "裁剪修改了原片")
        }
        // JPEG goes through the ordinary-image path; verify the exported decoded image as a new source.
        let jpeg = root.appendingPathComponent("out-1.jpg")
        let jpegSource = SourceRoot(name: "JPEG", bookmarkData: nil, pathHint: root.path)
        try await store.upsertSource(jpegSource)
        let id = try await PhotoShareChecks.index(jpeg, store: store, source: jpegSource)
        var values = ColorAdjustments(); values.crop = crop
        let jpegSnapshot = try await store.colorSnapshot(assetID: id)
        let jpegResult = try await renderer.render(jpegSnapshot, adjustments: values)
        try check(jpegResult.image.width == 32, "JPEG 裁剪失败")
        await renderer.release()
    }

    @MainActor static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<400 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        throw ColorChecks.Failure(description: "等待构图会话超时")
    }
    @MainActor static func editing() async throws {
        let root = try ColorChecks.root(); defer { try? FileManager.default.removeItem(at: root) }
        let (store, source, _) = try await PhotoShareChecks.fixture(root)
        let snapshot = try await ColorChecks.fixture(store: store, source: source, name: "edit.png")
        let detector: CompositionSession.Detector = { _ in [CGRect(x: 0.4, y: 0.3, width: 0.2, height: 0.3)] }
        let editor = try ColorEditSession(store: store, snapshot: snapshot, saved: {})
        editor.start()
        editor.change(.exposure, value: 0.5)
        try await editor.beginComposition(detector: detector)
        let cancelled = editor.composition!
        try await eventually { cancelled.preview != nil && !cancelled.isAnalyzing }
        try check(editor.adjustments.crop == nil && !editor.isDirty, "推荐进入自动保存")
        cancelled.setCrop(crop)
        editor.change(.exposure, value: 4); editor.undo()
        try check(editor.adjustments.exposure == 0.5 && editor.isComposing, "构图期间调色或撤销重入")
        do { try await editor.applyExternal(.undo, expectedVersion: editor.editVersion); throw ColorChecks.Failure(description: "MCP 在构图期间写入") } catch is ColorEditError {}
        editor.cancelComposition()
        try check(editor.adjustments.crop == nil && cancelled.preview == nil, "取消修改编辑或保留大图")

        try await editor.beginComposition(detector: detector)
        let draft = editor.composition!
        try await eventually { draft.preview != nil && !draft.isAnalyzing }
        draft.setCrop(crop)
        try check(await editor.applyComposition(), "应用裁剪失败")
        try check(editor.composition == nil && editor.adjustments.crop == crop && !editor.isDirty, "应用未保存或未退出构图")
        editor.undo(); _ = await editor.flush()
        try check(editor.adjustments.crop == nil && editor.adjustments.exposure == 0.5, "一次撤销未只恢复裁剪")
        editor.redo(); _ = await editor.flush()
        let reopened = try CatalogStore(databaseURL: root.appendingPathComponent("Catalog.sqlite"))
        try check(try await reopened.colorSnapshot(assetID: snapshot.asset.id).adjustments.crop == crop, "重开丢失裁剪")
        try await editor.beginComposition(detector: { _ in throw ColorEditError("已有裁剪不应自动分析") })
        let existing = editor.composition!
        try await eventually { existing.preview != nil }
        try check(existing.crop == crop && !existing.isAnalyzing && existing.errorMessage == nil, "再次进入覆盖当前裁剪")
        existing.reset()
        try check(await editor.applyComposition() && editor.adjustments.crop == nil && editor.adjustments.exposure == 0.5, "重置裁剪影响调色")

        let database = try DatabaseQueue(path: root.appendingPathComponent("Catalog.sqlite").path)
        try await database.write { try $0.execute(sql: "CREATE TRIGGER fail_crop BEFORE UPDATE ON colorEdits BEGIN SELECT RAISE(ABORT, 'crop failure'); END") }
        try await editor.beginComposition(detector: detector)
        let failing = editor.composition!
        try await eventually { failing.preview != nil && !failing.isAnalyzing }
        failing.setCrop(crop)
        try check(!(await editor.applyComposition()) && editor.isDirty && editor.saveError != nil && editor.adjustments.crop == crop, "保存失败丢失裁剪草稿")
        try await database.write { try $0.execute(sql: "DROP TRIGGER fail_crop") }
        try check(await editor.flush(), "裁剪保存无法重试")

        let patch = ColorPatch(values: [.contrast: 12])
        try await editor.applyExternal(.set(patch.applying(to: editor.adjustments, groups: [.tone], isRAW: false)), expectedVersion: editor.editVersion)
        try check(editor.adjustments.crop == crop, "MCP 调色参数覆盖裁剪")

        try await editor.beginComposition(detector: detector)
        let stale = editor.composition!
        try await eventually { stale.preview != nil }
        stale.reset()
        var external = editor.adjustments; external.shadows = 15
        _ = try await store.saveColorAdjustments(external, snapshot: editor.snapshot)
        try check(!(await editor.applyComposition()) && stale.errorMessage != nil, "过期修订覆盖后续编辑")
        editor.cancelComposition(); editor.dispose()

        let nextSnapshot = try await store.colorSnapshot(assetID: snapshot.asset.id)
        let next = try ColorEditSession(store: store, snapshot: nextSnapshot, saved: {})
        next.resetAll(); _ = await next.flush()
        try await next.beginComposition(detector: { _ in
            try? await Task.sleep(for: .milliseconds(200)) // Deliberately ignores cancellation.
            return [CGRect(x: 0.7, y: 0.3, width: 0.1, height: 0.2)]
        })
        let slow = next.composition!
        try await eventually { slow.isAnalyzing }
        slow.setCrop(crop)
        try await Task.sleep(for: .milliseconds(250))
        try check(slow.crop == crop && !slow.isAnalyzing, "过期推荐覆盖手动草稿")
        slow.recommend(); next.dispose()
        try await Task.sleep(for: .milliseconds(250))
        try check(slow.preview == nil && next.composition == nil, "关闭后推荐重新出现")
        let beforeReopen = try await store.colorSnapshot(assetID: snapshot.asset.id)
        var proportional = ColorAdjustments(); proportional.crop = CropAdjustment(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let changedSnapshot = try await store.saveColorAdjustments(proportional, snapshot: beforeReopen)
        let changed = try ColorEditSession(store: store, snapshot: changedSnapshot, saved: {})
        try await changed.beginComposition(detector: detector)
        let replaced = changed.composition!
        try await eventually { replaced.preview != nil && !replaced.isAnalyzing }
        try check(replaced.ratio == .original && replaced.crop == proportional.crop, "重开已有裁剪未保持原图比例或改动取景")
        replaced.setCrop(crop)
        let file = URL(fileURLWithPath: source.pathHint).appendingPathComponent(snapshot.asset.fileName)
        try Data("replaced after analysis".utf8).write(to: file, options: .atomic)
        try check(!(await changed.applyComposition()) && replaced.errorMessage != nil, "文件替换后仍应用裁剪")
        changed.dispose()
        try database.close()
    }
}
