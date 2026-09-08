import CoreGraphics
import Foundation
import ImageIO

/// Shared display-referred input for histogram and quality analysis; never sensor-linear RAW data.
public enum DecodedPreview {
    public static func image(at url: URL, maximumDimension: Int = 1024) throws -> CGImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maximumDimension, max(width, height)),
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
        try Task.checkCancellation()
        return image
    }
}

/// RGBA sRGB, unpremultiplied once. Both consumers ignore alpha == 0 and count other pixels equally.
public struct SRGBPixels: Sendable {
    public let width: Int
    public let height: Int
    public let rgba: [UInt8]

    public init(_ image: CGImage, maximumDimension: Int = 1024) throws {
        let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
        width = max(1, Int((Double(image.width) * scale).rounded()))
        height = max(1, Int((Double(image.height) * scale).rounded()))
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { throw CocoaError(.fileReadCorruptFile) }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        for i in stride(from: 0, to: bytes.count, by: 4) {
            if i % 16384 == 0 { try Task.checkCancellation() }
            let alpha = Int(bytes[i + 3])
            if alpha > 0 {
                for channel in 0..<3 { bytes[i + channel] = UInt8(min(255, Int(bytes[i + channel]) * 255 / alpha)) }
            }
        }
        rgba = bytes
    }

    public static func luminance(red: UInt8, green: UInt8, blue: UInt8) -> Double {
        0.2126 * Double(red) + 0.7152 * Double(green) + 0.0722 * Double(blue)
    }

    public func histogram() throws -> HistogramResult {
        var result = HistogramResult()
        for i in stride(from: 0, to: rgba.count, by: 4) {
            if i % 16384 == 0 { try Task.checkCancellation() }
            guard rgba[i + 3] > 0 else { continue }
            result.red[Int(rgba[i])] += 1
            result.green[Int(rgba[i + 1])] += 1
            result.blue[Int(rgba[i + 2])] += 1
            let bin = min(255, Int(Self.luminance(red: rgba[i], green: rgba[i + 1], blue: rgba[i + 2]).rounded()))
            result.luminance[bin] += 1
        }
        return result
    }
}
