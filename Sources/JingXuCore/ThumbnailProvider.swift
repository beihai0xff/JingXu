@preconcurrency import AppKit
import Foundation
@preconcurrency import QuickLookThumbnailing

public protocol ThumbnailProvider: Sendable {
    func thumbnailData(for assetID: String, url: URL, pixelSize: Int, scale: CGFloat) async throws -> Data
}
public struct DefaultThumbnailProvider: ThumbnailProvider {
    private let cache: ThumbnailCache
    private let requests = ThumbnailRequests()
    public init(cache: ThumbnailCache) { self.cache = cache }
    public func thumbnailData(for assetID: String, url: URL, pixelSize: Int, scale: CGFloat = 2) async throws -> Data {
        try Task.checkCancellation()
        let size = ThumbnailCache.pixelSize(pixelSize, scale: scale), fingerprint = try AnalysisFingerprint(url: url)
        let key = ThumbnailCache.Key(assetID: assetID, kind: "original", fingerprint: fingerprint, pixelSize: size)
        let (ticket, cached) = await cache.lookup(key)
        if let cached { return cached }
        return try await requests.data(key: "\(assetID)-\(fingerprint.identifier ?? "")-\(fingerprint.size)-\(fingerprint.modifiedAt.timeIntervalSince1970)-\(size)") { [cache] in
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 1, representationTypes: .thumbnail)
        let representation = try await withTaskCancellationHandler {
            try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        } onCancel: { QLThumbnailGenerator.shared.cancel(request) }
        try Task.checkCancellation()
        guard let tiff = representation.nsImage.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { throw CocoaError(.fileReadCorruptFile) }
        try ColorSourceAccess.requireSame(fingerprint, AnalysisFingerprint(url: url))
        await cache.store(data, for: key, ticket: ticket)
        return data
        }
    }
    public func clearDiskCache() async throws { try await cache.clear() }
    public func invalidate(assetIDs: Set<String>) async throws { try await cache.invalidate(assetIDs: assetIDs) }
}
