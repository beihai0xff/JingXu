import CryptoKit
import Foundation
import GRDB

public enum QualityAssessmentStatus: String, Codable, DatabaseValueConvertible, Sendable {
    case legacy, pendingCalibration, insufficientEvidence, noIssueDetected, suspectedBlur, failed, stale

    public var title: String {
        switch self {
        case .legacy: "旧版分析，建议重算"
        case .pendingCalibration: "待校准 · 模糊报警未启用"
        case .insufficientEvidence: "无法可靠判断"
        case .noIssueDetected: "未发现明确模糊证据"
        case .suspectedBlur: "疑似模糊"
        case .failed: "分析未完成"
        case .stale: "文件已变化，建议重算"
        }
    }
}

public struct AnalysisFingerprint: Codable, Sendable, Equatable {
    public var identifier: String?
    public var size: Int64
    public var modifiedAt: Date

    public init(asset: MediaAsset) {
        identifier = asset.fileIdentifier; size = asset.fileSize; modifiedAt = asset.modifiedAt
    }
    public init(url: URL) throws {
        // A fresh URL avoids NSURL resource-value caching across the pre/post decode checks.
        let fresh = URL(fileURLWithPath: url.path)
        let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey])
        guard values.isRegularFile == true, let size = values.fileSize, let date = values.contentModificationDate
        else { throw CocoaError(.fileReadNoSuchFile) }
        identifier = FileIdentity.resourceIdentifier(for: fresh); self.size = Int64(size); modifiedAt = date
    }
    public func matches(_ other: Self) -> Bool {
        size == other.size && abs(modifiedAt.timeIntervalSince(other.modifiedAt)) < 0.001 &&
        (identifier == nil || other.identifier == nil || identifier == other.identifier)
    }
}

public struct QualityScaleMetrics: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var validBlocks: Int = 0
    public var noisyBlocks: Int = 0
    public var flatBlocks: Int = 0
    public var transparentBlocks: Int = 0
    public var contrast: Double = 0
    public var sobelEnergy: Double = 0
    public var laplacianVariance: Double = 0
    public var strongestSobel: Double = 0
    public var strongestLaplacian: Double = 0
    public var hasReliableSharpRegion: Bool = false
}

public struct ExposureStatistics: Codable, Sendable, Equatable {
    public var validPixels: Int
    public var shadows: Double
    public var highlights: Double
    public var nearBlack: Double
    public var nearWhite: Double
    public init(histogram: HistogramResult) {
        validPixels = histogram.luminance.reduce(0, +)
        let denominator = Double(max(1, validPixels))
        shadows = Double(histogram.luminance[0...12].reduce(0, +)) / denominator
        highlights = Double(histogram.luminance[243...255].reduce(0, +)) / denominator
        nearBlack = Double(histogram.luminance[0...2].reduce(0, +)) / denominator
        nearWhite = Double(histogram.luminance[253...255].reduce(0, +)) / denominator
    }
}

/// Evidence is tied to the exact parameter digest. No unlabelled or synthetic data can enable alerts.
public struct QualityValidationEvidence: Codable, Sendable, Equatable {
    public var parameterDigest: String
    public var usableCount: Int
    public var falsePositives: Int
    public var blurryCount: Int
    public var truePositives: Int
    public var humanLabelsComplete: Bool
    public var independentHoldout: Bool
    public init(parameterDigest: String, usableCount: Int, falsePositives: Int, blurryCount: Int,
                truePositives: Int, humanLabelsComplete: Bool, independentHoldout: Bool) {
        self.parameterDigest = parameterDigest; self.usableCount = usableCount; self.falsePositives = falsePositives
        self.blurryCount = blurryCount; self.truePositives = truePositives
        self.humanLabelsComplete = humanLabelsComplete; self.independentHoldout = independentHoldout
    }
}

public struct QualityParameters: Codable, Sendable, Equatable {
    public var version = "v2.0-unvalidated-1"
    public var minimumContrast = 0.02
    public var minimumBlocks = 6
    public var weakSobel = 0.012
    public var weakLaplacian = 0.006
    public var sharpSobel = 0.04
    public var sharpLaplacian = 0.025
    public var maximumNoiseRatio = 0.65
    public var validation: QualityValidationEvidence?
    public init() {}

    public var digest: String {
        var copy = self; copy.validation = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = (try? encoder.encode(copy)) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public var warningsEnabled: Bool {
        guard let v = validation, v.parameterDigest == digest, v.humanLabelsComplete, v.independentHoldout,
              v.usableCount >= 20, v.blurryCount >= 10,
              (0...v.usableCount).contains(v.falsePositives), (0...v.blurryCount).contains(v.truePositives)
        else { return false }
        return Double(v.falsePositives) / Double(v.usableCount) <= 0.05 &&
            Double(v.truePositives) / Double(v.blurryCount) >= 0.60
    }
}

public struct QualityDiagnosticSummary: Codable, Sendable, Equatable {
    public var parameterVersion: String
    public var parameterDigest: String
    public var warningsEnabled: Bool
    public var scales: [QualityScaleMetrics]
    public var exposure: ExposureStatistics
    public var reasons: [String]
    public var candidateBlur: Bool
    public var featurePrintFailure: String?
    public var elapsedMilliseconds: Double

    public func decision(using parameters: QualityParameters) -> (QualityAssessmentStatus, Bool, [String]) {
        guard scales.count == 2, let small = scales.first, let large = scales.last,
              max(large.width, large.height) >= 1024, min(small.width, small.height) >= 128 else {
            return (.insufficientEvidence, false, ["预览分辨率不足，未放大补足；不能进行可靠双尺度判断"])
        }
        guard scales.allSatisfy({ $0.validBlocks >= parameters.minimumBlocks }) else {
            return (.insufficientEvidence, false, ["有效纹理区块不足；平坦、透明或噪声区域不作为模糊证据"])
        }
        let clear = scales.contains { $0.hasReliableSharpRegion }
        let weak = scales.map { $0.sobelEnergy < parameters.weakSobel && $0.laplacianVariance < parameters.weakLaplacian }
        let candidate = weak.allSatisfy { $0 } && !clear
        if !candidate && !clear {
            return (.insufficientEvidence, false, ["两个尺度或边缘指标证据不一致，保留人工判断"])
        }
        let reasons = candidate ? ["两个尺度的有效纹理区域均偏弱，未发现可靠清晰区域"] : ["存在局部清晰纹理；不判断主体是否合焦"]
        return (parameters.warningsEnabled ? (candidate ? .suspectedBlur : .noIssueDetected) : .pendingCalibration,
                candidate, reasons + (parameters.warningsEnabled ? [] : ["真实照片人工校准／独立验证尚未通过，报警关闭"]))
    }
}

public enum QualityAnalysisError: LocalizedError {
    case changedFile, unsafePath
    public var errorDescription: String? {
        switch self {
        case .changedFile: "文件身份、大小或修改时间已变化，请重新扫描后重试"
        case .unsafePath: "照片路径超出已授权来源"
        }
    }
}
