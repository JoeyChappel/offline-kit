import Foundation
import Compression

/// Just enough ZIP to read EPUB books: the central directory, stored and deflated entries. No dependencies.
final class ZipReader: @unchecked Sendable {
    struct Entry { let name: String; let method: UInt16; let compressedSize: Int; let size: Int; let localOffset: Int }

    private let handle: FileHandle
    private let lock = NSLock()
    private(set) var entries: [String: Entry] = [:]

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
        guard readDirectory() else { return nil }
    }

    deinit { try? handle.close() }

    private func read(at offset: Int, count: Int) -> Data? {
        lock.withLock {
            guard (try? handle.seek(toOffset: UInt64(offset))) != nil else { return nil }
            return try? handle.read(upToCount: count)
        }
    }

    private func readDirectory() -> Bool {
        guard let end = lock.withLock({ try? handle.seekToEnd() }) else { return false }
        let total = Int(end)
        let tailSize = min(total, 66_000)   // the end record sits within the last 64 KB
        guard let tail = read(at: total - tailSize, count: tailSize) else { return false }
        let bytes = [UInt8](tail)
        guard let eocd = stride(from: bytes.count - 22, through: 0, by: -1).first(where: {
            bytes[$0] == 0x50 && bytes[$0 + 1] == 0x4B && bytes[$0 + 2] == 0x05 && bytes[$0 + 3] == 0x06
        }) else { return false }
        let count = Int(u16(bytes, eocd + 10))
        let dirSize = Int(u32(bytes, eocd + 12)), dirOffset = Int(u32(bytes, eocd + 16))
        guard let dir = read(at: dirOffset, count: dirSize) else { return false }
        let d = [UInt8](dir)
        var p = 0
        for _ in 0..<count {
            guard p + 46 <= d.count, u32(d, p) == 0x02014B50 else { break }
            let method = u16(d, p + 10)
            let compressed = Int(u32(d, p + 20)), size = Int(u32(d, p + 24))
            let nameLength = Int(u16(d, p + 28)), extra = Int(u16(d, p + 30)), comment = Int(u16(d, p + 32))
            let local = Int(u32(d, p + 42))
            guard p + 46 + nameLength <= d.count else { break }
            let name = String(decoding: d[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries[name] = Entry(name: name, method: method, compressedSize: compressed, size: size, localOffset: local)
            p += 46 + nameLength + extra + comment
        }
        return !entries.isEmpty
    }

    func data(_ name: String) -> Data? {
        guard let e = entries[name] ?? entries.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value,
              let header = read(at: e.localOffset, count: 30) else { return nil }
        let h = [UInt8](header)
        guard h.count == 30, u32(h, 0) == 0x04034B50 else { return nil }
        let start = e.localOffset + 30 + Int(u16(h, 26)) + Int(u16(h, 28))
        guard let raw = read(at: start, count: e.compressedSize) else { return nil }
        switch e.method {
        case 0: return raw
        case 8: return inflate(raw, size: e.size)
        default: return nil
        }
    }

    /// Raw DEFLATE (what ZIP uses) is Compression's COMPRESSION_ZLIB.
    private func inflate(_ data: Data, size: Int) -> Data? {
        guard size > 0 else { return Data() }
        // A book's pages and pictures are well under this; a made-up size mustn't claim gigabytes of memory.
        guard size <= Self.largestEntry, !data.isEmpty else { return nil }
        var out = Data(count: size)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                guard let to = dst.bindMemory(to: UInt8.self).baseAddress,
                      let from = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(to, size, from, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        return written == size ? out : nil
    }

    static let largestEntry = 256 << 20

    private func u16(_ b: [UInt8], _ i: Int) -> UInt16 { UInt16(b[i]) | UInt16(b[i + 1]) << 8 }
    private func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

/// An EPUB book: its metadata, reading order and cover, read from the package file.
struct EPUBBook: Sendable {
    struct Chapter: Sendable, Hashable { let path: String; let title: String }

    let title: String
    let author: String?
    let subjects: [String]
    let chapters: [Chapter]
    let coverPath: String?

    static func open(_ url: URL) -> (EPUBBook, ZipReader)? {
        guard let zip = ZipReader(url: url),
              let container = zip.data("META-INF/container.xml"),
              let opfPath = firstMatch(#"full-path\s*=\s*"([^"]+)""#, in: String(decoding: container, as: UTF8.self)),
              let opfData = zip.data(opfPath) else { return nil }
        let opf = String(decoding: opfData, as: UTF8.self)
        let base = (opfPath as NSString).deletingLastPathComponent
        func resolve(_ href: String) -> String {
            let clean = (href.removingPercentEncoding ?? href).components(separatedBy: "#")[0]
            return base.isEmpty ? clean : (base as NSString).appendingPathComponent(clean)
        }

        // Manifest: id → (href, media type, properties).
        var manifest: [String: (href: String, type: String, props: String)] = [:]
        for item in matches(#"<item\b[^>]*>"#, in: opf) {
            guard let id = attr("id", item), let href = attr("href", item) else { continue }
            manifest[id] = (href, attr("media-type", item) ?? "", attr("properties", item) ?? "")
        }
        // Spine: the reading order.
        let spineIDs = matches(#"<itemref\b[^>]*>"#, in: opf).compactMap { attr("idref", $0) }
        let titles = tocTitles(zip: zip, opf: opf, manifest: manifest, resolve: resolve)
        var chapters: [EPUBBook.Chapter] = []
        for (index, id) in spineIDs.enumerated() {
            guard let entry = manifest[id], entry.type.contains("html") else { continue }
            let path = resolve(entry.href)
            chapters.append(Chapter(path: path, title: friendlyTitle(titles[path], path: path, index: index)))
        }
        guard !chapters.isEmpty else { return nil }

        // Cover: EPUB 3 "cover-image", or EPUB 2 <meta name="cover" content="id">.
        var cover = manifest.values.first(where: { $0.props.contains("cover-image") }).map { resolve($0.href) }
        if cover == nil, let meta = matches(#"<meta\b[^>]*name\s*=\s*"cover"[^>]*>"#, in: opf).first,
           let id = attr("content", meta), let entry = manifest[id] { cover = resolve(entry.href) }
        if cover == nil {
            cover = manifest.values.first(where: { $0.type.hasPrefix("image/") && $0.href.lowercased().contains("cover") }).map { resolve($0.href) }
        }

        let title = text(#"<dc:title[^>]*>([\s\S]*?)</dc:title>"#, in: opf) ?? url.deletingPathExtension().lastPathComponent
        let author = text(#"<dc:creator[^>]*>([\s\S]*?)</dc:creator>"#, in: opf)
        let subjects = matches(#"<dc:subject[^>]*>[\s\S]*?</dc:subject>"#, in: opf).compactMap {
            text(#"<dc:subject[^>]*>([\s\S]*?)</dc:subject>"#, in: $0)
        }
        return (EPUBBook(title: title, author: author, subjects: subjects, chapters: chapters, coverPath: cover), zip)
    }

    /// Book-production labels ("Titlepage", "Imprint", "Uncopyright") and bare file names as words a reader expects.
    static func friendlyTitle(_ label: String?, path: String, index: Int) -> String {
        let names: [String: String] = [
            "titlepage": "Title Page", "title page": "Title Page", "halftitlepage": "Title Page", "half title page": "Title Page",
            "half-title": "Title Page", "halftitle": "Title Page",
            "imprint": "About This Edition", "colophon": "About This Edition", "uncopyright": "Copyright", "copyright": "Copyright",
            "copyright page": "Copyright", "cover": "Cover", "toc": "Contents", "table of contents": "Contents", "contents": "Contents",
            "endnotes": "Notes", "loi": "Illustrations", "dedication": "Dedication", "epigraph": "Epigraph", "preface": "Preface",
            "foreword": "Foreword", "introduction": "Introduction", "acknowledgments": "Acknowledgments", "glossary": "Glossary",
        ]
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            return names[label.lowercased()] ?? label
        }
        // No table-of-contents entry: name it from the file when that says what it is ("chapter-3" → "Chapter 3").
        let file = ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
        if let known = names[file] ?? names[file.replacingOccurrences(of: "-", with: " ")] { return known }
        if let match = file.range(of: #"^(chapter|part|book)[-_ ]?(\d{1,3})$"#, options: .regularExpression) {
            let text = String(file[match])
            let number = text.filter(\.isNumber)
            let word = text.prefix { $0.isLetter }.capitalized
            return "\(word) \(Int(number) ?? index + 1)"
        }
        return "Section \(index + 1)"
    }

    /// Chapter titles from the EPUB 3 nav document or the EPUB 2 NCX, keyed by file path.
    private static func tocTitles(zip: ZipReader, opf: String, manifest: [String: (href: String, type: String, props: String)],
                                  resolve: (String) -> String) -> [String: String] {
        var titles: [String: String] = [:]
        if let nav = manifest.values.first(where: { $0.props.contains("nav") }), let data = zip.data(resolve(nav.href)) {
            let html = String(decoding: data, as: UTF8.self)
            let navBase = (resolve(nav.href) as NSString).deletingLastPathComponent
            for link in matches(#"<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*>([\s\S]*?)</a>"#, in: html) {
                guard let href = attr("href", link), let label = text(#"<a\b[^>]*>([\s\S]*?)</a>"#, in: link) else { continue }
                let clean = (href.removingPercentEncoding ?? href).components(separatedBy: "#")[0]
                let path = navBase.isEmpty ? clean : ((navBase as NSString).appendingPathComponent(clean) as NSString).standardizingPath
                if titles[path] == nil { titles[path] = label }
            }
        } else if let ncx = manifest.values.first(where: { $0.type.contains("dtbncx") }), let data = zip.data(resolve(ncx.href)) {
            let xml = String(decoding: data, as: UTF8.self)
            let ncxBase = (resolve(ncx.href) as NSString).deletingLastPathComponent
            for point in matches(#"<navPoint\b[\s\S]*?<content\b[^>]*/>"#, in: xml) {
                guard let label = text(#"<text>([\s\S]*?)</text>"#, in: point),
                      let content = matches(#"<content\b[^>]*>"#, in: point).last, let src = attr("src", content) else { continue }
                let clean = (src.removingPercentEncoding ?? src).components(separatedBy: "#")[0]
                let path = ncxBase.isEmpty ? clean : ((ncxBase as NSString).appendingPathComponent(clean) as NSString).standardizingPath
                if titles[path] == nil { titles[path] = label }
            }
        }
        return titles
    }

    // MARK: Tiny XML helpers (EPUB package files are small and regular)

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static func attr(_ name: String, _ tag: String) -> String? {
        firstMatch(#"\b\#(name)\s*=\s*"([^"]*)""#, in: tag) ?? firstMatch(#"\b\#(name)\s*=\s*'([^']*)'"#, in: tag)
    }

    /// Inner text with tags removed and entities decoded, or nil if empty.
    private static func text(_ pattern: String, in source: String) -> String? {
        guard let inner = firstMatch(pattern, in: source) else { return nil }
        let stripped = inner.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let decoded = HTMLText.decodeEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return decoded.isEmpty ? nil : decoded
    }
}
