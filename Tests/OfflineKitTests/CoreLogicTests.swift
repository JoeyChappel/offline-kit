import Foundation
import Testing

@Suite("ContentFormat")
struct ContentFormatTests {
    @Test("Archives are classified by catalog name", arguments: [
        ("gutenberg_en_lcc-pz", ContentFormat.books), ("wikibooks_en_all", .books), ("wikisource_en_all", .books),
        ("ted_mul_ted-ed", .video), ("khanacademy_en_all", .video), ("voa_learning_english", .video),
        ("librivox_audiobooks", .audio), ("maps_en_north-america", .maps), ("phet_en_all", .interactive),
        ("wikipedia_en_all_maxi", .reference), ("Gutenberg_EN", .books),
    ])
    func classify(_ name: String, _ expected: ContentFormat) {
        #expect(ContentFormat(archiveName: name) == expected)
    }
}

@Suite("Retriever text helpers")
struct RetrieverTextTests {
    @Test("Terms: lowercased, stopwords and single letters out, each once")
    func terms() {
        #expect(Retriever.terms("How do I treat a BURN on my hand? burn") == ["treat", "burn", "hand"])
        #expect(Retriever.terms("what is the best way") == [])
        #expect(Retriever.terms("CPR for a 2-year-old") == ["cpr", "year", "old"])
    }

    @Test("Phrases are adjacent pairs")
    func phrases() {
        #expect(Retriever.phrases(["heat", "stroke", "child"]) == ["heat stroke", "stroke child"])
        #expect(Retriever.phrases(["one"]) == [])
    }

    @Test("Query variants: strict, then the three longest words, then the longest")
    func variants() {
        #expect(Retriever.queryVariants(["signs", "heat", "stroke", "child"]) == ["signs heat stroke child", "stroke signs child", "stroke"])
        #expect(Retriever.queryVariants(["burn"]) == ["burn"])
    }

    @Test("Stack Exchange listings are recognised")
    func listings() {
        #expect(Retriever.isListing(path: "questions/tagged/electrical", title: "x"))
        #expect(Retriever.isListing(path: "a", title: "Highest voted questions"))
        #expect(!Retriever.isListing(path: "questions/123/how-to-reset-gfci", title: "How to reset a GFCI?"))
    }

    @Test("Relevance favors title matches and exact phrases")
    func relevance() {
        let terms = ["heat", "stroke"], phrases = ["heat stroke"]
        let title = Retriever.plainRelevance(title: "heat stroke", text: "", xapian: 0, terms: terms, phrases: phrases)
        let body = Retriever.plainRelevance(title: "first aid", text: "signs of heat stroke", xapian: 0, terms: terms, phrases: phrases)
        let none = Retriever.plainRelevance(title: "burns", text: "cool water", xapian: 0, terms: terms, phrases: phrases)
        #expect(title.0 > body.0 && body.0 > none.0)
        #expect(title.1 == 1 && body.1 == 1 && none.1 == 0)
    }
}

@Suite("SpokenAnswer")
struct SpokenAnswerTests {
    @Test("Citations, markdown and links are removed; emergency numbers are spelled out")
    func clean() {
        #expect(SpokenAnswer.clean("Cool the burn [1] under water [2, 3].") == "Cool the burn under water.")
        #expect(SpokenAnswer.clean("## Steps\n1. **Call** 911\n2. Cool it") == "Steps\nStep 1. Call 9 1 1\nStep 2. Cool it")
        #expect(SpokenAnswer.clean("See [the guide](https://example.com/x) or www.example.com now") == "See the guide or now")
        #expect(SpokenAnswer.clean("- a *bullet* point\n- and `code`") == "a bullet point\nand code")
        #expect(SpokenAnswer.clean("Not from the library: rest").hasPrefix("The next part is not from your library."))
        #expect(SpokenAnswer.clean("Call 988 [3") == "Call 9 8 8")
    }

    @Test("Speakable text ends at a finished sentence, not at abbreviations or step numbers")
    func speakableEnd() {
        func head(_ s: String) -> String { String(s[..<SpokenAnswer.speakableEnd(in: s)]) }
        #expect(head("First sentence. Second is still stream") == "First sentence.")
        #expect(head("Ask Dr. Smith about it") == "")
        #expect(head("Use e.g. ice. Then") == "Use e.g. ice.")
        #expect(head("1. Call for help") == "")
        #expect(head("Line one\nline two") == "Line one\n")
        #expect(head("No end yet") == "")
    }

    @Test("A streamed answer is handed out sentence by sentence, and a restart is noticed")
    func stream() {
        var stream = SpokenAnswerStream()
        #expect(stream.next(answer: "Cool the burn.", final: false).text == "")
        let first = stream.next(answer: "Cool the burn. Cover it", final: false)
        #expect(first.text == "Cool the burn." && !first.restarted)
        let rest = stream.next(answer: "Cool the burn. Cover it loosely.", final: true)
        #expect(rest.text == "Cover it loosely.")
        let restarted = stream.next(answer: "Different answer. More", final: false)
        #expect(restarted.restarted && restarted.text == "Different answer.")
    }
}

@Suite("ScanGate")
@MainActor
struct ScanGateTests {
    @Test("Requests during a scan share one more scan that starts after them")
    func coalesces() async {
        let gate = ScanGate()
        var runs = 0
        let scan: @MainActor () async -> Void = {
            runs += 1
            try? await Task.sleep(for: .milliseconds(40))
        }
        let first = Task { await gate.run(scan) }
        _ = await eventually { gate.isRunning }
        let second = Task { await gate.run(scan) }
        let third = Task { await gate.run(scan) }
        await first.value
        await second.value
        await third.value
        #expect(runs == 2)
        #expect(!gate.isRunning)
    }

    @Test("runAgain adds one pass while running and does nothing when idle")
    func runAgain() async {
        let gate = ScanGate()
        var runs = 0
        gate.runAgain()
        await gate.run {
            runs += 1
            if runs == 1 { gate.runAgain(); gate.runAgain() }
        }
        #expect(runs == 2)
        await gate.run { runs += 1 }
        #expect(runs == 3)
    }
}
