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
            let result = await ForestImage.load()
            guard !Task.isCancelled else { return }
            image = result
        }
        #if os(iOS)
        // On iPhone the picture reaches behind the status bar and tab bar; without this a white band showed at the top.
        .ignoresSafeArea()
        #endif
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// The forest picture, decoded once and shared by every screen. Each visit to Watch, Listen or Books used to decode its
/// own copy (about 6 MB each) and the old ones stayed in memory, so browsing grew the app by that much per visit.
private enum ForestImage {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var shared: CGImage?

    static func load() async -> CGImage? {
        if let hit = lock.withLock({ shared }) { return hit }
        let decoded = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let url = Bundle.main.url(forResource: "watch-forest", withExtension: "jpg"),
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 1920,
                                                                   kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        }.value
        if let decoded { lock.withLock { shared = decoded } }
        return decoded
    }
}
