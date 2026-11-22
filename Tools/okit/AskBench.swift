import Darwin
import Foundation

/// Ask end to end, the way a person uses it: a fresh process opens the library, Ask opens (its warm-up and the
/// model preload start), the person types for `--wait` seconds, asks, reads for `--gap` seconds and asks a
/// follow-up. Times each turn from pressing Return to the first word, with where the time went.
/// usage: OFFLINEKIT_GREEDY=1 okit --ask-bench <conversations.txt> [--wait 5] [--gap 3] [--out results.json]
///   One question per line; a line "---" starts a new conversation (New Conversation). Lines starting "#" are skipped.
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
    }

    static func run(file: String, wait: Double, gap: Double, out: String?) async {
        let launched = Date()
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        var conversations: [[String]] = [[]]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { if !conversations[conversations.count - 1].isEmpty { conversations.append([]) }; continue }
            if line.isEmpty || line.hasPrefix("#") { continue }
            conversations[conversations.count - 1].append(line)
        }
        conversations.removeAll { $0.isEmpty }

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
            for (t, question) in questions.enumerated() {
                var row = TurnResult(conversation: c + 1, turn: t + 1, question: question)
                let start = Date()
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
                    if let error = turn.error { row.answer = "ERROR: " + error }
                }
                row.promptTokens = LlamaRuntime.lastPrefill.total
                row.reusedTokens = LlamaRuntime.lastPrefill.reused
                row.prefillMs = LlamaRuntime.lastTimings.prefillMs
                print(String(format: "  c%d t%d  search %6.0f ms  first word %6.0f ms  (prompt %4d tok, %4d reused, prefill %5.0f ms)  total %6.0f ms  footprint %4.0f MB  %@",
                             row.conversation, row.turn, row.searchMs, row.firstWordMs, row.promptTokens, row.reusedTokens,
                             row.prefillMs, row.totalMs, footprintMB(), question))
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
        print(String(format: "Peak footprint %.0f MB; saved model state now %.0f MB", LlamaBench.peakFootprintMB(),
                     Double(LlamaRuntime.shared.savedStateBytes) / 1_048_576))
        if let out {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(results).write(to: URL(fileURLWithPath: out))
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
