import Foundation
import Testing
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics

/// The Share server's faster paths: item ids made in one pass, items found by id through an index, finished media lists
/// kept per library revision, and phone-sized artwork made ahead of time.
@Suite("Share performance paths")
struct SharePerformanceTests {
    /// The id encoding as it was (three string replacements): ids in bookmarks and the Apple TV app must not change.
    static func oldID(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    @Test("One-pass base64url gives the same ids as before, padding and all")
    func base64URLMatchesOldEncoding() {
        var generator = SystemRandomNumberGenerator()
        for length in 0..<70 {
            let data = Data((0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) })
            #expect(ShareController.base64URL(data) == Self.oldID(data))
        }
        // Bytes that encode to "+" and "/" (0xFB 0xFF) and need padding.
        let tricky = Data([0xFB, 0xFF, 0xBF, 0xFE])
        #expect(ShareController.base64URL(tricky) == Self.oldID(tricky))
        #expect(!ShareController.base64URL(tricky).contains { "+/=".contains($0) })
    }

    @Test("The id index finds every item by its id, the first of any two that share one")
    func idIndex() {
        let root = URL(fileURLWithPath: "/tmp/okit-index/Media", isDirectory: true)
        let items = (0..<300).map { MediaItem(kind: .video, title: "Movie \($0)", tracks: [root.appending(path: "Movie \($0).mp4")], root: root, cover: nil) }
        let twin = MediaItem(kind: .video, title: "Twin", tracks: [root.appending(path: "Movie 7.mp4")], root: root, cover: nil)
        let index = ShareController.index(items + [twin])
        #expect(index.count == 300)
        for item in items { #expect(index[ShareController.mediaID(item)]?.title == item.title) }
        #expect(index[ShareController.mediaID(twin)]?.title == "Movie 7")
        #expect(index["not-an-id"] == nil)
    }

    @Test("Finished media lists are kept per revision and dropped when the library changes or searches pile up")
    @MainActor
    func bodyCache() throws {
        _ = try TestSupport.testHome()
        let share = ShareController()
        let body = Data("{\"items\":[]}".utf8)
        share.keepBody(body, "\"m-0-a\"", revision: 0)
        #expect(share.cachedBody("\"m-0-a\"", revision: 0) == body)
        #expect(share.cachedBody("\"m-0-a\"", revision: 1) == nil, "another revision never gets an old list")
        #expect(share.cachedBody("\"m-0-b\"", revision: 0) == nil)
        // A list built for a revision that has since moved on isn't kept.
        share.keepBody(body, "\"m-5-a\"", revision: 5)
        #expect(share.cachedBody("\"m-5-a\"", revision: 5) == nil)
        // Many different searches: the store starts over instead of growing.
        for n in 0..<30 { share.keepBody(body, "\"q\(n)\"", revision: 0) }
        #expect(share.cachedBody("\"m-0-a\"", revision: 0) == nil)
        #expect(share.cachedBody("\"q29\"", revision: 0) == body)
    }

    @Test("Width buckets include 800, a phone's full-width picture at 2x")
    func buckets() {
        #expect(ShareArtwork.bucket("700") == 800)
        #expect(ShareArtwork.bucket("800") == 800)
        #expect(ShareArtwork.bucket("801") == 960)
        #expect(ShareArtwork.bucket("336") == 480)
        #expect(ShareArtwork.bucket("5000") == 1280)
        #expect(ShareArtwork.bucket("0") == nil)
        #expect(ShareArtwork.bucket("wide") == nil)
        #expect(ShareArtwork.bucket(nil) == nil)
    }

    /// A 1000 × 600 JPEG.
    static func writeJPEG(_ url: URL, width: Int = 1000, height: Int = 600) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let out = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(out, image, nil)
        #expect(CGImageDestinationFinalize(out))
    }

    static func pixelWidth(_ url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return props[kCGImagePropertyPixelWidth] as? Int
    }

    @Test("Artwork made ahead of time is the copy a request then gets, and a second run makes nothing new")
    func prepareAhead() async throws {
        _ = try TestSupport.testHome()
        let tmp = try TempDir("prepare")
        let cover = tmp.url.appending(path: "cover-\(UUID().uuidString).jpg")
        try Self.writeJPEG(cover)
        let ready = await ShareArtwork.prepare([(source: cover, widths: [320, 640])])
        #expect(ready == 2)
        let small = try #require(await ShareArtwork.resized(cover, width: 320))
        #expect(Self.pixelWidth(small.url) == 320)
        #expect(small.contentType == "image/jpeg")
        let made = try FileManager.default.attributesOfItem(atPath: small.url.path)[.modificationDate] as? Date
        // Again: the copies are found, not made again.
        #expect(await ShareArtwork.prepare([(source: cover, widths: [320, 640])]) == 2)
        #expect(try FileManager.default.attributesOfItem(atPath: small.url.path)[.modificationDate] as? Date == made)
        #expect(Self.pixelWidth(try #require(await ShareArtwork.resized(cover, width: 640)).url) == 640)
        // Wider than the original: no copy (the original is sent), and nothing counted.
        #expect(await ShareArtwork.prepare([(source: cover, widths: [1280])]) == 0)
        // A missing file is skipped.
        #expect(await ShareArtwork.prepare([(source: tmp.url.appending(path: "gone.jpg"), widths: [320])]) == 0)
    }

    @Test("Making artwork ahead stops when its task is cancelled")
    func prepareCancels() async throws {
        _ = try TestSupport.testHome()
        let tmp = try TempDir("prepare-cancel")
        var jobs: [(source: URL, widths: [Int])] = []
        for n in 0..<40 {
            let url = tmp.url.appending(path: "c\(n)-\(UUID().uuidString).jpg")
            try Self.writeJPEG(url, width: 900, height: 900)
            jobs.append((url, [160]))
        }
        let task = Task.detached { await ShareArtwork.prepare(jobs) }
        task.cancel()
        let done = await task.value
        #expect(done < jobs.count)
    }
}
