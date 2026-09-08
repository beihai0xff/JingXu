import Foundation

public enum CalibrationLabel: String, Codable, Sendable { case usable, blurry, uncertain }

public struct CalibrationObservation: Sendable {
    public var label: CalibrationLabel
    public var diagnostic: QualityDiagnosticSummary?
    public init(label: CalibrationLabel, diagnostic: QualityDiagnosticSummary?) { self.label = label; self.diagnostic = diagnostic }
}

public struct CalibrationCounts: Codable, Sendable {
    public var total = 0
    public var usable = 0
    public var blurry = 0
    public var uncertain = 0
    public var falsePositives = 0
    public var truePositives = 0
    public var unableToJudge = 0
    public var decodeFailures = 0
    public var falsePositiveRate: Double? { usable > 0 ? Double(falsePositives) / Double(usable) : nil }
    public var recall: Double? { blurry > 0 ? Double(truePositives) / Double(blurry) : nil }
    public var hasEnoughSamples: Bool { usable >= 20 && blurry >= 10 }
    public var meetsTargets: Bool { hasEnoughSamples && (falsePositiveRate ?? 1) <= 0.05 && (recall ?? 0) >= 0.60 }

    private enum CodingKeys: String, CodingKey {
        case total, usable, blurry, uncertain, falsePositives, truePositives, unableToJudge, decodeFailures
    }
    private enum RateKeys: String, CodingKey { case falsePositiveRate, recall, unableToJudgeRate, hasEnoughSamples, meetsTargets }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(total, forKey: .total); try values.encode(usable, forKey: .usable)
        try values.encode(blurry, forKey: .blurry); try values.encode(uncertain, forKey: .uncertain)
        try values.encode(falsePositives, forKey: .falsePositives); try values.encode(truePositives, forKey: .truePositives)
        try values.encode(unableToJudge, forKey: .unableToJudge); try values.encode(decodeFailures, forKey: .decodeFailures)
        var rates = encoder.container(keyedBy: RateKeys.self)
        try rates.encode(falsePositiveRate, forKey: .falsePositiveRate); try rates.encode(recall, forKey: .recall)
        try rates.encode(total > 0 ? Double(unableToJudge) / Double(total) : nil, forKey: .unableToJudgeRate)
        try rates.encode(hasEnoughSamples, forKey: .hasEnoughSamples); try rates.encode(meetsTargets, forKey: .meetsTargets)
    }
}

public enum QualityCalibration {
    public static func measure(_ observations: [CalibrationObservation], parameters: QualityParameters) -> CalibrationCounts {
        var counts = CalibrationCounts()
        for observation in observations {
            counts.total += 1
            switch observation.label {
            case .usable: counts.usable += 1
            case .blurry: counts.blurry += 1
            case .uncertain: counts.uncertain += 1
            }
            guard let diagnostic = observation.diagnostic else { counts.decodeFailures += 1; counts.unableToJudge += 1; continue }
            let (status, candidate, _) = diagnostic.decision(using: parameters)
            if status == .insufficientEvidence { counts.unableToJudge += 1 }
            if candidate && observation.label == .usable { counts.falsePositives += 1 }
            if candidate && observation.label == .blurry { counts.truePositives += 1 }
        }
        return counts
    }

    /// Only the caller's calibration partition is accepted here. Holdout evaluation is a separate command.
    public static func selectParameters(calibration: [CalibrationObservation]) -> QualityParameters? {
        guard measure(calibration, parameters: QualityParameters()).hasEnoughSamples else { return nil }
        var winner: QualityParameters?
        var best: CalibrationCounts?
        for sobel in [0.002, 0.004, 0.008, 0.012, 0.018, 0.024] {
            for laplacian in [0.001, 0.002, 0.004, 0.006, 0.010] {
                var parameters = QualityParameters()
                parameters.version = "v2.0-calibration-candidate-1"
                parameters.weakSobel = sobel; parameters.weakLaplacian = laplacian
                let counts = measure(calibration, parameters: parameters)
                guard (counts.falsePositiveRate ?? 1) <= 0.05 else { continue }
                if best == nil || counts.truePositives > best!.truePositives ||
                    (counts.truePositives == best!.truePositives && counts.falsePositives < best!.falsePositives) {
                    winner = parameters; best = counts
                }
            }
        }
        return winner
    }
}
