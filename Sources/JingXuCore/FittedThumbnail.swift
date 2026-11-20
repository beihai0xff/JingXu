import AppKit
import SwiftUI

/// Preserve the complete image inside a fixed thumbnail slot at every aspect ratio.
public struct FittedThumbnail: View {
    private let image: NSImage
    public init(image: NSImage) { self.image = image }
    public var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

/// Center-crop the thumbnail to fill a 1:1 square slot cleanly without mutating cached assets.
public struct SquareThumbnail: View {
    private let image: NSImage
    public init(image: NSImage) { self.image = image }
    public var body: some View {
        GeometryReader { proxy in
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .center)
                .clipped()
        }
    }
}
