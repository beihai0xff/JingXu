import Foundation
import CoreGraphics
import Vision

public enum CompositionSuggestion: Equatable, Sendable {
    case crop(CropAdjustment), keepOriginal, cannotFit
}

/// Vision only locates regions. Geometry is deterministic and independently testable.
public actor CompositionAnalyzer {
    public static let shared = CompositionAnalyzer()
    public init() {}
    public func regions(in image: CGImage) async throws -> [CGRect] {
        try Task.checkCancellation()
        let objects = VNGenerateObjectnessBasedSaliencyImageRequest()
        let people = VNDetectHumanRectanglesRequest(); people.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        let requests: [VNRequest] = [objects, people, faces]
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        for request in requests { try Task.checkCancellation(); try handler.perform([request]) }
        try Task.checkCancellation()
        let boxes = (objects.results?.first?.salientObjects ?? []).map(\.boundingBox) +
            (people.results ?? []).map(\.boundingBox) + (faces.results ?? []).map(\.boundingBox)
        // Vision's origin is bottom left; the editor and stored recipe use top left.
        return boxes.map { CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height) }
    }
    public nonisolated static func suggest(regions: [CGRect], image: CGSize, ratio: Double) throws -> CompositionSuggestion {
        guard image.width.isFinite, image.height.isFinite, image.width > 0, image.height > 0,
              ratio.isFinite, ratio > 0 else { throw ColorEditError("无效构图比例或照片尺寸") }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let valid = regions.filter { rect in
            [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy(\.isFinite) && rect.width > 0 && rect.height > 0
        }.map { $0.intersection(unit) }.filter { !$0.isNull && !$0.isEmpty }
        guard var protected = valid.first else { return .keepOriginal }
        for region in valid.dropFirst() { protected = protected.union(region) }
        let r = ratio * image.height / image.width
        let sameRatio = abs(r - 1) < 0.000001
        protected = protected.insetBy(dx: -protected.width * 0.1, dy: -protected.height * 0.1)
        // A boundary-touching detection can be only a fragment of a subject (e.g. bright rocket exhaust).
        // Do not silently clip the protection margin and present that as a confident tighter composition.
        guard unit.contains(protected) else { return sameRatio ? .keepOriginal : .cannotFit }
        var w = max(protected.width, protected.height * r), h = w / r
        if sameRatio && w * h < 0.5 {
            let scale = sqrt(0.5 / (w * h)); w *= scale; h *= scale
        }
        guard w <= 1 + 0.000001, h <= 1 + 0.000001 else { return sameRatio ? .keepOriginal : .cannotFit }
        if sameRatio && w * h > 0.95 { return .keepOriginal }
        let result = CropGeometry.placed(size: CGSize(width: w, height: h), center: CGPoint(x: protected.midX, y: protected.midY))
        try result.validate()
        return result == .full ? .keepOriginal : .crop(result)
    }
}
