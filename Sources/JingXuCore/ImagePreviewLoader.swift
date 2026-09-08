import Foundation
import CoreGraphics
import ImageIO
import CoreImage

public struct PreviewImage: @unchecked Sendable {
    public let image: CGImage
    public let isEmbedded: Bool
    public let access: PreviewAccessLease?
}

/// One balanced security-scope acquisition, retained by the displayed preview.
public final class PreviewAccessLease: @unchecked Sendable {
    private let url: URL
    private let started: Bool
    public init(url: URL) {
        self.url = url
        started = url.startAccessingSecurityScopedResource()
    }
    deinit { if started { url.stopAccessingSecurityScopedResource() } }
}

public enum PreviewScale {
    public static func bounded(_ value: Double) -> Double { min(16, max(0.01, value)) }
    public static func actualPixels(backingScale: Double) -> Double { bounded(1 / max(1, backingScale)) }
}

public struct ImagePreviewLoader: Sendable {
    public init() {}
    public func load(url: URL, access: PreviewAccessLease? = nil) async throws -> PreviewImage {
        try await PreviewDecodeWorker.shared.load(url: url, access: access)
    }
}

/// Serial decoding bounds overlapping RAW allocations during rapid A → B → A navigation.
private actor PreviewDecodeWorker {
    static let shared = PreviewDecodeWorker()
    func load(url: URL, access: PreviewAccessLease?) throws -> PreviewImage {
        try Task.checkCancellation()
        return try autoreleasepool { try decode(url: url, access: access) }
    }

    private func decode(url: URL, access: PreviewAccessLease?) throws -> PreviewImage {
        try Task.checkCancellation()
        // Owned bytes, not a URL-backed/mapped source: ImageIO must never reopen the file later.
        let data = try Data(contentsOf: url, options: .uncached)
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw CocoaError(.fileReadCorruptFile) }
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
        try Task.checkCancellation()
        let oriented = try Self.oriented(decoded, orientation: orientation)
        // Materialize display pixels while access and decoding resources are still alive.
        let image = try Self.materialize(oriented)
        try Task.checkCancellation()
        return PreviewImage(image: image, isEmbedded: embedded, access: access)
    }

    private static func materialize(_ image: CGImage) throws -> CGImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { throw CocoaError(.fileReadTooLarge) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let pixels = context.data else { throw CocoaError(.fileReadCorruptFile) }
        let bytes = Data(bytes: pixels, count: context.bytesPerRow * image.height)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let result = CGImage(width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: context.bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: info),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw CocoaError(.fileReadCorruptFile) }
        return result
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
