import Foundation

// Small local-archive fixtures exercise the actual taxonomy and search implementation.
final class ZimArchive: @unchecked Sendable {
    let name: String
    let hasFullTextIndex = true
    let hits: [ZimHit]
    var queries: [String] = []
    init(_ name: String, _ hits: [ZimHit]) { self.name = name; self.hits = hits }
    func suggest(_ query: String, limit: Int) -> [ZimHit] { [] }
    func search(_ query: String, limit: Int) -> [ZimHit] { queries.append(query); return hits }
}
struct ZimHit: Sendable { let path: String; let title: String; let snippet: String; let score: Int }
struct ArticleRef: Hashable, Sendable {
    let bookID: String; let path: String; let title: String
    var id: String { bookID + "/" + path }
}
struct Book: Sendable { let id: String; let archive: ZimArchive; let shortTitle: String }

@main struct SubjectSearchChecks {
    static func main() {
        precondition(SubjectArea.allCases.count == 7)
        let allPacks = Set(Interests.all.flatMap(\.packs).map(\.name))
        let organized = Set(SubjectArea.allCases.flatMap(\.packs).map(\.name))
        precondition(allPacks.isSubset(of: organized), "Every existing pack must remain reachable")
        let topics = SubjectArea.allCases.flatMap(\.topics)
        precondition(Set(topics.map(\.id)).count == topics.count)
        precondition(topics.allSatisfy { !$0.queries.isEmpty })
        for area in SubjectArea.allCases {
            precondition(Set(area.packs.map(\.name)).count == area.packs.count, "No duplicate packs within an area")
            precondition(area.contains(archiveName: "wikipedia_en_all_maxi_2026-08"))
        }
        precondition(!SubjectArea.home.contains(archiveName: "diy.stackexchange.com_en_alligator"), "Archive identity uses a name boundary")
        let topic = SubjectArea.home.topics.first { $0.title == "Electrical" }!
        let diy = ZimArchive("diy.stackexchange.com_en_all", [
            ZimHit(path: "GFCI", title: "GFCI outlet won’t reset", snippet: "A saved <b>electrical</b> question", score: 2),
            ZimHit(path: "GFCI", title: "GFCI outlet won’t reset", snippet: "Duplicate hit", score: 2)
        ])
        let encyclopedia = ZimArchive("wikipedia_en_all", [
            ZimHit(path: "Circuit_breaker", title: "Circuit breaker", snippet: "An electrical safety device", score: 3),
            ZimHit(path: "Film", title: "Circuit Breaker (film)", snippet: "A film", score: 90),
            ZimHit(path: "Singapore", title: "2020 Singapore circuit breaker measures", snippet: "Pandemic restrictions", score: 99),
            ZimHit(path: "Finance", title: "Circuit breaker (finance)", snippet: "Financial regulation", score: 99)
        ])
        let medicine = ZimArchive("mdwiki_en_all", [ZimHit(path: "irrelevant", title: "Medicine", snippet: "Medical content", score: 99)])
        let results = SubjectSearch.articles(topic: topic, query: "", books: [
            Book(id: "diy", archive: diy, shortTitle: "Home Improvement"),
            Book(id: "wiki", archive: encyclopedia, shortTitle: "Wikipedia"),
            Book(id: "medicine", archive: medicine, shortTitle: "WikiMed")
        ])
        precondition(results.count == 2, "Deduplicate repeated hits and exclude unrelated namesakes")
        precondition(results.first?.ref.bookID == "diy", "Prefer dedicated subject references")
        precondition(results.first?.snippet == "A saved electrical question")
        precondition(medicine.queries.isEmpty, "Never search unrelated archives in a scoped shelf")
        diy.queries = []
        _ = SubjectSearch.articles(topic: topic, query: "outlet", books: [Book(id: "diy", archive: diy, shortTitle: "Home Improvement")])
        precondition(diy.queries == ["outlet"], "User search replaces the default topic queries")
        print("PASS: seven areas, complete pack coverage, unique topics, archive boundaries, scoped offline search, relevance, source ranking and deduplication.")
    }
}
