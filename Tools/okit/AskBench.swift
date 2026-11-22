import Darwin
import Foundation

/// Ask end to end, the way a person uses it: a fresh process opens the library, Ask opens (its warm-up and the
/// model preload start), the person types for `--wait` seconds, asks, reads for `--gap` seconds and asks a
/// follow-up. Times each turn from pressing Return to the first word, with where the time went.
/// Then scores each turn (AskQuality): the share of its top three sources on the expected topic, whether its
/// citations point at real sources, whether it says "not in your library" when it should, and instruction echoes.
/// usage: OFFLINEKIT_GREEDY=1 okit --ask-bench <conversations.txt> [--wait 5] [--gap 3] [--out results.json] [--sources-only]
///   One question per line; a line "---" starts a new conversation (New Conversation). Lines starting "#" are skipped.
///   "=> word|word; word" after a question is its expected topic, "=> none" a question the library doesn't cover.
///   --sources-only finds each turn's sources the way Ask does and skips the answers (fast, for retrieval changes).
///   Run with OFFLINEKIT_HOME=<test home> and OFFLINEKIT_NO_OLLAMA=1. OFFLINEKIT_NO_INDEX=1 searches with libzim only.
@MainActor
enum AskBench {
    struct TurnResult: Codable {
        let conversation: Int
        let turn: Int
        let question: String
        var searchMs = 0.0
        var firstWordMs = 0.0
        var totalMs = 0.0
        var promptTokens = 0
        var reusedTokens = 0
        var prefillMs = 0.0
        var sources: [String] = []
        var answer = ""
        var searchedFor: String?
        /// Share of the top three sources on the expected topic (nil when the question has none).
        var onTopic: Double?
        var onTopicSources: [Bool] = []
        /// The same with the old, strict test (any listed word anywhere in the title or passage).
        var strictOnTopicSources: [Bool] = []
        var uncovered = false
        var citations: [Int] = []
        var invalidCitations = 0
        var saysNotFound = false
        var echoes = false
        /// What the citation check did (CitationChecker): judged marks and how many their passage supported before
        /// the check, marks moved and dropped, and the sentences it changed.
        var citationCheck: CitationChecker.Report?
    }

    static func run(file: String, wait: Double, gap: Double, out: String?, sourcesOnly: Bool = false) async {
        let launched = Date()
        let conversations = AskQuality.conversations(file: file)

        let library = Library()
        await library.reload()
        // The app opens (or goes on building) the answer indexes once the library is open.
        if ProcessInfo.processInfo.environment["OFFLINEKIT_NO_INDEX"] == nil {
            AnswerIndex.shared.load(library.books.map(\.archive))
            let ready = AnswerIndex.shared.snapshot().rows.filter { $0.state == .ready }.count
            print("Answer indexes ready: \(ready) of \(library.books.count) archives")
        } else {
            print("Answer index: off (libzim search)")
        }
        print(String(format: "Library open %.2fs after launch: %d archives", Date().timeIntervalSince(launched), library.books.count))

        let model = AskModel()
        model.choice = .builtIn
        model.libraryFolders = library.folders
        // Ask opens.
        model.preloadIfNeeded(library: library, household: nil)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        print(String(format: "Footprint at the first question: %.0f MB (peak %.0f MB)", footprintMB(), LlamaBench.peakFootprintMB()))

        var results: [TurnResult] = []
        for (c, questions) in conversations.enumerated() {
            if c > 0 {
                model.clear()
                if gap > 0 { try? await Task.sleep(for: .seconds(gap)) }
            }
            for (t, q) in questions.enumerated() {
                let question = q.text
                var row = TurnResult(conversation: c + 1, turn: t + 1, question: question)
                let start = Date()
                if sourcesOnly {
                    let turn = await model.findSourcesForBench(question, library: library)
                    row.searchMs = Date().timeIntervalSince(start) * 1000
                    row.totalMs = row.searchMs
                    row.sources = turn.sources.map { "\($0.ref.title) · \($0.bookTitle)" }
                    row.searchedFor = turn.searchedFor
                    score(&row, q, turn)
                    print(String(format: "  c%d t%d  search %6.0f ms  on topic %@  %@", row.conversation, row.turn, row.searchMs,
                                 row.onTopic.map { String(format: "%.2f", $0) } ?? "  - ", question))
                    if let s = row.searchedFor { print("        searched for: \(s)") }
                    for (i, s) in row.sources.prefix(3).enumerated() { print("        \(row.onTopicSources.indices.contains(i) && row.onTopicSources[i] ? "+" : "-") \(s)") }
                    // OFFLINEKIT_SHOW_SOURCES=1 prints each source's passages, as the model gets them.
                    if ProcessInfo.processInfo.environment["OFFLINEKIT_SHOW_SOURCES"] != nil {
                        for source in turn.sources { print("        [\(source.id)] \(source.ref.title)\n\(source.text)\n") }
                    }
                    results.append(row)
                    continue
                }
                guard model.ask(question, library: library) else { print("  not taken: \(question)"); continue }
                var searched = false
                while model.isBusy {
                    if let turn = model.turns.last {
                        if !searched, turn.status != .searching { searched = true; row.searchMs = Date().timeIntervalSince(start) * 1000 }
                        if row.firstWordMs == 0, !turn.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            row.firstWordMs = Date().timeIntervalSince(start) * 1000
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(2))
                }
                row.totalMs = Date().timeIntervalSince(start) * 1000
                if let turn = model.turns.last {
                    row.answer = turn.answer
                    row.sources = turn.sources.map { "\($0.ref.title) · \($0.bookTitle)" }
                    row.searchedFor = turn.searchedFor
                    score(&row, q, turn)
                    if let error = turn.error { row.answer = "ERROR: " + error }
                }
                row.promptTokens = LlamaRuntime.lastPrefill.total
                row.reusedTokens = LlamaRuntime.lastPrefill.reused
                row.prefillMs = LlamaRuntime.lastTimings.prefillMs
                print(String(format: "  c%d t%d  search %6.0f ms  first word %6.0f ms  (prompt %4d tok, %4d reused, prefill %5.0f ms)  total %6.0f ms  footprint %4.0f MB  %@",
                             row.conversation, row.turn, row.searchMs, row.firstWordMs, row.promptTokens, row.reusedTokens,
                             row.prefillMs, row.totalMs, footprintMB(), question))
                print(String(format: "        on topic %@, citations %@%@%@%@", row.onTopic.map { String(format: "%.2f", $0) } ?? "-",
                             row.citations.map(String.init).joined(separator: ","), row.invalidCitations > 0 ? " (\(row.invalidCitations) invalid)" : "",
                             row.saysNotFound ? ", says not found" : "", row.echoes ? ", ECHOES INSTRUCTIONS" : ""))
                if let s = row.searchedFor { print("        searched for: \(s)") }
                for (i, s) in row.sources.prefix(3).enumerated() { print("        \(row.onTopicSources.indices.contains(i) && row.onTopicSources[i] ? "+" : "-") \(s)") }
                if let check = row.citationCheck {
                    print(String(format: "        citation check: %d judged, %d supported, %d moved, %d dropped, %d too short (%.1f ms)",
                                 check.checked, check.supported, check.repointed, check.dropped, check.unchecked, check.milliseconds))
                    for change in check.changes {
                        print("          \(change.from) -> \(change.to.isEmpty ? "dropped" : "\(change.to)"): \(change.sentence.prefix(140))")
                    }
                }
                results.append(row)
                if gap > 0 { try? await Task.sleep(for: .seconds(gap)) }
            }
        }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        for t in 1...max(1, results.map(\.turn).max() ?? 1) {
            let rows = results.filter { $0.turn == t }
            guard !rows.isEmpty else { continue }
            print(String(format: "Turn %d: first word median %.0f ms (%@), search median %.0f ms, prompt median %.0f tok, reused median %.0f tok",
                         t, median(rows.map(\.firstWordMs)), rows.map { String(format: "%.0f", $0.firstWordMs) }.joined(separator: ", "),
                         median(rows.map(\.searchMs)), median(rows.map { Double($0.promptTokens) }), median(rows.map { Double($0.reusedTokens) })))
        }
        summarize(results, answered: !sourcesOnly)
        print(String(format: "Peak footprint %.0f MB; saved model state now %.0f MB", LlamaBench.peakFootprintMB(),
                     Double(LlamaRuntime.shared.savedStateBytes) / 1_048_576))
        if let out {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(results).write(to: URL(fileURLWithPath: out))
        }
    }
}

extension AskBench {
    static func score(_ row: inout TurnResult, _ q: AskQuality.Question, _ turn: Turn) {
        row.uncovered = q.uncovered
        if !q.topic.isEmpty {
            row.onTopicSources = turn.sources.map { AskQuality.onTopic(title: $0.ref.title, text: $0.text, topic: q.topic) }
            row.strictOnTopicSources = turn.sources.map { AskQuality.matches($0.ref.title + "\n" + $0.text, topic: q.topic) }
            let top = row.onTopicSources.prefix(3)
            row.onTopic = top.isEmpty ? 0 : Double(top.filter { $0 }.count) / Double(top.count)
        }
        row.citations = AskQuality.citations(turn.answer)
        row.invalidCitations = row.citations.filter { $0 < 1 || $0 > turn.sources.count }.count
        row.saysNotFound = AskQuality.saysNotFound(turn.answer)
        row.echoes = AskQuality.echoes(turn.answer)
        row.citationCheck = turn.citations
    }

    /// On-topic rate per kind of turn, citations, "not in your library" and echoes, and search time.
    static func summarize(_ results: [TurnResult], answered: Bool) {
        func mean(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0, +) / Double(v.count) }
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        let kinds: [(String, (TurnResult) -> Bool)] = [
            ("first questions", { $0.turn == 1 }),
            ("follow-ups", { $0.turn > 1 }),
            ("  pronoun-led or short", { $0.turn > 1 && AskModel.isFollowUp($0.question) }),
            ("  other follow-ups", { $0.turn > 1 && !AskModel.isFollowUp($0.question) }),
            ("all", { _ in true }),
        ]
        print("\nQuality (top-3 sources on the expected topic; hit = at least one):")
        for (name, filter) in kinds {
            let rows = results.filter(filter).filter { $0.onTopic != nil }
            guard !rows.isEmpty else { continue }
            let hits = rows.filter { $0.onTopicSources.prefix(3).contains(true) }.count
            let topFirst = rows.filter { $0.onTopicSources.first == true }.count
            let strict = mean(rows.map { r in let top = r.strictOnTopicSources.prefix(3); return top.isEmpty ? 0 : Double(top.filter { $0 }.count) / Double(top.count) })
            print(String(format: "  %-24@ on topic %.2f  hit %2d/%-2d  first source on topic %2d/%-2d  search median %4.0f ms  (strict scorer %.2f)",
                         name as NSString, mean(rows.compactMap(\.onTopic)), hits, rows.count, topFirst, rows.count, median(rows.map(\.searchMs)), strict))
        }
        guard answered else { return }
        let cited = results.flatMap(\.citations).count, invalid = results.map(\.invalidCitations).reduce(0, +)
        // Citations of on-topic sources, among valid citations of scored turns.
        var onTopicCites = 0, scoredCites = 0
        for r in results where r.onTopic != nil {
            for n in r.citations where n >= 1 && n <= r.onTopicSources.count {
                scoredCites += 1
                if r.onTopicSources[n - 1] { onTopicCites += 1 }
            }
        }
        print(String(format: "  citations: %d, %d valid (%.0f%%); %d of %d cite an on-topic source", cited, cited - invalid,
                     cited == 0 ? 100 : Double(cited - invalid) / Double(cited) * 100, onTopicCites, scoredCites))
        let uncovered = results.filter(\.uncovered)
        let covered = results.filter { !$0.uncovered && $0.onTopicSources.prefix(3).contains(true) }
        print("  \"not in your library\": \(uncovered.filter(\.saysNotFound).count) of \(uncovered.count) uncovered questions say so; "
              + "\(covered.filter(\.saysNotFound).count) of \(covered.count) questions with on-topic sources wrongly say so")
        print("  answers with no citation despite on-topic sources: \(covered.filter { $0.citations.isEmpty && !$0.saysNotFound }.count)")
        print("  instruction echoes: \(results.filter(\.echoes).count)")
        let checks = results.compactMap(\.citationCheck)
        if !checks.isEmpty {
            let judged = checks.map(\.checked).reduce(0, +), supported = checks.map(\.supported).reduce(0, +)
            let moved = checks.map(\.repointed).reduce(0, +), dropped = checks.map(\.dropped).reduce(0, +)
            let short = checks.map(\.unchecked).reduce(0, +)
            let after = judged - dropped
            print(String(format: "  citation check: %d marks judged, %d supported by their passage before (%.0f%%), %.0f%% after; %d moved, %d dropped, %d too short to judge; median %.1f ms, max %.1f ms",
                         judged, supported, judged == 0 ? 100 : Double(supported) / Double(judged) * 100,
                         after == 0 ? 100 : Double(supported + moved) / Double(after) * 100, moved, dropped, short,
                         median(checks.map(\.milliseconds)), checks.map(\.milliseconds).max() ?? 0))
        }
    }
}

/// This process's memory footprint right now (what macOS counts against it, GPU buffers included).
func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let status = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

/// The first libzim search of each archive (it opens the archive's Xapian database) against the ones after it.
/// usage: okit --search-cold "query" [more queries…]
enum SearchCold {
    static func run(queries: [String]) async {
        let library = await MainActor.run { Library() }
        await library.reload()
        let archives = await MainActor.run { library.books.map(\.archive) }
        for archive in archives {
            var line = archive.title.padding(toLength: 34, withPad: " ", startingAt: 0)
            for (i, q) in queries.enumerated() {
                let s = Date()
                let hits = archive.search(q, limit: 10).count
                let s2 = Date()
                _ = archive.suggest(q, limit: 3)
                line += String(format: "  %@search %6.1f ms (%2d) suggest %5.1f ms", i == 0 ? "first " : "", s2.timeIntervalSince(s) * 1000, hits,
                               Date().timeIntervalSince(s2) * 1000)
            }
            print(line)
        }
    }
}

/// The real answer-index builder (the app's worker policy and priorities) on one archive for a while: articles
/// a second and CPU use. OFFLINEKIT_INDEX_WORKERS=1 is the battery path (one worker at background priority).
/// usage: okit --index-build <file.zim> [--seconds 60]
enum IndexBuild {
    static func run(zim: String, seconds: Double) async {
        guard let archive = try? ZimArchive(path: zim) else { print("can't open \(zim)"); return }
        let depth = AnswerIndexPolicy.depth(articleCount: Int(archive.articleCount))
        print("\(archive.title): \(archive.articleCount) articles, \(archive.entryCount) entries, depth \(depth.rawValue), workers \(AnswerIndexPolicy.workers(plugged: true))")
        // A fresh index each run.
        try? FileManager.default.removeItem(at: AnswerIndex.folder)
        func cpu() -> Double {
            var usage = rusage()
            getrusage(RUSAGE_SELF, &usage)
            return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        }
        func cursor() -> (done: Int, total: Int, ready: Bool) {
            guard let row = AnswerIndex.shared.snapshot().rows.first else { return (0, 1, false) }
            switch row.state {
            case .building(let done, let total): return (done, total, false)
            case .ready: return (Int(archive.entryCount), Int(archive.entryCount), true)
            default: return (0, 1, false)
            }
        }
        AnswerIndex.shared.setPaused(false)
        AnswerIndex.shared.load([archive])
        // Measure from the first progress, so opening the archive and the store isn't counted.
        while cursor().done == 0 && !cursor().ready { try? await Task.sleep(for: .milliseconds(20)) }
        let (startDone, total, _) = cursor()
        let startCPU = cpu(), start = Date()
        while Date().timeIntervalSince(start) < seconds, !cursor().ready { try? await Task.sleep(for: .milliseconds(200)) }
        let elapsed = Date().timeIntervalSince(start), used = cpu() - startCPU
        let (done, _, ready) = cursor()
        let entries = Double(done - startDone)
        let articles = entries * Double(archive.articleCount) / Double(max(total, 1))
        print(String(format: "%@ %.0f entries (about %.0f articles) in %.1fs: %.0f articles/s, CPU %.0f%% (%.2f ms CPU an article)",
                     ready ? "Finished:" : "Partial:", entries, articles, elapsed, articles / elapsed, used / elapsed * 100,
                     used * 1000 / max(articles, 1)))
    }
}

/// Where the right article for each benchmark question is in the library, if anywhere: the titles on the expected
/// topic that title lookups (each topic word) and a search of the question's words find, per archive. Tells a
/// retrieval miss apart from a gap in the library.
/// usage: okit --topic-check <questions.txt>
enum TopicCheck {
    @MainActor static func run(file: String) async {
        let library = Library()
        await library.reload()
        if ProcessInfo.processInfo.environment["OFFLINEKIT_NO_INDEX"] == nil { AnswerIndex.shared.load(library.books.map(\.archive)) }
        let archives = library.books.map(\.archive)
        var covered = 0, total = 0
        for q in AskQuality.conversations(file: file).flatMap({ $0 }) where !q.topic.isEmpty {
            total += 1
            var found: [(title: String, book: String, score: Double)] = []
            var seen = Set<String>()
            let terms = Retriever.terms(q.text)
            for archive in archives {
                var titles: [(path: String, title: String)] = []
                for word in q.topic.flatMap({ $0 }) { titles += archive.suggest(word, limit: 8).map { ($0.path, $0.title) } }
                if let store = AnswerIndex.shared.store(for: archive) {
                    titles += store.search(terms: terms, phrases: Retriever.phrases(terms), limit: 30).map { ($0.path, $0.title) }
                } else if archive.hasFullTextIndex {
                    titles += archive.search(terms.joined(separator: " "), limit: 20).map { ($0.path, $0.title) }
                }
                for t in titles where AskQuality.onTopic(title: t.title, text: "", topic: q.topic) && !Retriever.isListing(path: t.path, title: t.title)
                    && !t.title.hasPrefix("User ") && seen.insert(t.title.lowercased()).inserted {
                    // Ranked by how much of the question the title covers.
                    let (score, _) = Retriever.plainRelevance(title: t.title.lowercased(), text: "", xapian: 0, terms: terms,
                                                              phrases: Retriever.phrases(terms))
                    found.append((t.title, archive.title, score))
                }
            }
            found.sort { $0.score > $1.score }
            if !found.isEmpty { covered += 1 }
            print("\(found.isEmpty ? "MISSING" : "found  ") \(q.text)")
            for f in found.prefix(6) { print("          \(f.title) · \(f.book)") }
        }
        print("\(covered) of \(total) questions have an article titled on the topic")
    }
}

extension IndexBuild {
    /// Builds the answer index of every archive in the library (the app's builder, plugged-in policy) and waits until
    /// each is ready or `minutes` pass, so the Ask benchmarks search the way the app does once Kit Care is done.
    @MainActor static func all(minutes: Double) async {
        let library = Library()
        await library.reload()
        AnswerIndex.shared.setPaused(false)
        AnswerIndex.shared.setPlugged(true)
        AnswerIndex.shared.load(library.books.map(\.archive))
        let start = Date()
        var lastLine = ""
        while Date().timeIntervalSince(start) < minutes * 60 {
            let rows = AnswerIndex.shared.snapshot().rows
            let ready = rows.filter { $0.state == .ready }.count
            let pending = rows.filter { if case .building = $0.state { return true }; return $0.state == .waiting }
            let line = String(format: "%4.0fs  %d of %d ready", Date().timeIntervalSince(start), ready, rows.count)
                + (pending.first.map { row in
                    if case .building(let done, let total) = row.state { return String(format: "; building %@ %.0f%%", row.title, Double(done) / Double(max(total, 1)) * 100) }
                    return "; waiting " + row.title
                } ?? "")
            if line != lastLine, Int(Date().timeIntervalSince(start)) % 15 == 0 { print(line); lastLine = line }
            if pending.isEmpty { break }
            try? await Task.sleep(for: .seconds(1))
        }
        for row in AnswerIndex.shared.snapshot().rows {
            print(String(format: "  %@ %@ %@ %.0f MB %.0fs", row.title, row.depth.rawValue, "\(row.state)", Double(row.bytes) / 1_048_576, row.seconds))
        }
    }
}

extension AskModel {
    /// A turn whose sources were found the way Ask finds them (`AskModel.findSources`, with the conversation so far),
    /// left unanswered: added to the conversation as answered, so the next question is a follow-up to it.
    func findSourcesForBench(_ question: String, library: Library) async -> Turn {
        var turn = Turn(question: question)
        guard let engine = await resolveEngine() else { return turn }
        let previous = turns.filter { $0.status == .done }
        if let found = await Self.findSources(question: question, scope: nil, previous: previous, library: library, engine: engine,
                                              budget: engine.sourceBudget, emergency: false, isCurrent: { true }) {
            turn.sources = found.sources
            turn.searchedFor = found.searchedFor
            turn.query = found.query
        }
        turn.answer = "(not answered)"
        turn.status = .done
        turns.append(turn)
        return turn
    }
}
