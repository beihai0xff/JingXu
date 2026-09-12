import AppKit
import Foundation
import ImageIO
import JingXuCore
import SwiftUI

@MainActor
enum PreviewCanvasChecks {
    struct Failure: Error { var message: String }
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }

    static func capture(_ canvas: PreviewCanvasView) throws -> CGImage {
        let w = Int(canvas.bounds.width), h = Int(canvas.bounds.height)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(message: "无法创建画布") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()!
    }

    static func run() async throws {
        // Exercise the actual SwiftUI thumbnail view, not only geometry formulas.
        for ratio in [CGSize(width: 90, height: 60), CGSize(width: 60, height: 90),
                      CGSize(width: 60, height: 60), CGSize(width: 120, height: 20),
                      CGSize(width: 20, height: 120)] {
            let source = CGContext(data: nil, width: Int(ratio.width), height: Int(ratio.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            source.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            source.fill(CGRect(origin: .zero, size: ratio))
            let view = FittedThumbnail(image: NSImage(cgImage: source.makeImage()!, size: ratio))
                .frame(width: 96, height: 64).background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            guard let rendered = renderer.cgImage else { throw Failure(message: "缩略图渲染失败") }
            let bytes = try SRGBPixels(rendered).rgba
            var xs: [Int] = [], ys: [Int] = []
            for y in 0..<64 { for x in 0..<96 {
                if bytes[(y * 96 + x) * 4] > 200 { xs.append(x); ys.append(y) }
            } }
            guard let left = xs.min(), let right = xs.max(), let top = ys.min(), let bottom = ys.max() else {
                throw Failure(message: "缩略图未显示")
            }
            try check(abs(left + right - 95) <= 2 && abs(top + bottom - 63) <= 2, "不同比例的缩略图未居中")
            let scale = min(96 / ratio.width, 64 / ratio.height)
            try check(abs(Double(right - left + 1) - ratio.width * scale) <= 2 &&
                      abs(Double(bottom - top + 1) - ratio.height * scale) <= 2, "缩略图被裁切或拉伸")
        }
        let size = CGSize(width: 4672, height: 7008), viewport = CGSize(width: 800, height: 700)
        let scale = PreviewGeometry.fit(image: size, viewport: viewport)
        let rect = PreviewGeometry.imageRect(image: size, viewport: viewport, scale: scale, pan: .zero)
        try check(abs(rect.height - 700) < 0.001 && abs(rect.midX - 400) < 0.001, "适应窗口未居中或比例错误")
        try check(PreviewGeometry.clampedPan(CGPoint(x: 100, y: 100), image: size, viewport: viewport, scale: scale) == .zero, "适应模式可被拖离窗口")
        let oldScale: CGFloat = 0.5, newScale: CGFloat = 1
        let anchor = CGPoint(x: 320, y: 300)
        let pan = PreviewGeometry.zoomedPan(.zero, from: oldScale, to: newScale, anchor: anchor, image: size, viewport: viewport)
        let before = PreviewGeometry.imageRect(image: size, viewport: viewport, scale: oldScale, pan: .zero)
        let after = PreviewGeometry.imageRect(image: size, viewport: viewport, scale: newScale, pan: pan)
        try check(abs((anchor.x - before.minX) / oldScale - (anchor.x - after.minX) / newScale) < 0.001, "缩放没有保留锚点")
        let hugePan = PreviewGeometry.clampedPan(CGPoint(x: 1e6, y: -1e6), image: size, viewport: viewport, scale: 0.5)
        try check(abs(hugePan.x - 768) < 0.001 && abs(hugePan.y + 1402) < 0.001, "平移边界错误")

        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
            bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Use a specified profile: Device RGB red is not necessarily sRGB (255, 0, 0).
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [1, 0, 0, 1])!)
        context.fill(CGRect(origin: .zero, size: size))
        let image = context.makeImage()!
        let canvas = PreviewCanvasView(frame: CGRect(origin: .zero, size: viewport))
        canvas.setImage(image, assetID: "fixture", nativeSize: CGSize(width: image.width, height: image.height))
        try check(canvas.frame.size == viewport && canvas.fitted, "画布尺寸随原图膨胀")
        let rendered = try capture(canvas)
        let pixels = try SRGBPixels(rendered).rgba
        for y in 2..<698 {
            let i = (y * 800 + 400) * 4
            try check(pixels[i] > 245 && pixels[i+1] < 10, "适应绘制出现黑行／条纹 row=\(y) rgba=\(Array(pixels[i..<i+4]))")
        }
        canvas.perform("actual", backingScale: 2)
        try check(canvas.scale == 0.5 && !canvas.fitted && canvas.frame.size == viewport, "Retina 100% 比例或 backing 尺寸错误")
        let proxy = try QualityV2Checks.image(width: 32, height: 48) { _,_ in (255,0,0,255) }
        canvas.setImage(proxy, assetID: "fixture", nativeSize: size)
        try check(canvas.scale == 0.5 && !canvas.fitted && canvas.displayedImageRect.width == size.width * 0.5, "调色更新或降采样重置了缩放／100% 像素比例")
        canvas.setImage(image, assetID: "fixture", nativeSize: size)
        for _ in 0..<40 { canvas.perform("in") }
        try check(canvas.scale == 16 && canvas.frame.size == viewport, "放大导致超大 backing surface")
        for _ in 0..<80 { canvas.perform("out") }
        try check(canvas.scale == 0.01, "缩小边界错误")
        canvas.perform("fit")
        canvas.setFrameSize(CGSize(width: 400, height: 300))
        try check(abs(canvas.displayedImageRect.height - 300) < 0.001, "调整窗口未重新适应")
        let other = PreviewCanvasView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
        other.setImage(image, assetID: "other", nativeSize: CGSize(width: 6000, height: 4000))
        let pose = CanvasTransform(fitted: false, physicalZoom: 2, center: CGPoint(x: 0.6, y: 0.4))
        canvas.applyTransform(pose); other.applyTransform(pose)
        try check(abs(canvas.transform.center.x - other.transform.center.x) < 0.001 &&
                  abs(canvas.transform.center.y - other.transform.center.y) < 0.001, "不同比例照片的联动中心不一致")
        try check(canvas.transform.physicalZoom == other.transform.physicalZoom, "双图物理像素缩放不一致")
        other.applyTransform(CanvasTransform())
        try check(other.fitted && other.pan == .zero, "比较视图恢复适应失败")
        other.clearImage()
        canvas.clearImage()
        try check(canvas.image == nil, "关闭预览未释放图片引用")
        let empty = try SRGBPixels(capture(canvas)).rgba
        try check(stride(from: 0, to: empty.count, by: 4).allSatisfy { empty[$0] == 0 && empty[$0+1] == 0 && empty[$0+2] == 0 }, "切图清空后残留旧帧")
        canvas.setImage(image, assetID: "fixture", nativeSize: CGSize(width: image.width, height: image.height))
        try check(canvas.fitted, "换图未恢复适应模式")
    }

    /// Optional read-only real-file check; all diagnostic renders must remain outside Git repositories.
    static func verifyFile(_ url: URL, output: URL) async throws {
        var parent = output.standardizedFileURL.resolvingSymlinksInPath()
        while parent.path != "/" {
            guard !FileManager.default.fileExists(atPath: parent.appendingPathComponent(".git").path) else { throw Failure(message: "私有预览不能写入仓库") }
            parent.deleteLastPathComponent()
        }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let hash = try FileHasher.sha256(of: url)
        let decoded = try await ImagePreviewLoader().load(url: url)
        let canvas = PreviewCanvasView(frame: CGRect(x: 0, y: 0, width: 800, height: 700))
        canvas.setImage(decoded.image, assetID: "real", nativeSize: CGSize(width: decoded.image.width, height: decoded.image.height))
        let baseline = try SRGBPixels(capture(canvas)).rgba
        for _ in 0..<3 {
            canvas.clearImage()
            let repeated = try await ImagePreviewLoader().load(url: url)
            try check(repeated.image.width == decoded.image.width && repeated.image.height == decoded.image.height,
                      "真实图片重复读取尺寸改变")
            canvas.setImage(repeated.image, assetID: "real", nativeSize: CGSize(width: repeated.image.width, height: repeated.image.height))
            canvas.perform("fit")
            try check(try SRGBPixels(capture(canvas)).rgba == baseline, "真实图片重复加载后显示像素改变")
        }
        for action in ["fit", "actual", "in", "fit"] .enumerated() {
            canvas.perform(action.element, backingScale: 2)
            let target = output.appendingPathComponent("\(action.offset)-\(action.element).png")
            guard !FileManager.default.fileExists(atPath: target.path),
                  let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil) else { throw Failure(message: "输出已存在或不可写") }
            CGImageDestinationAddImage(destination, try capture(canvas), nil)
            try check(CGImageDestinationFinalize(destination), "预览导出失败")
        }
        canvas.clearImage()
        try check(try FileHasher.sha256(of: url) == hash, "诊断改变了原文件")
        print("原图 \(decoded.image.width)×\(decoded.image.height)，fit / 100% / 放大 / 再次 fit 绘制完成；原文件 SHA-256 不变")
    }
}
