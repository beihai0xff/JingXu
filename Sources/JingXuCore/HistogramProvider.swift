import Foundation
import CoreGraphics

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
        let values = try URL(fileURLWithPath: url.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw CocoaError(.fileReadNoSuchFile) }
        let key = "\(asset.id)-\(values.fileSize ?? Int(asset.fileSize))-\((values.contentModificationDate ?? asset.modifiedAt).timeIntervalSince1970)-v2"
        if let value = cache[key] {
            recency.removeAll { $0 == key }; recency.append(key)
            return value
        }
        let value = try Self.calculate(DecodedPreview.image(at: url))
        try Task.checkCancellation()
        cache[key] = value; recency.append(key)
        if recency.count > 100 { cache.removeValue(forKey: recency.removeFirst()) }
        return value
    }
    public static func calculate(_ image: CGImage) throws -> HistogramResult {
        try SRGBPixels(image, maximumDimension: max(image.width, image.height)).histogram()
    }
}
