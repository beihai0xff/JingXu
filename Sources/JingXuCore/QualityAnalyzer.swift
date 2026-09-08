import CoreGraphics
import Foundation
@preconcurrency import Vision

public protocol QualityAnalyzer: Sendable {
    func analyze(assetID: String, at url: URL) async throws -> AnalysisResult
    func featureDistance(_ lhs: Data, _ rhs: Data) throws -> Float
}

public struct DefaultQualityAnalyzer: QualityAnalyzer {
    public static let algorithmVersion = 2
    public let parameters: QualityParameters
    private let extractFeature: @Sendable (CGImage) throws -> Data?

    public init(parameters: QualityParameters = QualityParameters(),
                featureExtractor: @escaping @Sendable (CGImage) throws -> Data? = DefaultQualityAnalyzer.featurePrint) {
        self.parameters = parameters; extractFeature = featureExtractor
    }

    public func analyze(assetID: String, at url: URL) async throws -> AnalysisResult {
        let started = Date()
        let fingerprint = try AnalysisFingerprint(url: url)
        let image = try DecodedPreview.image(at: url)
        var result = try assess(image: image, assetID: assetID)
        do { result.featurePrint = try extractFeature(image) }
        catch is CancellationError { throw CancellationError() }
        catch {
            var diagnostic = result.diagnostic
            diagnostic?.featurePrintFailure = "相似度不可用：\(error.localizedDescription)"
            result.diagnostic = diagnostic
        }
        try Task.checkCancellation()
        guard fingerprint.matches(try AnalysisFingerprint(url: url)) else { throw QualityAnalysisError.changedFile }
        result.fingerprint = fingerprint
        var diagnostic = result.diagnostic
        diagnostic?.elapsedMilliseconds = Date().timeIntervalSince(started) * 1000
        result.diagnostic = diagnostic
        return result
    }

    public func assess(image: CGImage, assetID: String) throws -> AnalysisResult {
        let large = try SRGBPixels(image)
        let small = try SRGBPixels(image, maximumDimension: 512)
        let scales = try [measure(small), measure(large)]
        let exposure = try ExposureStatistics(histogram: large.histogram())
        var summary = QualityDiagnosticSummary(parameterVersion: parameters.version, parameterDigest: parameters.digest,
            warningsEnabled: parameters.warningsEnabled, scales: scales, exposure: exposure, reasons: [],
            candidateBlur: false, elapsedMilliseconds: 0)
        let (status, candidate, reasons) = summary.decision(using: parameters)
        summary.candidateBlur = candidate; summary.reasons = reasons
        var result = AnalysisResult(assetID: assetID, algorithmVersion: Self.algorithmVersion,
            sharpnessScore: scales.last?.laplacianVariance ?? 0, shadowClipping: exposure.shadows,
            highlightClipping: exposure.highlights, issues: status == .suspectedBlur ? [.blurry] : [])
        result.assessmentStatus = status; result.diagnostic = summary
        return result
    }

    private func measure(_ pixels: SRGBPixels) throws -> QualityScaleMetrics {
        let w = pixels.width, h = pixels.height, count = w * h
        var result = QualityScaleMetrics(width: w, height: h)
        guard w >= 24, h >= 24 else { return result }
        var gray = [Float](repeating: 0, count: count)
        var valid = [Bool](repeating: false, count: count)
        for i in 0..<count {
            if i % 16384 == 0 { try Task.checkCancellation() }
            let j = i * 4
            gray[i] = Float(SRGBPixels.luminance(red: pixels.rgba[j], green: pixels.rgba[j + 1], blue: pixels.rgba[j + 2]) / 255)
            valid[i] = pixels.rgba[j + 3] > 0
        }
        // 3x3 binomial Gaussian; the 5x5 validity footprint below excludes transparent boundaries.
        var smooth = gray
        for y in 1..<(h - 1) {
            if y % 32 == 0 { try Task.checkCancellation() }
            for x in 1..<(w - 1) {
                let i = y * w + x
                let corners = gray[i-w-1] + gray[i-w+1] + gray[i+w-1] + gray[i+w+1]
                let crosses = gray[i-w] + gray[i+w] + gray[i-1] + gray[i+1]
                smooth[i] = (corners + 2 * crosses + 4 * gray[i]) / 16
            }
        }
        struct Block { var contrast: Double; var sobel: Double; var laplacian: Double }
        var blocks: [Block] = []
        for by in 0..<8 {
            try Task.checkCancellation()
            for bx in 0..<8 {
                let x0 = max(2, bx * w / 8), x1 = min(w - 2, (bx + 1) * w / 8)
                let y0 = max(2, by * h / 8), y1 = min(h - 2, (by + 1) * h / 8)
                guard x1 > x0, y1 > y0 else { continue }
                var n = 0.0, sum = 0.0, squared = 0.0, noise = 0.0
                var gradient = 0.0, lapSum = 0.0, lapSquared = 0.0
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let i = y * w + x
                        var opaque = true
                        for dy in -2...2 {
                            for dx in -2...2 where !valid[i + dy * w + dx] { opaque = false }
                        }
                        guard opaque else { continue }
                        let c = Double(smooth[i]); n += 1; sum += c; squared += c * c
                        let residual = Double(gray[i] - smooth[i]); noise += residual * residual
                        let gx = Double(smooth[i-w+1] + 2*smooth[i+1] + smooth[i+w+1] - smooth[i-w-1] - 2*smooth[i-1] - smooth[i+w-1]) / 8
                        let gy = Double(smooth[i+w-1] + 2*smooth[i+w] + smooth[i+w+1] - smooth[i-w-1] - 2*smooth[i-w] - smooth[i-w+1]) / 8
                        gradient += gx * gx + gy * gy
                        let lap = Double(smooth[i-w] + smooth[i+w] + smooth[i-1] + smooth[i+1] - 4*smooth[i])
                        lapSum += lap; lapSquared += lap * lap
                    }
                }
                guard n >= Double((x1-x0)*(y1-y0)) * 0.75 else { result.transparentBlocks += 1; continue }
                let variance = max(0, squared/n - (sum/n)*(sum/n))
                let contrast = sqrt(variance)
                guard contrast >= parameters.minimumContrast, gradient/n > 0.0000001 else { result.flatBlocks += 1; continue }
                guard noise/n / max(variance, 0.0001) <= parameters.maximumNoiseRatio else { result.noisyBlocks += 1; continue }
                let sobel = gradient/n / max(variance, 0.0001)
                let laplacian = max(0, lapSquared/n - (lapSum/n)*(lapSum/n)) / max(variance, 0.0001)
                blocks.append(Block(contrast: contrast, sobel: sobel, laplacian: laplacian))
                if sobel >= parameters.sharpSobel && laplacian >= parameters.sharpLaplacian { result.hasReliableSharpRegion = true }
            }
        }
        result.validBlocks = blocks.count
        guard !blocks.isEmpty else { return result }
        // Summarize the clearer quartile rather than averaging sky and defocused backgrounds into the score.
        func topMean(_ values: [Double]) -> Double {
            let top = values.sorted(by: >).prefix(max(1, Int(ceil(Double(values.count) / 4))))
            return top.reduce(0, +) / Double(top.count)
        }
        result.contrast = topMean(blocks.map(\.contrast))
        result.sobelEnergy = topMean(blocks.map(\.sobel))
        result.laplacianVariance = topMean(blocks.map(\.laplacian))
        result.strongestSobel = blocks.map(\.sobel).max() ?? 0
        result.strongestLaplacian = blocks.map(\.laplacian).max() ?? 0
        return result
    }

    public func featureDistance(_ lhs: Data, _ rhs: Data) throws -> Float {
        guard let left = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: lhs),
              let right = try NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: rhs)
        else { throw CocoaError(.coderInvalidValue) }
        var distance: Float = 0
        try left.computeDistance(&distance, to: right)
        return distance
    }

    public static func featurePrint(for image: CGImage) throws -> Data? {
        let request = VNGenerateImageFeaturePrintRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        guard let observation = request.results?.first as? VNFeaturePrintObservation else { return nil }
        return try NSKeyedArchiver.archivedData(withRootObject: observation, requiringSecureCoding: true)
    }
}

public struct AnalysisProgress: Sendable, Equatable {
    public var total: Int
    public var completed: Int
    public var currentFile: String
    public init(total: Int, completed: Int, currentFile: String) {
        self.total = total; self.completed = completed; self.currentFile = currentFile
    }
}
public typealias AnalysisProgressHandler = @Sendable (AnalysisProgress) async -> Void

public actor AnalysisCoordinator {
    private let repository: any CatalogRepository
    private let analyzer: any QualityAnalyzer
    public init(repository: any CatalogRepository, analyzer: any QualityAnalyzer = DefaultQualityAnalyzer()) {
        self.repository = repository; self.analyzer = analyzer
    }

    public func analyzePending(sourceID: String, progress: AnalysisProgressHandler? = nil) async throws {
        let ids = try await repository.assetIDsNeedingAnalysis(sourceID: sourceID, algorithmVersion: DefaultQualityAnalyzer.algorithmVersion)
        try await analyze(assetIDs: ids, progress: progress)
    }

    public func analyze(assetIDs: [String], progress: AnalysisProgressHandler? = nil) async throws {
        for (index, id) in assetIDs.enumerated() {
            try Task.checkCancellation()
            let name = try await repository.asset(id: id)?.fileName ?? ""
            await progress?(AnalysisProgress(total: assetIDs.count, completed: index, currentFile: name))
            _ = try await analyzeOne(assetID: id)
        }
        try await groupSimilarBursts(assetIDs: assetIDs)
        await progress?(AnalysisProgress(total: assetIDs.count, completed: assetIDs.count, currentFile: ""))
    }

    @discardableResult public func analyzeOne(assetID: String) async throws -> Bool {
        try Task.checkCancellation()
        guard let asset = try await repository.asset(id: assetID), asset.kind == .photo else { return false }
        do {
            guard let source = try await repository.source(id: asset.sourceID) else { throw CocoaError(.fileReadNoSuchFile) }
            let root = try BookmarkStore.resolve(source).url
            let access = root.startAccessingSecurityScopedResource()
            defer { if access { root.stopAccessingSecurityScopedResource() } }
            let url = root.appendingPathComponent(asset.relativePath).standardizedFileURL.resolvingSymlinksInPath()
            guard url.pathComponents.starts(with: root.standardizedFileURL.resolvingSymlinksInPath().pathComponents) else { throw QualityAnalysisError.unsafePath }
            guard AnalysisFingerprint(asset: asset).matches(try AnalysisFingerprint(url: url)) else { throw QualityAnalysisError.changedFile }
            let result = try await analyzer.analyze(assetID: asset.id, at: url)
            try Task.checkCancellation()
            guard let fingerprint = result.fingerprint, fingerprint.matches(try AnalysisFingerprint(url: url)) else { throw QualityAnalysisError.changedFile }
            try await repository.saveComputedAnalysis(result, expectedAsset: asset, fileURL: url)
            return true
        } catch is CancellationError { throw CancellationError() }
        catch {
            try await repository.recordAnalysisFailure(assetID: asset.id, reason: error.localizedDescription, fingerprint: AnalysisFingerprint(asset: asset))
            return false
        }
    }

    public func groupSimilarBursts(assetIDs: [String]) async throws {
        var assets: [MediaAsset] = []
        for id in assetIDs {
            try Task.checkCancellation()
            if let asset = try await repository.asset(id: id), asset.kind == .photo { assets.append(asset) }
        }
        assets.sort { ($0.capturedAt ?? $0.modifiedAt, $0.id) < ($1.capturedAt ?? $1.modifiedAt, $1.id) }
        var group: String?
        for index in 1..<max(1, assets.count) {
            try Task.checkCancellation()
            let previous = assets[index - 1], current = assets[index]
            guard previous.cameraModel == current.cameraModel,
                  (current.capturedAt ?? current.modifiedAt).timeIntervalSince(previous.capturedAt ?? previous.modifiedAt) <= 2,
                  let left = try await repository.analysis(for: previous.id)?.featurePrint,
                  let right = try await repository.analysis(for: current.id)?.featurePrint,
                  let distance = try? analyzer.featureDistance(left, right), distance < 0.35 else { group = nil; continue }
            let id = group ?? UUID().uuidString; group = id
            try await repository.saveSimilarGroup(id, assetIDs: [previous.id, current.id])
        }
    }
}
