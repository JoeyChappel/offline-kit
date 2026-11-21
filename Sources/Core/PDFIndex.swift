import Foundation
import PDFKit

/// Text from the PDFs inside archives such as the Zimgit libraries (knots, water, first aid, food), which hold
/// documents instead of web pages and have no search index. Built once per archive in the background and cached,
/// so Ask can search and cite them like any article.
final class PDFIndex: @unchecked Sendable {
    static let shared = PDFIndex()

    struct Chunk: Codable, Sendable {
        let path: String      // the PDF inside the archive
        let title: String     // the document's own title
        let page: Int         // 1-based
        let text: String
        let lower: String     // lowercased, for fast matching
    }

    private let lock = NSLock()
    private var store: [String: [Chunk]] = [:]
    private var started = Set<String>()

    /// Chunks for an archive, or none if it has no PDFs or its index is still being built.
    func chunks(for uuid: String) -> [Chunk] { lock.withLock { store[uuid.lowercased()] ?? [] } }

    /// True while any archive's PDFs are still being read.
    var isBuilding: Bool { lock.withLock { !started.subtracting(store.keys).isEmpty } }

    /// Archives worth checking: the Zimgit document libraries, and small archives in general.
    /// (Listing every entry of a large encyclopedia just to look for PDFs would take far too long.)
    static func mayHoldPDFs(_ archive: ZimArchive) -> Bool {
        archive.name.lowercased().hasPrefix("zimgit") || archive.articleCount < 2_000
    }

    /// Loads or builds the index for archives that hold PDFs. Cheap to call after every library scan.
    func prepare(_ archives: [ZimArchive]) {
        for archive in archives where Self.mayHoldPDFs(archive) {
            let id = archive.uuid.lowercased()
            guard lock.withLock({ started.insert(id).inserted }) else { continue }
            Task.detached(priority: .utility) { [self] in
                let cache = Self.cacheURL(id)
                if let data = try? Data(contentsOf: cache), let chunks = try? JSONDecoder().decode([Chunk].self, from: data) {
                    lock.withLock { store[id] = chunks }
                    return
                }
                let chunks = Self.build(archive)
                lock.withLock { store[id] = chunks }
                try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(chunks).write(to: cache, options: .atomic)
            }
        }
    }

    private static func cacheURL(_ id: String) -> URL {
        URL.cachesDirectory.appending(path: "OfflineKit/pdf-text/\(id).json")
    }

    private static func build(_ archive: ZimArchive) -> [Chunk] {
        var chunks: [Chunk] = []
        var total = 0
        for entry in archive.entries(withMimePrefix: "application/pdf", limit: 400) {
            guard total < 40_000_000, let content = archive.content(atPath: entry.path),
                  let doc = PDFDocument(data: content.data) else { continue }
            let title = documentTitle(doc) ?? entry.title
            for index in 0..<doc.pageCount {
                guard let raw = doc.page(at: index)?.string else { continue }
                for piece in split(raw) {
                    total += piece.count
                    chunks.append(Chunk(path: content.path, title: title, page: index + 1, text: piece, lower: piece.lowercased()))
                }
            }
        }
        return chunks
    }

    /// The PDF's title, or its first line if that looks like one; "Knots (3).pdf" says nothing.
    private static func documentTitle(_ doc: PDFDocument) -> String? {
        if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let clean = t.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.count > 3, !clean.lowercased().hasPrefix("microsoft"), !clean.hasSuffix(".doc") { return clean }
        }
        let first = doc.page(at: 0)?.string?.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.count >= 6 && $0.count <= 90 }
        return first
    }

    /// About 1,000 characters per chunk, broken at line ends.
    private static func split(_ text: String) -> [String] {
        let lines = text.replacingOccurrences(of: "\r", with: "\n").split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var out: [String] = []
        var current = ""
        for line in lines {
            if current.count + line.count > 1_000, current.count > 200 { out.append(current); current = "" }
            current += (current.isEmpty ? "" : " ") + line
        }
        if current.count > 80 { out.append(current) }
        return out
    }
}
