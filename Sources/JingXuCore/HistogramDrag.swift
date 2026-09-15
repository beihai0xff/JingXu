import Foundation

/// Fixed hit regions select existing tone controls; they are not rendering masks.
public struct HistogramDrag: Sendable {
    public static let parameters: [ColorParameter] = [.blacks, .shadows, .exposure, .highlights, .whites]
    public let parameter: ColorParameter
    private let initialValue: Double
    private let width: Double

    public static func parameter(at x: Double, width: Double) -> ColorParameter? {
        guard x.isFinite, width.isFinite, width > 0 else { return nil }
        return parameters[min(4, max(0, Int((min(width, max(0, x)) / width * 5).rounded(.down))))]
    }

    public init?(startX: Double, width: Double, initialValue: Double) {
        guard let parameter = Self.parameter(at: startX, width: width), initialValue.isFinite else { return nil }
        self.parameter = parameter; self.width = width; self.initialValue = initialValue
    }

    public func value(translation: Double) -> Double {
        guard translation.isFinite else { return initialValue }
        let scale = parameter == .exposure ? 5.0 : 100.0
        let precision = parameter == .exposure ? 100.0 : 1.0
        let range = parameter.range(isRAW: false)
        let value = min(range.upperBound, max(range.lowerBound, initialValue + translation / width * scale))
        return (value * precision).rounded() / precision
    }
}
