import Foundation
import CoreGraphics

/// Normalized coordinates in the orientation-corrected, uncropped image; origin is top left.
public struct CropAdjustment: Codable, Equatable, Sendable {
    public var x: Double, y: Double, width: Double, height: Double
    public static let full = CropAdjustment(x: 0, y: 0, width: 1, height: 1)
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public init(_ rect: CGRect) {
        self.init(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }
    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public var normalized: CropAdjustment? { self == .full ? nil : self }
    public func validate() throws {
        guard [x, y, width, height].allSatisfy(\.isFinite), x >= 0, y >= 0,
              width > 0, height > 0, x + width <= 1, y + height <= 1 else {
            throw ColorEditError("裁剪范围无效，请在完整照片内重新调整")
        }
    }
    /// One conversion for rendering, export and displayed dimensions. Rounds size once, then bounds origin.
    public func pixelRect(in size: CGSize) throws -> CGRect {
        try validate()
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1 else {
            throw ColorEditError("无效照片尺寸")
        }
        let w = min(size.width.rounded(.down), max(1, (width * size.width).rounded()))
        let h = min(size.height.rounded(.down), max(1, (height * size.height).rounded()))
        let left = min(size.width.rounded(.down) - w, (x * size.width).rounded())
        let top = min(size.height.rounded(.down) - h, (y * size.height).rounded())
        return CGRect(x: left, y: top, width: w, height: h)
    }
}

public enum CompositionRatio: String, CaseIterable, Sendable {
    case original, free, square, threeTwo, fourThree, sixteenNine
    public var title: String {
        switch self { case .original: "原图比例"; case .free: "自由"; case .square: "1:1"
        case .threeTwo: "3:2"; case .fourThree: "4:3"; case .sixteenNine: "16:9" }
    }
    public var canRotate: Bool { self == .threeTwo || self == .fourThree || self == .sixteenNine }
    public func value(image: CGSize, portrait: Bool) -> Double? {
        let ratio: Double
        switch self {
        case .original: return image.width / image.height
        case .free: return nil
        case .square: ratio = 1
        case .threeTwo: ratio = 3.0 / 2
        case .fourThree: ratio = 4.0 / 3
        case .sixteenNine: ratio = 16.0 / 9
        }
        return portrait ? 1 / ratio : ratio
    }
}

public enum CropGeometry {
    /// Center-preserving placement, translated only as needed to remain inside the image.
    public static func placed(size: CGSize, center: CGPoint) -> CropAdjustment {
        let w = min(1, max(0.000001, size.width)), h = min(1, max(0.000001, size.height))
        return CropAdjustment(x: min(1 - w, max(0, center.x - w / 2)),
            y: min(1 - h, max(0, center.y - h / 2)), width: w, height: h)
    }
    public static func changingRatio(_ crop: CropAdjustment, image: CGSize, ratio: Double) -> CropAdjustment {
        let r = ratio * image.height / image.width
        let area = crop.width * crop.height
        var w = sqrt(area * r), h = w / r
        let scale = min(1, 1 / w, 1 / h); w *= scale; h *= scale
        return placed(size: CGSize(width: w, height: h), center: CGPoint(x: crop.rect.midX, y: crop.rect.midY))
    }
    public static func moved(_ crop: CropAdjustment, delta: CGSize) -> CropAdjustment {
        placed(size: crop.rect.size, center: CGPoint(x: crop.rect.midX + delta.width, y: crop.rect.midY + delta.height))
    }
    /// Corners numbered clockwise starting at top left. Opposite corner stays fixed.
    public static func resized(_ crop: CropAdjustment, corner: Int, delta: CGSize, image: CGSize, ratio: Double?) -> CropAdjustment {
        let left = corner == 0 || corner == 3, top = corner == 0 || corner == 1
        let anchor = CGPoint(x: left ? crop.rect.maxX : crop.x, y: top ? crop.rect.maxY : crop.y)
        let maxW = left ? anchor.x : 1 - anchor.x, maxH = top ? anchor.y : 1 - anchor.y
        var w = min(maxW, max(min(maxW, 1 / image.width), crop.width + (left ? -delta.width : delta.width)))
        var h = min(maxH, max(min(maxH, 1 / image.height), crop.height + (top ? -delta.height : delta.height)))
        if let ratio {
            let r = ratio * image.height / image.width
            if abs(delta.height * r) > abs(delta.width) { w = h * r }
            w = min(w, maxW, maxH * r)
            w = max(min(maxW, maxH * r, max(1 / image.width, r / image.height)), w)
            h = w / r
        }
        return placed(size: CGSize(width: w, height: h), center: CGPoint(
            x: anchor.x + (left ? -w : w) / 2, y: anchor.y + (top ? -h : h) / 2))
    }
}
