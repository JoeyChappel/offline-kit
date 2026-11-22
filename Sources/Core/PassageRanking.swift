import Foundation
import NaturalLanguage

/// Re-ranks candidate passages by meaning, so "warm up someone with hypothermia" finds "rewarm the center of the
/// body" even when the keyword scores are close.
///
/// Uses Apple's on-device word embeddings, averaged over a passage's words. On the test questions this ranked the
/// right passage first 13 times in 15, against 2 for `NLEmbedding.sentenceEmbedding` and 4 for
/// `NLContextualEmbedding` (mean-pooled), and it's about ten times faster (about 1 ms a passage).
/// Languages without an embedding are skipped: the keyword ranking stands on its own.
final class SemanticRanker: @unchecked Sendable {
    static let shared = SemanticRanker()

    private let lock = NSLock()
    private var embeddings: [NLLanguage: NLEmbedding?] = [:]
    private var questions: [String: [Float]] = [:]
    private var questionOrder: [String] = []
    private var words: [String: [Float]] = [:]

    /// Loads the English embedding ahead of the first question (it takes a moment).
    func warm() {
        lock.withLock { _ = embedding(.english) }
    }

    /// Cosine similarity of each text to the question, or nil when there's no embedding for its language.
    func similarities(question: String, texts: [String]) -> [Double]? {
        lock.withLock {
            guard let (embedding, q) = questionVector(question) else { return nil }
            return texts.map { text in vector(text, embedding).map { Self.cosine(q, $0) } ?? 0 }
        }
    }

    private func questionVector(_ question: String) -> (NLEmbedding, [Float])? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(question)
        let language = recognizer.dominantLanguage ?? .english
        guard let embedding = embedding(language) else { return nil }
        let key = language.rawValue + "|" + question
        if let cached = questions[key] { return (embedding, cached) }
        guard let v = vector(question, embedding) else { return nil }
        questions[key] = v
        questionOrder.append(key)
        if questionOrder.count > 32 { questions[questionOrder.removeFirst()] = nil }
        return (embedding, v)
    }

    private func embedding(_ language: NLLanguage) -> NLEmbedding? {
        if let known = embeddings[language] { return known }
        let loaded = NLEmbedding.wordEmbedding(for: language)
        embeddings[language] = loaded
        return loaded
    }

    /// The mean of the text's word vectors (stopwords and very short words left out).
    private func vector(_ text: String, _ embedding: NLEmbedding) -> [Float]? {
        var sum = [Float](repeating: 0, count: embedding.dimension)
        var count = 0
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter }) where word.count > 2 {
            let w = String(word)
            if Retriever.stopwords.contains(w) { continue }
            let v: [Float]
            if let cached = words[w] {
                v = cached
            } else if let looked = embedding.vector(for: w) {
                v = looked.map(Float.init)
                if words.count > 10_000 { words.removeAll(keepingCapacity: true) }
                words[w] = v
            } else { continue }
            for i in 0..<min(v.count, sum.count) { sum[i] += v[i] }
            count += 1
        }
        return count > 0 ? sum : nil
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na > 0 && nb > 0 ? Double(dot / (na.squareRoot() * nb.squareRoot())) : 0
    }
}

/// Near-duplicate passages (the same lead in WikiMed and Wikipedia, or an article and its "in children" variant).
enum PassageDedupe {
    /// Word three-grams of a passage.
    static func shingles(_ text: String) -> Set<Int> {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        guard words.count >= 3 else { return Set(words.map { $0.hashValue }) }
        var out = Set<Int>()
        for i in 0..<(words.count - 2) {
            var h = Hasher()
            h.combine(words[i]); h.combine(words[i + 1]); h.combine(words[i + 2])
            out.insert(h.finalize())
        }
        return out
    }

    /// Share of the smaller passage's three-grams the two have in common: high when one repeats the other.
    static func overlap(_ a: Set<Int>, _ b: Set<Int>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(min(a.count, b.count))
    }
}

/// Paragraphs already pulled out of an article's HTML, so a repeat hit skips reading and stripping it.
/// Used by archives without a ready answer index. A few in memory, the rest in a small SQLite file (about 24 MB,
/// least recently used dropped first).
final class ParagraphCache: @unchecked Sendable {
    static let shared = ParagraphCache()

    private let lock = NSLock()
    private var memory: [String: (path: String, paragraphs: [String])] = [:]
    private var memoryOrder: [String] = []
    private var db: SQLiteDB?
    private var opened = false
    private var writes = 0
    private static let maxBytes: Int64 = 24 << 20

    static var url: URL { KitLocation.caches.appending(path: "OfflineKit/paragraph-cache.sqlite") }

    /// The article's final path (after redirects) and its paragraphs.
    func get(archive: String, path: String) -> (path: String, paragraphs: [String])? {
        let key = archive.lowercased() + "/" + path
        return lock.withLock {
            if let hit = memory[key] { touch(key); return hit }
            guard let db = open() else { return nil }
            var found: (String, [String])?
            try? db.run("SELECT body FROM paragraphs WHERE key = ?", [.text(key)]) { row in
                let parts = row.text(0).components(separatedBy: "\u{1F}")
                if parts.count == 2 { found = (parts[0], parts[1].components(separatedBy: "\u{1E}")) }
            }
            guard let found else { return nil }
            try? db.run("UPDATE paragraphs SET used = ? WHERE key = ?", [.int(Int64(Date().timeIntervalSince1970)), .text(key)])
            remember(key, found)
            return found
        }
    }

    func put(archive: String, path: String, finalPath: String, paragraphs: [String]) {
        let key = archive.lowercased() + "/" + path
        let body = finalPath + "\u{1F}" + paragraphs.joined(separator: "\u{1E}")
        lock.withLock {
            remember(key, (finalPath, paragraphs))
            guard let db = open() else { return }
            try? db.run("INSERT OR REPLACE INTO paragraphs VALUES (?, ?, ?, ?)",
                        [.text(key), .text(body), .int(Int64(body.utf8.count)), .int(Int64(Date().timeIntervalSince1970))])
            writes += 1
            if writes % 50 == 0 { trim(db) }
        }
    }

    private func remember(_ key: String, _ value: (path: String, paragraphs: [String])) {
        memory[key] = value
        touch(key)
        if memoryOrder.count > 64 { memory[memoryOrder.removeFirst()] = nil }
    }

    private func touch(_ key: String) {
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
    }

    private func open() -> SQLiteDB? {
        if opened { return db }
        opened = true
        db = try? SQLiteDB(url: Self.url)
        try? db?.script("""
            PRAGMA journal_mode=TRUNCATE; PRAGMA synchronous=OFF;
            CREATE TABLE IF NOT EXISTS paragraphs(key TEXT PRIMARY KEY, body TEXT NOT NULL, bytes INTEGER NOT NULL, used INTEGER NOT NULL);
            CREATE INDEX IF NOT EXISTS paragraphs_used ON paragraphs(used);
            """)
        return db
    }

    /// Drops the least recently used articles once the cache passes its size.
    private func trim(_ db: SQLiteDB) {
        guard let total = try? db.scalar("SELECT COALESCE(SUM(bytes), 0) FROM paragraphs"), total > Self.maxBytes else { return }
        try? db.run("""
            DELETE FROM paragraphs WHERE key IN (SELECT key FROM paragraphs ORDER BY used LIMIT
            (SELECT COUNT(*) / 4 FROM paragraphs))
            """)
    }
}
