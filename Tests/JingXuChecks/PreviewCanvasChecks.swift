import AppKit
import Foundation
import ImageIO
import JingXuCore

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
        canvas.setImage(image)
        try check(canvas.frame.size == viewport && canvas.fitted, "画布尺寸随原图膨胀")
        let rendered = try capture(canvas)
        let pixels = try SRGBPixels(rendered).rgba
        for y in 2..<698 {
            let i = (y * 800 + 400) * 4
            try check(pixels[i] > 245 && pixels[i+1] < 10, "适应绘制出现黑行／条纹 row=\(y) rgba=\(Array(pixels[i..<i+4]))")
        }
        canvas.perform("actual", backingScale: 2)
        try check(canvas.scale == 0.5 && !canvas.fitted && canvas.frame.size == viewport, "Retina 100% 比例或 backing 尺寸错误")
        for _ in 0..<40 { canvas.perform("in") }
        try check(canvas.scale == 16 && canvas.frame.size == viewport, "放大导致超大 backing surface")
        for _ in 0..<80 { canvas.perform("out") }
        try check(canvas.scale == 0.01, "缩小边界错误")
        canvas.perform("fit")
        canvas.setFrameSize(CGSize(width: 400, height: 300))
        try check(abs(canvas.displayedImageRect.height - 300) < 0.001, "调整窗口未重新适应")
        canvas.setImage(nil)
        try check(canvas.image == nil, "关闭预览未释放图片引用")
        let empty = try SRGBPixels(capture(canvas)).rgba
        try check(stride(from: 0, to: empty.count, by: 4).allSatisfy { empty[$0] == 0 && empty[$0+1] == 0 && empty[$0+2] == 0 }, "切图清空后残留旧帧")
        canvas.setImage(image)
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
        canvas.setImage(decoded.image)
        for action in ["fit", "actual", "in", "fit"] .enumerated() {
            canvas.perform(action.element, backingScale: 2)
            let target = output.appendingPathComponent("\(action.offset)-\(action.element).png")
            guard !FileManager.default.fileExists(atPath: target.path),
                  let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil) else { throw Failure(message: "输出已存在或不可写") }
            CGImageDestinationAddImage(destination, try capture(canvas), nil)
            try check(CGImageDestinationFinalize(destination), "预览导出失败")
        }
        canvas.setImage(nil)
        try check(try FileHasher.sha256(of: url) == hash, "诊断改变了原文件")
        print("原图 \(decoded.image.width)×\(decoded.image.height)，fit / 100% / 放大 / 再次 fit 绘制完成；原文件 SHA-256 不变")
    }
}
