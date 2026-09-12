import AppKit
import CoreGraphics

public struct CanvasTransform: Sendable, Equatable {
    public var fitted: Bool
    public var physicalZoom: CGFloat
    public var center: CGPoint
    public init(fitted: Bool = true, physicalZoom: CGFloat = 1, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.fitted = fitted; self.physicalZoom = physicalZoom; self.center = center
    }
}

/// Coordinates are display points; scale is points per original image pixel.
public enum PreviewGeometry {
    public static func fit(image: CGSize, viewport: CGSize) -> CGFloat {
        guard image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0 else { return 1 }
        return min(viewport.width / image.width, viewport.height / image.height)
    }

    public static func clampedPan(_ pan: CGPoint, image: CGSize, viewport: CGSize, scale: CGFloat) -> CGPoint {
        let x = max(0, (image.width * scale - viewport.width) / 2)
        let y = max(0, (image.height * scale - viewport.height) / 2)
        return CGPoint(x: min(x, max(-x, pan.x)), y: min(y, max(-y, pan.y)))
    }

    public static func imageRect(image: CGSize, viewport: CGSize, scale: CGFloat, pan: CGPoint) -> CGRect {
        let offset = clampedPan(pan, image: image, viewport: viewport, scale: scale)
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (viewport.width - size.width) / 2 + offset.x,
                      y: (viewport.height - size.height) / 2 + offset.y, width: size.width, height: size.height)
    }

    public static func zoomedPan(_ pan: CGPoint, from oldScale: CGFloat, to newScale: CGFloat,
                                 anchor: CGPoint, image: CGSize, viewport: CGSize) -> CGPoint {
        let oldRect = imageRect(image: image, viewport: viewport, scale: oldScale, pan: pan)
        let pixel = CGPoint(x: (anchor.x - oldRect.minX) / max(oldScale, 0.000001),
                            y: (anchor.y - oldRect.minY) / max(oldScale, 0.000001))
        let offset = CGPoint(x: anchor.x - pixel.x * newScale - (viewport.width - image.width * newScale) / 2,
                             y: anchor.y - pixel.y * newScale - (viewport.height - image.height * newScale) / 2)
        return clampedPan(offset, image: image, viewport: viewport, scale: newScale)
    }
}

public enum PreviewCanvasRenderer {
    public static func draw(_ image: CGImage?, in context: CGContext, viewport: CGRect, imageRect: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: viewport)
        // Every frame is opaque and complete, including while switching image/scale.
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(viewport)
        guard let image, !imageRect.isEmpty else { return }
        context.interpolationQuality = .high
        context.draw(image, in: imageRect)
    }
}

/// The backing surface is always viewport-sized, never an original-pixel-sized NSImageView layer.
/// Zoom/pan change the draw transform, not NSScrollView magnification or the document view's bounds.
@MainActor
public final class PreviewCanvasView: NSView {
    public var onExit: (() -> Void)?
    public var onTransformChange: ((CanvasTransform) -> Void)?
    public private(set) var image: CGImage?
    public private(set) var scale: CGFloat = 1
    public private(set) var pan = CGPoint.zero
    public private(set) var fitted = true
    private var actual = false
    private var dragAnchor = CGPoint.zero
    private var initialPan = CGPoint.zero
    private var assetIdentity: String?
    private var nativeSize: CGSize = .zero

    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    private var imageSize: CGSize { nativeSize }
    public var displayedImageRect: CGRect {
        PreviewGeometry.imageRect(image: imageSize, viewport: bounds.size, scale: scale, pan: pan)
    }

    public var transform: CanvasTransform {
        CanvasTransform(fitted: fitted, physicalZoom: scale * (window?.backingScaleFactor ?? 2),
            center: CGPoint(x: 0.5 - pan.x / max(1, imageSize.width * scale),
                            y: 0.5 - pan.y / max(1, imageSize.height * scale)))
    }
    public func applyTransform(_ value: CanvasTransform) {
        guard image != nil else { return }
        fitted = value.fitted; actual = !value.fitted && value.physicalZoom == 1
        if fitted { pan = .zero; updateFit() }
        else {
            scale = PreviewScale.bounded(value.physicalZoom / (window?.backingScaleFactor ?? 2))
            pan = PreviewGeometry.clampedPan(CGPoint(x: (0.5 - value.center.x) * imageSize.width * scale,
                y: (0.5 - value.center.y) * imageSize.height * scale), image: imageSize, viewport: bounds.size, scale: scale)
        }
        needsDisplay = true
    }

    public func clearImage() {
        image = nil
        assetIdentity = nil
        nativeSize = .zero
        fitted = true; actual = false; pan = .zero
        updateFit()
        needsDisplay = true
    }

    public func setImage(_ value: CGImage?, assetID: String, nativeSize size: CGSize) {
        let changedPhoto = assetIdentity != assetID
        image = value; assetIdentity = assetID; nativeSize = size
        if changedPhoto { fitted = true; actual = false; pan = .zero }
        if fitted { updateFit() }
        else { pan = PreviewGeometry.clampedPan(pan, image: imageSize, viewport: bounds.size, scale: scale) }
        needsDisplay = true
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitted { updateFit() }
        else { pan = PreviewGeometry.clampedPan(pan, image: imageSize, viewport: bounds.size, scale: scale) }
        needsDisplay = true
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if actual { perform("actual") }
        needsDisplay = true
    }

    private func updateFit() {
        scale = PreviewGeometry.fit(image: imageSize, viewport: bounds.size)
    }

    public func perform(_ action: String, backingScale: CGFloat? = nil) {
        guard image != nil else { return }
        if action == "fit" {
            fitted = true; actual = false; pan = .zero; updateFit(); needsDisplay = true
            onTransformChange?(transform)
            return
        }
        let factor = backingScale ?? window?.backingScaleFactor ?? 2
        let target = action == "actual" ? PreviewScale.actualPixels(backingScale: factor) :
            PreviewScale.bounded(scale * (action == "in" ? 1.5 : 1 / 1.5))
        zoom(to: target, anchor: CGPoint(x: bounds.midX, y: bounds.midY))
        actual = action == "actual"
        onTransformChange?(transform)
    }

    private func zoom(to value: CGFloat, anchor: CGPoint) {
        let target = PreviewScale.bounded(value)
        pan = PreviewGeometry.zoomedPan(pan, from: scale, to: target, anchor: anchor, image: imageSize, viewport: bounds.size)
        scale = target; fitted = false; actual = false; needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        PreviewCanvasRenderer.draw(image, in: context, viewport: bounds, imageRect: displayedImageRect)
    }

    public override func magnify(with event: NSEvent) {
        guard image != nil else { return }
        zoom(to: scale * max(0.1, 1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
        onTransformChange?(transform)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount == 2 { perform(fitted ? "actual" : "fit"); return }
        dragAnchor = event.locationInWindow; initialPan = pan
    }

    public override func mouseDragged(with event: NSEvent) {
        let location = event.locationInWindow
        pan = PreviewGeometry.clampedPan(CGPoint(x: initialPan.x + location.x - dragAnchor.x,
            y: initialPan.y + location.y - dragAnchor.y), image: imageSize, viewport: bounds.size, scale: scale)
        needsDisplay = true
        onTransformChange?(transform)
    }

    public override func scrollWheel(with event: NSEvent) {
        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        pan = PreviewGeometry.clampedPan(CGPoint(x: pan.x + event.scrollingDeltaX * multiplier,
            y: pan.y - event.scrollingDeltaY * multiplier), image: imageSize, viewport: bounds.size, scale: scale)
        needsDisplay = true
        onTransformChange?(transform)
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onExit?() } else { super.keyDown(with: event) }
    }
}
