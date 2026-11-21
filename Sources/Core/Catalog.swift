import Foundation

/// One downloadable archive from the Kiwix catalog (a specific name + flavour, latest date).
struct CatalogEntry: Identifiable, Hashable, Sendable {
    var name: String          // e.g. wikipedia_en_medicine
    var flavour: String       // maxi, nopic, mini, or ""
    var title: String
    var summary: String
    var size: Int64
    var metalink: URL         // .meta4 with mirrors and checksums
    var issued: String        // yyyy-MM-dd
    var articleCount: Int

    var id: String { name + "|" + flavour }
    /// File name on disk, e.g. wikipedia_en_medicine_maxi_2026-10.zim
    var fileName: String { metalink.lastPathComponent.replacingOccurrences(of: ".meta4", with: "") }
    var editionLabel: String {
        switch flavour {
        case "maxi", "full": "With pictures"
        case "nopic": "Text only"
        case "mini": "Summaries"
        default: "Published edition"
        }
    }
}

/// How much of each archive to get. Not every pack comes in every size; the closest available is used.
enum PictureChoice: String, CaseIterable, Identifiable, Sendable {
    case full, noPictures, summaries
    var id: String { rawValue }
    var label: String {
        switch self {
        case .full: "With pictures"
        case .noPictures: "Text only"
        case .summaries: "Summaries"
        }
    }
    /// What each choice means for a first-time user.
    var explanation: String {
        switch self {
        case .full: "Full articles with images. Largest."
        case .noPictures: "The same articles without images. About half the size."
        case .summaries: "Just the opening of each article. Smallest."
        }
    }

    var preference: [String] {
        switch self {
        case .full: ["maxi", "", "full", "nopic", "mini"]
        case .noPictures: ["nopic", "", "mini", "maxi", "full"]
        case .summaries: ["mini", "nopic", "", "maxi", "full"]
        }
    }
}

/// A curated item in the picker. Resolved against the live catalog for size and latest version.
struct Pack: Identifiable, Hashable, Sendable {
    let name: String
    let label: String
    var note: String = ""
    var id: String { name }
}

/// A group of packs people choose by interest ("only science", "no sports or celebrities").
struct Interest: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let packs: [Pack]
    var startsSelected = false
}

enum Interests {
    /// General Wikipedia: pick at most one. These include everything popular, celebrities and sports too.
    static let encyclopedia: [Pack] = [
        Pack(name: "wikipedia_en_top", label: "Best of Wikipedia", note: "The most-read articles. Includes pop culture."),
        Pack(name: "wikipedia_en_top1m", label: "Top 1 million articles", note: "Broad coverage. Includes pop culture."),
        Pack(name: "wikipedia_en_all", label: "All of Wikipedia", note: "Everything, about 7 million articles."),
        Pack(name: "wikipedia_en-simple_all", label: "Simple English Wikipedia", note: "Easier reading, good for kids."),
    ]

    static let all: [Interest] = [
        Interest(id: "essentials", title: "Emergency essentials",
                 subtitle: "Medicine, repairs and disaster know-how", symbol: "cross.case",
                 packs: [
                    Pack(name: "zimgit-post-disaster_en", label: "After a disaster", note: "Guides to shelter, sanitation, power and rebuilding after an emergency."),
                    Pack(name: "zimgit-water_en", label: "Safe drinking water", note: "How to collect, filter and disinfect water."),
                    Pack(name: "zimgit-food-preparation_en", label: "Food storage and preparation", note: "Ways to store and cook food when the power is out."),
                    Pack(name: "zimgit-medicine_en", label: "Emergency medicine books", note: "Books on first aid and wilderness medicine."),
                 ], startsSelected: true),
        Interest(id: "survival", title: "Survival and preparedness",
                 subtitle: "Military manuals, disaster plans and self-reliance", symbol: "shield.lefthalf.filled",
                 packs: [
                    Pack(name: "armypubs_en_all", label: "U.S. Army field manuals", note: "Official Army manuals, including survival and first aid. Very large."),
                    Pack(name: "irp.fas.org_en_military-medicine", label: "Military first-aid manuals", note: "Army first-aid and medical training guides."),
                    Pack(name: "ready.gov_en_all", label: "Ready.gov disaster plans", note: "FEMA checklists for emergency kits, storms, fires and power outages."),
                    Pack(name: "cd3wdproject.org_en_all", label: "Low-tech how-to manuals", note: "900+ manuals on water, farming, building and power (CD3WD)."),
                    Pack(name: "trueprepper.com_en_all", label: "Home preparedness guides", note: "Articles on getting your home and family ready (True Prepper)."),
                    Pack(name: "canadian-prepper_en_winterprepping", label: "Winter survival videos", note: "Staying warm and safe through winter storms."),
                    Pack(name: "canadian-prepper_en_preppingfood", label: "Food storage videos", note: "Storing food for the long term."),
                    Pack(name: "canadian-prepper_en_bugoutconcepts", label: "Evacuation planning videos", note: "Planning to leave home quickly in an emergency."),
                    Pack(name: "urban-prepper_en_all", label: "City preparedness videos", note: "Getting ready for emergencies in towns and cities."),
                    Pack(name: "lrnselfreliance_en_all", label: "Self-reliance videos", note: "Homesteading, gardening and beekeeping."),
                    Pack(name: "survivorlibrary.com_en_all", label: "Survivor Library", note: "Thousands of old how-to books from before electricity. Very large."),
                 ]),
        Interest(id: "health", title: "Health and family",
                 subtitle: "Medical reference, parenting and pets", symbol: "heart.text.square",
                 packs: [
                    Pack(name: "mdwiki_en_all", label: "WikiMed medical encyclopedia", note: "Plain-language health articles from Wikipedia's medical project."),
                    Pack(name: "wikipedia_en_medicine", label: "Wikipedia: Medicine", note: "Every medical article on Wikipedia."),
                    Pack(name: "medlineplus.gov_en_all", label: "MedlinePlus", note: "The U.S. National Library of Medicine's guides to conditions and medicines."),
                    Pack(name: "medicalsciences.stackexchange.com_en_all", label: "Health questions and answers", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                    Pack(name: "parenting.stackexchange.com_en_all", label: "Parenting questions and answers", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                    Pack(name: "pets.stackexchange.com_en_all", label: "Pet care questions and answers", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                 ]),
        Interest(id: "home", title: "Home, repair and tools",
                 subtitle: "DIY, vehicles, electronics and radio", symbol: "wrench.and.screwdriver",
                 packs: [
                    Pack(name: "ifixit_en_all", label: "iFixit repair guides", note: "Step-by-step photo guides for fixing phones, appliances, cars and more."),
                    Pack(name: "diy.stackexchange.com_en_all", label: "Home repair questions and answers", note: "Electrical, plumbing and building questions answered by a community (Stack Exchange)."),
                    Pack(name: "mechanics.stackexchange.com_en_all", label: "Car repair questions and answers", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                    Pack(name: "electronics.stackexchange.com_en_all", label: "Electronics questions and answers", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                    Pack(name: "woodworking.stackexchange.com_en_all", label: "Woodworking questions and answers", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                    Pack(name: "bicycles.stackexchange.com_en_all", label: "Bicycle repair questions and answers", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                    Pack(name: "ham.stackexchange.com_en_all", label: "Ham radio questions and answers", note: "Useful for emergency radio communication (Stack Exchange)."),
                    Pack(name: "lifehacks.stackexchange.com_en_all", label: "Everyday tips and tricks", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                    Pack(name: "energypedia_en_all", label: "Off-grid power", note: "Solar panels, batteries and small-scale energy (Energypedia)."),
                 ]),
        Interest(id: "food", title: "Food, garden and outdoors",
                 subtitle: "Cooking, growing food, camping and knots", symbol: "leaf",
                 packs: [
                    Pack(name: "cooking.stackexchange.com_en_all", label: "Cooking questions and answers", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                    Pack(name: "gardening.stackexchange.com_en_all", label: "Gardening questions and answers", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                    Pack(name: "outdoors.stackexchange.com_en_all", label: "Outdoor skills questions and answers", note: "Camping, hiking and wilderness skills (Stack Exchange)."),
                    Pack(name: "sustainability.stackexchange.com_en_all", label: "Sustainable living questions and answers", note: "Questions answered by a community of enthusiasts (Stack Exchange)."),
                    Pack(name: "appropedia_en_all", label: "Practical sustainability projects", note: "Water, energy and building projects (Appropedia)."),
                    Pack(name: "gardenology_en_all", label: "Plant encyclopedia", note: "Growing guides for thousands of plants (Gardenology)."),
                    Pack(name: "publicdomainrecipes.com_en_all", label: "Free recipes", note: "A collection of public-domain recipes."),
                    Pack(name: "zimgit-knots_en", label: "Knots", note: "Illustrated guides to tying knots."),
                 ]),
        Interest(id: "science", title: "Science",
                 subtitle: "Physics, chemistry, biology, math, space, computers", symbol: "atom",
                 packs: [
                    Pack(name: "wikipedia_en_physics", label: "Wikipedia: Physics"),
                    Pack(name: "wikipedia_en_chemistry", label: "Wikipedia: Chemistry"),
                    Pack(name: "wikipedia_en_molcell", label: "Wikipedia: Molecular and cell biology"),
                    Pack(name: "wikipedia_en_mathematics", label: "Wikipedia: Mathematics"),
                    Pack(name: "wikipedia_en_astronomy", label: "Wikipedia: Astronomy"),
                    Pack(name: "wikipedia_en_climate-change", label: "Wikipedia: Climate change"),
                    Pack(name: "wikipedia_en_computer", label: "Wikipedia: Computers"),
                    Pack(name: "phet_en_all", label: "Interactive science simulations", note: "Hands-on science and math activities for kids (PhET)."),
                 ]),
        Interest(id: "society", title: "History, geography and travel",
                 subtitle: "History, places, society and travel guides", symbol: "globe.americas",
                 packs: [
                    Pack(name: "wikipedia_en_history", label: "Wikipedia: History"),
                    Pack(name: "wikipedia_en_geography", label: "Wikipedia: Geography"),
                    Pack(name: "wikipedia_en_sociology", label: "Wikipedia: Sociology"),
                    Pack(name: "wikivoyage_en_all", label: "Travel guides", note: "City and country guides (Wikivoyage)."),
                 ]),
        Interest(id: "learning", title: "Learning and books",
                 subtitle: "Textbooks, courses and a kids' encyclopedia", symbol: "books.vertical",
                 packs: [
                    Pack(name: "wikibooks_en_all", label: "Free textbooks", note: "Open textbooks on many subjects (Wikibooks)."),
                    Pack(name: "wikiversity_en_all", label: "Free courses", note: "Learning materials and courses (Wikiversity)."),
                    Pack(name: "vikidia_en_all", label: "Encyclopedia for kids", note: "Articles written for ages 8 to 13 (Vikidia)."),
                 ]),
        Interest(id: "books", title: "Books to read",
                 subtitle: "Free classic books from Project Gutenberg, readable offline", symbol: "books.vertical",
                 packs: [
                    Pack(name: "gutenberg_en_lcc-pz", label: "Children's books and fiction",
                         note: "Gutenberg's children's and fiction shelf."),
                    Pack(name: "gutenberg_en_lcc-pr", label: "English literature", note: "Austen, Dickens, Shakespeare and more."),
                    Pack(name: "gutenberg_en_lcc-ps", label: "American literature", note: "Twain, Alcott, Poe and more."),
                    Pack(name: "gutenberg_en_all", label: "All of Project Gutenberg (English)",
                         note: "Every English book. Very large."),
                 ]),
        Interest(id: "video", title: "Watch and learn",
                 subtitle: "Videos that play right in the app: lessons, talks and courses", symbol: "play.rectangle",
                 packs: [
                    Pack(name: "ted_mul_ted-ed", label: "TED-Ed animated lessons", note: "Short animated lessons. Great for kids."),
                    Pack(name: "ted_mul_kids", label: "TED talks for kids", note: "Short talks chosen for young viewers."),
                    Pack(name: "ted_mul_science", label: "TED: Science", note: "Short talks about science."),
                    Pack(name: "ted_mul_animals", label: "TED: Animals", note: "Short talks about animals."),
                    Pack(name: "ted_mul_space", label: "TED: Space", note: "Short talks about space."),
                    Pack(name: "crashcourse_en_all", label: "CrashCourse", note: "Full video courses in many subjects."),
                    Pack(name: "khanacademy_en_all", label: "Khan Academy",
                         note: "Lessons and practice from kindergarten to college. Very large."),
                 ]),
        Interest(id: "entertainment", title: "Sports and entertainment",
                 subtitle: "Movies, comics and sports. Off unless you want them.", symbol: "film",
                 packs: [
                    Pack(name: "wikipedia_en_movies", label: "Wikipedia: Movies"),
                    Pack(name: "wikipedia_en_comics", label: "Wikipedia: Comics"),
                    Pack(name: "wikipedia_en_football", label: "Wikipedia: Football (soccer)"),
                    Pack(name: "wikipedia_en_baseball", label: "Wikipedia: Baseball"),
                    Pack(name: "wikipedia_en_basketball", label: "Wikipedia: Basketball"),
                    Pack(name: "wikipedia_en_ice-hockey", label: "Wikipedia: Ice hockey"),
                    Pack(name: "wikipedia_en_tennis", label: "Wikipedia: Tennis"),
                    Pack(name: "wikipedia_en_golf", label: "Wikipedia: Golf"),
                 ]),
    ]
}

/// The Kiwix OPDS catalog: every English archive with its latest version, size and download link.
struct Catalog: Sendable {
    var entries: [CatalogEntry]

    static let feed = URL(string: "https://library.kiwix.org/catalog/v2/entries?lang=eng&count=-1")!

    /// Best entry for a pack name, by the picture preference.
    func entry(for name: String, pictures: PictureChoice) -> CatalogEntry? {
        let matches = entries.filter { $0.name == name }
        for flavour in pictures.preference {
            if let e = matches.filter({ $0.flavour == flavour }).max(by: { $0.issued < $1.issued }) { return e }
        }
        return matches.max { $0.issued < $1.issued }
    }

    /// Loads the catalog from Kiwix, caching it so the picker still shows sizes offline.
    static func load(cache: URL) async throws -> Catalog {
        do {
            var request = URLRequest(url: feed, timeoutInterval: 30)
            request.setValue(ProductLookup.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let catalog = try parse(data)
            try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: cache, options: .atomic)
            return catalog
        } catch {
            if let data = try? Data(contentsOf: cache), let catalog = try? parse(data), !catalog.entries.isEmpty {
                return catalog
            }
            throw error
        }
    }

    static func parse(_ data: Data) throws -> Catalog {
        let parser = OPDSParser()
        let xml = XMLParser(data: data)
        xml.delegate = parser
        guard xml.parse() else { throw xml.parserError ?? URLError(.cannotParseResponse) }
        return Catalog(entries: parser.entries)
    }
}

private final class OPDSParser: NSObject, XMLParserDelegate {
    var entries: [CatalogEntry] = []
    private var current: [String: String]?
    private var text = ""
    private var stack: [String] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        stack.append(name)
        text = ""
        if name == "entry" { current = [:] }
        if name == "link", current != nil, attributes["type"] == "application/x-zim" {
            current?["href"] = attributes["href"]
            current?["length"] = attributes["length"]
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        // <author><name> and <publisher><name> also exist; only direct children of <entry> count.
        let parent = stack.dropLast().last
        stack.removeLast()
        guard current != nil, name == "entry" || parent == "entry" else { return }
        switch name {
        case "name", "flavour", "title", "summary", "articleCount", "dc:issued", "issued":
            current?[name == "dc:issued" ? "issued" : name] = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "entry":
            if let c = current, let href = c["href"], let url = URL(string: href), let entryName = c["name"] {
                entries.append(CatalogEntry(
                    name: entryName, flavour: c["flavour"] ?? "", title: c["title"] ?? entryName,
                    summary: c["summary"] ?? "", size: Int64(c["length"] ?? "") ?? 0, metalink: url,
                    issued: String((c["issued"] ?? "").prefix(10)), articleCount: Int(c["articleCount"] ?? "") ?? 0))
            }
            current = nil
        default: break
        }
    }
}
