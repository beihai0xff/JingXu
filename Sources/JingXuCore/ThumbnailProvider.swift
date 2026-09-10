@preconcurrency import AppKit
import Foundation
import CryptoKit
@preconcurrency import QuickLookThumbnailing

public protocol ThumbnailProvider: Sendable {
    func thumbnailData(for assetID: String, url: URL, pixelSize: Int, scale: CGFloat) async throws -> Data
}

public final class DefaultThumbnailProvider: ThumbnailProvider, @unchecked Sendable {
    private let memoryCache = NSCache<NSString, NSData>()
    private let cacheDirectory: URL

    public init(cacheDirectory: URL) throws {
        self.cacheDirectory = cacheDirectory
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        memoryCache.countLimit = 600
        memoryCache.totalCostLimit = 256 * 1_024 * 1_024
    }

    public func thumbnailData(for assetID: String, url: URL, pixelSize: Int, scale: CGFloat = 2) async throws -> Data {
        let boundedSize = min(max(pixelSize, 64), 2_048)
        let fingerprint = try AnalysisFingerprint(url: url)
        let key = "\(assetID)-\(fingerprint.identifier ?? "unknown")-\(fingerprint.size)-\(fingerprint.modifiedAt.timeIntervalSince1970)-\(boundedSize)" as NSString
        if let data = memoryCache.object(forKey: key) { return data as Data }
        let safeKey = SHA256.hash(data: Data((key as String).utf8)).map { String(format: "%02x", $0) }.joined()
        let diskURL = cacheDirectory.appendingPathComponent("\(assetID)-\(safeKey).jpg")
        if let data = try? Data(contentsOf: diskURL) {
            memoryCache.setObject(data as NSData, forKey: key, cost: data.count)
            return data
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: boundedSize, height: boundedSize),
            scale: scale,
            representationTypes: .thumbnail
        )
        let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        guard let tiff = representation.nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try data.write(to: diskURL, options: .atomic)
        memoryCache.setObject(data as NSData, forKey: key, cost: data.count)
        return data
    }

    public func clearDiskCache() throws {
        memoryCache.removeAllObjects()
        let urls = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
        for url in urls { try FileManager.default.removeItem(at: url) }
    }

    public func invalidate(assetIDs: Set<String>) throws {
        memoryCache.removeAllObjects()
        for url in try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil) {
            if assetIDs.contains(where: { url.lastPathComponent.hasPrefix($0 + "-") }) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }
}
