import Foundation
import Testing

/// An answer engine that answers nothing, with the budgets a test needs.
private struct StubEngine: AnswerEngine {
    var sourceBudget: Int
    var promptBudget: Int
    var name = "Stub"
    var displayName: String { name }
    var runsOnDevice: Bool { true }
    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

@Suite("Ask prompts keep the same beginning across a conversation")
@MainActor
struct AskPromptTests {
    private func done(_ question: String, _ answer: String) -> Turn {
        var turn = Turn(question: question)
        turn.answer = answer
        turn.status = .done
        return turn
    }

    @Test("A prompt is its head (context and history) followed by the question and sources")
    func headIsPrefix() {
        let source = Source(id: 1, ref: ArticleRef(bookID: "b", path: "Burns", title: "Burns"), bookTitle: "Medicine", text: "Cool it.")
        let head = AskModel.promptHead(context: "Home: cabin", history: "Q: a\nA: b")
        let prompt = AskModel.prompt(question: "And then?", sources: [source], context: "Home: cabin", history: "Q: a\nA: b")
        #expect(prompt == head + AskModel.promptQuestion(question: "And then?", sources: [source]))
        #expect(prompt.hasPrefix(head))
        #expect(head.hasSuffix("\n\n"))
        #expect(AskModel.promptHead(context: "", history: "").isEmpty)
        // The next question's head starts with this one's, less its closing blank line.
        let next = AskModel.promptHead(context: "Home: cabin", history: "Q: a\nA: b\nQ: c\nA: d")
        #expect(next.hasPrefix(String(head.dropLast(2))))
    }

    @Test("Earlier answers lose their citation marks")
    func citations() {
        #expect(AskModel.withoutCitations("Cool the burn [1]. Cover it [2][3], then rest [2, 4].") == "Cool the burn. Cover it, then rest.")
        #expect(AskModel.withoutCitations("Steps 1-3 [1-2] apply; [x] stays.") == "Steps 1-3 apply; [x] stays.")
        #expect(AskModel.withoutCitations("No marks here.") == "No marks here.")
    }

    @Test("Big models drop the oldest turns a few at a time, so the history keeps its beginning")
    func historyKeepsItsStart() {
        let model = AskModel()
        let engine = StubEngine(sourceBudget: 14_000, promptBudget: 18_000)
        var histories: [String] = []
        for i in 1...12 {
            model.turns.append(done("Question \(i)?", "Answer \(i) [1]."))
            histories.append(model.conversationSoFar(engine: engine, context: ""))
        }
        #expect(histories[0] == "Q: Question 1?\nA: Answer 1.")
        #expect(histories[5].hasPrefix("Q: Question 1?"), "six turns fit")
        // The seventh turn is one too many: down to four, starting at turn 4.
        #expect(histories[6].hasPrefix("Q: Question 4?") && histories[6].hasSuffix("Answer 7."))
        // Then the same beginning for the next turns, each history extending the last.
        for i in 7..<9 { #expect(histories[i].hasPrefix(histories[i - 1] + "\n")) }
        #expect(histories[9].hasPrefix("Q: Question 7?"))
        #expect(histories.allSatisfy { $0.components(separatedBy: "Q: ").count - 1 <= 6 })
    }

    @Test("History stays within half of what's left after the household context")
    func historyLimit() {
        let model = AskModel()
        let engine = StubEngine(sourceBudget: 14_000, promptBudget: 12_000)
        let long = String(repeating: "word ", count: 290)   // 1,450 characters
        for i in 1...6 { model.turns.append(done("Question \(i)?", long)) }
        let history = model.conversationSoFar(engine: engine, context: String(repeating: "c", count: 2_000))
        #expect(history.count <= 5_000)
        #expect(history.hasSuffix(long.prefix(1_500).description))
        #expect(!history.contains("Question 1?"))
    }

    @Test("Each engine trims the history for its own room: a smaller model's trim doesn't shorten a larger one's")
    func historyPerEngine() {
        let model = AskModel()
        let small = StubEngine(sourceBudget: 14_000, promptBudget: 4_000, name: "Built-in")
        let large = StubEngine(sourceBudget: 14_000, promptBudget: 30_000, name: "Ollama")
        let long = String(repeating: "word ", count: 290)
        for i in 1...3 { model.turns.append(done("Question \(i)?", long)) }
        let trimmed = model.conversationSoFar(engine: small, context: "")
        #expect(!trimmed.contains("Question 1?"), "the small model's room holds one turn")
        let full = model.conversationSoFar(engine: large, context: "")
        #expect(full.hasPrefix("Q: Question 1?"), "the large model still gets all three")
        #expect(model.conversationSoFar(engine: small, context: "") == trimmed)
    }

    @Test("New Conversation counts for the built-in model whichever engine answered, without starting it")
    func newConversationCounts() {
        let before = LlamaRuntime.conversationCount
        let existed = LlamaRuntime.exists
        let model = AskModel()
        model.turns.append(done("Kept?", "Yes."))
        model.clear()
        #expect(LlamaRuntime.conversationCount > before, "a conversation being prepared sees the count move and stops")
        #expect(LlamaRuntime.exists == existed, "counting never creates the runtime")
    }

    @Test("Small models keep the last two turns, short")
    func smallModels() {
        let model = AskModel()
        let engine = StubEngine(sourceBudget: 5_000, promptBudget: 40_000)
        for i in 1...4 { model.turns.append(done("Question \(i)?", String(repeating: "a", count: 300))) }
        let history = model.conversationSoFar(engine: engine, context: "")
        #expect(history.hasPrefix("Q: Question 3?"))
        #expect(history.contains("Q: Question 4?"))
        #expect(history.count <= engine.contextBudget / 2)
    }

    @Test("Turns that failed, were stopped or have no answer stay out of the history")
    func onlyAnswered() {
        let model = AskModel()
        let engine = StubEngine(sourceBudget: 14_000, promptBudget: 18_000)
        model.turns.append(done("Kept?", "Yes."))
        var failed = Turn(question: "Failed?")
        failed.status = .failed
        model.turns.append(failed)
        model.turns.append(done("Empty?", ""))
        #expect(model.conversationSoFar(engine: engine, context: "") == "Q: Kept?\nA: Yes.")
    }
}

@Suite("Search speedups")
struct SearchSpeedTests {
    @Test("A hit the caller already has comes back without its snippet; others keep theirs")
    func snippetsExcept() throws {
        let zim = try ZimArchive(path: try TestSupport.fixture("tiny-indexed.zim").path)
        try #require(zim.hasFullTextIndex)
        let all = zim.search("water", limit: 10)
        try #require(!all.isEmpty)
        let known: Set<String> = [all[0].path]
        let some = zim.search("water", limit: 10, snippetsExcept: known)
        #expect(some.map(\.path) == all.map(\.path), "same hits, same order")
        #expect(some[0].snippet.isEmpty)
        for (a, b) in zip(all.dropFirst(), some.dropFirst()) { #expect(a.snippet == b.snippet) }
    }

    @Test("Each archive's kept searchers give the same results, from many threads at once")
    func searchersAreReused() async throws {
        let zim = try ZimArchive(path: try TestSupport.fixture("tiny-indexed.zim").path)
        let expected = zim.search("heat stroke", limit: 5).map(\.path)
        let titles = zim.suggest("Burn", limit: 3).map(\.path)
        try #require(!expected.isEmpty && !titles.isEmpty)
        let results = await withTaskGroup(of: ([String], [String]).self) { group in
            for _ in 0..<16 {
                group.addTask { (zim.search("heat stroke", limit: 5).map(\.path), zim.suggest("Burn", limit: 3).map(\.path)) }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        #expect(results.allSatisfy { $0.0 == expected && $0.1 == titles })
    }

    @Test("Once lets only the first caller through")
    func once() {
        let once = Once()
        #expect(once.claim())
        #expect(!once.claim())
    }
}
