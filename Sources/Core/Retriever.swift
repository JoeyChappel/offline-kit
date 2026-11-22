import Foundation
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// One numbered passage handed to the model and shown to the user as a citation.
struct Source: Identifiable, Hashable, Sendable {
    let id: Int
    let ref: ArticleRef
    let bookTitle: String
    let text: String
}

/// Finds passages in the offline archives that are relevant to a question.
/// Pure and synchronous: call it off the main actor.
enum Retriever {

    /// One article found by a search, before its text is read.
    struct Candidate: @unchecked Sendable {
        let archive: ZimArchive; let hit: ZimHit; var score: Double; var coverage: Double
    }

    /// One passage found in an archive's answer index, scored like a search hit.
    struct IndexedCandidate: Sendable {
        let archive: ZimArchive; let hit: IndexHit; var score: Double; var coverage: Double
    }

    /// Everything one archive's searches found for a question. Kept so a second pass over the same archive
    /// (health questions search the medical references first) doesn't search it again.
    struct Gathered: Sendable {
        let archive: ZimArchive
        let fullText: [Candidate]
        let titles: [Candidate]
        /// Passages from the archive's answer index, when it has a complete one (then the other two are empty).
        var indexed: [IndexedCandidate] = []
    }

    /// The most HTML read from one article. Long articles bury their useful lead under megabytes of markup;
    /// the first part is where the passages come from.
    static let maxHTMLBytes = 200_000

    /// Passages taken from one answer index per question, before the best articles are picked. Generous, because
    /// one article can fill many of them.
    static let indexHits = 150

    /// Search, shortlist and read: synchronous. Call it off the main actor.
    static func retrieve(question: String, archives: [ZimArchive], budgetChars: Int, maxSources: Int = 6) -> [Source] {
        let terms = Self.terms(question)
        guard !terms.isEmpty else { return [] }
        AnswerIndex.shared.beginAsk()
        defer { AnswerIndex.shared.endAsk() }
        let phrases = Self.phrases(terms)
        let gathered = archives.map { gather(in: $0, terms: terms, phrases: phrases, cancelled: { false }) }
        let picks = shortlist(from: gathered, terms: terms, phrases: phrases)
        let passages = picks.flatMap { passages(for: $0, terms: terms, phrases: phrases) }
        return assemble(articlePassages: passages, archives: archives, question: question, terms: terms, phrases: phrases,
                        budgetChars: budgetChars, maxSources: maxSources)
    }

    /// Same result as `retrieve`, with independent archives searched (and articles read) at the same time.
    /// Stops early when the calling task is cancelled. `reusing` holds what an earlier pass already found,
    /// by archive id, for the same question.
    static func retrieveConcurrently(question: String, archives: [ZimArchive], budgetChars: Int, maxSources: Int = 6,
                                     reusing known: [String: Gathered] = [:]) async -> (sources: [Source], gathered: [String: Gathered]) {
        let terms = Self.terms(question)
        guard !terms.isEmpty else { return ([], known) }
        AnswerIndex.shared.beginAsk()
        defer { AnswerIndex.shared.endAsk() }
        let phrases = Self.phrases(terms)
        #if DEBUG
        let started = Date()
        #endif

        var found: [Gathered?] = archives.map { known[$0.uuid] }
        await withTaskGroup(of: (Int, Gathered).self) { group in
            for (i, archive) in archives.enumerated() where found[i] == nil {
                group.addTask { (i, gather(in: archive, terms: terms, phrases: phrases, cancelled: { Task.isCancelled })) }
            }
            for await (i, g) in group { found[i] = g }
        }
        guard !Task.isCancelled else { return ([], known) }
        let gathered = found.compactMap { $0 }
        var all = known
        for g in gathered { all[g.archive.uuid] = g }
        #if DEBUG
        let searched = Date()
        #endif

        let picks = shortlist(from: gathered, terms: terms, phrases: phrases)
        var read = [[Passage]](repeating: [], count: picks.count)
        await withTaskGroup(of: (Int, [Passage]).self) { group in
            for (i, pick) in picks.enumerated() {
                group.addTask { (i, passages(for: pick, terms: terms, phrases: phrases)) }
            }
            for await (i, p) in group { read[i] = p }
        }
        guard !Task.isCancelled else { return ([], all) }
        #if DEBUG
        let readDone = Date()
        #endif
        let sources = assemble(articlePassages: read.flatMap { $0 }, archives: archives, question: question, terms: terms,
                               phrases: phrases, budgetChars: budgetChars, maxSources: maxSources)
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
            let indexed = gathered.filter { !$0.indexed.isEmpty || AnswerIndex.shared.store(for: $0.archive) != nil }.count
            FileHandle.standardError.write(Data(String(format: "retrieve: search %.1f ms, read %.1f ms, assemble %.1f ms; %d of %d archives indexed; %d sources, %d chars\n",
                searched.timeIntervalSince(started) * 1000, readDone.timeIntervalSince(searched) * 1000,
                Date().timeIntervalSince(readDone) * 1000, indexed, gathered.count, sources.count,
                sources.reduce(0) { $0 + $1.text.count }).utf8))
        }
        #endif
        return (sources, all)
    }

    /// Opens what the first search would otherwise wait for, once per launch, in the background: each archive's
    /// search index (libzim's full-text and title indexes, or its answer index), the paragraph cache and the word
    /// embeddings. Called when Ask opens.
    static func warm(_ archives: [ZimArchive]) {
        guard Self.warmed.claim() else { return }
        Task.detached(priority: .utility) {
            #if DEBUG
            let started = Date()
            #endif
            _ = SemanticRanker.shared.similarities(question: "boil water", texts: ["Boiling water makes it safe to drink."])
            _ = ParagraphCache.shared.get(archive: "", path: "")
            await withTaskGroup(of: Void.self) { group in
                for archive in archives {
                    group.addTask {
                        if let store = AnswerIndex.shared.store(for: archive) {
                            _ = store.search(terms: ["water"], phrases: [], limit: 1)
                        } else {
                            if archive.hasFullTextIndex { _ = archive.search("water", limit: 1) }
                            _ = archive.suggest("water", limit: 1)
                        }
                    }
                }
            }
            #if DEBUG
            if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
                FileHandle.standardError.write(Data(String(format: "retrieve: warmed %d archives in %.0f ms\n", archives.count,
                                                           Date().timeIntervalSince(started) * 1000).utf8))
            }
            #endif
        }
    }

    private static let warmed = Once()

    /// Searches one archive: its answer index when that's ready, else libzim (full-text first, exact phrases then
    /// broader queries, then titles).
    private static func gather(in archive: ZimArchive, terms: [String], phrases: [String], cancelled: () -> Bool) -> Gathered {
        if let store = AnswerIndex.shared.store(for: archive) {
            return Gathered(archive: archive, fullText: [], titles: [],
                            indexed: indexed(store.search(terms: terms, phrases: phrases, limit: indexHits),
                                             archive: archive, terms: terms, phrases: phrases))
        }
        var fullText: [Candidate] = []
        if archive.hasFullTextIndex {
            // libzim matches ALL words, so a long question can miss the obvious article.
            // Search each two-word phrase on its own, then the whole question, then its most specific words.
            var seen = Set<String>(), seenTitles = Set<String>()
            let queries = phrases.map { ($0, 5) } + queryVariants(terms).map { ($0, 10) }
            for (query, limit) in queries {
                if cancelled() { break }
                for hit in archive.search(query, limit: limit, snippetsExcept: seen)
                where seen.insert(hit.path).inserted && seenTitles.insert(hit.title.lowercased()).inserted && !isListing(hit) {
                    var (score, coverage) = relevance(title: hit.title, snippet: hit.snippet, xapian: hit.score,
                                                      terms: terms, phrases: phrases)
                    titleBonus(hit.title, terms: terms, score: &score, coverage: &coverage)
                    fullText.append(Candidate(archive: archive, hit: hit, score: score, coverage: coverage))
                }
                if seen.count >= 20 { break }
            }
        }
        // Titles too, in every archive: some (like the Zimgit guides) have no full-text index at all, and an
        // article named for the topic ("Bowline") beats a forum post that happens to mention it.
        var titles: [Candidate] = []
        let specific = terms.max { $0.count < $1.count } ?? ""
        var seenPaths = Set(fullText.map(\.hit.path))
        for query in Set([terms.prefix(3).joined(separator: " "), specific]) where !query.isEmpty {
            if cancelled() { break }
            for hit in archive.suggest(query, limit: 3) where seenPaths.insert(hit.path).inserted && !isListing(hit) {
                var (score, coverage) = relevance(title: hit.title, snippet: "", xapian: 0, terms: terms, phrases: phrases)
                titleBonus(hit.title, terms: terms, score: &score, coverage: &coverage)
                titles.append(Candidate(archive: archive, hit: hit, score: score, coverage: coverage))
            }
        }
        return Gathered(archive: archive, fullText: fullText, titles: titles)
    }

    /// An article named exactly for part of the question ("Heat stroke") is on topic.
    private static func titleBonus(_ title: String, terms: [String], score: inout Double, coverage: inout Double) {
        let titleTerms = Self.terms(title)
        if !titleTerms.isEmpty && titleTerms.allSatisfy({ t in terms.contains { $0.hasPrefix(String(t.prefix(5))) } }) {
            score += 2 + Double(titleTerms.count)
            coverage = max(coverage, 1)
        }
    }

    /// Index passages scored on the same scale as search hits, so indexed and searched archives (and PDF pages)
    /// compete fairly. BM25 stands in for libzim's own score; the opening section gets a small lift.
    private static func indexed(_ hits: [IndexHit], archive: ZimArchive, terms: [String], phrases: [String]) -> [IndexedCandidate] {
        let best = max(hits.map(\.bm25).max() ?? 1, 0.0001)
        return hits.filter { !isListing(path: $0.path, title: $0.title) }.map { hit in
            var (score, coverage) = plainRelevance(title: hit.title.lowercased(), text: searchableText(hit),
                                                   xapian: Int(100 * hit.bm25 / best), terms: terms, phrases: phrases)
            titleBonus(hit.title, terms: terms, score: &score, coverage: &coverage)
            if hit.lead { score += 0.3 }
            // A tie between the same article in a full index and a leads-only one (WikiMed and Wikipedia): the full
            // one has the rest of the article too.
            if !hit.text.isEmpty { score += 0.01 }
            return IndexedCandidate(archive: archive, hit: hit, score: score, coverage: coverage)
        }
    }

    /// What a hit is scored on: its text, or for a leads-only index (which keeps no text) the question words the
    /// query that found it guarantees.
    private static func searchableText(_ hit: IndexHit) -> String {
        hit.text.isEmpty ? hit.matched.joined(separator: " ") : (hit.heading + " " + hit.text).lowercased()
    }

    /// An article picked for reading: a search hit whose HTML is read, or an indexed article whose passages are in hand.
    enum Pick: @unchecked Sendable {
        case article(Candidate)
        case indexed(score: Double, [IndexedCandidate])

        var archive: ZimArchive {
            switch self {
            case .article(let c): c.archive
            case .indexed(_, let passages): passages[0].archive
            }
        }
    }

    /// Keep articles that mention most of the question; cap each archive so none dominates.
    /// Weak matches are dropped: no source is better than a misleading one.
    private static func shortlist(from gathered: [Gathered], terms: [String], phrases: [String]) -> [Pick] {
        var picks: [(pick: Pick, score: Double, coverage: Double)] =
            (gathered.flatMap(\.fullText) + gathered.flatMap(\.titles)).map { (.article($0), $0.score, $0.coverage) }
        // Indexed passages count per article: the article's best passage, and how much of the question its passages
        // cover between them.
        for g in gathered where !g.indexed.isEmpty {
            var byArticle: [String: [IndexedCandidate]] = [:]
            var order: [String] = []
            for c in g.indexed {
                if byArticle[c.hit.path] == nil { order.append(c.hit.path) }
                byArticle[c.hit.path, default: []].append(c)
            }
            for path in order {
                let passages = byArticle[path]!
                let joined = passages.prefix(5).map { searchableText($0.hit) }.joined(separator: " ")
                let (_, together) = plainRelevance(title: passages[0].hit.title.lowercased(), text: joined, xapian: 0,
                                                   terms: terms, phrases: phrases)
                let score = passages.map(\.score).max() ?? 0
                picks.append((.indexed(score: score, passages), score, max(together, passages.map(\.coverage).max() ?? 0)))
            }
        }
        let bestCoverage = picks.map(\.coverage).max() ?? 0
        let floor = max(0.5, min(0.6, bestCoverage))
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
            for p in picks.sorted(by: { $0.score > $1.score }).prefix(12) {
                let title: String
                switch p.pick { case .article(let c): title = c.hit.title; case .indexed(_, let hits): title = hits[0].hit.title + " (index)" }
                FileHandle.standardError.write(Data(String(format: "  candidate %.2f coverage %.2f%@ %@\n", p.score, p.coverage,
                                                           p.coverage >= floor ? "" : " (dropped)", title).utf8))
            }
        }
        #endif
        var perArchive: [String: Int] = [:]
        return Array(picks
            .filter { $0.coverage >= floor }
            .sorted { $0.score > $1.score }
            .filter { p in
                let n = perArchive[p.pick.archive.uuid, default: 0]
                perArchive[p.pick.archive.uuid] = n + 1
                return n < 3
            }
            .prefix(8)
            .map(\.pick))
    }

    struct Passage: Sendable {
        var score: Double; let ref: ArticleRef; let book: String; let text: String
        /// Position in its article, so two passages of one article read in order.
        var order = 0
        /// The section it's from, when known (index passages).
        var heading = ""
    }

    /// The passages of one picked article, each scored: the article's score twice, plus the passage's own match.
    private static func passages(for pick: Pick, terms: [String], phrases: [String]) -> [Passage] {
        switch pick {
        case .article(let c):
            return articlePassages(c, terms: terms, phrases: phrases)
        case .indexed(let score, let hits):
            return hits.compactMap { c in
                // A leads-only index reads the lead back from the archive: one small read, only for picked articles.
                guard let text = c.hit.text.isEmpty ? PassageStore.leadText(archive: c.archive, path: c.hit.path) : c.hit.text
                else { return nil }
                // The section heading counts like a title: "Treatment" answers "how do I treat…".
                let (own, _) = textRelevance(title: c.hit.heading.lowercased(), text: text.lowercased(), terms: terms, phrases: phrases)
                let ref = ArticleRef(bookID: c.archive.uuid.lowercased(), path: c.hit.path, title: c.hit.title)
                return Passage(score: score * 2 + own + (c.hit.lead ? 0.3 : 0), ref: ref, book: c.archive.title,
                               text: text, order: c.hit.order, heading: c.hit.heading)
            }
        }
    }

    /// The best paragraphs of one article, read from its HTML (or the paragraph cache).
    private static func articlePassages(_ c: Candidate, terms: [String], phrases: [String]) -> [Passage] {
        let finalPath: String, paragraphs: [String]
        if let cached = ParagraphCache.shared.get(archive: c.archive.uuid, path: c.hit.path) {
            (finalPath, paragraphs) = cached
        } else {
            guard let content = c.archive.content(atPath: c.hit.path), content.mimeType.hasPrefix("text/html") else { return [] }
            let html: String
            if content.data.count > maxHTMLBytes {
                html = String(decoding: content.data.prefix(maxHTMLBytes), as: UTF8.self)
            } else if let whole = String(data: content.data, encoding: .utf8) {
                html = whole
            } else { return [] }
            finalPath = content.path
            paragraphs = HTMLText.paragraphs(html)
            ParagraphCache.shared.put(archive: c.archive.uuid, path: c.hit.path, finalPath: finalPath, paragraphs: paragraphs)
        }
        guard !paragraphs.isEmpty else { return [] }

        let scored = paragraphs.enumerated().map { (i, p) -> (Int, Double) in
            let (s, _) = relevance(title: "", snippet: p, xapian: 0, terms: terms, phrases: phrases)
            return (i, s + (i == 0 ? 0.3 : 0))   // lead paragraph usually defines the topic
        }
        let best = scored.filter { $0.1 > 0.5 }.sorted { $0.1 > $1.1 }.prefix(3)
        let ref = ArticleRef(bookID: c.archive.uuid.lowercased(), path: finalPath, title: c.hit.title)
        return best.map { (i, s) in
            Passage(score: c.score * 2 + s, ref: ref, book: c.archive.title, text: paragraphs[i], order: i)
        }
    }

    /// Longest passage handed to the model, and most text from one article.
    static let maxPassageChars = 1_400
    static let maxSourceChars = 2_400

    /// Adds PDF and built-in guide passages to the article passages, re-ranks them by meaning, drops weak and
    /// repeated ones, and fills the budget with the best: at most three passages from any one article.
    private static func assemble(articlePassages: [Passage], archives: [ZimArchive], question: String, terms: [String],
                                 phrases: [String], budgetChars: Int, maxSources: Int) -> [Source] {
        var passages = articlePassages
        let perArticle = max(600, budgetChars / 3)

        // 3b. PDF libraries (knots, water, first aid…): match the question against each page's text.
        for archive in archives {
            let chunks = PDFIndex.shared.chunks(for: archive.uuid)
            guard !chunks.isEmpty else { continue }
            var best: [(chunk: PDFIndex.Chunk, score: Double)] = []
            for chunk in chunks {
                let (score, coverage) = textRelevance(title: chunk.title.lowercased(), text: chunk.lower, terms: terms, phrases: phrases)
                if coverage >= 0.6 { best.append((chunk, score)) }
            }
            var perDocument = Set<String>()
            for hit in best.sorted(by: { $0.score > $1.score }) where perDocument.insert(hit.chunk.path).inserted {
                let ref = ArticleRef(bookID: archive.uuid.lowercased(), path: hit.chunk.path,
                                     title: "\(hit.chunk.title), page \(hit.chunk.page)")
                passages.append(Passage(score: hit.score * 3, ref: ref, book: archive.title,
                                        text: String(hit.chunk.text.prefix(perArticle))))
                if perDocument.count == 2 { break }
            }
        }

        // 3c. Offline Kit's built-in power-out guide (food, generators, water). Scored like a PDF page, a little higher:
        // it's short, on topic and from official sources.
        for match in PowerOutGuide.matches(terms: terms, phrases: phrases) {
            passages.append(Passage(score: match.score * 4, ref: match.ref, book: PowerOutGuide.bookTitle,
                                    text: String(match.text.prefix(perArticle))))
        }
        guard !passages.isEmpty else { return [] }

        // 4. Meaning: the best few dozen passages, re-ranked against the question.
        passages.sort { $0.score > $1.score }
        passages = Array(passages.prefix(50))
        #if DEBUG
        let rerankStart = Date()
        #endif
        if let similarity = SemanticRanker.shared.similarities(question: question, texts: passages.map { $0.ref.title + ". " + $0.heading + ". " + $0.text }) {
            // How far each passage is from the others in meaning, in standard deviations, worth up to 20% either way.
            let mean = similarity.reduce(0, +) / Double(similarity.count)
            let deviation = (similarity.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(similarity.count)).squareRoot()
            if deviation > 0.005 {
                passages = zip(passages, similarity).map { p, s in
                    var q = p
                    q.score = p.score * (1 + 0.1 * max(-2, min(2, (s - mean) / deviation)))
                    return q
                }
                passages.sort { $0.score > $1.score }
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
            FileHandle.standardError.write(Data(String(format: "rerank: %d passages in %.1f ms\n", passages.count,
                                                       Date().timeIntervalSince(rerankStart) * 1000).utf8))
        }
        #endif

        // 5. Drop weak stragglers and passages that repeat a better one.
        let top = passages.first?.score ?? 0
        passages.removeAll { $0.score < top * 0.5 }
        var kept: [(passage: Passage, shingles: Set<Int>)] = []
        for p in passages {
            let s = PassageDedupe.shingles(p.text)
            if kept.contains(where: { PassageDedupe.overlap($0.shingles, s) >= 0.6 }) { continue }
            kept.append((p, s))
        }

        // 6. Highest-scoring articles first, within budget: each article's best passage, and up to two more when
        // they're nearly as good. WikiMed, MDWiki and Wikipedia often carry the same article; one copy leaves room for others.
        var used = 0
        var seenTitles = Set<String>()
        var chosen: [(ref: ArticleRef, book: String, best: Double, parts: [Passage], chars: Int)] = []
        var slot: [String: Int] = [:]
        for (p, _) in kept {
            let text = trimmed(p.text, to: maxPassageChars)
            let piece = Passage(score: p.score, ref: p.ref, book: p.book, text: text, order: p.order)
            if let i = slot[p.ref.id] {
                guard chosen[i].parts.count < 3, p.score >= chosen[i].best * 0.6,
                      chosen[i].chars + text.count <= maxSourceChars, used + text.count <= budgetChars else { continue }
                chosen[i].parts.append(piece)
                chosen[i].chars += text.count
                used += text.count
                continue
            }
            let titleKey = p.ref.title.lowercased().filter { $0.isLetter || $0.isNumber }
            guard chosen.count < maxSources, !seenTitles.contains(titleKey) else { continue }
            if used + text.count > budgetChars && !chosen.isEmpty { continue }
            seenTitles.insert(titleKey)
            slot[p.ref.id] = chosen.count
            chosen.append((p.ref, p.book, p.score, [piece], text.count))
            used += text.count
        }
        return chosen.enumerated().map { i, c in
            Source(id: i + 1, ref: c.ref, bookTitle: c.book,
                   text: c.parts.sorted { $0.order < $1.order }.map(\.text).joined(separator: "\n"))
        }
    }

    /// At most `limit` characters, cut at the end of a sentence when there's one in the second half.
    static func trimmed(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        if let end = head.range(of: ". ", options: .backwards), head.distance(from: head.startIndex, to: end.lowerBound) > limit / 2 {
            return String(head[..<end.lowerBound]) + "."
        }
        return head + "…"
    }

    /// How many sources are clearly about the question: their title covers at least half its words.
    /// Zero means the search probably missed (a misspelling, or different words than the articles use).
    static func strength(_ sources: [Source], question: String) -> Int {
        let words = terms(question)
        guard !words.isEmpty else { return 0 }
        return sources.filter { source in
            let title = source.ref.title.lowercased()
            let hits = words.filter { title.contains(String($0.prefix(5))) }.count
            return Double(hits) >= Double(words.count) / 2
        }.count
    }

    /// The question with misspelled words fixed by the system spell checker, or nil if nothing changed.
    @MainActor static func spellCorrected(_ text: String) -> String? {
        var result = text
        var changed = false
        var offset = 0
        #if canImport(AppKit)
        let checker = NSSpellChecker.shared
        while offset < (result as NSString).length {
            let range = checker.checkSpelling(of: result, startingAt: offset, language: "en", wrap: false,
                                              inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            let word = (result as NSString).substring(with: range)
            if let fix = checker.correction(forWordRange: range, in: result, language: "en", inSpellDocumentWithTag: 0), fix != word {
                result = (result as NSString).replacingCharacters(in: range, with: fix)
                changed = true
                offset = range.location + (fix as NSString).length
            } else {
                offset = range.location + range.length
            }
        }
        #elseif canImport(UIKit)
        let checker = UITextChecker()
        while offset < (result as NSString).length {
            let range = checker.rangeOfMisspelledWord(in: result, range: NSRange(location: 0, length: (result as NSString).length),
                                                      startingAt: offset, wrap: false, language: "en")
            guard range.location != NSNotFound, range.length > 0 else { break }
            if let fix = checker.guesses(forWordRange: range, in: result, language: "en")?.first {
                result = (result as NSString).replacingCharacters(in: range, with: fix)
                changed = true
                offset = range.location + (fix as NSString).length
            } else {
                offset = range.location + range.length
            }
        }
        #endif
        return changed ? result : nil
    }

    /// Stack Exchange tag and listing pages match many words but answer nothing.
    static func isListing(_ hit: ZimHit) -> Bool { isListing(path: hit.path, title: hit.title) }

    static func isListing(path: String, title: String) -> Bool {
        let p = path.lowercased(), t = title.lowercased()
        return p.contains("tagged/") || p.contains("_page=") || p.hasPrefix("tags") || p.hasPrefix("users")
            || t.hasPrefix("highest voted") || t.hasPrefix("newest") || t.hasPrefix("questions/")
    }

    /// Adjacent word pairs from the question, e.g. "heat stroke".
    static func phrases(_ terms: [String]) -> [String] {
        guard terms.count > 1 else { return [] }
        return (0..<(terms.count - 1)).map { "\(terms[$0]) \(terms[$0 + 1])" }
    }

    /// Title matches count most, exact phrases beat scattered words, longer words are more specific.
    /// Returns (score, coverage) where coverage is the weighted share of question words present.
    static func relevance(title: String, snippet: String, xapian: Int,
                          terms: [String], phrases: [String]) -> (Double, Double) {
        plainRelevance(title: title.lowercased(), text: HTMLText.stripTags(snippet).lowercased(), xapian: xapian,
                       terms: terms, phrases: phrases)
    }

    /// `relevance` for plain, already-lowercased text (index passages): no tag stripping.
    static func plainRelevance(title t: String, text s: String, xapian: Int,
                               terms: [String], phrases: [String]) -> (Double, Double) {
        var total = 0.0, inTitle = 0.0, inAny = 0.0
        for term in terms {
            let w = term.count >= 6 ? 1.5 : 1.0
            total += w
            let stem = String(term.prefix(5))
            if t.contains(stem) { inTitle += w; inAny += w } else if s.contains(stem) { inAny += w }
        }
        var phraseScore = 0.0
        for p in phrases {
            if t.contains(p) { phraseScore += 3 } else if s.contains(p) { phraseScore += 1.5 }
        }
        let coverage = total > 0 ? inAny / total : 0
        let score = 3 * (inTitle / max(total, 1)) + 2 * coverage + phraseScore + Double(xapian) / 200
        return (score, coverage)
    }

    /// `relevance` for plain, already-lowercased text (PDF pages): no tag stripping, so thousands of pages stay fast.
    static func textRelevance(title: String, text: String, terms: [String], phrases: [String]) -> (Double, Double) {
        var total = 0.0, inTitle = 0.0, inAny = 0.0
        for term in terms {
            let w = term.count >= 6 ? 1.5 : 1.0
            total += w
            let stem = String(term.prefix(5))
            if title.contains(stem) { inTitle += w; inAny += w } else if text.contains(stem) { inAny += w }
        }
        var phraseScore = 0.0
        for p in phrases where text.contains(p) || title.contains(p) { phraseScore += 1.5 }
        let coverage = total > 0 ? inAny / total : 0
        return (3 * (inTitle / max(total, 1)) + 2 * coverage + phraseScore, coverage)
    }

    // MARK: Text scoring

    static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) && seen.insert($0).inserted }
    }

    /// Strict query first, then the longest (most specific) words.
    static func queryVariants(_ terms: [String]) -> [String] {
        var variants = [terms.joined(separator: " ")]
        if terms.count > 3 {
            variants.append(terms.sorted { $0.count > $1.count }.prefix(3).joined(separator: " "))
        }
        if terms.count > 1 {
            variants.append(terms.max { $0.count < $1.count }!)
        }
        return variants
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "of", "to", "in", "on", "at", "by", "for", "with",
        "about", "from", "into", "is", "are", "was", "were", "be", "been", "being", "do", "does", "did", "how",
        "what", "when", "where", "which", "who", "whom", "why", "can", "could", "should", "would", "will",
        "shall", "may", "might", "must", "i", "me", "my", "we", "our", "you", "your", "he", "she", "it", "its",
        "they", "them", "their", "this", "that", "these", "those", "there", "here", "so", "as", "not", "no",
        "yes", "any", "some", "all", "get", "got", "make", "best", "way", "ways", "tell", "explain", "please",
        "much", "many", "need", "want", "know", "use", "using", "used", "without", "have", "has", "had",
    ]
}

/// Minimal HTML-to-text for article bodies. Good enough for retrieval, not for display.
///
/// One pass over the UTF-8 bytes (the answer index runs it over every article of every reference): blocks that
/// say nothing (scripts, styles, navigation, figures, tables, footnote marks) are dropped, nested ones whole;
/// paragraph-level tags become line breaks and section headings are marked; other tags go; entities are
/// decoded; footnote marks like "[3]" go; runs of spaces become one; lines shorter than `minLength` are dropped.
/// Same text as the regular expressions it replaced (okit --html-check compares them over an archive) except
/// for nested tables, which it drops whole where they left the outer table's tail (navbox lists, infobox
/// names) in the text; 30 to 60 times faster on Wikipedia, iFixit and Stack Exchange articles.
enum HTMLText {
    private static let tags = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let numericEntity = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")

    static func stripTags(_ s: String) -> String {
        tags.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    static func paragraphs(_ html: String, minLength: Int = 80) -> [String] {
        var html = html
        return html.withUTF8 { lines($0, minLength: minLength, headings: false).map(\.text) }
    }

    /// Paragraphs in reading order, each with the heading of the section it's in (nil before the first heading:
    /// the lead). Same cleanup as `paragraphs`.
    static func sections(_ html: String, minLength: Int = 80) -> [(heading: String?, text: String)] {
        var html = html
        return html.withUTF8 { sections(utf8: $0, minLength: minLength) }
    }

    static func sections(utf8: UnsafeBufferPointer<UInt8>, minLength: Int = 80) -> [(heading: String?, text: String)] {
        lines(utf8, minLength: minLength, headings: true)
    }

    // MARK: Scanner

    private enum Tag { case drop, heading, lineBreak, other }
    private static let lt: UInt8 = 0x3C, gt: UInt8 = 0x3E, amp: UInt8 = 0x26, slash: UInt8 = 0x2F, newline: UInt8 = 0x0A
    private static let headingMark: UInt8 = 0x01

    @inline(__always) private static func lower(_ c: UInt8) -> UInt8 { c >= 0x41 && c <= 0x5A ? c | 0x20 : c }
    @inline(__always) private static func isAlnum(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c | 0x20 >= 0x61 && c | 0x20 <= 0x7A)
    }

    /// The tag name packed into an integer, lowercased (names up to 8 letters; "blockquote" gets its own value).
    @inline(__always) private static func pack(_ s: StaticString) -> UInt64 {
        var v: UInt64 = 0
        s.withUTF8Buffer { for (i, c) in $0.enumerated() { v |= UInt64(c) << (8 * UInt64(i)) } }
        return v
    }
    private static let blockquote: UInt64 = ~0
    private static let dropNames: Set<UInt64> = [pack("script"), pack("style"), pack("head"), pack("nav"), pack("footer"),
                                                 pack("figure"), pack("table"), pack("sup")]
    private static let headingNames: Set<UInt64> = [pack("h2"), pack("h3"), pack("h4"), pack("h5"), pack("h6")]
    private static let breakNames: Set<UInt64> = [pack("p"), pack("br"), pack("li"), pack("h1"), pack("h2"), pack("h3"),
                                                  pack("h4"), pack("h5"), pack("h6"), pack("div"), pack("section"),
                                                  pack("tr"), pack("dd"), pack("dt"), blockquote]

    /// Reads the tag name at `i` (just after "<" or "</"): its packed value and where it ends, or nil when it
    /// isn't followed by a word boundary (so "<tables>" or "<h2x>" are no known tag).
    @inline(__always)
    private static func name(_ b: UnsafeBufferPointer<UInt8>, at i: Int, end: Int) -> (key: UInt64, end: Int)? {
        var j = i, key: UInt64 = 0
        while j < end, isAlnum(b[j]) {
            if j - i < 8 { key |= UInt64(lower(b[j])) << (8 * UInt64(j - i)) }
            j += 1
        }
        guard j > i else { return nil }
        if j < end, b[j] == 0x5F || b[j] >= 0x80 { return nil }   // "_" or a non-ASCII letter: no word boundary
        if j - i > 8 {
            guard j - i == 10, key == pack("blockquo"), lower(b[i + 8]) == 0x74, lower(b[i + 9]) == 0x65 else { return (0, j) }
            return (blockquote, j)
        }
        return (key, j)
    }

    /// Next `byte` at or after `i`, before `end`.
    @inline(__always)
    private static func find(_ byte: UInt8, _ b: UnsafeBufferPointer<UInt8>, from i: Int, end: Int) -> Int? {
        guard i < end, let base = b.baseAddress, let p = memchr(base + i, Int32(byte), end - i) else { return nil }
        return base.distance(to: p.assumingMemoryBound(to: UInt8.self))
    }

    /// True when `</name>` (exactly, any case) starts at `i`.
    @inline(__always)
    private static func isClose(_ b: UnsafeBufferPointer<UInt8>, at i: Int, end: Int, name: Range<Int>) -> Bool {
        let n = name.count
        guard i + n + 3 <= end, b[i + 1] == slash, b[i + n + 2] == gt else { return false }
        for k in 0..<n where lower(b[i + 2 + k]) != lower(b[name.lowerBound + k]) { return false }
        return true
    }

    /// Where a dropped block that opened with `name` ends (just past its closing tag), counting nested blocks of
    /// the same kind. Unbalanced: the first closing tag. None at all: nil, and the opening tag is just a tag.
    private static func blockEnd(_ b: UnsafeBufferPointer<UInt8>, from start: Int, end: Int, name: Range<Int>, key: UInt64) -> Int? {
        var depth = 1, i = start, firstClose: Int?
        while let open = find(lt, b, from: i, end: end) {
            if isClose(b, at: open, end: end, name: name) {
                let after = open + name.count + 3
                if firstClose == nil { firstClose = after }
                depth -= 1
                if depth == 0 { return after }
                i = after
            } else if let tag = Self.name(b, at: open + 1, end: end), tag.key == key, tag.end - open - 1 == name.count,
                      let close = find(gt, b, from: tag.end, end: end) {
                depth += 1
                i = close + 1
            } else {
                i = open + 1
            }
        }
        return firstClose
    }

    /// Appends text with its entities decoded.
    private static func appendText(_ b: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, to out: inout [UInt8]) {
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            guard let a = find(amp, b, from: i, end: end) else {
                out.append(contentsOf: UnsafeBufferPointer(rebasing: b[i..<end]))
                return
            }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: b[i..<a]))
            if let used = entity(b, at: a, end: end, into: &out) { i = used } else { out.append(amp); i = a + 1 }
        }
    }

    private static let named: [(name: [UInt8], value: [UInt8])] = ([
        ("nbsp", " "), ("amp", "&"), ("lt", "<"), ("gt", ">"), ("quot", "\""), ("#39", "'"), ("apos", "'"),
        ("ndash", "-"), ("mdash", "-"), ("minus", "-"), ("deg", "°"), ("times", "×"),
    ] as [(String, String)]).map { (name: Array($0.0.utf8), value: Array($0.1.utf8)) }

    /// Decodes the entity at `i` (the "&") into `out` and returns where it ends, or nil when it isn't one we know.
    private static func entity(_ b: UnsafeBufferPointer<UInt8>, at i: Int, end: Int, into out: inout [UInt8]) -> Int? {
        guard let semi = find(0x3B, b, from: i + 1, end: min(end, i + 12)), semi > i + 1 else { return nil }
        let body = UnsafeBufferPointer(rebasing: b[(i + 1)..<semi])
        for entry in named where entry.name.elementsEqual(body) {
            out.append(contentsOf: entry.value)
            return semi + 1
        }
        guard body.count >= 2, body[0] == 0x23 else { return nil }   // "#"
        let hex = body[1] == 0x78                                     // "x"
        let digits = body.dropFirst(hex ? 2 : 1)
        guard !digits.isEmpty, digits.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 | 0x20 >= 0x61 && $0 | 0x20 <= 0x66) })
        else { return nil }
        // Like the pattern it replaces: "&#12a;" is consumed even though it isn't a number.
        var code: UInt32 = 0, valid = true
        for d in digits {
            let v: UInt32 = d <= 0x39 ? UInt32(d - 0x30) : UInt32((d | 0x20) - 0x61 + 10)
            if !hex && v > 9 { valid = false; break }
            let (m, o1) = code.multipliedReportingOverflow(by: hex ? 16 : 10)
            let (s, o2) = m.addingReportingOverflow(v)
            if o1 || o2 { valid = false; break }
            code = s
        }
        if valid, let scalar = Unicode.Scalar(code) { out.append(contentsOf: Array(String(Character(scalar)).utf8)) }
        return semi + 1
    }

    /// The text with tags handled: line breaks, heading marks (when `headings`) and decoded entities.
    private static func strip(_ b: UnsafeBufferPointer<UInt8>, headings: Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count / 2)
        let end = b.count
        var i = 0
        while i < end {
            guard let open = find(lt, b, from: i, end: end) else { appendText(b, i..<end, to: &out); break }
            appendText(b, i..<open, to: &out)
            // A tag runs to the first ">" and holds at least one character; anything else is text.
            guard let close = find(gt, b, from: open + 1, end: end), close > open + 1 else {
                out.append(lt)
                i = open + 1
                continue
            }
            let closing = b[open + 1] == slash
            let nameStart = open + (closing ? 2 : 1)
            var kind = Tag.other
            if let tag = name(b, at: nameStart, end: end), tag.end <= close {
                if !closing, dropNames.contains(tag.key) { kind = .drop }
                else if !closing, headings, headingNames.contains(tag.key) { kind = .heading }
                else if breakNames.contains(tag.key) { kind = .lineBreak }
                if kind == .drop, let after = blockEnd(b, from: close + 1, end: end, name: nameStart..<tag.end, key: tag.key) {
                    out.append(0x20)
                    i = after
                    continue
                }
                if kind == .drop { kind = .other }
            }
            switch kind {
            case .heading: out.append(newline); out.append(headingMark)
            case .lineBreak: out.append(newline)
            case .drop, .other: break
            }
            i = close + 1
        }
        return out
    }

    /// Splits the stripped text into lines: footnote marks out, spaces collapsed, trimmed, short ones dropped.
    private static func lines(_ b: UnsafeBufferPointer<UInt8>, minLength: Int, headings: Bool) -> [(heading: String?, text: String)] {
        let text = strip(b, headings: headings)
        var out: [(heading: String?, text: String)] = []
        var heading: String?
        var line: [UInt8] = []
        line.reserveCapacity(4096)
        text.withUnsafeBufferPointer { t in
            var start = 0
            while start <= t.count {
                let stop = find(newline, t, from: start, end: t.count) ?? t.count
                defer { start = stop + 1 }
                let isHeading = stop > start && t[start] == headingMark
                // A line can't have more characters than bytes.
                guard isHeading || stop - start >= minLength else { continue }
                clean(t, (isHeading ? start + 1 : start)..<stop, into: &line)
                let s = String(decoding: line, as: UTF8.self)
                let trimmed = needsTrim(line) ? s.trimmingCharacters(in: .whitespaces) : s
                if isHeading {
                    if !trimmed.isEmpty { heading = trimmed }
                } else if trimmed.count >= minLength {
                    out.append((heading, trimmed))
                }
            }
        }
        return out
    }

    @inline(__always) private static func needsTrim(_ line: [UInt8]) -> Bool {
        guard let first = line.first, let last = line.last else { return false }
        return first == 0x20 || last == 0x20 || first >= 0x80 || last >= 0x80
    }

    /// One line with footnote marks ("[12]", "[citation needed]", "[edit]") removed and each run of spaces, tabs
    /// and no-break spaces made one space.
    private static func clean(_ t: UnsafeBufferPointer<UInt8>, _ range: Range<Int>, into line: inout [UInt8]) {
        line.removeAll(keepingCapacity: true)
        var i = range.lowerBound, inSpace = false
        let end = range.upperBound
        while i < end {
            let c = t[i]
            if c == 0x5B, let after = footnoteEnd(t, at: i, end: end) { i = after; continue }   // "["
            let space = c == 0x20 || c == 0x09 || (c == 0xC2 && i + 1 < end && t[i + 1] == 0xA0)
            if space {
                if !inSpace { line.append(0x20); inSpace = true }
                i += c == 0xC2 ? 2 : 1
                continue
            }
            inSpace = false
            line.append(c)
            i += 1
        }
    }

    private static let footnoteWords: [[UInt8]] = [Array("citation needed]".utf8), Array("edit]".utf8)]

    @inline(__always)
    private static func footnoteEnd(_ t: UnsafeBufferPointer<UInt8>, at i: Int, end: Int) -> Int? {
        var j = i + 1
        while j < end, t[j] >= 0x30, t[j] <= 0x39 { j += 1 }
        if j > i + 1, j < end, t[j] == 0x5D { return j + 1 }
        for word in footnoteWords where i + 1 + word.count <= end
            && UnsafeBufferPointer(rebasing: t[(i + 1)..<(i + 1 + word.count)]).elementsEqual(word) {
            return i + 1 + word.count
        }
        return nil
    }

    static func decodeEntities(_ input: String) -> String {
        var s = input
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                       "&apos;": "'", "&ndash;": "-", "&mdash;": "-", "&minus;": "-", "&deg;": "°", "&times;": "×"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in numericEntity.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let code = UInt32(num, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

/// True for the first caller only.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
