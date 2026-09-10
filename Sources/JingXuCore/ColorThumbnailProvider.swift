import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public actor ColorThumbnailProvider {
    private let directory: URL
    public init(directory: URL) { self.directory = directory }
    public func thumbnail(_ snapshot: ColorEditSnapshot, pixelSize: Int) async throws -> Data {
        let access = try ColorSourceAccess(snapshot)
        let size = min(2048, max(64, pixelSize))
        let key = "\(snapshot.asset.id)-color-\(snapshot.revision)-\(access.fingerprint.size)-\(access.fingerprint.modifiedAt.timeIntervalSince1970)-\(size).png"
        let url = directory.appendingPathComponent(key)
        if let bytes = try? Data(contentsOf: url) { try access.revalidate(); return bytes }
        let result = try await ColorImageRenderer.shared.render(snapshot, adjustments: snapshot.adjustments, maximumDimension: size)
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ColorEditError("无法生成调色缩略图") }
        CGImageDestinationAddImage(destination, result.image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ColorEditError("无法编码调色缩略图") }
        try access.revalidate()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (data as Data).write(to: url, options: .atomic)
        return data as Data
    }
}
