import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import Vision

public protocol QualityAnalyzer: Sendable {
    func analyze(assetID: String, at url: URL) async throws -> AnalysisResult
    func featureDistance(_ lhs: Data, _ rhs: Data) throws -> Float
}

public struct DefaultQualityAnalyzer: QualityAnalyzer {
    public static let algorithmVersion = 1

    public init() {}

    public func analyze(assetID: String, at url: URL) async throws -> AnalysisResult {
        try Task.checkCancellation()
        guard let image = Self.thumbnail(at: url, maxPixelSize: 1_024) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let metrics = try Self.metrics(for: image)
        let featurePrint = try Self.featurePrint(for: image)
        var issues: [QualityIssue] = []
        if metrics.sharpness < 0.035 { issues.append(.blurry) }
        if metrics.highlightClipping > 0.18 { issues.append(.clippedHighlights) }
        if metrics.shadowClipping > 0.30 { issues.append(.crushedShadows) }

        return AnalysisResult(
            assetID: assetID,
            algorithmVersion: Self.algorithmVersion,
            sharpnessScore: metrics.sharpness,
            shadowClipping: metrics.shadowClipping,
            highlightClipping: metrics.highlightClipping,
            featurePrint: featurePrint,
            issues: issues,
            suggestionState: .pending
        )
    }

    public func featureDistance(_ lhs: Data, _ rhs: Data) throws -> Float {
        guard
            let left = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: lhs),
            let right = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: rhs)
        else { throw CocoaError(.coderInvalidValue) }
        var distance: Float = 0
        try left.computeDistance(&distance, to: right)
        return distance
    }

    private static func thumbnail(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private struct ImageMetrics {
        var sharpness: Double
        var shadowClipping: Double
        var highlightClipping: Double
    }

    private static func metrics(for image: CGImage) throws -> ImageMetrics {
        let width = image.width
        let height = image.height
        guard width > 2, height > 2 else { throw CocoaError(.fileReadCorruptFile) }
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let created = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { throw CocoaError(.fileReadCorruptFile) }

        let sampleStep = max(1, min(width, height) / 512)
        var shadows = 0
        var highlights = 0
        var sampled = 0
        var edgeSum = 0.0
        var edgeCount = 0

        func luminance(x: Int, y: Int) -> Double {
            let index = y * bytesPerRow + x * bytesPerPixel
            return (0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])) / 255.0
        }

        for y in stride(from: 0, to: height - sampleStep, by: sampleStep) {
            for x in stride(from: 0, to: width - sampleStep, by: sampleStep) {
                let value = luminance(x: x, y: y)
                if value <= 12.0 / 255.0 { shadows += 1 }
                if value >= 243.0 / 255.0 { highlights += 1 }
                sampled += 1

                let horizontal = abs(value - luminance(x: x + sampleStep, y: y))
                let vertical = abs(value - luminance(x: x, y: y + sampleStep))
                edgeSum += horizontal + vertical
                edgeCount += 2
            }
        }

        return ImageMetrics(
            sharpness: edgeCount == 0 ? 0 : edgeSum / Double(edgeCount),
            shadowClipping: sampled == 0 ? 0 : Double(shadows) / Double(sampled),
            highlightClipping: sampled == 0 ? 0 : Double(highlights) / Double(sampled)
        )
    }

    private static func featurePrint(for image: CGImage) throws -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }
}

public struct AnalysisProgress: Sendable, Equatable {
    public var total: Int
    public var completed: Int
    public var currentFile: String

    public init(total: Int, completed: Int, currentFile: String) {
        self.total = total
        self.completed = completed
        self.currentFile = currentFile
    }
}

public typealias AnalysisProgressHandler = @Sendable (AnalysisProgress) async -> Void

public actor AnalysisCoordinator {
    private let repository: any CatalogRepository
    private let analyzer: any QualityAnalyzer

    public init(repository: any CatalogRepository, analyzer: any QualityAnalyzer = DefaultQualityAnalyzer()) {
        self.repository = repository
        self.analyzer = analyzer
    }

    public func analyzePending(sourceID: String, progress: AnalysisProgressHandler? = nil) async throws {
        let assetIDs = try await repository.assetIDsNeedingAnalysis(
            sourceID: sourceID,
            algorithmVersion: DefaultQualityAnalyzer.algorithmVersion
        )
        try await analyze(assetIDs: assetIDs, progress: progress)
    }

    public func analyze(assetIDs: [String], progress: AnalysisProgressHandler? = nil) async throws {
        var analyzed: [(MediaAsset, AnalysisResult)] = []
        for (index, assetID) in assetIDs.enumerated() {
            try Task.checkCancellation()
            guard let asset = try await repository.asset(id: assetID), asset.kind == .photo,
                  let source = try await repository.source(id: asset.sourceID) else { continue }
            await progress?(AnalysisProgress(total: assetIDs.count, completed: index, currentFile: asset.fileName))
            do {
                let resolved = try BookmarkStore.resolve(source).url
                let didAccess = resolved.startAccessingSecurityScopedResource()
                defer { if didAccess { resolved.stopAccessingSecurityScopedResource() } }
                let url = resolved.appendingPathComponent(asset.relativePath)
                let result = try await analyzer.analyze(assetID: asset.id, at: url)
                try await repository.saveAnalysis(result)
                analyzed.append((asset, result))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }
        try await groupSimilarBursts(analyzed)
        await progress?(AnalysisProgress(total: assetIDs.count, completed: assetIDs.count, currentFile: ""))
    }

    private func groupSimilarBursts(_ values: [(MediaAsset, AnalysisResult)]) async throws {
        let sorted = values.sorted {
            ($0.0.capturedAt ?? $0.0.modifiedAt) < ($1.0.capturedAt ?? $1.0.modifiedAt)
        }
        var currentGroup: String?
        guard sorted.count > 1 else { return }
        for index in 1..<sorted.count {
            let previous = sorted[index - 1]
            let current = sorted[index]
            guard previous.0.cameraModel == current.0.cameraModel else {
                currentGroup = nil
                continue
            }
            let previousDate = previous.0.capturedAt ?? previous.0.modifiedAt
            let currentDate = current.0.capturedAt ?? current.0.modifiedAt
            guard currentDate.timeIntervalSince(previousDate) <= 2.0,
                  let left = previous.1.featurePrint,
                  let right = current.1.featurePrint,
                  try analyzer.featureDistance(left, right) < 0.35 else {
                currentGroup = nil
                continue
            }

            let groupID = currentGroup ?? UUID().uuidString
            currentGroup = groupID
            var leftResult = previous.1
            var rightResult = current.1
            if !leftResult.issues.contains(.similarBurst) { leftResult.issues.append(.similarBurst) }
            if !rightResult.issues.contains(.similarBurst) { rightResult.issues.append(.similarBurst) }
            leftResult.similarGroupID = groupID
            rightResult.similarGroupID = groupID
            try await repository.saveAnalysis(leftResult)
            try await repository.saveAnalysis(rightResult)
        }
    }
}
