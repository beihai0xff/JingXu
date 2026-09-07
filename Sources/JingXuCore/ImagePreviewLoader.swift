import Foundation
import CoreGraphics
import ImageIO
import CoreImage

public struct PreviewImage: @unchecked Sendable {
    public let image: CGImage
    public let isEmbedded: Bool
}

public enum PreviewScale {
    public static func bounded(_ value: Double) -> Double { min(16, max(0.01, value)) }
    public static func actualPixels(backingScale: Double) -> Double { bounded(1 / max(1, backingScale)) }
}

public struct ImagePreviewLoader: Sendable {
    public init() {}
    public func load(url: URL) async throws -> PreviewImage {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CocoaError(.fileReadCorruptFile) }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        var embedded = false
        var decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        if decoded == nil {
            embedded = true
            decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageIfAbsent: false] as CFDictionary)
        }
        guard let decoded else { throw CocoaError(.fileReadCorruptFile) }
        embedded = embedded || (width > 0 && height > 0 && (decoded.width < width || decoded.height < height))
        let orientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let image = try Self.oriented(decoded, orientation: orientation)
        try Task.checkCancellation()
        return PreviewImage(image: image, isEmbedded: embedded)
    }

    private static func oriented(_ image: CGImage, orientation: Int) throws -> CGImage {
        guard orientation != 1 else { return image }
        let oriented = CIImage(cgImage: image).oriented(forExifOrientation: Int32(orientation))
        guard let result = CIContext(options: [.cacheIntermediates: false]).createCGImage(oriented, from: oriented.extent) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
}
