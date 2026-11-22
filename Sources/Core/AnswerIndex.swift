import Foundation
import Observation
#if os(macOS)
import IOKit.ps
#elseif canImport(UIKit)
import UIKit
#endif

/// How much of each reference the answer index holds. One place, so it's easy to tune.
///
/// Most answers come from an article's lead: the opening paragraphs that say what the topic is and what to do.
/// The practical references (MedlinePlus, WikiMed, iFixit, Stack Exchange sites, the Zimgit guides) are small
/// enough to index every section. Full Wikipedia has millions of articles, so it gets each article's title and
/// lead only. All indexes share one disk budget, smallest references first: a reference that won't fit is left
/// to libzim's own search, the way Ask searched before, so nothing is lost, only not faster.
enum AnswerIndexPolicy {
    enum Depth: String, Sendable { case full, leads }

    /// Archives with at most this many articles are indexed in full; bigger ones get leads only.
    static var fullArticleLimit: Int {
        #if DEBUG
        // Test hook: OFFLINEKIT_INDEX_FULL_LIMIT=10000 exercises the leads-only policy on a small archive.
        if let forced = ProcessInfo.processInfo.environment["OFFLINEKIT_INDEX_FULL_LIMIT"].flatMap(Int.init) { return forced }
        #endif
        return 60_000
    }

    static func depth(articleCount: Int) -> Depth { articleCount <= fullArticleLimit ? .full : .leads }

    /// All answer indexes together: a tenth of the free space (counting what they already use), at most 8 GB on
    /// a Mac and 1.5 GB on iPhone and iPad.
    static func totalBudget(free: Int64, used: Int64) -> Int64 {
        #if os(macOS)
        let cap: Int64 = 8 << 30
        #else
        let cap: Int64 = 1536 << 20
        #endif
        return min(cap, (free + used) / 10)
    }

    /// Rough index size per article, to skip a reference that can't fit before spending hours on it. A leads-only
    /// index keeps the words but not the text, and reads a hit's lead back from the archive: 520 bytes an article
    /// with its title index, for leads of about 700 characters (120 words at most), measured on a 300,000-article
    /// test archive. Real leads use more distinct words, hence the margin: about 4.8 GB for full English Wikipedia
    /// (6.8 million articles). The build still stops if the index outgrows the budget.
    static func estimatedBytes(articles: Int, depth: Depth) -> Int64 {
        Int64(articles) * (depth == .full ? 20_000 : 700)
    }

    /// Most words kept from a lead in a leads-only index.
    static let leadWords = 120

    /// The most HTML read from one article: the first part is where the passages are.
    static func maxHTMLBytes(_ depth: Depth) -> Int { depth == .full ? 200_000 : 32_000 }
    static func maxPassages(_ depth: Depth) -> Int { depth == .full ? 40 : 1 }
    /// Articles read and written per transaction. Small enough that pausing for a question is quick.
    static func chunk(_ depth: Depth) -> Int { depth == .full ? 60 : 400 }

    /// Threads turning articles into passages: one on battery, a few on power (one more SQLite writer keeps up
    /// with about three; measured on an M4 Pro). iPhone and iPad stay at two to keep cool while charging.
    static func workers(plugged: Bool) -> Int {
        #if DEBUG
        // Test hook: OFFLINEKIT_INDEX_WORKERS=1 measures the battery path on power.
        if let forced = ProcessInfo.processInfo.environment["OFFLINEKIT_INDEX_WORKERS"].flatMap(Int.init) { return max(1, forced) }
        #endif
        guard plugged else { return 1 }
        let cores = ProcessInfo.processInfo.activeProcessorCount
        #if os(macOS)
        return min(3, max(1, cores / 3))
        #else
        return min(2, max(1, cores / 3))
        #endif
    }

    /// Sections that list sources or links rather than say anything.
    static let skippedSections: Set<String> = ["references", "external links", "see also", "further reading", "notes",
                                               "bibliography", "sources", "citations", "footnotes", "related articles"]
}

/// One passage found in an answer index.
struct IndexHit: Sendable {
    let path: String
    let title: String
    let heading: String
    let text: String
    let lead: Bool
    /// Position in the article, for putting two passages of one article back in reading order.
    let order: Int
    /// BM25, larger is better (SQLite returns it negated).
    var bm25: Double
    /// Question words the passage is sure to contain, from the query that found it. A leads-only index keeps no
    /// text (`text` is empty until the lead is read back), so this is what it's scored on.
    var matched: [String] = []
}

/// One reference's passages in an SQLite FTS5 table.
final class PassageStore: @unchecked Sendable {
    static let version = "4"
    let url: URL
    let depth: AnswerIndexPolicy.Depth
    private let lock = NSLock()
    private var db: SQLiteDB?
    /// Words found to be common or not (see `isCommon`, `isCommonTitle`). Guarded by `lock`.
    private var common: [String: Bool] = [:]
    private var commonTitle: [String: Bool] = [:]

    /// A full index keeps each passage's text, so a hit needs nothing from the archive. A leads-only index is
    /// contentless: it keeps the words for searching (and the path, title and position) but not the text, which
    /// halves its size; a hit's lead is read back from the archive.
    init(url: URL, depth: AnswerIndexPolicy.Depth) throws {
        self.url = url
        self.depth = depth
        let db = try SQLiteDB(url: url)
        let content = depth == .leads ? ", content='', contentless_unindexed=1" : ""
        try db.script("""
            PRAGMA auto_vacuum=INCREMENTAL; PRAGMA journal_mode=TRUNCATE; PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE VIRTUAL TABLE IF NOT EXISTS passages USING fts5(title, heading, body, path UNINDEXED, lead UNINDEXED,
                ord UNINDEXED, name UNINDEXED, tokenize='porter unicode61 remove_diacritics 2'\(content));
            """)
        // A leads-only index (a huge reference) also keeps its titles on their own: see `titled`.
        if depth == .leads {
            try db.script("""
                CREATE VIRTUAL TABLE IF NOT EXISTS titles USING fts5(title, first UNINDEXED, last UNINDEXED,
                    tokenize='porter unicode61 remove_diacritics 2', content='', contentless_unindexed=1);
                """)
        }
        self.db = db
    }

    func close() { lock.withLock { db?.close(); db = nil } }

    func meta(_ key: String) -> String? {
        lock.withLock {
            var value: String?
            try? db?.run("SELECT value FROM meta WHERE key = ?", [.text(key)]) { value = $0.text(0) }
            return value
        }
    }

    func setMeta(_ values: [String: String]) throws {
        try lock.withLock {
            guard let db else { return }
            try db.transaction { for (k, v) in values { try db.run("INSERT OR REPLACE INTO meta VALUES (?, ?)", [.text(k), .text(v)]) } }
        }
    }

    struct Draft { let heading: String; let text: String; let lead: Bool; let order: Int }

    /// Adds one chunk of articles and moves the cursor, in one transaction, so a relaunch resumes exactly here.
    func append(_ articles: [(path: String, title: String, passages: [Draft])], cursor: Int, seconds: Double) throws {
        try lock.withLock {
            guard let db else { return }
            try db.transaction {
                var added = 0
                for article in articles {
                    var first: Int64?
                    for p in article.passages {
                        try db.run("INSERT INTO passages(title, heading, body, path, lead, ord, name) VALUES (?, ?, ?, ?, ?, ?, ?)",
                                   [.text(article.title), .text(p.heading), .text(p.text), .text(article.path),
                                    .int(p.lead ? 1 : 0), .int(Int64(p.order)), .text(article.title)])
                        if first == nil { first = db.lastInsertRowID }
                        added += 1
                    }
                    // The article's title on its own, pointing at its passages (inserted together, so their rowids run on).
                    if depth == .leads, let first {
                        try db.run("INSERT INTO titles(title, first, last) VALUES (?, ?, ?)",
                                   [.text(article.title), .int(first), .int(db.lastInsertRowID)])
                    }
                }
                var count = 0
                try db.run("SELECT value FROM meta WHERE key = 'passages'") { count = Int($0.text(0)) ?? 0 }
                try db.run("INSERT OR REPLACE INTO meta VALUES ('passages', ?)", [.text(String(count + added))])
                try db.run("INSERT OR REPLACE INTO meta VALUES ('cursor', ?)", [.text(String(cursor))])
                try db.run("INSERT OR REPLACE INTO meta VALUES ('seconds', ?)", [.text(String(format: "%.2f", seconds))])
            }
        }
    }

    /// Merges the index's segments once it's complete, and gives the space they used back: smaller and faster to search.
    func optimize() {
        lock.withLock {
            try? db?.script("""
                INSERT INTO passages(passages) VALUES('optimize');
                \(depth == .leads ? "INSERT INTO titles(titles) VALUES('optimize');" : "")
                PRAGMA incremental_vacuum;
                """)
        }
    }

    var bytes: Int64 { Self.fileBytes(url) }

    static func fileBytes(_ url: URL) -> Int64 {
        let fm = FileManager.default
        return [url.path, url.path + "-journal", url.path + "-wal"].reduce(Int64(0)) { sum, path in
            sum + ((try? fm.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0)
        }
    }

    /// BM25 search, narrow to broad like Ask's libzim searches: every word, then word pairs as phrases, then the
    /// three most specific words, and any word only when all that found almost nothing; and always the articles
    /// named for the question's words. Title matches weigh most, then section headings.
    ///
    /// The cost of a ranked query is the passages it has to score, so on a huge index (a leads-only Wikipedia)
    /// queries that would match tens of thousands of passages are left out: a phrase of two common words
    /// ("power outage" in an encyclopedia) is counted first, cheaply and only up to `broadLimit`, and skipped when
    /// it reaches it (the title search finds the article named for it), and a leads-only index looks titles up in
    /// a separate index of titles instead of filtering every passage by its title column.
    func search(terms: [String], phrases: [String], limit: Int) -> [IndexHit] {
        guard !terms.isEmpty else { return [] }
        func quoted(_ words: [String]) -> String { words.map { "\"\($0)\"" }.joined(separator: " ") }
        let common = Set(terms.filter { isCommon($0) })
        // Each query with the words every hit of it must contain, and whether it may be too broad to rank.
        var queries: [(match: String, words: [String], check: Bool)] = [(quoted(terms), terms, false)]
        // Long questions: the pairs with an uncommon word first, and at most four.
        let pairs = phrases.map { ($0, $0.split(separator: " ").map(String.init)) }
            .sorted { $0.1.filter(common.contains).count < $1.1.filter(common.contains).count }
            .prefix(4)
        queries += pairs.map { ("\"\($0.0)\"", $0.1, $0.1.allSatisfy(common.contains)) }
        if terms.count > 3 {
            let specific = Array(terms.sorted { (common.contains($0) ? 1 : 0, -$0.count) < (common.contains($1) ? 1 : 0, -$1.count) }.prefix(3))
            queries.append((quoted(specific), specific, specific.allSatisfy(common.contains)))
        }
        var hits: [IndexHit] = []
        var seen = Set<String>()
        func add(_ found: [IndexHit], _ words: [String]) {
            for var hit in found where seen.insert("\(hit.path)#\(hit.order)").inserted {
                hit.matched = words
                hits.append(hit)
            }
        }
        // Broader queries only while the narrower ones found few passages: each costs a few milliseconds.
        for q in queries where hits.count < 40 {
            if q.check && isBroad(q.match) { continue }
            add(query(q.match, limit: limit), q.words)
        }
        // Articles named for any of the words, always: a passage holds only part of an article, so "signs of
        // dehydration in a baby" can miss "Dehydration" when its signs and its babies are in different passages.
        // A full index (at most 60,000 articles) asks its passages, which picks each article's passages that best match;
        // a leads-only one has one passage an article and asks its title index, whose BM25 is on a different scale:
        // the best title counts as much as the best passage.
        let any = terms.map { "\"\($0)\"" }.joined(separator: " OR ")
        var named = depth == .full ? query("title : (\(any))", limit: limit / 2) : titled(terms, limit: limit / 2)
        if depth == .leads, let bestTitle = named.map(\.bm25).max(), bestTitle > 0 {
            let top = hits.map(\.bm25).max() ?? bestTitle
            for i in named.indices { named[i].bm25 = top * named[i].bm25 / bestTitle }
        }
        add(named, [])
        // Still almost nothing: any word that isn't so common that scoring every passage with it would be slow.
        if hits.count < 10 && terms.count > 1 {
            let uncommon = terms.filter { !common.contains($0) }.map { "\"\($0)\"" }
            if !uncommon.isEmpty { add(query(uncommon.joined(separator: " OR "), limit: limit), []) }
        }
        return hits
    }

    /// Most matches a query may have and still be ranked (about 3 ms of scoring).
    static let broadLimit = 8_000

    /// True when a query matches at least `broadLimit` passages. Counting stops there and scores nothing.
    private func isBroad(_ match: String) -> Bool {
        lock.withLock {
            let count = (try? db?.scalar("SELECT count(*) FROM (SELECT rowid FROM passages WHERE passages MATCH ? LIMIT \(Self.broadLimit))",
                                         [.text(match)])) ?? 0
            #if DEBUG
            if Self.traceQueries && count >= Self.broadLimit {
                FileHandle.standardError.write(Data("  index query skipped, too broad: \(match)\n".utf8))
            }
            #endif
            return count >= Self.broadLimit
        }
    }

    /// Passages of the articles whose titles have the most of these words: the best few titles from the title
    /// index (words in thousands of titles left out, unless that's all there is), then the first three passages of
    /// each (the lead and what follows), read by rowid, so many articles get a turn. They're scored by their title's
    /// BM25, not by a passage query: BM25 counts every passage that has each word, which on a big index
    /// costs milliseconds per query even when it scores one row.
    private func titled(_ terms: [String], limit: Int) -> [IndexHit] {
        let usable = terms.filter { !isCommonTitle($0) }
        let words = usable.isEmpty ? terms : usable
        let any = words.map { "\"\($0)\"" }.joined(separator: " OR ")
        #if DEBUG
        let started = Date()
        defer {
            if Self.traceQueries {
                FileHandle.standardError.write(Data(String(format: "  title query %6.2f ms  %@\n", Date().timeIntervalSince(started) * 1000, any).utf8))
            }
        }
        #endif
        return lock.withLock {
            var articles: [(first: Int64, last: Int64, score: Double)] = []
            try? db?.run("SELECT first, last, bm25(titles) FROM titles WHERE titles MATCH ? ORDER BY rank LIMIT 24", [.text(any)]) { row in
                articles.append((row.int(0), row.int(1), -row.double(2)))
            }
            var hits: [IndexHit] = []
            for article in articles where hits.count < limit {
                try? db?.run("SELECT path, name, heading, body, lead, ord FROM passages WHERE rowid BETWEEN ? AND ? LIMIT 3",
                             [.int(article.first), .int(article.last)]) { row in
                    hits.append(IndexHit(path: row.text(0), title: row.text(1), heading: row.text(2), text: row.text(3),
                                         lead: row.int(4) == 1, order: Int(row.int(5)), bm25: article.score))
                }
            }
            return Array(hits.prefix(limit))
        }
    }

    /// True when a word is in at least 2,000 titles ("river" in an encyclopedia). Remembered like `isCommon`.
    private func isCommonTitle(_ term: String) -> Bool {
        lock.withLock {
            if let known = commonTitle[term] { return known }
            let count = (try? db?.scalar("SELECT count(*) FROM (SELECT rowid FROM titles WHERE titles MATCH ? LIMIT 2000)",
                                         [.text("\"\(term)\"")])) ?? 0
            if commonTitle.count > 5_000 { commonTitle.removeAll() }
            commonTitle[term] = count >= 2000
            return count >= 2000
        }
    }

    #if DEBUG
    static let traceQueries = ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE_QUERIES"] != nil
    #endif

    /// True when a word is in more than 1,500 passages ("water" in an encyclopedia). Counting stops there, so
    /// it's quick even on a huge index.
    /// Remembered per word: a complete index doesn't change.
    private func isCommon(_ term: String) -> Bool {
        lock.withLock {
            if let known = common[term] { return known }
            let count = (try? db?.scalar("SELECT count(*) FROM (SELECT rowid FROM passages WHERE passages MATCH ? LIMIT 1500)",
                                         [.text("\"\(term)\"")])) ?? 0
            if common.count > 5_000 { common.removeAll() }
            common[term] = count >= 1500
            return count >= 1500
        }
    }

    private func query(_ match: String, limit: Int) -> [IndexHit] {
        #if DEBUG
        let started = Date()
        defer {
            if Self.traceQueries {
                FileHandle.standardError.write(Data(String(format: "  index query %6.2f ms  %@\n", Date().timeIntervalSince(started) * 1000, match).utf8))
            }
        }
        #endif
        return lock.withLock {
            var hits: [IndexHit] = []
            try? db?.run("""
                SELECT path, name, heading, body, lead, ord, bm25(passages, 5.0, 2.0, 1.0, 0, 0, 0, 0) AS score
                FROM passages WHERE passages MATCH ? ORDER BY score LIMIT ?
                """, [.text(match), .int(Int64(limit))]) { row in
                hits.append(IndexHit(path: row.text(0), title: row.text(1), heading: row.text(2), text: row.text(3),
                                     lead: row.int(4) == 1, order: Int(row.int(5)), bm25: -row.double(6)))
            }
            return hits
        }
    }

    // MARK: Passages from HTML

    /// The passages of each article read from an archive (articles with none are left out).
    static func drafts(_ articles: [ZimArticle], depth: AnswerIndexPolicy.Depth) -> [(path: String, title: String, passages: [Draft])] {
        articles.compactMap { article in
            let passages = passages(html: article.html, depth: depth)
            return passages.isEmpty ? nil : (article.path, article.title, passages)
        }
    }

    /// Splits an article into passages of about 80 to 200 words, each within one section. A leads-only index
    /// reads only the HTML before the first section heading.
    static func passages(html: Data, depth: AnswerIndexPolicy.Depth) -> [Draft] {
        html.withUnsafeBytes { raw in
            let all = raw.bindMemory(to: UInt8.self)
            let part = depth == .leads ? UnsafeBufferPointer(rebasing: all[..<leadEnd(all)]) : all
            return passages(blocks: HTMLText.sections(utf8: part), depth: depth)
        }
    }

    static func passages(html: String, depth: AnswerIndexPolicy.Depth) -> [Draft] {
        passages(html: Data(html.utf8), depth: depth)
    }

    private static func passages(blocks: [(heading: String?, text: String)], depth: AnswerIndexPolicy.Depth) -> [Draft] {
        let hasLead = blocks.contains { $0.heading == nil }
        var out: [Draft] = []
        var current: [String] = [], words = 0, heading: String?, lead = false
        let limit = AnswerIndexPolicy.maxPassages(depth)

        func flush() {
            guard !current.isEmpty, out.count < limit else { current = []; words = 0; return }
            out.append(Draft(heading: heading ?? "", text: current.joined(separator: " "), lead: lead, order: out.count))
            current = []
            words = 0
        }

        for block in blocks {
            if let h = block.heading, AnswerIndexPolicy.skippedSections.contains(h.lowercased()) { continue }
            let isLead = block.heading == nil || (!hasLead && out.isEmpty && (heading == nil || heading == block.heading))
            if depth == .leads && !isLead { break }
            if block.heading != heading || isLead != lead {
                flush()
                heading = block.heading
                lead = isLead
            }
            for piece in pieces(block.text) {
                let n = wordCount(piece)
                if words > 0 && words + n > 200 { flush() }
                current.append(piece)
                words += n
                if words >= 80 { flush() }
            }
            if out.count >= limit { break }
        }
        flush()
        if depth == .leads, let first = out.first {
            return [Draft(heading: first.heading, text: trimmedWords(first.text, AnswerIndexPolicy.leadWords), lead: true, order: 0)]
        }
        return out
    }

    /// At most `limit` words, ending at a sentence when one ends in the second half.
    static func trimmedWords(_ text: String, _ limit: Int) -> String {
        let words = text.split(separator: " ")
        guard words.count > limit else { return text }
        let head = words.prefix(limit).joined(separator: " ")
        if let end = head.range(of: ". ", options: .backwards), head.distance(from: head.startIndex, to: end.lowerBound) > head.count / 2 {
            return String(head[..<end.lowerBound]) + "."
        }
        return head
    }

    /// A leads-only hit's text, read back from the archive: the same passage the index was built from.
    static func leadText(archive: ZimArchive, path: String) -> String? {
        if let cached = ParagraphCache.shared.get(archive: archive.uuid, path: "#lead#" + path) { return cached.paragraphs.first }
        guard let data = archive.data(atPath: path, offset: 0, length: UInt(AnswerIndexPolicy.maxHTMLBytes(.leads))),
              let text = passages(html: data, depth: .leads).first?.text else { return nil }
        ParagraphCache.shared.put(archive: archive.uuid, path: "#lead#" + path, finalPath: path, paragraphs: [text])
        return text
    }

    /// Where the lead ends: the first section heading ("<h2", any case) that follows a paragraph ("<p"), or the
    /// end. All a leads-only index reads, and much quicker to clean up than the whole article.
    static func leadEnd(_ html: UnsafeBufferPointer<UInt8>) -> Int {
        func next(_ second: UInt8, _ third: UInt8?, from start: Int) -> Int? {
            var i = start
            while i + 1 < html.count, let base = html.baseAddress,
                  let p = memchr(base + i, 0x3C, html.count - i) {
                let at = base.distance(to: p.assumingMemoryBound(to: UInt8.self))
                if at + 1 < html.count, html[at + 1] | 0x20 == second,
                   third == nil || (at + 2 < html.count && html[at + 2] == third) { return at }
                i = at + 1
            }
            return nil
        }
        guard let paragraph = next(0x70, nil, from: 0) else { return html.count }        // "<p"
        return next(0x68, 0x32, from: paragraph + 2) ?? html.count                       // "<h2"
    }

    /// Words in a passage: runs of characters between spaces.
    static func wordCount(_ text: String) -> Int {
        var count = 0, inWord = false
        for c in text.utf8 {
            if c == 0x20 { inWord = false } else if !inWord { inWord = true; count += 1 }
        }
        return count
    }

    /// A paragraph, or a long one cut at sentence ends into parts of about 150 words.
    private static func pieces(_ paragraph: String) -> [String] {
        guard wordCount(paragraph) > 200 else { return [paragraph] }
        var parts: [String] = [], current = "", count = 0
        paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence = sentence?.trimmingCharacters(in: .whitespaces), !sentence.isEmpty else { return }
            let n = wordCount(sentence)
            if count > 0 && count + n > 150 { parts.append(current); current = ""; count = 0 }
            current += (current.isEmpty ? "" : " ") + sentence
            count += n
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}

/// Builds and serves one passage index per reference, in the background, so Ask can go straight to the passages
/// that answer a question instead of searching each archive and reading whole articles.
final class AnswerIndex: @unchecked Sendable {
    static let shared = AnswerIndex()

    enum State: Sendable, Equatable {
        case waiting
        case building(done: Int, total: Int)
        case ready
        /// Too big for the disk budget: Ask searches it the usual way.
        case tooLarge
        case failed(String)
    }

    struct Entry {
        let archive: ZimArchive
        let key: String
        let depth: AnswerIndexPolicy.Depth
        var state: State
        var bytes: Int64 = 0
        var buildSeconds: Double = 0
    }

    enum Pause: String, Sendable { case user, lowPower, battery }

    private let condition = NSCondition()
    /// One library load at a time.
    private let loadLock = NSLock()
    // Everything below is guarded by `condition`.
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var stores: [String: PassageStore] = [:]
    private var userPaused = KitSettings.shared.bool(forKey: "answerIndexPaused") ?? false
    private var powerPause: Pause?
    private var asking = 0
    /// On mains power: indexing may use a few cores at utility priority instead of one at background priority.
    private var plugged = AnswerIndexStatus.pluggedIn()
    private var generation = 0
    private var started = false
    private var lastPublish = Date.distantPast

    static var folder: URL { KitLocation.caches.appending(path: "OfflineKit/answer-index", directoryHint: .isDirectory) }

    /// Reads and cleans up chunks on power. Its own work only; it waits for nothing.
    private let workers = DispatchQueue(label: "Answer index workers", qos: .utility, attributes: .concurrent)

    private init() {}

    // MARK: Library

    /// Opens the indexes of these references and queues the missing ones. Cheap to call after every library scan;
    /// the work happens off the calling thread.
    func prepare(_ archives: [ZimArchive]) {
        Task.detached(priority: .utility) { [self] in self.load(archives) }
    }

    /// Blocking form of `prepare`, for the command-line tool.
    func load(_ archives: [ZimArchive]) {
        loadLock.lock()
        defer { loadLock.unlock() }
        SemanticRanker.shared.warm()
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let files = (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var current: [String: (ZimArchive, String)] = [:]
        for archive in archives where Self.indexable(archive) {
            current[archive.uuid.lowercased()] = (archive, Self.key(archive))
        }
        // Clean up: an archive that changed gets a new index; one that's been gone a week (an unplugged drive
        // comes back, a deleted archive doesn't) loses its index.
        for file in files where file.pathExtension == "sqlite" {
            let name = file.deletingPathExtension().lastPathComponent
            let uuid = String(name.prefix { $0 != "_" })
            if let (_, key) = current[uuid] {
                if name != key { Self.remove(file) } else { try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path) }
            } else {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified < Date().addingTimeInterval(-7 * 86_400) { Self.remove(file) }
            }
        }

        var opened: [String: (Entry, PassageStore?)] = [:]
        for (uuid, (archive, key)) in current {
            if let existing = condition.withLock({ entries[uuid] }), existing.key == key { continue }
            let depth = AnswerIndexPolicy.depth(articleCount: Int(archive.articleCount))
            var entry = Entry(archive: archive, key: key, depth: depth, state: .waiting)
            let url = Self.folder.appending(path: key + ".sqlite")
            var store: PassageStore?
            if fm.fileExists(atPath: url.path) {
                if let s = try? PassageStore(url: url, depth: depth), s.meta("version") == PassageStore.version, s.meta("depth") == depth.rawValue {
                    entry.bytes = s.bytes
                    entry.buildSeconds = Double(s.meta("seconds") ?? "") ?? 0
                    switch s.meta("state") {
                    case "complete": entry.state = .ready; store = s
                    case "tooLarge": entry.state = .tooLarge; s.close()
                    default:
                        entry.state = .building(done: Int(s.meta("cursor") ?? "") ?? 0, total: Int(archive.entryCount))
                        s.close()
                    }
                } else {
                    Self.remove(url)
                }
            }
            opened[uuid] = (entry, store)
        }
        condition.withLock {
            for (uuid, value) in opened {
                stores[uuid]?.close()
                entries[uuid] = value.0
                stores[uuid] = value.1
            }
            for uuid in entries.keys where current[uuid] == nil {
                stores[uuid]?.close()
                stores[uuid] = nil
                entries[uuid] = nil
            }
            // Smallest first: many references are ready quickly, and the huge one waits for spare time.
            order = entries.keys.sorted { (entries[$0]!.archive.articleCount, $0) < (entries[$1]!.archive.articleCount, $1) }
            if !started {
                started = true
                let thread = Thread { [self] in self.builderLoop() }
                thread.name = "Answer index"
                thread.qualityOfService = .background
                thread.stackSize = 4 << 20
                thread.start()
            }
            condition.broadcast()
        }
        publish(force: true)
    }

    /// Maps hold vector tiles, not articles.
    static func indexable(_ archive: ZimArchive) -> Bool {
        archive.articleCount > 0 && !archive.name.lowercased().hasPrefix("maps_")
    }

    /// Archive UUID, size and modification date: a changed file gets a new index.
    static func key(_ archive: ZimArchive) -> String {
        let values = try? URL(fileURLWithPath: archive.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let size = values?.fileSize ?? 0
        let modified = Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(archive.uuid.lowercased())_\(size)_\(modified)"
    }

    private static func remove(_ url: URL) {
        for suffix in ["", "-journal", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    // MARK: Ask

    /// The index for this archive when it's complete; nil means search it the usual way.
    func store(for archive: ZimArchive) -> PassageStore? {
        condition.withLock { stores[archive.uuid.lowercased()] }
    }

    /// A question is being answered: indexing waits until it's done. Calls nest; balance each with `endAsk`.
    func beginAsk() { condition.withLock { asking += 1 } }

    func endAsk() {
        condition.withLock {
            asking = max(0, asking - 1)
            condition.broadcast()
        }
    }

    // MARK: Controls

    var isPaused: Bool { condition.withLock { userPaused } }

    func setPaused(_ paused: Bool) {
        KitSettings.shared.set(paused, forKey: "answerIndexPaused")
        condition.withLock {
            userPaused = paused
            condition.broadcast()
        }
        publish(force: true)
    }

    /// On mains power or not (reported by the app; macOS and tvOS also know it at launch).
    func setPlugged(_ value: Bool) {
        condition.withLock { plugged = value }
    }

    /// The builder thread's priority: utility on power, so it can use the fast cores; background otherwise, so it
    /// stays on the efficiency cores and its disk writes yield to everything else.
    private static func setPriority(plugged: Bool) {
        pthread_set_qos_class_self_np(plugged ? QOS_CLASS_UTILITY : QOS_CLASS_BACKGROUND, 0)
    }

    /// Low Power Mode or a low battery (reported by the app, which can read the battery).
    func setPowerPause(_ pause: Pause?) {
        let changed: Bool = condition.withLock {
            guard powerPause != pause else { return false }
            powerPause = pause
            condition.broadcast()
            return true
        }
        if changed { publish(force: true) }
    }

    /// Deletes every index and builds them again. Returns at once: closing an index waits for any query or merge
    /// in progress, and deleting gigabytes takes a moment, so neither happens on the caller's (main) thread.
    func rebuild() {
        Task.detached(priority: .utility) { [self] in self.rebuildNow() }
    }

    private func rebuildNow() {
        let archives: [ZimArchive] = condition.withLock {
            generation += 1
            for store in stores.values { store.close() }
            stores.removeAll()
            let list = entries.values.map(\.archive)
            entries.removeAll()
            return list
        }
        let fm = FileManager.default
        for file in (try? fm.contentsOfDirectory(at: Self.folder, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: file) }
        prepare(archives)
    }

    // MARK: Building

    private func builderLoop() {
        while true {
            condition.lock()
            var job: (uuid: String, entry: Entry, generation: Int)?
            while job == nil {
                if userPaused == false, powerPause == nil, asking == 0,
                   let uuid = order.first(where: { uuid in
                       switch entries[uuid]?.state { case .waiting, .building: true; default: false }
                   }), let entry = entries[uuid] {
                    job = (uuid, entry, generation)
                } else {
                    condition.wait(until: Date().addingTimeInterval(5))
                }
            }
            condition.unlock()
            if let job { build(job.uuid, job.entry, generation: job.generation) }
        }
    }

    /// Waits while a question is answered or indexing is paused. False when this build should stop
    /// (a rebuild started, or the archive left the library).
    private func mayContinue(_ uuid: String, generation: Int) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while true {
            guard self.generation == generation, entries[uuid] != nil else { return false }
            if asking == 0 && !userPaused && powerPause == nil { return true }
            if userPaused || powerPause != nil { return false }   // the loop picks it up again when resumed
            condition.wait(until: Date().addingTimeInterval(0.25))
        }
    }

    private func build(_ uuid: String, _ entry: Entry, generation: Int) {
        let archive = entry.archive, depth = entry.depth
        let articles = Int(archive.articleCount)
        // Read in storage order, so positions run over every entry (images too); the estimate counts articles.
        let total = Int(archive.entryCount)
        let url = Self.folder.appending(path: entry.key + ".sqlite")
        let store: PassageStore
        do {
            store = try PassageStore(url: url, depth: depth)
            if store.meta("version") == nil {
                try store.setMeta(["version": PassageStore.version, "depth": depth.rawValue, "state": "building",
                                   "cursor": "0", "passages": "0", "total": String(total), "seconds": "0"])
            }
        } catch {
            update(uuid, generation) { $0.state = .failed(error.localizedDescription) }
            return
        }
        defer { if store !== condition.withLock({ stores[uuid] }) { store.close() } }

        var cursor = Int(store.meta("cursor") ?? "") ?? 0
        var seconds = Double(store.meta("seconds") ?? "") ?? 0
        // Skip a reference that clearly can't fit, before spending hours on it.
        let budget = remainingBudget(excluding: uuid)
        if cursor == 0, AnswerIndexPolicy.estimatedBytes(articles: articles, depth: depth) > budget {
            try? store.setMeta(["state": "tooLarge"])
            update(uuid, generation) { $0.state = .tooLarge; $0.bytes = store.bytes }
            return
        }
        update(uuid, generation) { $0.state = .building(done: cursor, total: total) }

        let chunk = AnswerIndexPolicy.chunk(depth)
        #if DEBUG
        var waitTime = 0.0, writeTime = 0.0
        #endif
        // Chunks are read and turned into passages ahead: on power by a few worker threads, while this one writes the
        // chunks before them; otherwise one at a time on this thread, at background priority. Written in order,
        // one transaction per chunk, so a relaunch resumes exactly where the last one ended.
        var ahead: ChunkWork?
        defer { _ = ahead?.results() }   // workers never touch the store, but don't leave them running
        while cursor < total {
            guard mayContinue(uuid, generation: generation) else { return }
            let lanes = AnswerIndexPolicy.workers(plugged: condition.withLock { plugged })
            Self.setPriority(plugged: lanes > 1)
            let start = Date()
            let work = ahead.flatMap { $0.start == cursor ? $0 : nil }
                ?? ChunkWork(archive: archive, depth: depth, from: cursor, chunks: lanes, total: total, queue: lanes > 1 ? workers : nil)
            let batches = work.results()
            #if DEBUG
            waitTime += Date().timeIntervalSince(start)
            #endif
            ahead = lanes > 1 && work.end < total
                ? ChunkWork(archive: archive, depth: depth, from: work.end, chunks: lanes, total: total, queue: workers) : nil
            #if DEBUG
            let written = Date()
            #endif
            do {
                for (i, batch) in batches.enumerated() {
                    cursor = min(total, work.starts[i] + chunk)
                    try store.append(batch, cursor: cursor, seconds: seconds + Date().timeIntervalSince(start))
                }
                #if DEBUG
                writeTime += Date().timeIntervalSince(written)
                #endif
                seconds += Date().timeIntervalSince(start)
            } catch {
                update(uuid, generation) { $0.state = .failed(error.localizedDescription) }
                return
            }
            let bytes = store.bytes
            if bytes > budget {
                try? store.setMeta(["state": "tooLarge"])
                update(uuid, generation) { $0.state = .tooLarge; $0.bytes = bytes }
                return
            }
            update(uuid, generation) { $0.state = .building(done: cursor, total: total); $0.bytes = bytes; $0.buildSeconds = seconds }
        }
        let start = Date()
        store.optimize()
        seconds += Date().timeIntervalSince(start)
        try? store.setMeta(["state": "complete", "seconds": String(format: "%.2f", seconds)])
        let bytes = store.bytes
        condition.withLock {
            guard self.generation == generation, entries[uuid] != nil else { return }
            entries[uuid]?.state = .ready
            entries[uuid]?.bytes = bytes
            entries[uuid]?.buildSeconds = seconds
            stores[uuid] = store
        }
        publish(force: true)
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
            FileHandle.standardError.write(Data(String(format: "answer index: %@ %@ %d articles, %.1f MB, %.1fs (this run: waiting for passages %.1fs, writing %.1fs)\n",
                                                       archive.title, depth.rawValue, articles, Double(bytes) / 1e6, seconds, waitTime, writeTime).utf8))
        }
        #endif
    }

    private func update(_ uuid: String, _ generation: Int, _ change: (inout Entry) -> Void) {
        condition.withLock {
            guard self.generation == generation, entries[uuid] != nil else { return }
            change(&entries[uuid]!)
        }
        publish(force: false)
    }

    private func remainingBudget(excluding uuid: String) -> Int64 {
        let used = condition.withLock { entries.filter { $0.key != uuid }.values.reduce(Int64(0)) { $0 + $1.bytes } }
        // Plain free space: the "important usage" figure can take seconds to work out.
        let free = Int64((try? Self.folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0)
        return max(0, AnswerIndexPolicy.totalBudget(free: free, used: used) - used)
    }

    // MARK: Status

    struct Snapshot: Sendable, Equatable {
        struct Row: Sendable, Equatable, Identifiable {
            let id: String
            let title: String
            let articles: Int
            let depth: AnswerIndexPolicy.Depth
            let state: State
            let bytes: Int64
            let seconds: Double
        }
        var rows: [Row] = []
        var userPaused = false
        var powerPause: Pause?
        var asking = false
        var bytes: Int64 { rows.reduce(0) { $0 + $1.bytes } }
    }

    func snapshot() -> Snapshot {
        condition.withLock {
            Snapshot(rows: order.compactMap { uuid in
                entries[uuid].map { Snapshot.Row(id: uuid, title: $0.archive.title, articles: Int($0.archive.articleCount),
                                                 depth: $0.depth, state: $0.state, bytes: $0.bytes, seconds: $0.buildSeconds) }
            }, userPaused: userPaused, powerPause: powerPause, asking: asking > 0)
        }
    }

    /// Sends the status to Kit Care, at most twice a second while building.
    private func publish(force: Bool) {
        let send: Bool = condition.withLock {
            guard force || Date().timeIntervalSince(lastPublish) > 0.5 else { return false }
            lastPublish = Date()
            return true
        }
        guard send else { return }
        let snapshot = snapshot()
        Task { @MainActor in AnswerIndexStatus.shared.snapshot = snapshot }
    }
}

/// Chunks of an archive read and turned into passages: on worker threads (each chunk at once) or, without a
/// queue, right here.
private final class ChunkWork: @unchecked Sendable {
    typealias Batch = [(path: String, title: String, passages: [PassageStore.Draft])]
    /// First entry of each chunk, and the entry after the last one.
    let starts: [Int]
    let end: Int
    var start: Int { starts.first ?? end }
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var batches: [Batch]

    init(archive: ZimArchive, depth: AnswerIndexPolicy.Depth, from: Int, chunks: Int, total: Int, queue: DispatchQueue?) {
        let chunk = AnswerIndexPolicy.chunk(depth), maxBytes = AnswerIndexPolicy.maxHTMLBytes(depth)
        end = min(total, from + chunks * chunk)
        starts = Array(stride(from: from, to: end, by: chunk))
        batches = Array(repeating: [], count: starts.count)
        for (i, first) in starts.enumerated() {
            let work: @Sendable () -> Void = { [self] in
                let batch = autoreleasepool {
                    PassageStore.drafts(archive.articles(from: UInt(first), count: UInt(chunk), maxBytes: UInt(maxBytes)), depth: depth)
                }
                lock.withLock { batches[i] = batch }
            }
            if let queue { queue.async(group: group, execute: work) } else { work() }
        }
    }

    /// The chunks' passages, in order, once they're all done.
    func results() -> [Batch] {
        group.wait()
        return lock.withLock { batches }
    }
}

/// The answer index's progress for Kit Care, and the power checks that pause it.
@MainActor @Observable
final class AnswerIndexStatus {
    static let shared = AnswerIndexStatus()
    var snapshot = AnswerIndex.Snapshot()
    @ObservationIgnored private var watching: Task<Void, Never>?

    /// Checks Low Power Mode and the battery now and then, and pauses indexing on battery below 30%.
    func watchPower() {
        guard watching == nil else { return }
        #if canImport(UIKit) && !os(macOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        watching = Task { @MainActor in
            while !Task.isCancelled {
                AnswerIndex.shared.setPowerPause(Self.powerPause())
                AnswerIndex.shared.setPlugged(Self.pluggedIn())
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// On mains power: a Mac on its adapter (or without a battery), a charging iPhone or iPad, an Apple TV.
    nonisolated static func pluggedIn() -> Bool {
        #if os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
        #elseif os(tvOS)
        return true
        #elseif canImport(UIKit)
        // UIDevice belongs to the main thread; until the power watcher reports, assume battery.
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            let state = UIDevice.current.batteryState
            return state == .charging || state == .full
        }
        #else
        return false
        #endif
    }

    static func powerPause() -> AnswerIndex.Pause? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .lowPower }
        #if os(macOS)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            if Double(current) / Double(max) < 0.3 { return .battery }
        }
        return nil
        #elseif canImport(UIKit)
        let device = UIDevice.current
        if device.batteryState == .unplugged, device.batteryLevel >= 0, device.batteryLevel < 0.3 { return .battery }
        return nil
        #else
        return nil
        #endif
    }
}
