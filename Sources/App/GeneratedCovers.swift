import Foundation
import CoreGraphics
import CoreText
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Typographic covers for albums and books that came without art: the title (and artist or author) in the app's rounded
/// type on a genre-tinted card, with the genre's symbol set faintly behind it. Square for music and audiobooks, 2:3 for
/// books. Drawn with Core Graphics and Core Text, so it runs on any thread.
enum GeneratedCovers {
    struct Request: Sendable, Hashable {
        enum Shape: Sendable { case square, book }
        var title: String
        var byline: String?
        var genre: String?
        var shape: Shape
        /// A small label at the top ("ALBUM", "AUDIOBOOK", "BOOK").
        var label: String
    }

    static func request(for item: MediaItem, info: MediaInfo?) -> Request {
        let title = MediaCatalog.displayTitle(item.title)
        switch item.kind {
        case .book:
            return Request(title: title, byline: info?.author, genre: info?.genre, shape: .book, label: "BOOK")
        case .audio:
            let audiobook = MediaCatalog.category(item, info) == .audiobooks
            let label = audiobook ? "AUDIOBOOK" : (item.tracks.count > 1 ? "ALBUM" : "SONG")
            return Request(title: info?.album ?? title, byline: info?.albumArtist ?? info?.artist ?? info?.author,
                           genre: info?.genre, shape: .square, label: label)
        case .video:
            return Request(title: title, byline: nil, genre: info?.genre, shape: .square, label: "VIDEO")
        }
    }

    /// Draws the cover and saves it beside the other generated art, named after the source file (path, size, date) and
    /// what the card says, so the same file isn't drawn twice and a retitled one is drawn again.
    static func generate(_ request: Request, source: URL) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let key = ArtworkRules.key(for: source, kind: "cover|\(request.title)|\(request.byline ?? "")|\(request.genre ?? "")") else { return nil }
            let url = ArtworkFiles.folder.appending(path: "gen-\(key).jpg")
            if FileManager.default.fileExists(atPath: url.path) { return url.path }
            guard let image = draw(request), ArtworkFiles.writeJPEG(image, to: url, quality: 0.88) else { return nil }
            return url.path
        }.value
    }

    // MARK: Colours

    struct RGB: Equatable, Sendable { var r: Double, g: Double, b: Double }

    /// The genre's tint, picked by the same words as its symbol (GenreIcon); a title with no genre gets a steady colour of its own.
    static func tint(genre: String?, title: String) -> RGB {
        if let genre, let colour = tints[GenreIcon.symbol(for: genre)] { return colour }
        let fallback: [RGB] = [RGB(r: 0.20, g: 0.36, b: 0.52), RGB(r: 0.42, g: 0.27, b: 0.45), RGB(r: 0.18, g: 0.42, b: 0.38),
                               RGB(r: 0.52, g: 0.30, b: 0.22), RGB(r: 0.30, g: 0.33, b: 0.42), RGB(r: 0.45, g: 0.38, b: 0.20)]
        let seed = title.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return fallback[Int(seed % UInt32(fallback.count))]
    }

    private static let tints: [String: RGB] = [
        "sparkles": RGB(r: 0.20, g: 0.22, b: 0.52), "wand.and.stars": RGB(r: 0.42, g: 0.24, b: 0.58),
        "magnifyingglass": RGB(r: 0.22, g: 0.30, b: 0.42), "moon.stars": RGB(r: 0.30, g: 0.16, b: 0.32),
        "map": RGB(r: 0.16, g: 0.44, b: 0.42), "pawprint": RGB(r: 0.58, g: 0.36, b: 0.18),
        "teddybear": RGB(r: 0.78, g: 0.40, b: 0.34), "leaf": RGB(r: 0.24, g: 0.46, b: 0.24),
        "heart": RGB(r: 0.66, g: 0.24, b: 0.34), "theatermasks": RGB(r: 0.66, g: 0.44, b: 0.14),
        "globe.americas": RGB(r: 0.16, g: 0.38, b: 0.54), "building.columns": RGB(r: 0.46, g: 0.34, b: 0.22),
        "text.quote": RGB(r: 0.44, g: 0.26, b: 0.40), "lightbulb": RGB(r: 0.62, g: 0.50, b: 0.16),
        "atom": RGB(r: 0.12, g: 0.44, b: 0.56), "function": RGB(r: 0.26, g: 0.32, b: 0.50),
        "paintpalette": RGB(r: 0.62, g: 0.24, b: 0.50), "flame": RGB(r: 0.70, g: 0.28, b: 0.14),
        "graduationcap": RGB(r: 0.18, g: 0.26, b: 0.46), "fork.knife": RGB(r: 0.62, g: 0.36, b: 0.18),
        "cross.case": RGB(r: 0.18, g: 0.48, b: 0.44), "figure.run": RGB(r: 0.20, g: 0.46, b: 0.30),
        "music.note": RGB(r: 0.48, g: 0.22, b: 0.46), "music.quarternote.3": RGB(r: 0.30, g: 0.24, b: 0.42),
        "music.mic": RGB(r: 0.20, g: 0.26, b: 0.44), "waveform": RGB(r: 0.14, g: 0.36, b: 0.58),
        "guitars": RGB(r: 0.54, g: 0.38, b: 0.20), "bolt": RGB(r: 0.32, g: 0.30, b: 0.34),
        "star": RGB(r: 0.74, g: 0.30, b: 0.46), "headphones": RGB(r: 0.30, g: 0.22, b: 0.50),
        "film": RGB(r: 0.24, g: 0.28, b: 0.36), "book.closed": RGB(r: 0.46, g: 0.18, b: 0.20),
        "video": RGB(r: 0.26, g: 0.34, b: 0.44), "mic": RGB(r: 0.36, g: 0.24, b: 0.44),
    ]

    // MARK: Drawing

    /// The cover as a picture: 900×900 for music, 640×960 for books.
    static func draw(_ request: Request) -> CGImage? {
        let size = request.shape == .square ? CGSize(width: 900, height: 900) : CGSize(width: 640, height: 960)
        let w = Int(size.width), h = Int(size.height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let tint = tint(genre: request.genre, title: request.title)
        func colour(_ c: RGB, _ alpha: Double = 1) -> CGColor { CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha) }
        func shade(_ c: RGB, _ by: Double) -> RGB { RGB(r: c.r * (1 - by), g: c.g * (1 - by), b: c.b * (1 - by)) }

        // Background: the tint, deepening toward the bottom corner.
        let gradient = CGGradient(colorsSpace: space, colors: [colour(tint), colour(shade(tint, 0.5))] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: size.height), end: CGPoint(x: size.width, y: 0), options: [])

        // A fine diagonal weave, barely there, so it reads as a printed card and not a flat swatch.
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.035))
        context.setLineWidth(2)
        var x = -size.height
        while x < size.width {
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x + size.height, y: size.height))
            x += 14
        }
        context.strokePath()
        context.restoreGState()

        // The genre's symbol, large and faint, tilted off the corner (as on the game shelves' stand-in tiles).
        let symbolName = request.genre.map(GenreIcon.symbol(for:)) ?? (request.shape == .book ? "book.closed" : "music.note")
        if let symbol = symbolImage(symbolName == "tag" ? (request.shape == .book ? "book.closed" : "music.note") : symbolName,
                                    pointSize: size.width * 0.6) {
            context.saveGState()
            let side = size.width * 0.72
            let aspect = Double(symbol.width) / Double(max(1, symbol.height))
            let rect = CGRect(x: 0, y: 0, width: side * min(1, aspect), height: side / max(1, aspect))
            context.translateBy(x: size.width * 0.78, y: size.height * 0.62)
            context.rotate(by: .pi / 18)
            context.translateBy(x: -rect.width / 2, y: -rect.height / 2)
            context.clip(to: rect, mask: symbol)
            context.setFillColor(CGColor(gray: 1, alpha: 0.13))
            context.fill(rect)
            context.restoreGState()
        }

        // Books get a darker spine down the left edge.
        if request.shape == .book {
            context.setFillColor(colour(shade(tint, 0.62), 0.55))
            context.fill(CGRect(x: 0, y: 0, width: size.width * 0.045, height: size.height))
            context.setFillColor(CGColor(gray: 1, alpha: 0.12))
            context.fill(CGRect(x: size.width * 0.045, y: 0, width: 2, height: size.height))
        }

        // A soft shade under the words, so they read at shelf size on any tint.
        let shadeGradient = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 0.38)] as CFArray, locations: [0, 1])!
        context.drawLinearGradient(shadeGradient, start: CGPoint(x: 0, y: size.height * 0.55), end: CGPoint(x: 0, y: 0), options: [])

        let inset = size.width * (request.shape == .book ? 0.11 : 0.08)
        let left = request.shape == .book ? inset + size.width * 0.02 : inset
        let width = size.width - left - inset

        // The small label pill at the top, like the shelves' system badges.
        let labelFont = font(size: size.width * 0.036, weight: .heavy)
        let labelLine = CTLineCreateWithAttributedString(attributed(request.label, font: labelFont, colour: CGColor(gray: 1, alpha: 0.88), tracking: 2))
        let labelBounds = CTLineGetBoundsWithOptions(labelLine, [])
        let pill = CGRect(x: left, y: size.height - inset - labelBounds.height - size.width * 0.03,
                          width: labelBounds.width + size.width * 0.05, height: labelBounds.height + size.width * 0.03)
        context.setFillColor(CGColor(gray: 0, alpha: 0.22))
        context.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: pill.minX + size.width * 0.025, y: pill.minY + size.width * 0.015 - labelBounds.minY)
        CTLineDraw(labelLine, context)

        // Byline under the title, at the bottom; the title above it, as large as fits in four lines.
        var bottom = inset
        if let byline = request.byline?.trimmingCharacters(in: .whitespaces), !byline.isEmpty {
            let bylineFont = font(size: size.width * 0.05, weight: .semibold)
            let used = drawText(byline, font: bylineFont, colour: CGColor(gray: 1, alpha: 0.78), in: CGRect(x: left, y: bottom, width: width, height: size.width * 0.14),
                                maxLines: 2, context: context, alignBottom: true)
            bottom += used + size.width * 0.025
        }
        let titleTop = pill.minY - size.width * 0.06
        let titleBox = CGRect(x: left, y: bottom, width: width, height: max(10, titleTop - bottom))
        var titleSize = size.width * 0.13
        while titleSize > size.width * 0.06 {
            if fits(request.title, font: font(size: titleSize, weight: .bold), in: titleBox.size, maxLines: 4) { break }
            titleSize -= size.width * 0.006
        }
        drawText(request.title, font: font(size: titleSize, weight: .bold), colour: CGColor(gray: 1, alpha: 1), in: titleBox,
                 maxLines: 4, context: context, alignBottom: true, shadow: true)
        return context.makeImage()
    }

    // MARK: Type

    private enum Weight { case semibold, bold, heavy }

    private static func font(size: CGFloat, weight: Weight) -> CTFont {
        #if os(macOS)
        let w: NSFont.Weight = switch weight { case .semibold: .semibold; case .bold: .bold; case .heavy: .heavy }
        let base = NSFont.systemFont(ofSize: size, weight: w)
        let rounded = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        return rounded as CTFont
        #else
        let w: UIFont.Weight = switch weight { case .semibold: .semibold; case .bold: .bold; case .heavy: .heavy }
        let base = UIFont.systemFont(ofSize: size, weight: w)
        let rounded = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        return rounded as CTFont
        #endif
    }

    private static func attributed(_ text: String, font: CTFont, colour: CGColor, tracking: CGFloat = 0) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): colour,
        ]
        if tracking != 0 { attributes[NSAttributedString.Key(kCTKernAttributeName as String)] = tracking }
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func lines(_ text: String, font: CTFont, colour: CGColor = CGColor(gray: 1, alpha: 1), width: CGFloat) -> [CTLine] {
        let framesetter = CTFramesetterCreateWithAttributedString(attributed(text, font: font, colour: colour))
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: width, height: 100_000), transform: nil)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        return (CTFrameGetLines(frame) as? [CTLine]) ?? []
    }

    /// True when the text fits in the box within `maxLines`, with no word broken across lines.
    private static func fits(_ text: String, font: CTFont, in size: CGSize, maxLines: Int) -> Bool {
        let found = lines(text, font: font, width: size.width)
        let lineHeight = (CTFontGetAscent(font) + CTFontGetDescent(font)) * 1.04
        guard found.count <= maxLines, CGFloat(found.count) * lineHeight <= size.height else { return false }
        // A word wider than the box would be broken mid-word: smaller type instead.
        let white = CGColor(gray: 1, alpha: 1)
        let longest = text.split(separator: " ").map {
            CTLineGetTypographicBounds(CTLineCreateWithAttributedString(attributed(String($0), font: font, colour: white)), nil, nil, nil)
        }.max() ?? 0
        return CGFloat(longest) <= size.width
    }

    /// Draws up to `maxLines` lines ending at the bottom of the box (the last shown line ends in "…" when cut short);
    /// returns the height used.
    @discardableResult
    private static func drawText(_ text: String, font: CTFont, colour: CGColor, in box: CGRect, maxLines: Int,
                                 context: CGContext, alignBottom: Bool, shadow: Bool = false) -> CGFloat {
        let all = lines(text, font: font, colour: colour, width: box.width)
        var shown = Array(all.prefix(maxLines))
        if all.count > maxLines, let last = shown.popLast() {
            let rest = (text as NSString).substring(from: CTLineGetStringRange(last).location)
            let token = CTLineCreateWithAttributedString(attributed("…", font: font, colour: colour))
            let full = CTLineCreateWithAttributedString(attributed(rest, font: font, colour: colour))
            shown.append(CTLineCreateTruncatedLine(full, Double(box.width), .end, token) ?? last)
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = (ascent + descent) * 1.04
        let used = CGFloat(shown.count) * lineHeight
        context.saveGState()
        if shadow { context.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: CGColor(gray: 0, alpha: 0.35)) }
        let top = alignBottom ? box.minY + used : box.maxY
        for (index, line) in shown.enumerated() {
            context.textPosition = CGPoint(x: box.minX, y: top - CGFloat(index) * lineHeight - ascent)
            CTLineDraw(line, context)
        }
        context.restoreGState()
        return used
    }

    /// An SF Symbol's shape as a grey mask (white where the symbol is), or nil.
    private static func symbolImage(_ name: String, pointSize: CGFloat) -> CGImage? {
        #if os(macOS)
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)) else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        #else
        guard let image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)),
              let cg = image.cgImage else { return nil }
        #endif
        return alphaMask(cg)
    }

    /// The symbol's alpha channel as a grey image (clip(to:mask:) reads grey images as coverage).
    private static func alphaMask(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = context.data else { return nil }
        let bytes = Data(bytes: data, count: w * h)
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }
}
