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
