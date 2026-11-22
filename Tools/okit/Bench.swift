import Foundation

/// Headless Ask benchmark: retrieval time, source size and (with a built-in model) time to first word.
/// usage: okit --bench <questions.txt> [--ttfw] [--out results.json]
/// Run it with OFFLINEKIT_HOME=<test home> so only the test library is read.
@MainActor
enum Bench {
    struct Row: Codable {
        let question: String
        var retrievalMs: [Double] = []
        var sources: [String] = []
        var sourceChars = 0
        var sourceTokens = 0
        var promptTokens = 0
        var firstWordMs: Double?
    }

    static func run(questionsFile: String, ttfw: Bool, out: String?) async {
        let questions = ((try? String(contentsOfFile: questionsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let library = Library()
        await library.reload()
        let archives = library.books.map(\.archive)
        print("Archives: \(library.books.map { "\($0.title) (\($0.archive.articleCount) articles)" }.joined(separator: ", "))")
        await prepare(library: library)

        let model = LocalModels.selected(libraryFolders: library.folders, id: "")
        let engine = model.map { LlamaEngine(model: $0) }
        let budget = engine?.sourceBudget ?? 14_000
        print("Model: \(model?.shortName ?? "none (token counts are characters / 3)")  budget: \(budget) chars")
        let kit = AskModel.kitSummary(library)
        let context = AskContext.build(HouseholdData(privacy: AskPrivacy(personalize: false)), kit: kit, limit: engine?.contextBudget ?? 4_000)

        var rows = questions.map { Row(question: $0) }
        // Two passes: the first is what a person sees on a fresh launch, the second shows caching.
        for pass in 0..<2 {
            for i in rows.indices {
                let start = Date()
                let sources = await retrieve(rows[i].question, archives: archives, budget: budget)
                rows[i].retrievalMs.append(Date().timeIntervalSince(start) * 1000)
                if pass == 0 {
                    rows[i].sources = sources.map { "\($0.ref.title) · \($0.bookTitle)" }
                    let body = sources.map { "[\($0.id)] \($0.ref.title) (\($0.bookTitle))\n\($0.text)" }.joined(separator: "\n\n")
                    rows[i].sourceChars = body.count
                    rows[i].sourceTokens = model.map { LlamaRuntime.shared.tokenCount(file: $0.url, text: body) } ?? body.count / 3
                }
            }
        }

        if ttfw, let engine, let model {
            print("Loading \(model.shortName)…")
            engine.preload(instructions: AskModel.instructions)
            while !engine.isReady { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .milliseconds(500))
            for i in rows.indices {
                let sources = await retrieve(rows[i].question, archives: archives, budget: budget)
                let prompt = AskModel.prompt(question: rows[i].question, sources: sources, context: context)
                rows[i].promptTokens = LlamaRuntime.shared.tokenCount(file: model.url, text: AskModel.instructions + "\n\n" + prompt)
                let start = Date()
                do {
                    for try await text in engine.stream(instructions: AskModel.instructions, prompt: prompt)
                    where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        rows[i].firstWordMs = Date().timeIntervalSince(start) * 1000
                        break
                    }
                } catch {
                    print("  error: \(error.localizedDescription)")
                }
                print(String(format: "  first word %6.0f ms  prompt %5d tokens  %@", rows[i].firstWordMs ?? -1, rows[i].promptTokens, rows[i].question))
            }
        }

        for r in rows {
            print(String(format: "%7.1f ms %7.1f ms  %2d sources %5d chars %5d tokens  %@", r.retrievalMs[0], r.retrievalMs[1],
                         r.sources.count, r.sourceChars, r.sourceTokens, r.question))
            for s in r.sources { print("      \(s)") }
        }
        func stats(_ v: [Double]) -> String {
            let s = v.sorted()
            guard !s.isEmpty else { return "-" }
            let median = s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
            let p90 = s[min(s.count - 1, Int((Double(s.count) * 0.9).rounded(.up)) - 1)]
            return String(format: "median %.1f  p90 %.1f", median, p90)
        }
        print("\nRetrieval, first pass (ms): \(stats(rows.map { $0.retrievalMs[0] }))")
        print("Retrieval, second pass (ms): \(stats(rows.map { $0.retrievalMs[1] }))")
        print("Source tokens: \(stats(rows.map { Double($0.sourceTokens) }))")
        if ttfw {
            print("Prompt tokens: \(stats(rows.map { Double($0.promptTokens) }))")
            print("First word (ms): \(stats(rows.compactMap(\.firstWordMs)))")
        }
        if let out {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(rows).write(to: URL(fileURLWithPath: out))
        }
    }

    /// Checks that saving the instructions' state doesn't change answers: the same prompts answered with greedy
    /// sampling the old way (whole prompt at once), with the state just saved, and with it restored.
    /// usage: OFFLINEKIT_GREEDY=1 okit --prefix-check <questions.txt>
    static func prefixCheck(questionsFile: String) async {
        let questions = ((try? String(contentsOfFile: questionsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let library = Library()
        await library.reload()
        await prepare(library: library)
        guard let model = LocalModels.selected(libraryFolders: library.folders, id: "") else { print("No model"); return }
        let engine = LlamaEngine(model: model)
        let tokens: Int32 = { if case .ready(let t) = model.plan { return t }; return 4096 }()
        var same = 0
        for question in questions.prefix(5) {
            let sources = await retrieve(question, archives: library.books.map(\.archive), budget: engine.sourceBudget)
            let prompt = AskModel.prompt(question: question, sources: sources)
            func answer() -> (String, Double) {
                var text = ""
                let start = Date()
                try? LlamaRuntime.shared.generate(file: model.url, contextTokens: tokens, custom: model.isCustom,
                                                  system: AskModel.instructions, user: prompt, maxTokens: 160,
                                                  isCancelled: { false }) { text = $0 }
                return (text, Date().timeIntervalSince(start))
            }
            LlamaRuntime.reusesInstructions = false
            let (old, oldTime) = answer()
            LlamaRuntime.reusesInstructions = true
            LlamaRuntime.shared.forgetInstructions()
            let (cold, coldTime) = answer()
            let (warm, warmTime) = answer()
            let ok = old == cold && cold == warm
            if ok { same += 1 }
            print(String(format: "%@  whole %.2fs, saving %.2fs, restored %.2fs (%d of %d prompt tokens reused)  %@", ok ? "SAME" : "DIFFERENT",
                         oldTime, coldTime, warmTime, LlamaRuntime.lastPrefill.reused, LlamaRuntime.lastPrefill.total, question))
            if !ok {
                print("  whole:    \(old.prefix(300))\n  saving:   \(cold.prefix(300))\n  restored: \(warm.prefix(300))")
            }
        }
        print("\(same) of \(min(5, questions.count)) answers identical")
        // The emergency instructions start with the usual ones, so they reuse the same saved state.
        try? LlamaRuntime.shared.generate(file: model.url, contextTokens: tokens, custom: model.isCustom,
                                          system: AskModel.instructions + AskModel.emergencyInstructions,
                                          user: "Question: my child swallowed bleach", maxTokens: 8, isCancelled: { false }) { _ in }
        print("Emergency instructions: \(LlamaRuntime.lastPrefill.reused) of \(LlamaRuntime.lastPrefill.total) prompt tokens reused")
    }

    /// Checks that a follow-up's answer doesn't depend on whether the conversation's state was prepared: each
    /// conversation's second question answered with greedy sampling after only the instructions were saved, and
    /// after the conversation so far was prepared and restored.
    /// usage: OFFLINEKIT_GREEDY=1 okit --followup-check <conversations.txt>   (okit --ask-bench's format)
    static func followUpCheck(file: String) async {
        let conversations = AskQuality.conversations(file: file).map { $0.map(\.text) }.filter { $0.count >= 2 }
        let library = Library()
        await library.reload()
        await prepare(library: library)
        guard let model = LocalModels.selected(libraryFolders: library.folders, id: "") else { print("No model"); return }
        let engine = LlamaEngine(model: model)
        let tokens: Int32 = { if case .ready(let t) = model.plan { return t }; return 4096 }()
        let archives = library.books.map(\.archive)
        let context = AskContext.build(HouseholdData(privacy: AskPrivacy(personalize: false)), kit: AskModel.kitSummary(library),
                                       limit: engine.contextBudget)
        func answer(_ prompt: String, head: String?) -> (String, Double) {
            var out = ""
            let start = Date()
            try? LlamaRuntime.shared.generate(file: model.url, contextTokens: tokens, custom: model.isCustom, system: AskModel.instructions,
                                              user: prompt, head: head, maxTokens: 160, isCancelled: { false }) { out = $0 }
            return (out, Date().timeIntervalSince(start))
        }
        var same = 0
        for turns in conversations {
            let first = AskModel.prompt(question: turns[0], sources: await retrieve(turns[0], archives: archives, budget: engine.sourceBudget),
                                        context: context)
            let (reply, _) = answer(first, head: AskModel.promptHead(context: context, history: ""))
            let history = "Q: \(turns[0])\nA: \(AskModel.withoutCitations(String(reply.prefix(1_500))))"
            let head = AskModel.promptHead(context: context, history: history)
            let second = head + AskModel.promptQuestion(question: turns[1],
                                                        sources: await retrieve(turns[1], archives: archives, budget: engine.sourceBudget))
            LlamaRuntime.shared.forgetInstructions()
            _ = answer(first, head: nil)                        // instructions saved again, nothing else
            let (plain, plainTime) = answer(second, head: nil)
            let plainReused = LlamaRuntime.lastPrefill.reused
            LlamaRuntime.shared.prepareConversation(file: model.url, contextTokens: tokens, custom: model.isCustom,
                                                    system: AskModel.instructions, head: head)
            let (prepared, preparedTime) = answer(second, head: head)
            let ok = plain == prepared
            if ok { same += 1 }
            print(String(format: "%@  instructions only %.2fs (%d tokens reused), conversation prepared %.2fs (%d of %d reused)  %@ → %@",
                         ok ? "SAME" : "DIFFERENT", plainTime, plainReused, preparedTime, LlamaRuntime.lastPrefill.reused,
                         LlamaRuntime.lastPrefill.total, turns[0], turns[1]))
            if !ok { print("  instructions only: \(plain.prefix(300))\n  prepared:          \(prepared.prefix(300))") }
        }
        print("\(same) of \(conversations.count) follow-up answers identical")
    }

    /// Anything the library needs before a fair measurement (PDF text, answer index).
    static func prepare(library: Library) async {
        try? await Task.sleep(for: .milliseconds(200))
        while PDFIndex.shared.isBuilding { try? await Task.sleep(for: .milliseconds(200)) }
        // Without OFFLINEKIT_NO_INDEX, build (or open) the answer index first and report what it took.
        guard ProcessInfo.processInfo.environment["OFFLINEKIT_NO_INDEX"] == nil else { print("Answer index: off"); return }
        let start = Date()
        AnswerIndex.shared.load(library.books.map(\.archive))
        while true {
            let snapshot = AnswerIndex.shared.snapshot()
            if snapshot.rows.allSatisfy({ if case .building = $0.state { false } else if case .waiting = $0.state { false } else { true } }) {
                for row in snapshot.rows {
                    print(String(format: "Answer index: %@ (%d articles, %@): %@, %.1f MB, built in %.1fs", row.title, row.articles,
                                 row.depth.rawValue, "\(row.state)", Double(row.bytes) / 1e6, row.seconds))
                }
                print(String(format: "Answer index ready after %.1fs", Date().timeIntervalSince(start)))
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    /// The same passes Ask makes: medical references first for health questions, then everything.
    static func retrieve(_ question: String, archives: [ZimArchive], budget: Int) async -> [Source] {
        let medical = AskModel.isHealthQuestion(question) ? archives.filter { AskModel.isMedical($0.name) } : []
        var sources: [Source] = []
        var searched: [String: Retriever.Gathered] = [:]
        if !medical.isEmpty {
            let result = await Retriever.retrieveConcurrently(question: question, archives: medical, budgetChars: budget)
            sources = result.sources
            searched = result.gathered
        }
        if Retriever.strength(sources, question: question) == 0 {
            sources = await Retriever.retrieveConcurrently(question: question, archives: archives, budgetChars: budget,
                                                           reusing: searched).sources
        }
        return sources
    }
}
