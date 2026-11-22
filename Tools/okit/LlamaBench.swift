import Darwin
import Foundation

/// Model runtime benchmark: prompt and generation speed, time to the first word and peak memory for the current
/// llama.cpp settings (LlamaTuning; DEBUG builds take OFFLINEKIT_LLAMA overrides). One configuration per run, so
/// peak memory is this configuration's own. Run with OFFLINEKIT_GREEDY=1 so answers can be compared across runs.
/// usage: OFFLINEKIT_GREEDY=1 okit --llama-bench <questions.txt> [--tokens 128] [--out results.json]
@MainActor
enum LlamaBench {
    struct Row: Codable {
        let question: String
        var promptTokens = 0
        var wholePrefillMs = 0.0      // the whole prompt, nothing reused
        var reusedTokens = 0
        var restoreMs = 0.0
        var prefillMs = 0.0           // with the instructions restored
        var firstTextMs = 0.0
        var tokens = 0
        var generateMs = 0.0
        var sampleMs = 0.0
        var gpuWaitMs = 0.0
        var answer = ""
    }

    struct Result: Codable {
        let tuning: String
        let loadSeconds: Double
        let peakFootprintMB: Double
        let rows: [Row]
    }

    static func run(questionsFile: String, maxTokens: Int, out: String?) async {
        let questions = ((try? String(contentsOfFile: questionsFile, encoding: .utf8)) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        let library = Library()
        await library.reload()
        await Bench.prepare(library: library)
        guard let model = LocalModels.selected(libraryFolders: library.folders, id: "") else { print("No model"); return }
        let engine = LlamaEngine(model: model)
        let contextTokens: Int32 = { if case .ready(let t) = model.plan { return t }; return 4096 }()
        print("Model: \(model.shortName), context \(contextTokens)\nSettings: \(LlamaTuning.current)")
        let kit = AskModel.kitSummary(library)
        let context = AskContext.build(HouseholdData(privacy: AskPrivacy(personalize: false)), kit: kit, limit: engine.contextBudget)
        var prompts: [String] = []
        for q in questions {
            let sources = await Bench.retrieve(q, archives: library.books.map(\.archive), budget: engine.sourceBudget)
            prompts.append(AskModel.prompt(question: q, sources: sources, context: context))
        }

        func generate(_ prompt: String, tokens: Int) -> String {
            var text = ""
            do {
                try LlamaRuntime.shared.generate(file: model.url, contextTokens: contextTokens, custom: model.isCustom,
                                                 system: AskModel.instructions, user: prompt, maxTokens: tokens,
                                                 isCancelled: { false }) { text = $0 }
            } catch { print("  error: \(error.localizedDescription)") }
            return text
        }

        LlamaRuntime.measuresTimings = true
        // Load, and evaluate and save the instructions, the way the app's preload does.
        let loadStart = Date()
        _ = generate(prompts[0], tokens: 1)
        let loadSeconds = Date().timeIntervalSince(loadStart)
        print(String(format: "Loaded in %.1fs", loadSeconds))

        var rows: [Row] = []
        for (q, prompt) in zip(questions, prompts) {
            var row = Row(question: q)
            // Prompt speed: the whole prompt, nothing reused.
            LlamaRuntime.reusesInstructions = false
            _ = generate(prompt, tokens: 1)
            row.promptTokens = LlamaRuntime.lastPrefill.total
            row.wholePrefillMs = LlamaRuntime.lastTimings.prefillMs
            LlamaRuntime.reusesInstructions = true
            // What a question costs: instructions restored, then the answer.
            row.answer = generate(prompt, tokens: maxTokens)
            let t = LlamaRuntime.lastTimings
            row.reusedTokens = LlamaRuntime.lastPrefill.reused
            row.restoreMs = t.restoreMs
            row.prefillMs = t.prefillMs
            row.firstTextMs = t.firstTextMs
            row.tokens = t.tokens
            row.generateMs = t.generateMs
            row.sampleMs = t.sampleMs
            row.gpuWaitMs = t.gpuWaitMs
            print(String(format: "  prompt %4d tok whole %6.0f ms (%4.0f tok/s) | restore %4.1f ms, rest %4d tok %5.0f ms, first word %5.0f ms | %3d tok %5.1f tok/s (GPU %.2f, sampling %.2f ms/tok)  %@",
                         row.promptTokens, row.wholePrefillMs, Double(row.promptTokens) / row.wholePrefillMs * 1000,
                         row.restoreMs, row.promptTokens - row.reusedTokens, row.prefillMs, row.firstTextMs,
                         row.tokens, Double(max(row.tokens - 1, 0)) / max(row.generateMs, 1) * 1000,
                         row.gpuWaitMs / Double(max(row.tokens, 1)), row.sampleMs / Double(max(row.tokens, 1)), q))
            rows.append(row)
        }
        let peak = peakFootprintMB()
        func median(_ v: [Double]) -> Double { let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        print(String(format: "\nSettings: %@\nprompt %.0f tok/s | after restore: prompt %.0f ms, first word %.0f ms | generation %.1f tok/s | sampling %.2f ms/tok | restore %.1f ms | load %.1fs | peak footprint %.0f MB",
                     "\(LlamaTuning.current)",
                     median(rows.map { Double($0.promptTokens) / $0.wholePrefillMs * 1000 }),
                     median(rows.map(\.prefillMs)),
                     median(rows.map(\.firstTextMs)),
                     median(rows.map { Double(max($0.tokens - 1, 0)) / max($0.generateMs, 1) * 1000 }),
                     median(rows.map { $0.sampleMs / Double(max($0.tokens, 1)) }),
                     median(rows.map(\.restoreMs)), loadSeconds, peak))
        if let out {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(Result(tuning: "\(LlamaTuning.current)", loadSeconds: loadSeconds, peakFootprintMB: peak, rows: rows))
                .write(to: URL(fileURLWithPath: out))
        }
    }

    /// The most memory this process has used (its footprint: what macOS counts against it, GPU buffers included).
    static func peakFootprintMB() -> Double {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0) }
        }
        return status == 0 ? Double(info.ri_lifetime_max_phys_footprint) / 1_048_576 : -1
    }
}
