import SwiftUI
import ImageIO

/// Bundled decorative artwork for Watch & Listen, shared with the TV app. No network fetches or motion.
struct MediaForestBackground: View {
    @State private var image: CGImage?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private let canvas = Color(red: 0.045, green: 0.105, blue: 0.085)

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                canvas
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .bottomLeading)
                        .clipped()
                    // The original is already dark; the scrim keeps foreground contrast predictable.
                    canvas.opacity(reduceTransparency ? 0.48 : 0.28)
                }
            }
        }
        .task {
            guard image == nil else { return }
            let result = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let url = Bundle.main.url(forResource: "watch-forest", withExtension: "jpg"),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 1920,
                                                                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }.value
            guard !Task.isCancelled else { return }
            image = result
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
