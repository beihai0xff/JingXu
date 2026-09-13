import Combine
import CoreGraphics
import Foundation

/// An unsaved crop over a frozen full-frame rendering. It never writes to the catalog.
@MainActor
public final class CompositionSession: ObservableObject {
    public typealias Detector = @Sendable (CGImage) async throws -> [CGRect]
    public let snapshot: ColorEditSnapshot
    public let editVersion: UUID
    @Published public private(set) var preview: ColorRenderedImage?
    @Published public private(set) var crop: CropAdjustment
    @Published public private(set) var ratio: CompositionRatio
    @Published public private(set) var portrait = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var isAnalyzing = false
    @Published public internal(set) var isApplying = false
    @Published public private(set) var message = ""
    @Published public internal(set) var errorMessage: String?
    private let values: ColorAdjustments
    private let detector: Detector
    private var detected: [CGRect]?
    private var loading: Task<Void, Never>?
    private var analysis: Task<Void, Never>?
    private var generation = UUID()
    private var disposed = false
    public var aspectRatio: Double? { preview.flatMap { ratio.value(image: $0.nativeSize, portrait: portrait) } }
    public var canApply: Bool { preview != nil && !isLoading && !isApplying && !isAnalyzing }
    public var pixelSize: CGSize? { preview.flatMap { try? crop.pixelRect(in: $0.nativeSize).size } }

    public init(snapshot: ColorEditSnapshot, adjustments: ColorAdjustments, editVersion: UUID,
                detector: @escaping Detector = { try await CompositionAnalyzer.shared.regions(in: $0) }) {
        self.snapshot = snapshot; self.editVersion = editVersion; self.detector = detector
        crop = adjustments.crop ?? .full
        ratio = adjustments.crop == nil ? .original : .free
        var full = adjustments; full.crop = nil; values = full
    }
    public func start() {
        guard !disposed, !isLoading, preview == nil else { return }
        isLoading = true; errorMessage = nil
        loading = Task { [weak self, snapshot, values] in
            do {
                let image = try await ColorImageRenderer.shared.render(snapshot, adjustments: values, maximumDimension: 2048)
                guard let self, !Task.isCancelled, !self.disposed else { return }
                self.preview = image; self.isLoading = false
                self.portrait = image.nativeSize.height > image.nativeSize.width
                if self.crop == .full { self.recommend() }
                else {
                    let width = self.crop.width * image.nativeSize.width, height = self.crop.height * image.nativeSize.height
                    self.portrait = height > width
                    self.ratio = CompositionRatio.allCases.first { choice in
                        guard let ratio = choice.value(image: image.nativeSize, portrait: self.portrait) else { return false }
                        return abs(width - height * ratio) <= max(1, ratio)
                    } ?? .free
                }
            } catch is CancellationError {} catch {
                guard let self, !Task.isCancelled, !self.disposed else { return }
                self.isLoading = false; self.errorMessage = error.localizedDescription
            }
        }
    }
    private func invalidateRecommendation() {
        generation = UUID(); analysis?.cancel(); analysis = nil; isAnalyzing = false
        message = ""; errorMessage = nil
    }
    public func setCrop(_ value: CropAdjustment) {
        guard !disposed, !isApplying, preview != nil, (try? value.validate()) != nil else { return }
        invalidateRecommendation(); crop = value
    }
    public func setRatio(_ value: CompositionRatio, portrait: Bool? = nil) {
        guard !disposed, !isApplying, let preview else { return }
        invalidateRecommendation(); ratio = value
        if let portrait { self.portrait = portrait }
        if let r = aspectRatio { crop = CropGeometry.changingRatio(crop, image: preview.nativeSize, ratio: r) }
    }
    public func reset() {
        guard !disposed, !isApplying else { return }
        invalidateRecommendation(); crop = .full; ratio = .original
    }
    public func recommend() {
        guard !disposed, !isApplying, let preview, let aspectRatio else { return }
        invalidateRecommendation(); let token = generation
        isAnalyzing = true
        let cached = detected
        analysis = Task { [weak self, detector, snapshot] in
            do {
                let regions: [CGRect]
                if let cached { regions = cached } else { regions = try await detector(preview.image) }
                try Task.checkCancellation()
                // Check source identity again after analysis, before exposing a suggestion.
                try await ColorImageRenderer.shared.validateSource(snapshot)
                let suggestion = try CompositionAnalyzer.suggest(regions: regions, image: preview.nativeSize, ratio: aspectRatio)
                guard let self, !Task.isCancelled, !self.disposed, self.generation == token else { return }
                self.detected = regions; self.isAnalyzing = false
                switch suggestion {
                case .crop(let crop): self.crop = crop; self.message = "已生成建议，可拖动边角微调"
                case .keepOriginal: self.crop = .full; self.ratio = .original; self.message = "建议保留原构图"
                case .cannotFit: self.message = "该比例无法完整保留主体，可手动调整"
                }
            } catch is CancellationError {} catch {
                guard let self, !Task.isCancelled, !self.disposed, self.generation == token else { return }
                self.isAnalyzing = false; self.errorMessage = "推荐失败：\(error.localizedDescription)。可手动调整裁剪。"
            }
        }
    }
    public func dispose() {
        disposed = true; loading?.cancel(); invalidateRecommendation(); preview = nil; detected = nil; isLoading = false
    }
}
