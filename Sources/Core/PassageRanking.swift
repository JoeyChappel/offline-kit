import Accelerate
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
            vDSP_vadd(sum, 1, v, 1, &sum, 1, vDSP_Length(min(v.count, sum.count)))
            count += 1
        }
        return count > 0 ? sum : nil
    }

    /// The mean word vector of each text (nil for a text with no known word), in English; nil without the English
    /// embedding. For comparing an answer's sentences with its sources (`CitationChecker`).
    func vectors(_ texts: [String]) -> [[Float]?]? {
        lock.withLock {
            guard let embedding = embedding(.english) else { return nil }
            return texts.map { vector($0, embedding) }
        }
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        let n = vDSP_Length(min(a.count, b.count))
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, n)
        vDSP_svesq(a, 1, &na, n)
        vDSP_svesq(b, 1, &nb, n)
        return na > 0 && nb > 0 ? Double(dot / (na.squareRoot() * nb.squareRoot())) : 0
    }

    /// The vector scaled to length 1 (for many cosines against it: then a dot product is the cosine).
    static func normalized(_ v: [Float]) -> [Float] {
        var squares: Float = 0
        vDSP_svesq(v, 1, &squares, vDSP_Length(v.count))
        guard squares > 0 else { return v }
        var scale = 1 / squares.squareRoot()
        var out = [Float](repeating: 0, count: v.count)
        vDSP_vsmul(v, 1, &scale, &out, 1, vDSP_Length(v.count))
        return out
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Double {
        var d: Float = 0
        vDSP_dotpr(a, 1, b, 1, &d, vDSP_Length(min(a.count, b.count)))
        return Double(d)
    }
}

/// Checks each cited sentence of an answer against the passage it cites, and fixes what the passage doesn't support.
///
/// The model sometimes cites a source that doesn't say what the sentence says ("Remove rings before the area swells
/// [2]" with [2] an Everest thread). For each sentence with a "[n]", the sentence's words are looked for in passage n
/// (first five letters, longer words counting more) and the sentence is compared with each of the passage's sentences
/// by meaning (the word embeddings the retriever reranks with). A citation the passage supports stays. One it doesn't
/// is moved to another source only when that source clearly supports the sentence, and otherwise dropped; support
/// is never added where there was none. Sentences with fewer than three content words ("Call 911 [1].") are left
/// as they are: too little to judge. About a millisecond for a whole answer once the sources are prepared.
final class CitationChecker {
    /// What the check did to one answer.
    struct Report: Sendable, Equatable, Codable {
        /// Citation marks in sentences long enough to judge, and how many of them their passage supported.
        var checked = 0, supported = 0
        /// Marks moved to a source that supports the sentence, and marks dropped.
        var repointed = 0, dropped = 0
        /// Marks left alone: their sentence was too short to judge.
        var unchecked = 0
        var changes: [Change] = []
        /// Time the final check took.
        var milliseconds = 0.0

        /// The share of judged marks their passage supported, before the check changed anything.
        var supportedBefore: Double { checked == 0 ? 1 : Double(supported) / Double(checked) }
        /// The same after: marks moved count as supported, dropped ones are gone.
        var supportedAfter: Double {
            let left = checked - dropped
            return left == 0 ? 1 : Double(supported + repointed) / Double(left)
        }
    }

    struct Change: Sendable, Equatable, Codable {
        let sentence: String
        let from: [Int]
        let to: [Int]
    }

    /// A sentence the passage supports: this share of its content words is in the passage, or a smaller share
    /// (`looseOverlap`) with one of the passage's sentences close in meaning (`closeMeaning`). Averaged word vectors
    /// put most sentences of a topic at 0.7 to 0.85, so meaning only tips a near miss; the words decide. Set from
    /// spot checks of Gemma 4 E4B answers: at 0.5, paraphrases like "give them warm, sweet drinks" for "Hot sweet
    /// drinks" lost their citation.
    static let supportedOverlap = 0.4
    static let looseOverlap = 0.3
    static let closeMeaning = 0.8
    /// Another source clearly supports it: at least this share of its words, this much more than the cited one, and
    /// close in meaning when the embedding is there.
    static let clearOverlap = 0.65
    static let clearMargin = 0.25
    static let clearMeaning = 0.75
    /// Fewer content words than this and a sentence isn't judged.
    static let minimumWords = 3

    private struct Prepared {
        let id: Int
        /// The start (up to five letters) of every word in its title and passage: a sentence's word is found when
        /// its `Retriever.key` is one of them, at the start of a word ("cool" in "cooling", not in "school").
        let starts: Set<Substring>
        /// Its sentences' vectors, scaled to length 1.
        let vectors: [[Float]]
    }

    private let sources: [Prepared]
    private let ids: Set<Int>
    private let hasVectors: Bool
    private var cache: [String: [Int: (overlap: Double, meaning: Double)]] = [:]

    init(sources: [Source]) {
        let ranker = SemanticRanker.shared
        var prepared: [Prepared] = []
        var vectorsFound = false
        for source in sources {
            let text = (source.ref.title + ". " + source.text).lowercased()
            var starts = Set<Substring>()
            for word in text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                for n in 1...min(5, word.count) { starts.insert(word.prefix(n)) }
            }
            let sentences = Self.sentences(source.text)
            let vectors = ranker.vectors(sentences)?.compactMap { $0 }.map(SemanticRanker.normalized) ?? []
            if !vectors.isEmpty { vectorsFound = true }
            prepared.append(Prepared(id: source.id, starts: starts, vectors: vectors))
        }
        self.sources = prepared
        ids = Set(sources.map(\.id))
        hasVectors = vectorsFound
    }

    /// One citation group in an answer: "[1]", "[2][3]", "[1, 2]", with the numbers it names.
    private struct Group {
        let range: Range<String.Index>
        let numbers: [Int]
    }

    private static let groupPattern = try! NSRegularExpression(pattern: #"(?:\s*\[\d+(?:\s*[,–-]\s*\d+)*\])+"#)
    private static let numberPattern = try! NSRegularExpression(pattern: #"\[(\d+(?:\s*[,–-]\s*\d+)*)\]"#)

    /// The answer with its citations checked. While it streams (`final: false`), a citation at the very end may still
    /// grow ("[1]" before "[2]" arrives) and is left for the next pass.
    func apply(_ answer: String, final: Bool) -> (text: String, report: Report) {
        let started = Date()
        var report = Report()
        let ns = answer as NSString
        let matches = Self.groupPattern.matches(in: answer, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty, !sources.isEmpty else { return (answer, report) }
        var out = ""
        var cursor = answer.startIndex
        var claimFrom = answer.startIndex
        var previousClaim = ""
        for m in matches {
            guard let range = Range(m.range, in: answer) else { continue }
            if !final, answer.distance(from: range.upperBound, to: answer.endIndex) < 2 { break }
            let numbers = Self.numbers(in: String(answer[range]))
            var claim = Self.claim(in: answer, before: range.lowerBound, from: claimFrom)
            if Retriever.terms(claim).isEmpty { claim = previousClaim }   // "[1]" on its own, after another citation
            previousClaim = claim
            claimFrom = range.upperBound
            out += answer[cursor..<range.lowerBound]
            cursor = range.upperBound
            let kept = judge(claim: claim, cited: numbers, final: final, report: &report)
            if kept == numbers {
                out += answer[range]
            } else {
                report.changes.append(Change(sentence: claim.trimmingCharacters(in: .whitespacesAndNewlines), from: numbers, to: kept))
                if !kept.isEmpty { out += " " + kept.map { "[\($0)]" }.joined() }
            }
        }
        out += answer[cursor...]
        report.milliseconds = Date().timeIntervalSince(started) * 1000
        return (out, report)
    }

    /// Which of the cited sources to keep for a sentence: the ones that support it, or the one source that clearly
    /// does when none of them do, or none.
    #if DEBUG
    private static let traceScores = ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE_CITATIONS"] != nil
    #endif

    private func judge(claim: String, cited: [Int], final: Bool, report: inout Report) -> [Int] {
        let words = Retriever.terms(claim)
        guard words.count >= Self.minimumWords else {
            report.unchecked += cited.count
            return cited
        }
        let scores = support(claim: claim, words: words)
        report.checked += cited.count
        #if DEBUG
        if final, Self.traceScores {
            let line = scores.keys.sorted().map { String(format: "[%d]%@ %.2f/%.2f", $0, cited.contains($0) ? "*" : "", scores[$0]!.overlap, scores[$0]!.meaning) }
            FileHandle.standardError.write(Data(("citation: \(line.joined(separator: "  "))  \(claim.prefix(90))\n").utf8))
        }
        #endif
        var kept: [Int] = []
        for n in cited where ids.contains(n) && !kept.contains(n) {
            guard let s = scores[n], supports(s) else { continue }
            kept.append(n)
        }
        report.supported += kept.count
        if !kept.isEmpty {
            report.dropped += cited.count - kept.count
            return kept
        }
        let bestCited = cited.compactMap { scores[$0]?.overlap }.max() ?? 0
        if let best = scores.filter({ !cited.contains($0.key) }).max(by: { $0.value.overlap < $1.value.overlap }),
           best.value.overlap >= Self.clearOverlap, best.value.overlap >= bestCited + Self.clearMargin,
           !hasVectors || best.value.meaning >= Self.clearMeaning {
            report.repointed += 1
            report.dropped += cited.count - 1
            return [best.key]
        }
        report.dropped += cited.count
        return []
    }

    private func supports(_ s: (overlap: Double, meaning: Double)) -> Bool {
        s.overlap >= Self.supportedOverlap || (s.overlap >= Self.looseOverlap && s.meaning >= Self.closeMeaning)
    }

    /// Each source's support for a sentence: the weighted share of its words in the passage, and how close in meaning
    /// it is to the passage's closest sentence (0 without the embedding).
    private func support(claim: String, words: [String]) -> [Int: (overlap: Double, meaning: Double)] {
        if let known = cache[claim] { return known }
        let vector = (hasVectors ? SemanticRanker.shared.vectors([claim])?.first ?? nil : nil).map(SemanticRanker.normalized)
        var result: [Int: (overlap: Double, meaning: Double)] = [:]
        for source in sources {
            var total = 0.0, found = 0.0
            for word in words {
                let w = word.count >= 6 ? 1.5 : 1.0
                total += w
                // Long words also by their first four letters: "sealing" and "sealed", "warmer" and "warm".
                if source.starts.contains(Substring(Retriever.key(word))) || (word.count >= 6 && source.starts.contains(word.prefix(4))) {
                    found += w
                }
            }
            let meaning = vector.map { v in source.vectors.map { SemanticRanker.dot(v, $0) }.max() ?? 0 } ?? 0
            result[source.id] = (total > 0 ? found / total : 0, meaning)
        }
        if cache.count > 200 { cache.removeAll() }
        cache[claim] = result
        return result
    }

    /// The sentence a citation group belongs to: back from the group to the end of the sentence before it (a line
    /// break, or ". ", "! ", "? " ending a sentence), not before the previous group.
    static func claim(in text: String, before end: String.Index, from floor: String.Index) -> String {
        var i = end
        // Step over the sentence's own closing punctuation ("water. [1]").
        while i > floor, let c = text[text.index(before: i)...].first, c == " " || c == "." || c == "!" || c == "?" {
            i = text.index(before: i)
        }
        var start = i
        while start > floor {
            let prev = text.index(before: start)
            let c = text[prev]
            if c == "\n" { break }
            if (c == "." || c == "!" || c == "?") && start < text.endIndex && text[start] == " " { break }
            start = prev
        }
        return String(text[start..<i]).trimmingCharacters(in: .whitespaces)
    }

    static func numbers(in group: String) -> [Int] {
        var found: [Int] = []
        for m in numberPattern.matches(in: group, range: NSRange(group.startIndex..., in: group)) {
            guard let r = Range(m.range(at: 1), in: group) else { continue }
            for part in group[r].split(separator: ",") {
                let ends = part.split(whereSeparator: { $0 == "-" || $0 == "–" }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if ends.count == 2, ends[0] <= ends[1], ends[1] - ends[0] < 20 { found += Array(ends[0]...ends[1]) } else { found += ends }
            }
        }
        var seen = Set<Int>()
        return found.filter { seen.insert($0).inserted }
    }

    /// A passage's sentences, for comparing meaning.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sub, _, _, _ in
            if let sub, sub.count > 20 { out.append(sub) }
        }
        return out.isEmpty ? [text] : out
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
