import Foundation
import Testing

/// A finished turn with sources, as the conversation keeps it.
func answeredTurn(_ question: String, sources: [(path: String, title: String)] = [], query: SearchQuery? = nil) -> Turn {
    var turn = Turn(question: question)
    turn.status = .done
    turn.answer = "An answer."
    turn.sources = sources.enumerated().map { i, s in
        Source(id: i + 1, ref: ArticleRef(bookID: "book", path: s.path, title: s.title), bookTitle: "Book", text: "Text about \(s.title).")
    }
    turn.query = query
    return turn
}

@Suite("Follow-up searches")
struct FollowUpSearchTests {
    @Test("A question that stands on its own is searched as it is")
    func standalone() {
        let previous = answeredTurn("How can I purify water without power?")
        for question in ["How do I treat a bee sting?", "What are the symptoms of carbon monoxide poisoning in adults and children?"] {
            let query = AskModel.searchQuery(for: question, after: previous)
            #expect(!query.isFollowUp)
            #expect(query == SearchQuery(question))
        }
        #expect(!AskModel.searchQuery(for: "Is that different at high altitude?", after: nil).isFollowUp, "no turn before it")
    }

    @Test("Pronoun-led and short follow-ups are recognized")
    func recognized() {
        for question in ["Should I put ice on it?", "What about kids?", "How do I warm someone up?", "Is that different at high altitude?",
                         "And for a dog?", "How long should I let it run afterward?"] {
            #expect(AskModel.isFollowUp(question), "\(question)")
        }
        #expect(AskModel.isDefiniteFollowUp("Why are the leaves turning yellow?"))
        #expect(!AskModel.isDefiniteFollowUp("How do I treat a bee sting?"), "no \"the\"")
        #expect(!AskModel.isDefiniteFollowUp("What is the safest way to store gasoline for a generator?"), "too long")
        #expect(!AskModel.isFollowUp("How do I fix a leaking faucet?"))
    }

    @Test("A follow-up keeps its own words, drops filler and carries the topic, which counts for less")
    func carriesTopic() {
        let first = answeredTurn("How can I purify water without power?",
                                 sources: [("A/Boiling_water", "How long does water need to be boiled?"), ("A/Filters", "Water filters")])
        let firstQuery = AskModel.searchQuery(for: first.question, after: nil)
        let second = AskModel.searchQuery(for: "How long should I boil it?", after: answeredTurn(first.question, sources: [
            ("A/Boiling_water", "How long does water need to be boiled?")], query: firstQuery))
        #expect(second.isFollowUp)
        #expect(second.terms.first == "boil", "its own words come first")
        #expect(!second.terms.contains("long"), "\"how long\" says nothing about the topic")
        #expect(second.carried.contains("water") && second.carried.contains("purify"))
        #expect(second.terms.first(where: second.carried.contains) == "water", "a word the last sources' titles name is carried first")
        #expect(second.preferred == ["book/A/Boiling_water"])

        let third = AskModel.searchQuery(for: "Is that different at high altitude?",
                                         after: answeredTurn("How long should I boil it?", sources: [("B/Altitude", "Boiling water at altitude")],
                                                             query: second))
        #expect(!third.terms.contains("different"), "filler words go")
        #expect(third.terms.prefix(2) == ["high", "altitude"])
        #expect(third.carried.contains("boil") && third.carried.contains("water"))
        #expect(third.carried.count <= AskModel.carriedLimit)
        #expect(third.phrases.contains("high altitude"))
        #expect(!third.phrases.contains("altitude boil"), "no phrases across the question and the carried words")
        #expect(third.combinations.first == ["high", "altitude", third.terms[2]])
        #expect(third.text.hasPrefix("Is that different at high altitude?"))
    }

    @Test("Carried words weigh half as much: a passage with only the topic covers less of the question")
    func weights() {
        let terms = ["altitude", "boil", "water"]
        let carried: Set<String> = ["boil", "water"]
        let (_, onlyTopic) = Retriever.plainRelevance(title: "boiling water", text: "how to boil water safely", xapian: 0,
                                                      terms: terms, phrases: [], carried: carried)
        let (_, onlyOwn) = Retriever.plainRelevance(title: "altitude", text: "altitude sickness", xapian: 0,
                                                    terms: terms, phrases: [], carried: carried)
        let (_, unweighted) = Retriever.plainRelevance(title: "boiling water", text: "how to boil water safely", xapian: 0,
                                                       terms: terms, phrases: [])
        #expect(onlyTopic < unweighted)
        #expect(onlyOwn > onlyTopic, "the question's own word counts for more than two carried ones together")
        #expect(Retriever.weight("altitude", carried: carried) == 1.5 && Retriever.weight("boil", carried: carried) == 0.5)
    }

    @Test("A follow-up's strength counts sources about its own words and its topic together")
    func strength() {
        var query = SearchQuery("Should I put ice on it?")
        query.terms = ["ice", "burn"]
        query.carried = ["burn"]
        let sources = [
            Source(id: 1, ref: ArticleRef(bookID: "b", path: "Ice", title: "Ice packs"), bookTitle: "B", text: "Ice packs for sprains."),
            Source(id: 2, ref: ArticleRef(bookID: "b", path: "Burns", title: "Burns"), bookTitle: "B", text: "Never put ice on a burn."),
        ]
        #expect(AskModel.followUpStrength(sources, query: query) == 1)
        #expect(AskModel.followUpStrength([sources[0]], query: query) == 0)
    }
}
