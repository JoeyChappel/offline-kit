import Foundation
import Testing

// MARK: - HTML to text

/// Sample articles shaped like Wikipedia, WikiMed, iFixit and Stack Exchange pages.
enum SampleHTML {
    static let sentence = "Heat stroke is a medical emergency in which the body temperature rises above forty degrees and the body's cooling fails."
    static let sentence2 = "Move the person into shade, remove extra clothing and cool them with cold water, ice packs and a fan at once."

    static let all: [(name: String, html: String)] = [
        ("wikipedia", """
        <html><head><title>Heat stroke</title><style>.x{color:red}</style><script>var a = "<p>not text</p>";</script></head>
        <body><nav><a href="/">Home</a> | <a href="/r">Random</a></nav><h1>Heat stroke</h1>
        <p><b>Heat stroke</b> is a medical emergency in which the body temperature rises above 40&nbsp;&deg;C and the body&#39;s cooling fails.<sup class="reference">[1]</sup><sup>[2]</sup></p>
        <table class="infobox"><tr><td>Specialty</td><td><table><tr><td>Emergency medicine</td></tr></table></td></tr></table>
        <p>Older adults &amp; young children are at higher risk,[3] especially during long heat waves in cities without air conditioning.[citation needed]</p>
        <h2><span class="mw-headline" id="Treatment">Treatment</span><span class="mw-editsection">[edit]</span></h2>
        <p>\(sentence2) Keep cooling until the temperature falls to about 39&#x2009;&#176;C or help arrives.</p>
        <ul><li>Call emergency services first, then start cooling the person straight away without waiting for them.</li>
        <li>Do not give fever medicines such as acetaminophen or aspirin, because they do not help with heat stroke.</li></ul>
        <h2>References</h2><ol><li>A reference that is long enough to count as a paragraph of text in the index, page 12.</li></ol>
        <footer>Text is available under the Creative Commons Attribution-ShareAlike License; additional terms may apply.</footer>
        </body></html>
        """),
        ("uppercase and attributes", """
        <HTML><BODY><DIV CLASS="lead"><P ID="a">\(sentence)<BR/>\(sentence2)</P></DIV>
        <H3 class="section">Prevention</H3><P>Drink water regularly in hot weather before you feel thirsty, and rest in the shade often.</P>
        <BLOCKQUOTE>Schedule heavy work for the early morning or the evening, never for the hottest part of the day.</BLOCKQUOTE>
        <FIGURE><IMG SRC="x.jpg"><FIGCAPTION>A caption long enough to be a paragraph if figures were not dropped from the text.</FIGCAPTION></FIGURE>
        </BODY></HTML>
        """),
        ("stack exchange", """
        <div class="question"><h1>How do I reset a tripped GFCI outlet?</h1>
        <div class="post-text"><p>My bathroom outlet stopped working after I used a hair dryer. The little button on it won&apos;t stay in when I press it.</p></div>
        <div class="answer"><h2>Answer</h2><p>Unplug everything on the circuit first, then press <code>RESET</code> firmly until it clicks &mdash; if it trips again at once, an appliance is faulty.</p>
        <p>If it still won&quot;t reset, check the other GFCI outlets in the house: one of them may protect this outlet &ndash; it&#8217;s common in older homes.</p>
        <dl><dt>Tip</dt><dd>Test each GFCI monthly by pressing TEST, which should cut the power, and then RESET to bring it back.</dd></dl></div></div>
        """),
        ("ifixit", """
        <section><h2>Step 1: Remove the battery</h2><div class="step"><p>Power off the device and unplug the charger. Use a plastic opening tool to release the battery connector 5&times;.</p></div></section>
        <section><h2>Step 2</h2><div class="step"><p>Lift the battery out slowly using the pull tab; never pry it with metal tools, which can puncture it and start a fire.</p></div></section>
        """),
        ("short lines and spaces", """
        <p>Too short.</p><p>   Lots    of\tspaces   and&nbsp;&nbsp;no-break spaces   inside a paragraph that is long enough to keep around.   </p>
        <p>Numbers like [12] and [edit] marks vanish, but [notes] and [a1] in square brackets stay where they are in this sentence.</p>
        <h4>   </h4><p>A paragraph after an empty heading keeps the heading from before it, which is the lead heading here.</p>
        """),
    ]
}

@Suite("HTML to text")
struct HTMLTextTests {
    @Test("The byte scanner gives the same sections as the old regular expressions", arguments: SampleHTML.all.map(\.name))
    func matchesLegacy(_ name: String) {
        let html = SampleHTML.all.first { $0.name == name }!.html
        let new = HTMLText.sections(html)
        let old = LegacyHTMLText.sections(html)
        #expect(new.count == old.count)
        for (n, o) in zip(new, old) {
            #expect(n.heading == o.heading)
            #expect(n.text == o.text)
        }
        #expect(HTMLText.paragraphs(html) == LegacyHTMLText.paragraphs(html))
    }

    @Test("The lead ends where the old string search ended it", arguments: SampleHTML.all.map(\.name) + ["no sections", "heading first"])
    func leadMatchesLegacy(_ name: String) {
        let html: String = switch name {
        case "no sections": "<p>Just a lead with no sections at all.</p>"
        case "heading first": "<H2>Intro</H2><p>A paragraph</p><h2>Second</h2><p>more</p>"
        default: SampleHTML.all.first { $0.name == name }!.html
        }
        let bytes = Array(html.utf8)
        let end = bytes.withUnsafeBufferPointer { PassageStore.leadEnd($0) }
        #expect(String(decoding: bytes[..<end], as: UTF8.self) == LegacyHTMLText.leadHTML(html))
    }

    @Test("Scripts, styles, navigation, tables, footnotes and references are left out")
    func dropsNoise() {
        let sections = HTMLText.sections(SampleHTML.all[0].html)
        let text = sections.map(\.text).joined(separator: "\n")
        #expect(!text.contains("not text"))
        #expect(!text.contains("color:red"))
        #expect(!text.contains("Random"))
        #expect(!text.contains("Emergency medicine"))
        #expect(!text.contains("[1]") && !text.contains("[3]") && !text.contains("citation needed"))
        #expect(!text.contains("Creative Commons"))
        #expect(text.contains("40 °C and the body's cooling fails."))
        #expect(text.contains("Older adults & young children"))
        #expect(sections.first?.heading == nil, "the lead has no heading")
        #expect(sections.contains { $0.heading == "Treatment" }, "the [edit] link is cleaned out of the heading")
    }

    @Test("A stray < is handled the way the old expressions handled it")
    func strayLessThan() {
        // Archive HTML escapes "<" as &lt;, so this is rare. The old expressions turned <p> and </p> into line breaks
        // first and kept the stray "<" as text; the scanner reads a tag up to the next ">" (the one closing </p>).
        let html = "<p>Children under 5 years and adults over 65 are at risk when it is hot; keep the room temperature < 26 degrees if you can.</p><p>\(SampleHTML.sentence)</p>"
        withKnownIssue("HTMLText drops the text after an unescaped \"<\" up to the next \">\"; LegacyHTMLText kept it") {
            #expect(HTMLText.paragraphs(html) == LegacyHTMLText.paragraphs(html))
        }
        #expect(HTMLText.paragraphs(html).last == SampleHTML.sentence)
    }

    @Test("stripTags and decodeEntities")
    func helpers() {
        #expect(HTMLText.stripTags("<b>bold</b> and <i class=\"x\">italic</i>") == "bold and italic")
        #expect(HTMLText.decodeEntities("A&amp;B &lt;tag&gt; &#65;&#x42; &deg; &unknown;") == "A&B <tag> AB ° &unknown;")
    }
}

// MARK: - Passages, dedupe and trimming

@Suite("Passages, dedupe and trimming")
struct PassageTests {
    static func words(_ n: Int, _ word: String = "word") -> String {
        (0..<n).map { "\(word)\($0)" }.joined(separator: " ") + "."
    }

    @Test("Passages stay within a section, run 80 to 200 words, and skip reference sections")
    func fullDepth() {
        let html = "<p>\(Self.words(50, "lead"))</p><p>\(Self.words(50, "more"))</p>"
            + "<h2>Treatment</h2><p>\(Self.words(150, "treat"))</p><p>\(Self.words(150, "cool"))</p>"
            + "<h2>References</h2><p>\(Self.words(100, "ref"))</p>"
        let passages = PassageStore.passages(html: html, depth: .full)
        #expect(passages.count == 3)
        #expect(passages[0].lead && passages[0].heading == "")
        #expect(PassageStore.wordCount(passages[0].text) == 100)
        #expect(passages[1].heading == "Treatment" && !passages[1].lead)
        #expect(passages.dropFirst().allSatisfy { $0.heading == "Treatment" })
        #expect(passages.allSatisfy { PassageStore.wordCount($0.text) <= 200 })
        #expect(!passages.contains { $0.text.contains("ref0") }, "References sections are skipped")
        #expect(passages.map(\.order) == [0, 1, 2])
    }

    @Test("A long paragraph is cut at sentence ends")
    func longParagraph() {
        let sentence = "This sentence has exactly ten words in it for counting. "
        let html = "<p>" + String(repeating: sentence, count: 40) + "</p>"
        let passages = PassageStore.passages(html: html, depth: .full)
        #expect(passages.count >= 2)
        #expect(passages.allSatisfy { PassageStore.wordCount($0.text) <= 200 && $0.text.hasSuffix(".") })
    }

    @Test("Leads depth keeps one passage from the lead, at most 120 words")
    func leadsDepth() {
        let html = "<p>\(Self.words(90, "a"))</p><p>\(Self.words(90, "b"))</p><h2>Later</h2><p>\(Self.words(90, "c"))</p>"
        let passages = PassageStore.passages(html: html, depth: .leads)
        #expect(passages.count == 1)
        #expect(passages[0].lead)
        #expect(PassageStore.wordCount(passages[0].text) <= AnswerIndexPolicy.leadWords)
        #expect(!passages[0].text.contains("c0"))
    }

    @Test("Articles with no lead count their first section as the lead")
    func noLead() {
        let passages = PassageStore.passages(html: "<h2>Intro</h2><p>\(Self.words(90))</p>", depth: .full)
        #expect(passages.first?.lead == true)
        #expect(passages.first?.heading == "Intro")
    }

    @Test("trimmedWords ends at a sentence in the second half, else cuts at the limit")
    func trimmedWords() {
        #expect(PassageStore.trimmedWords("one two three", 5) == "one two three")
        #expect(PassageStore.trimmedWords("a b c d e f g. h i j k", 9) == "a b c d e f g.")
        #expect(PassageStore.trimmedWords("a. b c d e f g h i j k", 6) == "a. b c d e f")
    }

    @Test("Retriever.trimmed ends at a sentence, else adds an ellipsis")
    func trimmedChars() {
        #expect(Retriever.trimmed("short", to: 10) == "short")
        #expect(Retriever.trimmed("First sentence here. Second one runs on and on", to: 30) == "First sentence here.")
        #expect(Retriever.trimmed("No sentence end anywhere in this text at all", to: 10) == "No sentenc…")
    }

    @Test("Word counts count runs between spaces")
    func wordCount() {
        #expect(PassageStore.wordCount("") == 0)
        #expect(PassageStore.wordCount("  one  two   three ") == 3)
    }

    @Test("Near-duplicate passages overlap highly; different ones don't")
    func dedupe() {
        let lead = "Heat stroke is a medical emergency in which the body temperature rises above forty degrees and the cooling system fails"
        let variant = lead + " in children and older adults"
        let other = "Hypothermia is a dangerous drop in body temperature caused by losing heat faster than the body makes it"
        let a = PassageDedupe.shingles(lead), b = PassageDedupe.shingles(variant), c = PassageDedupe.shingles(other)
        #expect(PassageDedupe.overlap(a, b) == 1.0, "one repeats the other")
        #expect(PassageDedupe.overlap(a, c) < 0.1)
        #expect(PassageDedupe.overlap(a, []) == 0)
        #expect(PassageDedupe.shingles("Two words") .count == 2, "under three words, the words themselves")
        #expect(PassageDedupe.shingles("HEAT, stroke! now") == PassageDedupe.shingles("heat stroke now"), "case and punctuation don't matter")
    }
}

// MARK: - Answer index policy

@Suite("AnswerIndexPolicy")
struct AnswerIndexPolicyTests {
    @Test("Up to 60,000 articles get a full index, bigger ones leads only")
    func depth() throws {
        try #require(ProcessInfo.processInfo.environment["OFFLINEKIT_INDEX_FULL_LIMIT"] == nil)
        #expect(AnswerIndexPolicy.fullArticleLimit == 60_000)
        #expect(AnswerIndexPolicy.depth(articleCount: 0) == .full)
        #expect(AnswerIndexPolicy.depth(articleCount: 60_000) == .full)
        #expect(AnswerIndexPolicy.depth(articleCount: 60_001) == .leads)
        #expect(AnswerIndexPolicy.depth(articleCount: 6_800_000) == .leads)
    }

    @Test("The disk budget is a tenth of free plus used space, at most 8 GB on a Mac")
    func budget() {
        #expect(AnswerIndexPolicy.totalBudget(free: 10 << 30, used: 0) == 1 << 30)
        #expect(AnswerIndexPolicy.totalBudget(free: 9 << 30, used: 1 << 30) == 1 << 30)
        #expect(AnswerIndexPolicy.totalBudget(free: 500 << 30, used: 0) == 8 << 30)
        #expect(AnswerIndexPolicy.totalBudget(free: 0, used: 0) == 0)
    }

    @Test("Size estimates, read limits and chunk sizes")
    func limits() throws {
        #expect(AnswerIndexPolicy.estimatedBytes(articles: 1_000, depth: .full) == 20_000_000)
        #expect(AnswerIndexPolicy.estimatedBytes(articles: 6_800_000, depth: .leads) == 4_760_000_000)
        #expect(AnswerIndexPolicy.maxHTMLBytes(.full) == 200_000 && AnswerIndexPolicy.maxHTMLBytes(.leads) == 32_000)
        #expect(AnswerIndexPolicy.maxPassages(.full) == 40 && AnswerIndexPolicy.maxPassages(.leads) == 1)
        #expect(AnswerIndexPolicy.chunk(.full) == 60 && AnswerIndexPolicy.chunk(.leads) == 400)
        try #require(ProcessInfo.processInfo.environment["OFFLINEKIT_INDEX_WORKERS"] == nil)
        #expect(AnswerIndexPolicy.workers(plugged: false) == 1)
        #expect((1...3).contains(AnswerIndexPolicy.workers(plugged: true)))
        #expect(AnswerIndexPolicy.skippedSections.contains("external links"))
    }
}

// MARK: - Index build and query on a tiny archive

@Suite("Answer index on a tiny ZIM", .serialized)
struct AnswerIndexTests {
    func archive() throws -> ZimArchive {
        try ZimArchive(path: try TestSupport.fixture("tiny.zim").path)
    }

    func build(_ depth: AnswerIndexPolicy.Depth, in tmp: TempDir) throws -> PassageStore {
        let zim = try archive()
        let store = try PassageStore(url: tmp.url.appending(path: "index.sqlite"), depth: depth)
        let articles = zim.articles(from: 0, count: UInt(zim.entryCount), maxBytes: UInt(AnswerIndexPolicy.maxHTMLBytes(depth)))
        let drafts = PassageStore.drafts(articles, depth: depth)
        try store.append(drafts, cursor: Int(zim.entryCount), seconds: 0)
        store.optimize()
        return store
    }

    func search(_ store: PassageStore, _ question: String) -> [IndexHit] {
        let terms = Retriever.terms(question)
        return store.search(terms: terms, phrases: Retriever.phrases(terms), limit: 20).sorted { $0.bm25 > $1.bm25 }
    }

    @Test("The fixture opens and has its six articles")
    func fixture() throws {
        let zim = try archive()
        #expect(zim.articleCount == 6)
        #expect(zim.name == "test_tiny_en")
        let articles = zim.articles(from: 0, count: UInt(zim.entryCount), maxBytes: 200_000)
        #expect(Set(articles.map(\.path)).isSuperset(of: ["Heat_stroke", "Burns", "GFCI_outlet"]))
    }

    @Test("A full index finds the right article for each question")
    func fullIndex() throws {
        let tmp = try TempDir()
        let store = try build(.full, in: tmp)
        defer { store.close() }
        #expect(Int(store.meta("passages") ?? "") ?? 0 >= 6)
        #expect(search(store, "how do I treat heat stroke").first?.path == "Heat_stroke")
        #expect(search(store, "reset a tripped GFCI outlet").first?.path == "GFCI_outlet")
        #expect(search(store, "is boiled water safe to drink").first?.path == "Water_purification")
        let rewarm = search(store, "rewarm someone who is very cold")
        #expect(rewarm.first?.path == "Hypothermia")
        #expect(rewarm.first?.text.isEmpty == false, "a full index keeps passage text")
        #expect(search(store, "zzqx nothing matches").isEmpty)
        #expect(!search(store, "water references").contains { $0.heading == "References" }, "reference sections aren't indexed")
    }

    @Test("A leads-only index keeps one passage per article and finds articles by title")
    func leadsIndex() throws {
        let tmp = try TempDir()
        let store = try build(.leads, in: tmp)
        defer { store.close() }
        let hits = search(store, "burns first aid")
        #expect(hits.first?.path == "Burns")
        #expect(hits.allSatisfy { $0.lead && $0.order == 0 })
        #expect(hits.allSatisfy { $0.text.isEmpty }, "contentless: the lead is read back from the archive")
        let lead = try #require(PassageStore.leadText(archive: try archive(), path: "Burns"))
        #expect(lead.hasPrefix("A burn is damage to the skin"))
    }

    @Test("The background builder indexes the archive and Ask's retriever uses it")
    func backgroundBuild() async throws {
        _ = try TestSupport.testHome()
        let zim = try archive()
        AnswerIndex.shared.load([zim])
        let ready = await eventually(timeout: 30) { AnswerIndex.shared.store(for: zim) != nil }
        try #require(ready, "the index didn't finish")
        #expect(AnswerIndex.folder.path.hasPrefix(KitLocation.caches.path), "indexes live in the test home's caches")
        let sources = Retriever.retrieve(question: "how do I reset a tripped GFCI outlet", archives: [zim], budgetChars: 4_000)
        #expect(sources.first?.ref.title == "Ground fault circuit interrupter")
        #expect(sources.first?.text.contains("reset") == true)
    }
}
