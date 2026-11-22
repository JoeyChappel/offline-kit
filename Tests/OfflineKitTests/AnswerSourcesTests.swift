import Foundation
import Testing

@Suite("First-question sources")
struct FirstQuestionSourceTests {
    @Test("Everyday injury and symptom words add what references call them")
    func relatedWords() {
        #expect(Retriever.related(to: "What should I do for a burn from boiling water?").contains("scald"))
        #expect(Retriever.related(to: "How do I treat a deep cut on my hand?").contains("wound"))
        let breathing = Retriever.related(to: "My son can't breathe and is wheezing")
        #expect(breathing.contains("asthma") && breathing.contains("choking"))
        #expect(Retriever.related(to: "How do I stop a nosebleed?").contains("epistaxis"))
        #expect(Retriever.related(to: "What should I do if someone faints?").contains("syncope"))
        #expect(Retriever.related(to: "What are the signs of a heart attack?") == ["myocardial infarction"])
        #expect(Retriever.related(to: "Can I eat bread if I cut off the mold?").isEmpty, "\"cut off\" isn't a cut")
        #expect(Retriever.related(to: "How do I fix a leaking faucet?").isEmpty)
    }

    @Test("Health questions include breathing trouble and fainting, not cutting off mold")
    func healthQuestions() {
        #expect(AskModel.isHealthQuestion("My son can't breathe and is wheezing. What do I do?"))
        #expect(AskModel.isHealthQuestion("What should I do if someone passed out?"))
        #expect(AskModel.isHealthQuestion("How do I treat a deep cut on my hand?"))
        #expect(AskModel.isHealthQuestion("What should I do for a burn from boiling water?"))
        #expect(!AskModel.isHealthQuestion("Can I eat bread if I cut off the mold?"))
        #expect(!AskModel.isHealthQuestion("How do I fix a running toilet?"))
    }

    @Test("A circumstance clause counts for less; a question without one is unchanged")
    func circumstance() {
        let burn = SearchQuery("What should I do for a burn from boiling water?")
        #expect(burn.lighter == ["boiling": SearchQuery.circumstanceWeight, "water": SearchQuery.circumstanceWeight])
        #expect(SearchQuery("What should I do if I see a bear while hiking?").lighter.keys.sorted() == ["hiking"])
        #expect(SearchQuery("How do I safely use a generator during a power outage?").lighter.keys.sorted() == ["outage", "power"])
        for question in ["When should I plant tomatoes?", "How can I purify water without power?", "How do I fix a leaking faucet?",
                         "What if it still won't start after that?", "Can I refreeze it if it thawed?"] {
            #expect(SearchQuery(question).lighter.isEmpty, "\(question)")
        }
        // The burn outranks the boiling water in a title.
        let terms = burn.terms, phrases = burn.phrases
        let (burnScore, _) = Retriever.plainRelevance(title: "burn", text: "a burn from hot water", xapian: 0, terms: terms,
                                                      phrases: phrases, lighter: burn.lighter)
        let (boilScore, _) = Retriever.plainRelevance(title: "boiling water", text: "a burn from boiling water", xapian: 0, terms: terms,
                                                      phrases: phrases, lighter: burn.lighter)
        let (oldBoil, _) = Retriever.plainRelevance(title: "boiling water", text: "a burn from boiling water", xapian: 0, terms: terms,
                                                    phrases: phrases)
        #expect(boilScore < oldBoil)
        #expect(burnScore > 0)
    }

    @Test("Related words add to a match and never count against one")
    func relatedBonus() {
        let terms = ["deep", "cut", "hand"]
        let plain = Retriever.plainRelevance(title: "cut", text: "a deep cut on the hand", xapian: 0, terms: terms, phrases: [])
        let without = Retriever.plainRelevance(title: "cut", text: "a deep cut on the hand", xapian: 0, terms: terms, phrases: [],
                                               related: ["wound", "laceration"])
        #expect(plain == without, "absent related words change nothing")
        let with = Retriever.plainRelevance(title: "wound", text: "a deep cut on the hand", xapian: 0, terms: terms, phrases: [],
                                            related: ["wound", "laceration"])
        let unrelated = Retriever.plainRelevance(title: "garden", text: "a deep cut on the hand", xapian: 0, terms: terms, phrases: [])
        #expect(with.0 > unrelated.0)
        #expect(with.1 <= 1)
    }

    @Test("Questions that ask what to do lift Treatment and First aid sections")
    func steps() {
        for question in ["What should I do for a burn?", "How do I treat a bee sting?", "What to do if someone faints",
                         "First aid for a nosebleed"] {
            #expect(Retriever.asksWhatToDo(question), "\(question)")
        }
        for question in ["What are the signs of hypothermia?", "How long can cooked rice sit out?", "Why does it keep tripping?"] {
            #expect(!Retriever.asksWhatToDo(question), "\(question)")
        }
        let query = SearchQuery("What should I do for a burn?")
        #expect(Retriever.stepsBonus(heading: "Treatment", query: query) == 2)
        #expect(Retriever.stepsBonus(heading: "First aid", query: query) == 2)
        #expect(Retriever.stepsBonus(heading: "Treatments to avoid", query: query) == 1)
        #expect(Retriever.stepsBonus(heading: "Epidemiology", query: query) == 0)
        #expect(Retriever.stepsBonus(heading: "Treatment", query: SearchQuery("What are the signs of hypothermia?")) == 0)
    }

    @Test("Plural words find the singular; British spellings are related words")
    func spellings() {
        #expect(Retriever.key("eggs") == "egg" && Retriever.key("tires") == "tire" && Retriever.key("tomatoes") == "tomat")
        #expect(Retriever.key("gas") == "gas" && Retriever.key("glass") == "glass" && Retriever.key("virus") == "virus")
        #expect(SearchQuery("How do I get rid of mold in the bathroom?").related == ["mould"])
        #expect(SearchQuery("Is it safe to eat mouldy bread?").related == ["moldy"])
    }

    @Test("A medical source named for the condition counts; one named for a body part or a lookalike word doesn't")
    func conditionNamed() {
        func source(_ title: String, _ text: String) -> Source {
            Source(id: 1, ref: ArticleRef(bookID: "b", path: title, title: title), bookTitle: "MDWiki", text: text)
        }
        let question = "What should I do for a burn from boiling water?"
        var query = SearchQuery(question)
        query.relate(Retriever.related(to: question))
        #expect(AskModel.conditionStem("burned") == "burn" && AskModel.conditionStem("choking") == "chok")
        #expect(AskModel.conditionStrength([source("Thermal burn", "Burns from hot water and steam are called scalds.")],
                                           question: question, query: query) == 1)
        #expect(AskModel.conditionStrength([source("Scalding", "Scalding is a burn from hot liquids such as boiling water.")],
                                           question: question, query: query) == 1)
        #expect(AskModel.conditionStrength([source("Boil-water advisory", "Boil water before drinking it.")],
                                           question: question, query: query) == 0)
        let cut = "How do I treat a deep cut on my hand?"
        var cutQuery = SearchQuery(cut)
        cutQuery.relate(Retriever.related(to: cut))
        #expect(AskModel.conditionStrength([source("Cutaneous condition", "A deep cut on the hand is a skin injury.")],
                                           question: cut, query: cutQuery) == 0, "\"cutaneous\" isn't \"cut\"")
        #expect(AskModel.conditionStrength([source("Hand", "The hand has a deep cut.")], question: cut, query: cutQuery) == 0)
        #expect(AskModel.conditionStrength([source("Wound", "A deep cut on the hand is a wound; press on it to stop bleeding.")],
                                           question: cut, query: cutQuery) == 1)
    }
}
