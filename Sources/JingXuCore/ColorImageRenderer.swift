import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

public struct ColorSourceAccess: Sendable {
    public let url: URL
    public let lease: PreviewAccessLease
    public let fingerprint: AnalysisFingerprint
    public init(_ snapshot: ColorEditSnapshot, checkAdjustment: Bool = true) throws {
        let root = try BookmarkStore.resolve(snapshot.source)
        lease = PreviewAccessLease(url: root.url)
        guard !root.isStale, snapshot.asset.kind == .photo else { throw ColorEditError("照片来源未授权或不是照片") }
        _ = try MissingAssetProbe.identity(for: snapshot.source)
        let parts = snapshot.asset.relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ColorEditError("照片路径越界") }
        var candidate = root.url
        for part in parts {
            candidate.appendPathComponent(String(part))
            let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
            guard attributes[.type] as? FileAttributeType != .typeSymbolicLink else { throw ColorEditError("照片路径包含符号链接，无法确认文件身份") }
        }
        url = candidate
        fingerprint = try AnalysisFingerprint(url: candidate)
        try Self.requireSame(AnalysisFingerprint(asset: snapshot.asset), fingerprint)
        if checkAdjustment, let record = snapshot.record { try Self.requireSame(record.fingerprint, fingerprint) }
    }
    public static func requireSame(_ expected: AnalysisFingerprint, _ actual: AnalysisFingerprint) throws {
        guard let left = expected.identifier, let right = actual.identifier, left == right,
              expected.size == actual.size, abs(expected.modifiedAt.timeIntervalSince(actual.modifiedAt)) < 0.001 else {
            throw ColorEditError("原文件已变化或身份无法确认；请重新扫描来源，再明确放弃旧调整后重新开始。")
        }
    }
    public func revalidate() throws { try Self.requireSame(fingerprint, AnalysisFingerprint(url: url)) }
}

public struct ColorRenderedImage: @unchecked Sendable {
    public let image: CGImage
    public let nativeSize: CGSize
    public let rawTemperature: Double
    public let rawTint: Double
    public let histogram: HistogramResult
}

public enum ColorExportFormat: String, CaseIterable, Codable, Sendable {
    case jpeg, png, tiff
    public var title: String { switch self { case .jpeg: "JPEG · 品质 92%"; case .png: "PNG"; case .tiff: "TIFF · 16 位" } }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    public var type: UTType { switch self { case .jpeg: .jpeg; case .png: .png; case .tiff: .tiff } }
}

/// Owns source bytes and one decoder. Every consumer uses the same color-managed graph.
/// Actor isolation bounds expensive decoding/render allocations; callers cancel superseded work.
public actor ColorImageRenderer {
    public static let shared = ColorImageRenderer()
    private let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh, .cacheIntermediates: false])
    private let outputSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private struct Input {
        let key: String
        let bytes: Data
        let image: CIImage?
        let raw: CIRAWFilter?
        let temperature: Double
        let tint: Double
        let properties: [CFString: Any]
    }
    private var input: Input?
    public init() {}
    public func release() { input = nil; context.clearCaches() }

    private func load(_ snapshot: ColorEditSnapshot, access: ColorSourceAccess) throws -> Input {
        let key = "\(snapshot.asset.id)-\(access.url.path)-\(access.fingerprint.identifier ?? "")-\(access.fingerprint.size)-\(access.fingerprint.modifiedAt.timeIntervalSince1970)"
        if let input, input.key == key { return input }
        input = nil
        try Task.checkCancellation()
        let bytes = try Data(contentsOf: access.url, options: .uncached)
        let hint = UTType(filenameExtension: access.url.pathExtension)?.identifier
        var options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        if let hint { options[kCGImageSourceTypeIdentifierHint] = hint }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, options as CFDictionary) else { throw ColorEditError("无法解码照片") }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let value: Input
        if snapshot.isRAW {
            guard let raw = CIRAWFilter(imageData: bytes, identifierHint: hint), raw.decoderVersion != .none,
                  raw.supportedDecoderVersions.contains(raw.decoderVersion), raw.outputImage != nil else {
                throw ColorEditError("macOS 不支持此 RAW 原片的完整解码；无法调色或导出成片。")
            }
            value = Input(key: key, bytes: bytes, image: nil, raw: raw, temperature: Double(raw.neutralTemperature),
                tint: Double(raw.neutralTint), properties: properties)
        } else {
            guard let image = CIImage(data: bytes, options: [.applyOrientationProperty: true]) else { throw ColorEditError("无法完整解码照片") }
            value = Input(key: key, bytes: bytes, image: image, raw: nil, temperature: 0, tint: 0, properties: properties)
        }
        try access.revalidate(); try Task.checkCancellation()
        input = value
        return value
    }

    private func graph(_ input: Input, adjustments a: ColorAdjustments, isRAW: Bool) throws -> CIImage {
        try a.validate(isRAW: isRAW)
        var image: CIImage
        if let raw = input.raw {
            raw.neutralTemperature = Float(a.whiteBalance == .raw ? a.temperature : input.temperature)
            raw.neutralTint = Float(a.whiteBalance == .raw ? a.tint : input.tint)
            raw.scaleFactor = 1
            guard let decoded = raw.outputImage else { throw ColorEditError("RAW 解码失败") }
            image = decoded
        } else {
            guard let decoded = input.image else { throw ColorEditError("照片解码失败") }
            image = decoded
            if a.whiteBalance == .relative, a.temperature != 0 || a.tint != 0 {
                image = image.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0),
                    "inputTargetNeutral": CIVector(x: 6500 - a.temperature * 30, y: -a.tint)])
            }
        }
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty, extent.width.isFinite, extent.height.isFinite else { throw ColorEditError("无效照片尺寸") }
        if a.exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: a.exposure]) }
        if a.shadows != 0 || a.highlights != 0 || a.whites != 0 || a.blacks != 0 {
            // Ordered five-point tone controls use Core Image's spline interpolation.
            let x0 = max(0, -a.blacks) * 0.0015, y0 = max(0, a.blacks) * 0.0015
            let x4 = 1 - max(0, a.whites) * 0.0015, y4 = 1 + min(0, a.whites) * 0.0015
            let y1 = max(y0 + 0.001, 0.25 + a.shadows * 0.0012)
            let y3 = min(y4 - 0.001, 0.75 + a.highlights * 0.0012)
            image = image.applyingFilter("CIToneCurve", parameters: ["inputPoint0": CIVector(x: x0, y: y0),
                "inputPoint1": CIVector(x: 0.25, y: y1), "inputPoint2": CIVector(x: 0.5, y: 0.5),
                "inputPoint3": CIVector(x: 0.75, y: y3), "inputPoint4": CIVector(x: x4, y: y4)])
        }
        if a.contrast != 0 { image = image.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: pow(2, a.contrast / 100)]) }
        if a.vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: a.vibrance / 100]) }
        if a.saturation != 0 { image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1 + a.saturation / 100]) }
        return image.cropped(to: extent).transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }

    public func render(_ snapshot: ColorEditSnapshot, adjustments: ColorAdjustments, maximumDimension: Int? = nil) throws -> ColorRenderedImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            let access = try ColorSourceAccess(snapshot)
            let input = try load(snapshot, access: access)
            var image = try graph(input, adjustments: adjustments, isRAW: snapshot.isRAW)
            let size = image.extent.size
            if let limit = maximumDimension, max(size.width, size.height) > CGFloat(limit) {
                let scale = CGFloat(limit) / max(size.width, size.height)
                image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale, kCIInputAspectRatioKey: 1])
            }
            try Task.checkCancellation()
            guard let rendered = context.createCGImage(image, from: image.extent.integral, format: .RGBA8, colorSpace: outputSpace) else { throw ColorEditError("调色预览渲染失败") }
            try access.revalidate(); try Task.checkCancellation()
            let histogram = try SRGBPixels(rendered, maximumDimension: 1024).histogram()
            return ColorRenderedImage(image: rendered, nativeSize: size, rawTemperature: input.temperature, rawTint: input.tint, histogram: histogram)
        }
    }

    /// Writes only a caller-owned temporary file. Publication is the export coordinator's job.
    public func encode(_ snapshot: ColorEditSnapshot, adjustments: ColorAdjustments, format: ColorExportFormat, to temporaryURL: URL) throws {
        try Task.checkCancellation()
        try autoreleasepool {
            let access = try ColorSourceAccess(snapshot)
            let input = try load(snapshot, access: access)
            var image = try graph(input, adjustments: adjustments, isRAW: snapshot.isRAW)
            if format == .jpeg { image = image.composited(over: CIImage(color: .white).cropped(to: image.extent)) }
            guard let rendered = context.createCGImage(image, from: image.extent.integral,
                format: format == .tiff ? .RGBA16 : .RGBA8, colorSpace: outputSpace),
                let destination = CGImageDestinationCreateWithURL(temporaryURL as CFURL, format.type.identifier as CFString, 1, nil) else { throw ColorEditError("无法创建成片文件") }
            // Copy photographic metadata, not opaque RAW maker notes, embedded previews or XMP recipes.
            var properties: [CFString: Any] = [:]
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] { properties[key] = input.properties[key] }
            if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                exif[kCGImagePropertyExifPixelXDimension] = rendered.width; exif[kCGImagePropertyExifPixelYDimension] = rendered.height
                exif[kCGImagePropertyExifColorSpace] = 1 // sRGB, matching the embedded output profile.
                exif.removeValue(forKey: kCGImagePropertyExifMakerNote)
                properties[kCGImagePropertyExifDictionary] = exif
            }
            if let tiff = input.properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                var clean: [CFString: Any] = [:]
                for key in [kCGImagePropertyTIFFMake, kCGImagePropertyTIFFModel, kCGImagePropertyTIFFDateTime, kCGImagePropertyTIFFArtist, kCGImagePropertyTIFFCopyright] { clean[key] = tiff[key] }
                properties[kCGImagePropertyTIFFDictionary] = clean
            }
            properties[kCGImagePropertyOrientation] = 1
            properties[kCGImageDestinationEmbedThumbnail] = false
            if format == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = 0.92 }
            CGImageDestinationAddImage(destination, rendered, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ColorEditError("成片写入失败；请检查空间和目录权限") }
            try access.revalidate(); try Task.checkCancellation()
        }
    }
}
