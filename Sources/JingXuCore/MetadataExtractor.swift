@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct ExtractedMetadata: Sendable, Equatable {
    public var uniformType: String?
    public var capturedAt: Date?
    public var width: Int?
    public var height: Int?
    public var duration: Double?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lens: String?
    public var orientation: Int?
    public var latitude: Double?
    public var longitude: Double?
    public var errorMessage: String?

    public init(
        uniformType: String? = nil,
        capturedAt: Date? = nil,
        width: Int? = nil,
        height: Int? = nil,
        duration: Double? = nil,
        cameraMake: String? = nil,
        cameraModel: String? = nil,
        lens: String? = nil,
        orientation: Int? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        errorMessage: String? = nil
    ) {
        self.uniformType = uniformType
        self.capturedAt = capturedAt
        self.width = width
        self.height = height
        self.duration = duration
        self.cameraMake = cameraMake
        self.cameraModel = cameraModel
        self.lens = lens
        self.orientation = orientation
        self.latitude = latitude
        self.longitude = longitude
        self.errorMessage = errorMessage
    }
}

public protocol MetadataExtractor: Sendable {
    func extract(from url: URL, kind: MediaKind) async -> ExtractedMetadata
}

public struct DefaultMetadataExtractor: MetadataExtractor {
    public init() {}

    public func extract(from url: URL, kind: MediaKind) async -> ExtractedMetadata {
        switch kind {
        case .photo:
            extractImage(from: url)
        case .video:
            await extractVideo(from: url)
        }
    }

    private func extractImage(from url: URL) -> ExtractedMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return ExtractedMetadata(errorMessage: "系统无法读取图像元数据")
        }
        let type = CGImageSourceGetType(source) as String?
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ExtractedMetadata(uniformType: type, errorMessage: "图像不含可读元数据")
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]

        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        let latitude = coordinate(
            value: gps?[kCGImagePropertyGPSLatitude],
            reference: gps?[kCGImagePropertyGPSLatitudeRef] as? String
        )
        let longitude = coordinate(
            value: gps?[kCGImagePropertyGPSLongitude],
            reference: gps?[kCGImagePropertyGPSLongitudeRef] as? String
        )

        return ExtractedMetadata(
            uniformType: type,
            capturedAt: dateString.flatMap(Self.parseExifDate),
            width: number(properties[kCGImagePropertyPixelWidth]),
            height: number(properties[kCGImagePropertyPixelHeight]),
            cameraMake: trimmed(tiff?[kCGImagePropertyTIFFMake] as? String),
            cameraModel: trimmed(tiff?[kCGImagePropertyTIFFModel] as? String),
            lens: trimmed(exif?[kCGImagePropertyExifLensModel] as? String),
            orientation: number(properties[kCGImagePropertyOrientation]),
            latitude: latitude,
            longitude: longitude
        )
    }

    private func extractVideo(from url: URL) async -> ExtractedMetadata {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            var width: Int?
            var height: Int?
            if let track = tracks.first {
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let transformed = naturalSize.applying(transform)
                width = Int(abs(transformed.width))
                height = Int(abs(transformed.height))
            }
            return ExtractedMetadata(
                uniformType: UTType(filenameExtension: url.pathExtension)?.identifier,
                width: width,
                height: height,
                duration: duration.seconds.isFinite ? duration.seconds : nil
            )
        } catch {
            return ExtractedMetadata(
                uniformType: UTType(filenameExtension: url.pathExtension)?.identifier,
                errorMessage: "视频元数据读取失败：\(error.localizedDescription)"
            )
        }
    }

    private static func parseExifDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private func coordinate(value: Any?, reference: String?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let sign = (reference == "S" || reference == "W") ? -1.0 : 1.0
        return number.doubleValue * sign
    }

    private func number(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}
