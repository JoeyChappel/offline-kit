import Foundation
import ImageIO
import CoreGraphics

/// One shared cache of decoded artwork for every screen (Mac, iPhone, iPad and Apple TV).
///
/// A picture is decoded once per (file, modification date, pixel size) with ImageIO's thumbnailing, off the main
/// thread, and kept in an NSCache that frees itself under memory pressure. Two cards asking for the same cover at the
/// same moment share one decode, so a title on three shelves costs one read, not three.
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private struct Decoded: @unchecked Sendable { let image: CGImage }
    private final class Box { let image: CGImage; init(_ image: CGImage) { self.image = image } }

    private let cache = NSCache<NSString, Box>()
    private let lock = NSLock()
    private var inflight: [String: Task<Decoded?, Never>] = [:]
    /// Modification dates, looked up at most every few seconds per file, so views can ask on every redraw.
    private var stamps: [String: (date: TimeInterval, checked: Date)] = [:]

    private init() {
        // iPhone and Apple TV are ended by the system at far lower memory than a Mac, so they keep less decoded art
        // (the Mac's peak is dominated by GPU text surfaces, not this cache: 128 MB vs 48 MB changed it by under 5%).
        #if os(macOS)
        var megabytes = 128
        #elseif os(tvOS)
        var megabytes = 64
        #else
        var megabytes = 48
        #endif
        #if DEBUG
        // Test hook: -imageCacheMB N sets the cap, for comparing memory and scrolling.
        if let value = Int(UserDefaults.standard.string(forKey: "imageCacheMB") ?? ""), value > 0 { megabytes = value }
        #endif
        cache.totalCostLimit = megabytes * 1024 * 1024
        #if os(macOS)
        cache.countLimit = 800
        #else
        cache.countLimit = 300
        #endif
    }

    /// The decode size for a view this many points across on a screen of this scale, rounded up to a few sizes so a
    /// window that is being resized doesn't decode a new picture for every pixel it grows. The steps are close enough
    /// that a picture is never decoded at much more than it shows (a 276-point album cover was 768 pixels, 2.4 MB;
    /// now 640, 1.6 MB), and a 1x display gets half the pixels of a Retina one.
    static func pixels(forPoints points: CGFloat, scale: CGFloat = 2) -> Int {
        let wanted = Int((points * max(1, scale)).rounded(.up))
        return [128, 256, 384, 512, 640, 768, 1024, 1280, 1600].first { $0 >= wanted } ?? 1600
    }

    /// When the file last changed (0 if it can't be read). Part of the cache key, so a replaced cover loads again.
    func stamp(_ path: String) -> TimeInterval {
        let now = Date()
        if let known = lock.withLock({ stamps[path] }), now.timeIntervalSince(known.checked) < 3 { return known.date }
        let date = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        lock.withLock {
            if stamps.count > 5000 { stamps.removeAll() }
            stamps[path] = (date, now)
        }
        return date
    }

    private func key(_ path: String, _ pixels: Int) -> String { "\(path)|\(stamp(path))|\(pixels)" }

    /// The picture if it's already decoded (no disk read of the image, no waiting).
    func cached(_ path: String, pixels: Int) -> CGImage? {
        cache.object(forKey: key(path, pixels) as NSString)?.image
    }

    /// The picture at about `pixels` on its longest side: from the cache, or decoded now on a background thread.
    func image(_ path: String, pixels: Int) async -> CGImage? {
        let key = key(path, pixels)
        if let hit = cache.object(forKey: key as NSString) { return hit.image }
        let task: Task<Decoded?, Never> = lock.withLock {
            if let running = inflight[key] { return running }
            let started = Task.detached(priority: .utility) { () -> Decoded? in
                Self.decode(path, pixels: pixels).map(Decoded.init)
            }
            inflight[key] = started
            return started
        }
        let decoded = await task.value
        let finished: Bool = lock.withLock { inflight.removeValue(forKey: key) != nil }
        if finished, let decoded {
            cache.setObject(Box(decoded.image), forKey: key as NSString, cost: decoded.image.bytesPerRow * decoded.image.height)
        }
        return decoded?.image
    }

    private static func decode(_ path: String, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        // Decoded here, not later on the main thread when the picture is first drawn.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                               kCGImageSourceThumbnailMaxPixelSize: pixels,
                                                               kCGImageSourceCreateThumbnailWithTransform: true,
                                                               kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}
