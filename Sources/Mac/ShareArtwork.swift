import Foundation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// Phone-sized copies of covers and thumbnails for Share on Wi-Fi. A cover is often a 1000-pixel JPEG of 300 KB or more,
/// shown on a phone in a tile 150 points wide; the page asks for `?w=<pixels>` (see `srcset` in WebAppScript) and gets a
/// copy no wider than that, made once with ImageIO off the main thread and kept in the caches folder.
///
/// The caller has already checked the source against SharePolicy (only files in the library are read here). Copies are
/// named by a hash of the source's path, size, modification date and the width, so a changed cover gets a new copy.
enum ShareArtwork {
    /// The widths copies are made at; a request is rounded up to the next one, so a few copies serve every screen.
    static let widths = [160, 320, 480, 640, 960, 1280]

    /// The width bucket for a `?w=` value, or nil when there's none (or it isn't a number).
    static func bucket(_ value: String?) -> Int? {
        guard let value, let wanted = Int(value), wanted > 0 else { return nil }
        return widths.first { $0 >= wanted } ?? widths.last
    }

    nonisolated static var folder: URL {
        KitLocation.caches.appending(path: "OfflineKit/share-artwork", directoryHint: .isDirectory)
    }

    /// A copy of `source` at most `width` pixels wide, and its type. Nil when the original is already that small (or
    /// can't be read as an image): send the original then.
    nonisolated static func resized(_ source: URL, width: Int) async -> (url: URL, contentType: String)? {
        await Task.detached(priority: .userInitiated) { make(source, width: width) }.value
    }

    nonisolated private static func make(_ link: URL, width: Int) -> (url: URL, contentType: String)? {
        let source = link.resolvingSymlinksInPath()
        guard let values = try? source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize else { return nil }
        let stamp = values.contentModificationDate?.timeIntervalSince1970 ?? 0
        let name = SHA256.hash(data: Data("\(source.path)|\(size)|\(stamp)|\(width)".utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
        let folder = Self.folder
        let fm = FileManager.default
        for (ext, type) in [("jpg", "image/jpeg"), ("png", "image/png")] {
            let hit = folder.appending(path: "\(name).\(ext)")
            if fm.fileExists(atPath: hit.path) { return (hit, type) }
        }
        // Same width or narrower already: the original is the copy. Remembered with an empty marker so it isn't read again.
        let small = folder.appending(path: "\(name).orig")
        if fm.fileExists(atPath: small.path) { return nil }

        guard let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
              let pixelWidth = props[kCGImagePropertyPixelWidth] as? Int,
              let pixelHeight = props[kCGImagePropertyPixelHeight] as? Int, pixelWidth > 0, pixelHeight > 0 else { return nil }
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        // EXIF orientations 5 to 8 turn the picture on its side: its width on screen is its stored height.
        let rotated = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
        let shownWidth = rotated ? pixelHeight : pixelWidth
        guard shownWidth > width else {
            fm.createFile(atPath: small.path, contents: nil)
            return nil
        }
        let longest = Int((Double(width) * Double(max(pixelWidth, pixelHeight)) / Double(shownWidth)).rounded(.up))
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(image, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary) else { return nil }
        // Pictures with transparency stay PNG; everything else is a JPEG, which every browser shows.
        let alpha: Bool = switch thumb.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
        let (ext, type, uti) = alpha ? ("png", "image/png", UTType.png) : ("jpg", "image/jpeg", UTType.jpeg)
        let target = folder.appending(path: "\(name).\(ext)")
        let temp = folder.appending(path: ".\(name)-\(UUID().uuidString).\(ext)")
        guard let out = CGImageDestinationCreateWithURL(temp as CFURL, uti.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(out, thumb, (alpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.78]) as CFDictionary)
        guard CGImageDestinationFinalize(out) else { try? fm.removeItem(at: temp); return nil }
        // Two devices asking at once both make one; whichever lands second simply replaces the first.
        if (try? fm.replaceItemAt(target, withItemAt: temp)) == nil {
            try? fm.removeItem(at: temp)
            guard fm.fileExists(atPath: target.path) else { return nil }
        }
        pruneSometimes()
        return (target, type)
    }

    private final class Counter: @unchecked Sendable {
        let lock = NSLock()
        var made = 0
    }
    private static let counter = Counter()

    /// Every 200 copies, trims the folder back under 150 MB, oldest first (covers that changed leave old copies behind).
    nonisolated private static func pruneSometimes() {
        let due: Bool = counter.lock.withLock {
            counter.made += 1
            return counter.made % 200 == 0
        }
        guard due else { return }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        guard total > 150 << 20 else { return }
        entries.sort { $0.2 < $1.2 }
        for (url, size, _) in entries where total > 100 << 20 {
            try? fm.removeItem(at: url)
            total -= size
        }
    }
}
