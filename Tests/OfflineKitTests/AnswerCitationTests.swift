import Foundation
import Testing

private func source(_ id: Int, _ title: String, _ text: String) -> Source {
    Source(id: id, ref: ArticleRef(bookID: "b", path: title, title: title), bookTitle: "Book", text: text)
}

/// Passages shaped like a burn question's sources: MDWiki's article, a forum thread about boiling water at altitude.
private let burnSources = [
    source(1, "Thermal burn", "Cool the burn with cool running water for 20 minutes as soon as possible. Do not put ice, butter or "
           + "toothpaste on a burn. Remove rings, watches and tight clothing before the area swells. Cover the burn loosely with "
           + "cling film or a clean, non-fluffy dressing."),
    source(2, "Can you get burned by boiling water on everest?", "Water boils at about 70 degrees Celsius on the summit of Everest "
           + "because the air pressure is so low. Climbers still scald themselves on it, but more slowly than at sea level."),
]

@Suite("Citation check")
struct CitationCheckTests {
    @Test("A citation the passage supports stays, word for word")
    func supportedStays() {
        let answer = "1. Cool the burn under cool running water for 20 minutes [1].\n2. Cover it loosely with cling film [1]."
        let checked = CitationChecker(sources: burnSources).apply(answer, final: true)
        #expect(checked.text == answer)
        #expect(checked.report.checked == 2 && checked.report.supported == 2 && checked.report.changes.isEmpty)
        #expect(checked.report.supportedBefore == 1 && checked.report.supportedAfter == 1)
    }

    @Test("A citation of the wrong source moves to the one that clearly supports the sentence")
    func repointed() {
        let answer = "Remove rings, watches and tight clothing before the area swells [2]."
        let checked = CitationChecker(sources: burnSources).apply(answer, final: true)
        #expect(checked.text == "Remove rings, watches and tight clothing before the area swells [1].")
        #expect(checked.report.repointed == 1 && checked.report.supported == 0)
        #expect(checked.report.changes == [CitationChecker.Change(sentence: "Remove rings, watches and tight clothing before the area swells",
                                                                  from: [2], to: [1])])
        #expect(checked.report.supportedBefore == 0 && checked.report.supportedAfter == 1)
    }

    @Test("A close paraphrase keeps its citation, word endings aside")
    func paraphraseKept() {
        let sources = [source(1, "Using a thermometer for hypothermia diagnosis in backcountry?",
                              "Warm them, feed them. Hot sweet drinks. Get them into dry clothing. Get them out of the wind."),
                       source(2, "How long is raw chicken good for?", "Vacuum sealed raw chicken breasts in the fridge behave like "
                              + "other chicken breasts. The meat will be safe for 2 days.")]
        let answer = "If they are conscious and able to swallow, give them warm, sweet drinks [1]. "
            + "Vacuum sealing does not change the safety time [2]."
        let checked = CitationChecker(sources: sources).apply(answer, final: true)
        #expect(checked.text == answer)
    }

    @Test("A citation no source supports is dropped, never moved to a guess")
    func dropped() {
        let answer = "Take ibuprofen every six hours for the pain and swelling [1]. Then rest."
        let checked = CitationChecker(sources: burnSources).apply(answer, final: true)
        #expect(checked.text == "Take ibuprofen every six hours for the pain and swelling. Then rest.")
        #expect(checked.report.dropped == 1 && checked.report.repointed == 0)
    }

    @Test("Of several citations, the ones that support the sentence stay")
    func keepsSupportedOfSeveral() {
        let answer = "Do not put ice, butter or toothpaste on a burn [1][2]."
        let checked = CitationChecker(sources: burnSources).apply(answer, final: true)
        #expect(checked.text == "Do not put ice, butter or toothpaste on a burn [1].")
        #expect(checked.report.checked == 2 && checked.report.supported == 1 && checked.report.dropped == 1)
        let grouped = CitationChecker(sources: burnSources).apply("Do not put ice, butter or toothpaste on a burn [1, 2].", final: true)
        #expect(grouped.text == "Do not put ice, butter or toothpaste on a burn [1].")
    }

    @Test("A citation of a source that isn't there is fixed or dropped")
    func invalidNumber() {
        let checked = CitationChecker(sources: burnSources).apply("Cool the burn with cool running water for 20 minutes [7].", final: true)
        #expect(checked.text == "Cool the burn with cool running water for 20 minutes [1].")
    }

    @Test("Short sentences are left alone, and so is a citation still arriving")
    func leftAlone() {
        let checker = CitationChecker(sources: burnSources)
        #expect(checker.apply("Call 911 [2].", final: true).text == "Call 911 [2].")
        #expect(checker.apply("Call 911 [2].", final: true).report.unchecked == 1)
        let streaming = "Take ibuprofen every six hours for the pain and swelling [1]"
        #expect(checker.apply(streaming, final: false).text == streaming, "the next token may be another citation")
        #expect(checker.apply(streaming, final: true).text == "Take ibuprofen every six hours for the pain and swelling")
    }

    @Test("A citation after the full stop, or on its own after another, belongs to the sentence before it")
    func claimBoundaries() {
        let text = "Water boils at 70 degrees on Everest. Cool the burn with running water. [1]"
        let end = text.range(of: " [1]")!.lowerBound
        #expect(CitationChecker.claim(in: text, before: end, from: text.startIndex) == "Cool the burn with running water")
        let list = "Steps:\n1. Cool the burn [1]"
        let listEnd = list.range(of: " [1]")!.lowerBound
        #expect(CitationChecker.claim(in: list, before: listEnd, from: list.startIndex) == "Cool the burn")
        #expect(CitationChecker.numbers(in: " [2][3]") == [2, 3] && CitationChecker.numbers(in: "[1-3]") == [1, 2, 3])
    }

    @Test("An answer's check takes a few milliseconds")
    func fast() {
        let sources = (1...6).map { i in
            source(i, "Article \(i)", String(repeating: "Cool the burn with running water for twenty minutes and cover it loosely. "
                                                      + "Keep the person warm and watch for shock while help comes. ", count: 12))
        }
        let answer = (1...15).map { "Step \($0): cool the burn with running water and keep the person warm [\($0 % 6 + 1)]." }
            .joined(separator: "\n")
        let checker = CitationChecker(sources: sources)
        _ = checker.apply(answer, final: true)
        let fresh = CitationChecker(sources: sources)
        let started = Date()
        let report = fresh.apply(answer, final: true).report
        // A debug build (as tests run) is several times slower than the app.
        #expect(Date().timeIntervalSince(started) < 0.05, "\(report.milliseconds) ms")
        #expect(report.checked == 15)
    }
}

/// An engine that plays back answers in turn, one per prompt, recording the prompts it got.
private final class ScriptedEngine: AnswerEngine, @unchecked Sendable {
    let replies: [String]
    private(set) var prompts: [String] = []
    init(_ replies: [String]) { self.replies = replies }
    var displayName: String { "Scripted" }
    var runsOnDevice: Bool { true }
    var sourceBudget: Int { 14_000 }
    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        prompts.append(prompt)
        let reply = replies[min(prompts.count - 1, replies.count - 1)]
        return AsyncThrowingStream { continuation in
            var text = ""
            for word in reply.split(separator: " ", omittingEmptySubsequences: false) {
                text += (text.isEmpty ? "" : " ") + word
                continuation.yield(text)
            }
            continuation.finish()
        }
    }
}

@Suite("Answering with Ask's guards")
@MainActor
struct AnswerGuardTests {
    private func run(_ engine: ScriptedEngine) async -> (result: (outcome: AskModel.AnswerOutcome, text: String, sources: [Source],
                                                                  citations: CitationChecker.Report?), shown: [String]) {
        var shown: [String] = []
        let result = await AskModel.answer(question: "What should I do for a burn from boiling water?", sources: burnSources,
                                           engine: engine, instructions: AskModel.instructions, context: "", history: "",
                                           keepsConversation: false, show: { shown.append($0); return true },
                                           sourcesChanged: { _ in }, trace: { _ in })
        return (result, shown)
    }

    @Test("An answer that starts by printing the instructions is asked again, plainly")
    func echoRetried() async {
        let engine = ScriptedEngine([String(AskModel.instructions.prefix(300)),
                                     "Cool the burn under cool running water for 20 minutes [1]."])
        let (result, _) = await run(engine)
        #expect(result.outcome == .answered(cutShort: false))
        #expect(result.text == "Cool the burn under cool running water for 20 minutes [1].")
        #expect(engine.prompts.count == 2 && engine.prompts[1].hasSuffix(AskModel.echoNudge))
    }

    @Test("An echo after a real answer cuts it there; the citations are checked")
    func echoCutAndChecked() async {
        let kept = "Remove rings, watches and tight clothing before the area swells [2]. Cover the burn loosely with cling film [1]. "
            + "Do not put ice, butter or toothpaste on it [1]."
        let engine = ScriptedEngine([kept + "\n- Stick to facts. Never guess at doses, wiring, gas or structural safety; say what to check instead."])
        let (result, shown) = await run(engine)
        #expect(result.outcome == .answered(cutShort: false))
        #expect(result.text == "Remove rings, watches and tight clothing before the area swells [1]. Cover the burn loosely with cling film [1]. "
                + "Do not put ice, butter or toothpaste on it [1].")
        #expect(shown.last == result.text)
        #expect(result.citations?.repointed == 1)
        #expect(engine.prompts.count == 1)
    }

    @Test("A model that writes nothing is reported as empty")
    func empty() async {
        let (result, _) = await run(ScriptedEngine(["   "]))
        #expect(result.outcome == .empty)
    }

    @Test("Ask over Wi-Fi answers through the same guards")
    func wifiShares() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let share = try String(contentsOf: root.appending(path: "Sources/Mac/ShareController.swift"), encoding: .utf8)
        #expect(share.contains("AskModel.answer(") && share.contains("AskModel.findSources("))
        #expect(!share.contains("engine.stream("), "no answer loop of its own")
    }
}
