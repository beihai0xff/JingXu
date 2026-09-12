import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public actor ColorThumbnailProvider {
    private let cache: ThumbnailCache
    public init(cache: ThumbnailCache) { self.cache = cache }
    public func thumbnail(_ snapshot: ColorEditSnapshot, pixelSize: Int, scale: CGFloat = 1) async throws -> Data {
        let access = try ColorSourceAccess(snapshot)
        let size = ThumbnailCache.pixelSize(pixelSize, scale: scale)
        let key = ThumbnailCache.Key(assetID: snapshot.asset.id, kind: "color", revision: snapshot.revision, fingerprint: access.fingerprint, pixelSize: size)
        let (ticket, cached) = await cache.lookup(key)
        if let cached { try access.revalidate(); return cached }
        let result = try await ColorImageRenderer.shared.render(snapshot, adjustments: snapshot.adjustments, maximumDimension: size)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ColorEditError("无法生成调色缩略图") }
        CGImageDestinationAddImage(destination, result.image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ColorEditError("无法编码调色缩略图") }
        try access.revalidate()
        await cache.store(data as Data, for: key, ticket: ticket)
        return data as Data
    }
}
