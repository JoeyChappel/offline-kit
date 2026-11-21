import Foundation

/// An official page a safety figure came from. Every figure in the power-out guide and the calculators was
/// checked against these pages on `SafetySources.checkedOn`; nothing here is from memory.
struct SafetySource: Identifiable, Hashable, Sendable {
    let id: String
    let publisher: String
    let title: String
    let url: String
    var link: URL? { URL(string: url) }
}

enum SafetySources {
    static let checkedOn = "November 20, 2026"

    static let cdcFood = SafetySource(id: "cdc-food", publisher: "CDC", title: "Keep Food Safe After a Disaster or Emergency",
                                      url: "https://www.cdc.gov/food-safety/foods/keep-food-safe-after-emergency.html")
    static let foodOutage = SafetySource(id: "foodsafety-outage", publisher: "FoodSafety.gov", title: "Food Safety During Power Outage",
                                         url: "https://www.foodsafety.gov/food-safety-charts/food-safety-during-power-outage")
    static let fsis = SafetySource(id: "fsis-emergencies", publisher: "USDA FSIS", title: "Keep Your Food Safe During Emergencies",
                                   url: "https://www.fsis.usda.gov/food-safety/safe-food-handling-and-preparation/emergencies/keep-your-food-safe-during-emergencies")
    static let fda = SafetySource(id: "fda-outage", publisher: "FDA", title: "Food and Water Safety During Power Outages and Floods",
                                  url: "https://www.fda.gov/food/buy-store-serve-safe-food/food-and-water-safety-during-power-outages-and-floods")
    static let cdcCO = SafetySource(id: "cdc-co", publisher: "CDC", title: "Carbon Monoxide (CO) Poisoning Basics",
                                    url: "https://www.cdc.gov/carbon-monoxide/about/index.html")
    static let cpscCO = SafetySource(id: "cpsc-co", publisher: "CPSC", title: "Carbon Monoxide Information Center",
                                     url: "https://www.cpsc.gov/Safety-Education/Safety-Education-Centers/Carbon-Monoxide-Information-Center")
    static let generatorRefuel = SafetySource(id: "cpsc-generators", publisher: "CPSC", title: "Safety Alert: Portable Generators",
                                              url: "https://www.cpsc.gov/s3fs-public/5123_SafetyAlert_PortableGenerators_102021.pdf")
    static let cpscIndoors = SafetySource(id: "cpsc-2026", publisher: "CPSC", title: "CPSC Warns of Generator, Carbon Monoxide and Fire Hazards",
                                          url: "https://www.cpsc.gov/Newsroom/News-Releases/2026/CPSC-Warns-of-Generator-Carbon-Monoxide-and-Fire-Hazards-Ahead-of-Hurricane-Season")
    static let readyOutage = SafetySource(id: "ready-outage", publisher: "Ready.gov", title: "Power Outages",
                                          url: "https://www.ready.gov/power-outages")
    static let readySheet = SafetySource(id: "ready-sheet", publisher: "Ready.gov", title: "Be Prepared for a Power Outage (info sheet)",
                                         url: "https://www.ready.gov/sites/default/files/2024-03/ready.gov_power-outage_hazard-info-sheet.pdf")
    static let epaBleach = SafetySource(id: "epa-disinfection", publisher: "EPA", title: "Emergency Disinfection of Drinking Water",
                                        url: "https://www.epa.gov/ground-water-and-drinking-water/emergency-disinfection-drinking-water")
    static let readyWater = SafetySource(id: "ready-water", publisher: "Ready.gov", title: "Water", url: "https://www.ready.gov/water")
    static let readyKit = SafetySource(id: "ready-kit", publisher: "Ready.gov", title: "Build A Kit", url: "https://www.ready.gov/kit")
    static let cdcBoil = SafetySource(id: "cdc-boil", publisher: "CDC", title: "Boil Water Advisory",
                                      url: "https://www.cdc.gov/natural-disasters/psa-toolkit/boil-water-advisory.html")
    static let cdcAdvisories = SafetySource(id: "cdc-advisories", publisher: "CDC", title: "Drinking Water Advisories: An Overview",
                                            url: "https://www.cdc.gov/water-emergency/about/drinking-water-advisories-an-overview.html")
    static let eweb = SafetySource(id: "eweb-generator", publisher: "EWEB (Eugene Water & Electric Board)", title: "Generator Sizing Considerations",
                                   url: "https://www.eweb.org/documents/emergency-preparedness/generator-sizing-considerations.pdf")
    static let pvwatts = SafetySource(id: "nrel-pvwatts", publisher: "NREL", title: "PVWatts Version 5 Manual (default system losses)",
                                      url: "https://docs.nlr.gov/docs/fy14osti/62641.pdf")
}

/// One part of the power-out guide: shown in Prepare › Power out, and searchable by Ask.
struct GuideSection: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    let intro: String
    let points: [String]
    let sources: [SafetySource]
    /// Extra words people use for this topic, for Ask's search only (never shown).
    var keywords = ""

    var plainText: String {
        ([intro] + points).joined(separator: "\n")
            + "\nSources: " + sources.map { "\($0.publisher), \($0.title)" }.joined(separator: "; ")
    }
}

/// Offline Kit's built-in "The power's out" guide. Every figure is from the official pages in `SafetySources`.
enum PowerOutGuide {
    static let bookID = "offlinekit-guide"
    static let bookTitle = "Offline Kit power-out guide"

    // Food-safety limits with the doors kept closed (CDC, FSIS, FDA).
    static let fridgeHours: Double = 4
    static let fullFreezerHours: Double = 48
    static let halfFreezerHours: Double = 24

    static let fridgeSafeNote = "Keep the door shut. With it closed, a refrigerator keeps food safe for up to 4 hours."
    /// FoodSafety.gov's wording ("Food Safety During Power Outage"), checked November 2026.
    static let fridgePastNote = "Discard refrigerated perishable food such as meat, poultry, fish, eggs, milk and leftovers after 4 hours without power or a cold source like dry ice. Never taste it to check."
    static let freezerSafeNote = "Keep the door shut. A full freezer holds its temperature for about 48 hours, a half-full one about 24 hours."
    static let freezerPastNote = "Check each package. Food that still has ice crystals or is at 40 °F or below can be refrozen or cooked. When in doubt, throw it out."

    struct Alert: Sendable {
        let id: String
        let hours: Double
        let title: String
        let body: String
    }

    /// Notifications at the limits, counted from when the power went out.
    static func alerts(freezerFull: Bool) -> [Alert] {
        [
            Alert(id: "fridge", hours: fridgeHours, title: "Fridge food: 4 hours",
                  body: "The power’s been out 4 hours. Unless it’s been kept cold with ice or dry ice, discard refrigerated perishable food such as meat, poultry, fish, eggs, milk and leftovers."),
            freezerFull
                ? Alert(id: "freezer", hours: fullFreezerHours, title: "Full freezer: 48 hours",
                        body: "A full freezer holds its temperature about 48 hours with the door shut. Check each package: ice crystals or 40 °F or below can be refrozen.")
                : Alert(id: "freezer", hours: halfFreezerHours, title: "Half-full freezer: 24 hours",
                        body: "A half-full freezer holds its temperature about 24 hours with the door shut. Check each package: ice crystals or 40 °F or below can be refrozen."),
        ]
    }

    static let foodID = "food", returnsID = "power-returns", generatorID = "generator", waterID = "water", checklistID = "checklist"

    static let sections: [GuideSection] = [
        GuideSection(
            id: foodID, title: "Fridge and freezer food in a power outage", symbol: "snowflake",
            intro: "Keep the refrigerator and freezer doors closed. How long food stays safe when the power is out depends on it.",
            points: [
                "Discard refrigerated perishable food such as meat, poultry, fish, eggs, milk and leftovers after 4 hours without power or a cold source like dry ice (FoodSafety.gov).",
                "With the doors closed, food stays safe for up to 4 hours in a refrigerator, 48 hours (2 days) in a full freezer and 24 hours (1 day) in a half-full freezer.",
                "A safe refrigerator is at 40 °F (4 °C) or below. A safe freezer is at 0 °F or below. Keep an appliance thermometer in each.",
                "If you can’t keep it cold: Ready.gov says to throw away any food that has been at 40 °F or higher for 2 hours or more, or that has an unusual odor, color or texture.",
                "If someone’s life depends on a refrigerated medicine, such as insulin, don’t stop taking it: ask a doctor or pharmacist, and keep using it until a new supply is available. Other medication that should be refrigerated: discard it if the power is out for more than a day, unless the label says otherwise (Ready.gov).",
                "Frozen food that still has ice crystals or is at 40 °F or below is still safe: it can be refrozen or cooked, though its quality may suffer.",
                "For a long outage, get dry ice or block ice. Fifty pounds of dry ice should hold a full 18-cubic-foot freezer for 2 days. Don’t touch dry ice with bare hands or put it directly on food, and keep the room aired out: dry ice gives off carbon dioxide.",
                "You can also move food to a cooler with ice or frozen gel packs. Use enough ice to keep it at 40 °F or below.",
                "Never taste food to find out if it’s safe. When in doubt, throw it out.",
            ],
            sources: [SafetySources.cdcFood, SafetySources.fsis, SafetySources.foodOutage, SafetySources.fda, SafetySources.readyOutage],
            keywords: "fridge refrigerator freezer frozen food spoil spoiled safe eat good bad long hours days thaw thawed outage blackout power out cooler ice meat milk medicine medication insulin refrigerated"),
        GuideSection(
            id: returnsID, title: "When the power comes back on", symbol: "bolt.fill",
            intro: "Check the food before you use it.",
            points: [
                "If the freezer thermometer reads 40 °F or below, the food is safe and may be refrozen.",
                "No thermometer in the freezer? Check each package of food. You can’t rely on how it looks or smells.",
                "Thawed food that still has ice crystals or is at 40 °F or below can be safely refrozen or cooked.",
                "If the power was out no more than 4 hours and the doors stayed closed, refrigerated food should be safe.",
                "Otherwise, throw away refrigerated perishables that were above 40 °F for more than 2 hours. When in doubt, throw it out.",
            ],
            sources: [SafetySources.fda, SafetySources.foodOutage, SafetySources.cdcFood],
            keywords: "power back restored returns came on again outage blackout refreeze thawed fridge refrigerator freezer food safe eat keep"),
        GuideSection(
            id: generatorID, title: "Generator safety and carbon monoxide", symbol: "exclamationmark.triangle",
            intro: "Generator exhaust has carbon monoxide (CO), an odorless, colorless gas that can kill without warning.",
            points: [
                "Only run a generator outside, more than 20 feet away from any windows, doors and vents.",
                "Never run it inside a home, garage, basement, crawlspace or shed, even with doors or windows open.",
                "Use battery-powered or battery-backup CO alarms on every level of your home and near every sleeping area. Test them monthly.",
                "Signs of CO poisoning: headache, dizziness, weakness, upset stomach, vomiting, chest pain and confusion. If you suspect it, get outside to fresh air right away, then call 911.",
                "Turn the generator off and let it cool down before refueling. Gasoline spilled on hot engine parts could ignite.",
                "Never plug the generator into a wall outlet to power the house (“backfeeding”). It can electrocute utility workers and neighbors.",
                "Plug appliances into the generator with heavy-duty extension cords made for outdoor use.",
            ],
            sources: [SafetySources.cdcCO, SafetySources.cpscIndoors, SafetySources.cpscCO, SafetySources.generatorRefuel],
            keywords: "generator portable carbon monoxide co poisoning fumes exhaust distance far away feet place put run from house home window door garage indoors inside outside refuel gas gasoline fuel extension cord backfeed alarm detector power outage"),
        GuideSection(
            id: waterID, title: "Is the water safe?", symbol: "drop",
            intro: "Follow your local officials. If they say to boil water, boil it or use bottled water.",
            points: [
                "If local officials issue a boil water advisory, use commercially bottled water or boil your tap water.",
                "Boiling does not remove chemicals. Listen to local authorities about drinking boiled or bottled water.",
                "To boil: bring clear water to a rolling boil for 1 minute. Above 5,000 feet, boil for 3 minutes.",
                "Cloudy water: let it settle, then filter it through a clean cloth, paper towel or coffee filter.",
                "Can’t boil? Use regular unscented bleach (not color-safe or with added cleaners): 8 drops of 6% bleach or 6 drops of 8.25% bleach per gallon. Double it if the water is cloudy, colored or very cold. For any other strength, boil the water or use bottled water.",
                "Bleach doesn’t kill every germ (Cryptosporidium survives it), so boiling is better whenever you can.",
                "Stir and let it stand 30 minutes. It should smell slightly of chlorine. If not, repeat the dose and wait another 15 minutes. If it still doesn’t, throw it out and find another source.",
                "Store at least 1 gallon of water per person per day for at least 3 days, for drinking and sanitation. A 2-week supply is better at home.",
                "Fill your own containers only if they’re food-grade water storage containers. Replace water that isn’t commercially bottled every six months.",
            ],
            sources: [SafetySources.cdcAdvisories, SafetySources.cdcBoil, SafetySources.epaBleach, SafetySources.readyWater],
            keywords: "water drinking tap safe purify purification disinfect treat clean bleach chlorine drops gallon liter boil boiling advisory store storage much per person outage"),
        GuideSection(
            id: checklistID, title: "Power-out checklist", symbol: "checklist",
            intro: "Tick these off as you go.",
            points: [
                "Use flashlights, lanterns and other battery-powered lights, not candles, to lower the risk of fire.",
                "Keep phones charged. Use a portable charger or power bank.",
                "Unplug appliances and electronics to avoid damage from electrical surges.",
                "Keep the refrigerator and freezer closed. Put a thermometer in each.",
                "Make a plan for medicines that need the fridge and for medical devices that need power.",
                "Don’t use a gas stove or oven to heat your home. It raises the risk of carbon monoxide poisoning.",
                "If heat or cold is extreme, go to a community location with power. Ask local officials which heating and cooling locations are open.",
                "Check on family members and neighbors if it is safe to do so.",
            ],
            sources: [SafetySources.readyOutage, SafetySources.readySheet],
            keywords: "power outage blackout electricity out what to do first checklist flashlight light phone charge unplug surge heat cold warm cool neighbors medicine medical device"),
    ]

    static func section(_ id: String) -> GuideSection? { sections.first { $0.id == id } }

    /// A plain page for one section, for phones that open a citation over Wi-Fi sharing.
    static func html(section id: String) -> String? {
        guard let section = section(id) else { return nil }
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        let points = section.points.map { "<li>\(esc($0))</li>" }.joined()
        let sources = section.sources.map { "<li>\(esc($0.publisher)): <a href=\"\(esc($0.url))\">\(esc($0.title))</a></li>" }.joined()
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(section.title))</title>
        <style>body{font:17px/1.5 -apple-system,system-ui,sans-serif;max-width:680px;margin:0 auto;padding:20px;color:#1d1d1f}
        @media (prefers-color-scheme:dark){body{background:#111;color:#eee}a{color:#7cc}}li{margin:6px 0}small{color:#888}</style></head>
        <body><small>\(esc(bookTitle))</small><h1>\(esc(section.title))</h1><p>\(esc(section.intro))</p><ul>\(points)</ul>
        <h3>Sources</h3><ul>\(sources)</ul><small>Checked \(SafetySources.checkedOn). Links need internet.</small></body></html>
        """
    }

    struct Match: Sendable {
        let ref: ArticleRef
        let text: String
        let score: Double
    }

    /// Guide sections that answer the question, scored like a PDF page so they compete fairly with the library.
    static func matches(terms: [String], phrases: [String], limit: Int = 2) -> [Match] {
        sections.compactMap { section -> Match? in
            // The topic words count like a title: a section on generators is about "how far", "fumes" and "feet".
            let (score, coverage) = Retriever.textRelevance(title: (section.title + " " + section.keywords).lowercased(),
                                                            text: section.plainText.lowercased(),
                                                            terms: terms, phrases: phrases)
            guard coverage >= 0.6 else { return nil }
            return Match(ref: ArticleRef(bookID: bookID, path: section.id, title: section.title), text: section.plainText, score: score)
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }
    }
}

/// Household bleach for drinking water, from EPA's table (unscented bleach).
enum WaterDisinfection {
    struct Strength: Identifiable, Hashable, Sendable {
        let id: String
        let label: String
        let dropsPerGallon: Double
        let dropsPerLiter: Double
        /// "6%", for sentences.
        var percent: String { id + "%" }
    }

    /// EPA's table: 1 quart/liter → 2 drops for both strengths; 1 gallon → 8 drops (6%) or 6 drops (8.25%).
    static let strengths: [Strength] = [
        Strength(id: "6", label: "6% (regular bleach)", dropsPerGallon: 8, dropsPerLiter: 2),
        Strength(id: "8.25", label: "8.25%", dropsPerGallon: 6, dropsPerLiter: 2),
    ]

    /// EPA's table, verbatim, for reference under the calculator.
    static let tableRows: [(water: String, six: String, eight: String)] = [
        ("1 quart/liter", "2 drops", "2 drops"),
        ("1 gallon", "8 drops", "6 drops"),
        ("2 gallons", "16 drops (1/4 tsp)", "12 drops (1/8 teaspoon)"),
        ("4 gallons", "1/3 teaspoon", "1/4 teaspoon"),
        ("8 gallons", "2/3 teaspoon", "1/2 teaspoon"),
    ]

    static let afterAdding = "Stir and let stand 30 minutes. It should smell slightly of chlorine."
    static let cloudyFirst = "Let cloudy water settle, then filter it through a clean cloth, paper towel or coffee filter before adding bleach."
    static let warning = "Use only regular, unscented bleach (not color-safe or with added cleaners). No odor after 30 minutes? Repeat the dose and wait 15 more minutes. Still none? Throw it out and find another source."

    static let assumptions = [
        "EPA’s figures are for unscented household bleach at the strength shown on the label. EPA gives figures only for 6% and 8.25%.",
        "Cloudy, colored or very cold water gets double the bleach (EPA).",
        "Quarts and liters both use EPA’s 2-drop figure, so liters are worked out per liter rather than converted from gallons. EPA rounds its liter and gallon figures separately, so 4 liters (8 drops) and 1 gallon (6 drops of 8.25% bleach) don’t match exactly. Both are EPA’s own figures.",
        "Boiling (a rolling boil for at least 1 minute) is the alternative when you can heat water.",
    ]
}

/// Typical generator loads from EWEB's sizing worksheet. "Extra to start" is EWEB's "Additional Starting Watts".
enum ApplianceWatts {
    static let sourceName = "EWEB’s generator sizing worksheet"
    static let sources = [SafetySources.eweb, SafetySources.generatorRefuel]

    struct Typical: Sendable {
        let id: String
        let name: String
        let running: Double
        let extra: Double
    }

    static let typical: [Typical] = [
        Typical(id: "fridge", name: "Refrigerator/freezer", running: 700, extra: 2_200),
        Typical(id: "sump-third", name: "Sump pump, 1/3 HP", running: 800, extra: 1_300),
        Typical(id: "sump-half", name: "Sump pump, 1/2 HP", running: 1_050, extra: 2_200),
        Typical(id: "well-third", name: "Well pump, 1/3 HP", running: 1_000, extra: 2_000),
        Typical(id: "furnace-fan", name: "Furnace fan blower, 1/3 HP", running: 700, extra: 1_400),
        Typical(id: "window-ac", name: "Window AC, 12,000 BTU", running: 3_250, extra: 3_950),
        Typical(id: "space-heater", name: "Space heater", running: 1_500, extra: 0),
        Typical(id: "water-heater", name: "Electric water heater", running: 4_500, extra: 0),
        Typical(id: "microwave", name: "Microwave, 1,000 W", running: 1_000, extra: 0),
        Typical(id: "coffee", name: "Coffee maker", running: 1_000, extra: 0),
        Typical(id: "toaster", name: "Toaster", running: 850, extra: 0),
        Typical(id: "tv", name: "Color TV", running: 400, extra: 0),
        Typical(id: "computer", name: "Computer with monitor", running: 800, extra: 0),
        Typical(id: "laptop", name: "Laptop", running: 60, extra: 0),
        Typical(id: "radio", name: "AM/FM radio", running: 100, extra: 0),
        Typical(id: "led", name: "LED light bulb", running: 15, extra: 0),
        Typical(id: "phone", name: "Cell phone charger", running: 20, extra: 0),
    ]
}

/// Solar sizing defaults. Only the system-loss default is a published figure (NREL PVWatts).
enum SolarDefaults {
    /// PVWatts Version 5 manual: "Total system losses are specified as a percentage, with a default value of 14 %."
    static let systemLossesPercent: Double = 14
    static let sources = [SafetySources.pvwatts]
    static let assumptions = [
        "Peak sun hours depend on where you live and the season. Use a figure for your location; winter is lowest.",
        "System losses start at 14%, NREL PVWatts’ default (soiling, shading, wiring and similar). Inverter losses are extra.",
        "Share of the battery you’ll use: check your battery’s datasheet for its recommended depth of discharge. Blank means 100%.",
        "Days of backup covers cloudy days when the panels make little or nothing.",
    ]
}
