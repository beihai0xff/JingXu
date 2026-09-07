import Foundation
import CoreGraphics
import ImageIO

public struct HistogramResult: Sendable {
    public var luminance = [Int](repeating: 0, count: 256)
    public var red = [Int](repeating: 0, count: 256)
    public var green = [Int](repeating: 0, count: 256)
    public var blue = [Int](repeating: 0, count: 256)
}

public actor HistogramProvider {
    private var cache: [String: HistogramResult] = [:]
    private var recency: [String] = []
    public init() {}
    public func histogram(asset: MediaAsset, url: URL) throws -> HistogramResult {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadNoSuchFile) }
        let key = "\(asset.id)-\(values.fileSize ?? Int(asset.fileSize))-\((values.contentModificationDate ?? asset.modifiedAt).timeIntervalSince1970)-v1"
        if let value = cache[key] {
            recency.removeAll { $0 == key }; recency.append(key)
            return value
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1024
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        let value = try Self.calculate(image)
        try Task.checkCancellation()
        cache[key] = value; recency.append(key)
        if recency.count > 100 { cache.removeValue(forKey: recency.removeFirst()) }
        return value
    }
    public static func calculate(_ image: CGImage) throws -> HistogramResult {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw CocoaError(.fileReadCorruptFile) }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        var result = HistogramResult()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if i % 16384 == 0 { try Task.checkCancellation() }
            let alpha = Int(pixels[i + 3])
            guard alpha > 0 else { continue }
            let r = min(255, Int(pixels[i]) * 255 / alpha)
            let g = min(255, Int(pixels[i + 1]) * 255 / alpha)
            let b = min(255, Int(pixels[i + 2]) * 255 / alpha)
            result.red[r] += 1; result.green[g] += 1; result.blue[b] += 1
            let brightness = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            let bin = min(255, Int(brightness.rounded()))
            result.luminance[bin] += 1
        }
        return result
    }
}
