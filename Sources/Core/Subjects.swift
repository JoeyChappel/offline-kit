import Foundation

/// One taxonomy for browsing saved references and choosing new resources.
enum SubjectArea: String, CaseIterable, Identifiable, Codable, Sendable {
    case emergency, health, home, food, outdoors, learning, world
    var id: String { rawValue }

    var title: String {
        switch self {
        case .emergency: "Emergency & preparedness"
        case .health: "Health & family"
        case .home: "Home & repairs"
        case .food: "Food & water"
        case .outdoors: "Garden & outdoors"
        case .learning: "Science & learning"
        case .world: "World & interests"
        }
    }

    var subtitle: String {
        switch self {
        case .emergency: "First aid, shelter, supplies and power outages"
        case .health: "First aid, medicine, parenting and pets"
        case .home: "Electrical, plumbing, appliances and vehicles"
        case .food: "Cooking, food storage and safe water"
        case .outdoors: "Growing food, outdoor skills and self-reliance"
        case .learning: "Science, computers, books and learning for kids"
        case .world: "History, places, maps, sports and entertainment"
        }
    }

    var symbol: String {
        switch self {
        case .emergency: "shield.lefthalf.filled"
        case .health: "heart.text.square"
        case .home: "wrench.and.screwdriver"
        case .food: "drop"
        case .outdoors: "leaf"
        case .learning: "atom"
        case .world: "globe.americas"
        }
    }

    private func topic(_ title: String, _ queries: [String], _ detail: String = "Browse saved guides and reference articles") -> SubjectTopic {
        SubjectTopic(area: self, title: title, queries: queries, detail: detail)
    }

    var topics: [SubjectTopic] {
        switch self {
        case .emergency: [
            topic("Power outages", ["power outage", "emergency power", "generator"]),
            topic("Emergency supplies", ["emergency kit", "disaster supplies", "preparedness"]),
            topic("Shelter & warmth", ["shelter", "hypothermia", "winter survival"]),
            topic("Water safety", ["water purification", "water treatment", "drinking water"]),
            topic("Disaster recovery", ["disaster recovery", "flood", "earthquake"])
        ]
        case .health: [
            topic("First aid", ["first aid", "bleeding", "burn", "heat stroke"]),
            topic("Symptoms & conditions", ["symptom", "fever", "infection"]),
            topic("Medicines", ["medicine", "medication", "drug"]),
            topic("Children & parenting", ["child", "parenting", "infant"]),
            topic("Pets", ["pet", "dog", "cat"])
        ]
        case .home: [
            topic("Electrical", ["GFCI", "circuit breaker", "electrical outlet", "electrical"], "Outlets, circuit breakers, lighting and wiring"),
            topic("Plumbing", ["plumbing", "leak", "drain", "toilet"], "Leaks, drains, toilets and water supply"),
            topic("Appliances", ["appliance", "refrigerator", "washing machine"], "Identify faults and find repair guides"),
            topic("Building & woodworking", ["woodworking", "door", "wall", "construction"], "Walls, doors, furniture and basic construction"),
            topic("Vehicles", ["car", "engine", "battery", "vehicle"], "Starting problems, maintenance and repairs"),
            topic("Tools & electronics", ["electronics", "circuit", "soldering", "radio"], "Tools, circuits, radios and small devices")
        ]
        case .food: [
            topic("Cooking & recipes", ["cooking", "recipe", "bread"]),
            topic("Food storage", ["food storage", "refrigeration", "food safety"]),
            topic("Preserving food", ["canning", "food preservation", "dehydration"]),
            topic("Drinking water", ["drinking water", "water purification", "water filter"]),
            topic("Sanitation", ["sanitation", "hygiene", "disinfection"])
        ]
        case .outdoors: [
            topic("Vegetable gardening", ["vegetable", "gardening", "seed"]),
            topic("Plants & soil", ["soil", "compost", "plant"]),
            topic("Outdoor skills", ["camping", "knot", "navigation"]),
            topic("Bicycles", ["bicycle", "bicycle repair"]),
            topic("Sustainable living", ["sustainability", "solar power", "self sufficiency"])
        ]
        case .learning: [
            topic("Science", ["physics", "chemistry", "biology", "astronomy"]),
            topic("Math", ["mathematics", "algebra", "geometry"]),
            topic("Computers", ["computer", "programming", "network"]),
            topic("Books & courses", ["textbook", "course", "learning"]),
            topic("Learning for kids", ["science", "animal", "earth"])
        ]
        case .world: [
            topic("History & society", ["history", "civilization", "society"]),
            topic("Geography", ["geography", "country", "continent"]),
            topic("Travel & maps", ["travel", "map", "United States"]),
            topic("Sports", ["football", "baseball", "basketball", "tennis"]),
            topic("Movies & culture", ["film", "cinema", "comics"])
        ]
        }
    }

    /// Reuse the curated catalog identities. Overlapping interests share one archive.
    var packs: [Pack] {
        let groups: [String]
        let extra: [String]
        switch self {
        case .emergency: groups = ["essentials", "survival"]; extra = []
        case .health: groups = ["health"]; extra = ["mdwiki_en_all", "zimgit-medicine_en"]
        case .home: groups = ["home"]; extra = ["ifixit_en_all"]
        case .food: groups = []; extra = ["cooking.stackexchange.com_en_all", "publicdomainrecipes.com_en_all", "zimgit-water_en", "zimgit-food-preparation_en"]
        case .outdoors: groups = []; extra = ["gardening.stackexchange.com_en_all", "outdoors.stackexchange.com_en_all", "sustainability.stackexchange.com_en_all", "appropedia_en_all", "gardenology_en_all", "zimgit-knots_en", "bicycles.stackexchange.com_en_all"]
        case .learning: groups = ["science", "learning", "books", "video"]; extra = []
        case .world: groups = ["society", "entertainment"]; extra = []
        }
        let all = Interests.all.flatMap(\.packs)
        let candidates = Interests.all.filter { groups.contains($0.id) }.flatMap(\.packs) + all.filter { extra.contains($0.name) }
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.name).inserted }
    }

    func contains(archiveName: String) -> Bool {
        let name = archiveName.lowercased()
        // Broad encyclopedias can supply relevant articles in every subject.
        if Interests.encyclopedia.contains(where: { name == $0.name || name.hasPrefix($0.name + "_") }) { return true }
        return isDedicated(archiveName: name)
    }

    func isDedicated(archiveName: String) -> Bool {
        let name = archiveName.lowercased()
        // Every map region belongs with World & interests (see MapRegions).
        if self == .world && name.hasPrefix("maps_") { return true }
        return packs.contains { name == $0.name || name.hasPrefix($0.name + "_") }
    }
}

struct SubjectTopic: Hashable, Identifiable, Codable, Sendable {
    let area: SubjectArea
    let title: String
    let queries: [String]
    let detail: String
    var id: String { area.rawValue + "/" + title }
}

struct SubjectArticle: Identifiable, Sendable {
    let ref: ArticleRef
    let archiveTitle: String
    let snippet: String
    let rank: Int
    var id: String { ref.id }
}

enum SubjectSearch {
    /// Article titles and indexed text are read from local archives only.
    static func articles(topic: SubjectTopic, query: String, books: [Book]) -> [SubjectArticle] {
        let input = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let queries = input.isEmpty ? topic.queries : [input]
        var found: [String: SubjectArticle] = [:]
        for book in books where topic.area.contains(archiveName: book.archive.name) {
            if Task.isCancelled { break }
            let dedicated = topic.area.isDedicated(archiveName: book.archive.name)
            for (priority, term) in queries.enumerated() {
                let suggested = book.archive.suggest(term, limit: 8)
                let matches = book.archive.hasFullTextIndex ? book.archive.search(term, limit: 12) : []
                for hit in suggested + matches {
                    guard isRelevant(title: hit.title, snippet: hit.snippet, topic: topic, dedicated: dedicated) else { continue }
                    let ref = ArticleRef(bookID: book.id, path: hit.path, title: hit.title)
                    let titleMatch = hit.title.localizedCaseInsensitiveContains(term)
                    let exact = hit.title.caseInsensitiveCompare(term) == .orderedSame
                    let result = SubjectArticle(ref: ref, archiveTitle: book.shortTitle,
                                                snippet: hit.snippet.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression),
                                                rank: (dedicated ? 100 : 20) + (exact ? 80 : titleMatch ? 40 : 0)
                                                    + (queries.count - priority) * 8 + min(10, max(0, hit.score)))
                    if found[ref.id] == nil || result.rank > found[ref.id]!.rank { found[ref.id] = result }
                }
            }
        }
        return Array(found.values.sorted {
            $0.rank == $1.rank ? $0.ref.title.localizedStandardCompare($1.ref.title) == .orderedAscending : $0.rank > $1.rank
        }.prefix(60))
    }

    /// Broad encyclopedias contain namesakes as well as reference articles.
    /// Keep an electrical shelf about electricity, rather than films or pandemic measures.
    static func isRelevant(title: String, snippet: String, topic: SubjectTopic, dedicated: Bool) -> Bool {
        let lower = title.lowercased()
        if lower.contains("(disambiguation)") { return false }
        guard !dedicated else { return true }
        if topic.area != .world && ["(film)", "(song)", "(album)", "(band)", "(video game)", "(dc comics)"].contains(where: lower.contains) { return false }
        if topic.area == .home && topic.title == "Electrical" {
            if ["singapore", "finance", "property tax", "design pattern", "video game", "comics"].contains(where: lower.contains) { return false }
            let context = (title + " " + snippet).lowercased()
            return ["electric", "gfci", "voltage", "wire", "receptacle", "socket", "ground fault", "switchgear", "residual-current"].contains(where: context.contains)
        }
        return true
    }
}
