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

    static func retrieve(question: String, archives: [ZimArchive], budgetChars: Int, maxSources: Int = 6) -> [Source] {
        let terms = Self.terms(question)
        guard !terms.isEmpty else { return [] }
        let phrases = Self.phrases(terms)

        // 1. Gather candidates from every archive: exact phrases first, then broader queries.
        struct Candidate { let archive: ZimArchive; let hit: ZimHit; var score: Double; var coverage: Double }
        var candidates: [Candidate] = []
        for archive in archives where archive.hasFullTextIndex {
            // libzim matches ALL words, so a long question can miss the obvious article.
            // Search each two-word phrase on its own, then the whole question, then its most specific words.
            var seen = Set<String>(), seenTitles = Set<String>()
            let queries = phrases.map { ($0, 5) } + queryVariants(terms).map { ($0, 10) }
            for (query, limit) in queries {
                for hit in archive.search(query, limit: limit)
                where seen.insert(hit.path).inserted && seenTitles.insert(hit.title.lowercased()).inserted && !isListing(hit) {
                    var (score, coverage) = relevance(title: hit.title, snippet: hit.snippet, xapian: hit.score,
                                                      terms: terms, phrases: phrases)
                    // An article named exactly for part of the question ("Heat stroke") is on topic.
                    let titleTerms = Self.terms(hit.title)
                    if !titleTerms.isEmpty && titleTerms.allSatisfy({ t in terms.contains { $0.hasPrefix(String(t.prefix(5))) } }) {
                        score += 2 + Double(titleTerms.count)
                        coverage = max(coverage, 1)
                    }
                    candidates.append(Candidate(archive: archive, hit: hit, score: score, coverage: coverage))
                }
                if seen.count >= 20 { break }
            }
        }
        // Titles too, in every archive: some (like the Zimgit guides) have no full-text index at all, and an
        // article named for the topic ("Bowline") beats a forum post that happens to mention it.
        let specific = terms.max { $0.count < $1.count } ?? ""
        for archive in archives {
            var seenPaths = Set(candidates.filter { $0.archive.uuid == archive.uuid }.map(\.hit.path))
            for query in Set([terms.prefix(3).joined(separator: " "), specific]) where !query.isEmpty {
                for hit in archive.suggest(query, limit: 3) where seenPaths.insert(hit.path).inserted && !isListing(hit) {
                    var (score, coverage) = relevance(title: hit.title, snippet: "", xapian: 0, terms: terms, phrases: phrases)
                    let titleTerms = Self.terms(hit.title)
                    if !titleTerms.isEmpty && titleTerms.allSatisfy({ t in terms.contains { $0.hasPrefix(String(t.prefix(5))) } }) {
                        score += 2 + Double(titleTerms.count)
                        coverage = max(coverage, 1)
                    }
                    candidates.append(Candidate(archive: archive, hit: hit, score: score, coverage: coverage))
                }
            }
        }

        // 2. Keep articles that mention most of the question; cap each archive so none dominates.
        // Weak matches are dropped: no source is better than a misleading one.
        let bestCoverage = candidates.map(\.coverage).max() ?? 0
        let floor = max(0.5, min(0.6, bestCoverage))
        var perArchive: [String: Int] = [:]
        let shortlist = candidates
            .filter { $0.coverage >= floor }
            .sorted { $0.score > $1.score }
            .filter { c in
                let n = perArchive[c.archive.uuid, default: 0]
                perArchive[c.archive.uuid] = n + 1
                return n < 3
            }
            .prefix(8)

        // 3. Pull the best paragraphs from each article.
        struct Passage { let score: Double; let ref: ArticleRef; let book: String; let text: String }
        var passages: [Passage] = []
        let perArticle = max(600, budgetChars / 3)

        for c in shortlist {
            guard let content = c.archive.content(atPath: c.hit.path),
                  content.mimeType.hasPrefix("text/html"),
                  let html = String(data: content.data, encoding: .utf8) else { continue }
            let paragraphs = HTMLText.paragraphs(html)
            guard !paragraphs.isEmpty else { continue }

            let scored = paragraphs.enumerated().map { (i, p) -> (Int, Double) in
                let (s, _) = relevance(title: "", snippet: p, xapian: 0, terms: terms, phrases: phrases)
                return (i, s + (i == 0 ? 0.3 : 0))   // lead paragraph usually defines the topic
            }
            let best = scored.filter { $0.1 > 0.5 }.sorted { $0.1 > $1.1 }.prefix(3).sorted { $0.0 < $1.0 }
            guard !best.isEmpty else { continue }

            var text = ""
            for (i, _) in best {
                let p = paragraphs[i]
                if text.count + p.count > perArticle { break }
                text += (text.isEmpty ? "" : "\n") + p
            }
            if text.isEmpty { text = String(paragraphs[best[0].0].prefix(perArticle)) }

            let total = c.score * 2 + (best.map(\.1).max() ?? 0)
            let ref = ArticleRef(bookID: c.archive.uuid.lowercased(), path: content.path, title: c.hit.title)
            passages.append(Passage(score: total, ref: ref, book: c.archive.title, text: text))
        }

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

        // 4. Highest-scoring passages first, one per article, within budget. Drop weak stragglers.
        let top = passages.map(\.score).max() ?? 0
        passages.removeAll { $0.score < top * 0.5 }
        var used = 0
        var seen = Set<String>()
        // WikiMed, MDWiki and Wikipedia often carry the same article; one copy leaves room for other sources.
        var seenTitles = Set<String>()
        var sources: [Source] = []
        for p in passages.sorted(by: { $0.score > $1.score }) {
            let titleKey = p.ref.title.lowercased().filter { $0.isLetter || $0.isNumber }
            guard sources.count < maxSources, seen.insert(p.ref.id).inserted, seenTitles.insert(titleKey).inserted else { continue }
            if used + p.text.count > budgetChars && !sources.isEmpty { continue }
            used += p.text.count
            sources.append(Source(id: sources.count + 1, ref: p.ref, bookTitle: p.book, text: p.text))
        }
        return sources
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
    static func isListing(_ hit: ZimHit) -> Bool {
        let p = hit.path.lowercased(), t = hit.title.lowercased()
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
        let t = title.lowercased()
        let s = HTMLText.stripTags(snippet).lowercased()
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
enum HTMLText {
    private static let dropBlocks = try! NSRegularExpression(
        pattern: "<(script|style|head|nav|footer|figure|table|sup)\\b[^>]*>.*?</\\1>",
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let breaks = try! NSRegularExpression(
        pattern: "</?(p|br|li|h[1-6]|div|section|tr|dd|dt|blockquote)\\b[^>]*>", options: .caseInsensitive)
    private static let tags = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let numericEntity = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
    private static let spaces = try! NSRegularExpression(pattern: "[ \\t\\u00A0]+")
    private static let refMarks = try! NSRegularExpression(pattern: "\\[(\\d+|citation needed|edit)\\]")

    static func stripTags(_ s: String) -> String {
        replace(tags, in: s, with: "")
    }

    static func paragraphs(_ html: String, minLength: Int = 80) -> [String] {
        var s = html
        // Tables can nest; strip the innermost a few times.
        for _ in 0..<4 { s = replace(dropBlocks, in: s, with: " ") }
        s = replace(breaks, in: s, with: "\n")
        s = replace(tags, in: s, with: "")
        s = decodeEntities(s)
        s = replace(refMarks, in: s, with: "")
        s = replace(spaces, in: s, with: " ")
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= minLength }
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
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
