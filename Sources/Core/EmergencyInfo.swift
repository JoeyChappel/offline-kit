import Foundation

/// Reference numbers and radio frequencies that work without the internet. United States.
/// Checked against SAMHSA, CDC, FEMA and National Weather Service pages in November 2026.
enum EmergencyInfo {
    struct Entry: Identifiable, Hashable {
        let title: String
        let value: String
        let note: String
        /// Digits to dial, when it's a phone number.
        var dial: String? = nil
        var id: String { title + value }
    }

    struct Group: Identifiable {
        let title: String
        let symbol: String
        let intro: String
        let entries: [Entry]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Call for help", symbol: "phone.fill",
              intro: "These numbers work from any phone in the US when the phone network is up. Texting often gets through when calls don’t.",
              entries: [
                Entry(title: "Emergency", value: "911", note: "Police, fire, ambulance. Text 911 where your area supports it.", dial: "911"),
                Entry(title: "Poison Help", value: "1-800-222-1222", note: "Free, 24 hours. Swallowed something, chemicals on skin or in eyes, bites and stings.", dial: "18002221222"),
                Entry(title: "988 Suicide & Crisis Lifeline", value: "988", note: "Call or text, 24 hours.", dial: "988"),
                Entry(title: "Disaster Distress Helpline", value: "1-800-985-5990", note: "Call or text, 24 hours. Emotional support after a disaster.", dial: "18009855990"),
                Entry(title: "FEMA Helpline", value: "1-800-621-3362", note: "Disaster assistance applications. TTY 1-800-462-7585.", dial: "18006213362"),
              ]),
        Group(title: "NOAA Weather Radio", symbol: "antenna.radiowaves.left.and.right",
              intro: "The National Weather Service broadcasts alerts and forecasts all day on seven channels. A regular FM radio can’t pick these up; you need a weather radio or a radio with a Weather band. Each transmitter reaches about 40 miles. Try each channel to find yours.",
              entries: [
                Entry(title: "Channel 1", value: "162.400 MHz", note: ""),
                Entry(title: "Channel 2", value: "162.425 MHz", note: ""),
                Entry(title: "Channel 3", value: "162.450 MHz", note: ""),
                Entry(title: "Channel 4", value: "162.475 MHz", note: ""),
                Entry(title: "Channel 5", value: "162.500 MHz", note: ""),
                Entry(title: "Channel 6", value: "162.525 MHz", note: ""),
                Entry(title: "Channel 7", value: "162.550 MHz", note: ""),
              ]),
        Group(title: "Two-way radio", symbol: "dot.radiowaves.left.and.right",
              intro: "Common channels for reaching other people when phones are down.",
              entries: [
                Entry(title: "CB channel 9", value: "27.065 MHz AM", note: "The traditional CB emergency channel."),
                Entry(title: "CB channel 19", value: "27.185 MHz AM", note: "Busiest CB channel; truckers and highway traffic."),
                Entry(title: "Ham 2-meter calling", value: "146.520 MHz FM", note: "National simplex calling frequency. Transmitting needs an amateur license except in a real emergency."),
                Entry(title: "Ham 70-centimeter calling", value: "446.000 MHz FM", note: "National simplex calling frequency. Transmitting needs an amateur license except in a real emergency."),
                Entry(title: "FRS walkie-talkies", value: "Channels 1–22", note: "No license needed. GMRS radios need an FCC license."),
              ]),
    ]

    /// Macs, iPhones and iPads have no radio receiver.
    static let radioNote = "Your Mac, iPhone and iPad can’t receive radio, and internet radio stops when the internet does. Keep a battery or hand-crank weather radio in your kit."
}

// MARK: - Danger words

/// A can't-miss alert shown when a question sounds like someone is in danger right now.
struct EmergencyAlert: Equatable {
    let headline: String
    let detail: String
    let number: String
    let numberLabel: String
    /// True when the words of a question raised it (a smaller banner that can be dismissed, and the sidebar stays),
    /// false when someone pressed Emergency (the whole window becomes the emergency screen).
    var detected = false
    var dial: String { number.filter(\.isNumber) }

    static let general = EmergencyAlert(
        headline: "If anyone is in danger, call 911 now.",
        detail: "Then follow the steps below while you wait. Stay calm and go one step at a time.",
        number: "911", numberLabel: "Call 911")

    /// Shown in place of `detail` before anything has been asked, when there are no steps below yet.
    static let waitingDetail = "Tell me what’s happening and I’ll give you steps. Stay calm and go one step at a time."

    // Whole words and phrases only, so "keystroke" isn't a stroke and "poison ivy" isn't a poisoning.

    /// Everyday phrases that contain a danger word but aren't one. Removed before anything else is checked.
    private static let harmless = #"\b(poison(ous)? (ivy|oak|sumac)|food poisoning|key ?strokes?|brush ?strokes?|swim(ming)? strokes?|back ?stroke|breast ?stroke|stroke of (luck|genius)|ceasefire|fire ?(wood|place|pit|starter|starting|works|fly|flies|arm|arms|extinguisher|truck|fighter|fighters|proof)|camp ?fire|bon ?fire|wild ?fire season|tornado (season|alley|shelter|safety|kit|drill)s?)\b"#

    /// Words that make a question about learning or getting ready, not something happening now.
    private static let notNow = #"(^\s*(what|which) (is|are|was|were)\b|^\s*what's\b|\b(prevent\w*|season\w*|signs? of|symptoms?|warning signs|hazards?|risks? of|how (to|do i|can i|do you|do we|should i) (prevent|avoid|prepare|get ready|plan|practice|teach|learn|tell if)|safety tips?|prepare for|preparing for|plan for|in case of|difference between|history of|learn\w*|teach\w*|practice|drill|class|course|kit|checklist|install\w*|where (should|do) (i|we) put|treatment for|recover\w*|after ?care|last (week|month|year)|years? ago)\b)"#

    /// Phrases that mean someone is in danger now, whatever else the question says.
    private static let selfHarm = #"\b(kill(ing)? myself|suicid(e|al)|end(ing)? my life|want to die|wanna die|hurt(ing)? myself|self[- ]harm\w*|take my (own )?life)\b"#
    private static let poisonNow = #"\b(swallowed|ingested|overdosed|overdosing|took too many|poisoned|(drank|drunk|ate|eaten|ingested|swallowed|licked|chewed)\b.{0,30}\b(bleach|cleaner|detergent|laundry pods?|tide pods?|antifreeze|pills?|tablets?|medicine|medication|batter(y|ies)|button batter(y|ies)|chemicals?|gasoline|lamp oil|lighter fluid|rat poison|mushrooms?|berries))\b"#
    private static let poisonMaybe = #"\b(poison|poisoning|overdose)\b"#
    private static let gasNow = #"\b(smell(s|ing)? (of )?gas|gas (leak|smell)|leaking gas|smells like gas|(co|carbon monoxide) (alarm|detector) (is )?(going off|beeping|sounding|went off))\b"#
    private static let gasMaybe = #"\b(carbon monoxide|co poisoning)\b"#
    private static let fireMaybe = #"\b(on fire|house fire|kitchen fire|grease fire|electrical fire|fire in (the|my|our)|smoke (everywhere|filling)|(house|building|room|kitchen) is (burning|full of smoke))\b"#
    private static let urgentNow = #"\b((isn't|not|stopped|has stopped|can't|cant|cannot|can not|struggling to|trouble) breath(e|ing)|unconscious|unresponsive|won'?t wake( up)?|can'?t wake (him|her|them|up)|passed out|collapsed|no pulse|no heartbeat|having (a|an) (heart attack|stroke|seizure|allergic reaction)|(is|he's|she's|i'm|im|baby's|kid's|child's|they're) choking|choking on|is drowning|face (is )?drooping|slurred speech|throat (is )?(swelling|closing)|tongue (is )?swelling|bleeding (a lot|badly|heavily|everywhere)|won'?t stop bleeding|can'?t stop (the )?bleeding|lots of blood|spurting|gunshot|been shot|got shot|was shot|stabbed|electrocuted|severe burn|(we're|we are|i'm|i am|he's|she's|they're|is|are) trapped|trapped (in|under|inside))\b"#
    private static let tornadoNow = #"\b(tornado (warning|siren|sirens|is coming|coming|on the ground|touched down|is here)|(sirens?|siren is) (going off|sounding))\b"#
    private static let floodNow = #"\b(flash flood warning|water is rising|(house|home|basement|street|road) is flooding|flood ?water (is )?(rising|coming in))\b"#
    private static let cookingFire = #"\b(grease|pan|pot|stove|stovetop|oven|cooking|frying)\b"#
    private static let urgentMaybe = #"\b(choking|seizure|heart attack|chest pain|drowning|drowned|anaphyla\w*|heat ?stroke|sun ?stroke|epipen|severe allergic)\b"#

    private static func found(_ pattern: String, in text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Looks for signs of an emergency happening now. Questions about preventing, preparing for or learning about
    /// one (and everyday phrases like "poison ivy" or "keystroke") don't raise the alert.
    static func detect(in question: String) -> EmergencyAlert? {
        var q = question.lowercased().replacingOccurrences(of: "’", with: "'")
        q = q.replacingOccurrences(of: harmless, with: " ", options: [.regularExpression, .caseInsensitive])
        let calm = found(notNow, in: q)
        func now(_ sure: String, _ maybe: String? = nil) -> Bool {
            found(sure, in: q) || (!calm && maybe.map { found($0, in: q) } == true)
        }

        if found(selfHarm, in: q) {
            return EmergencyAlert(headline: "You don’t have to go through this alone.",
                                  detail: "Call or text 988 to talk with someone now, any time. If you’re in danger, call 911.",
                                  number: "988", numberLabel: "Call 988", detected: true)
        }
        if now(poisonNow, poisonMaybe) {
            return EmergencyAlert(headline: "Call Poison Help now: 1-800-222-1222.",
                                  detail: "If they aren’t breathing, can’t wake up or are having a seizure, call 911 instead.",
                                  number: "1-800-222-1222", numberLabel: "Call Poison Help", detected: true)
        }
        if now(gasNow, gasMaybe) {
            return EmergencyAlert(headline: "Get everyone outside now, then call 911.",
                                  detail: "Don’t switch lights or appliances on or off, and don’t use a phone until you’re outside.",
                                  number: "911", numberLabel: "Call 911", detected: true)
        }
        if !calm, found(fireMaybe, in: q), found(cookingFire, in: q) {
            return EmergencyAlert(headline: "Never use water on a grease fire.",
                                  detail: "Small pan fire: slide a lid over it and turn off the heat; leave the lid on until it cools. Oven fire: turn it off and keep the door shut. If the fire spreads, get out and call 911.",
                                  number: "911", numberLabel: "Call 911", detected: true)
        }
        if found(tornadoNow, in: q) {
            return EmergencyAlert(headline: "Take shelter now.",
                                  detail: "Go to the lowest floor, into a small room in the middle of the building away from windows, like a bathroom or closet. Cover your head. Call 911 if someone is hurt.",
                                  number: "911", numberLabel: "Call 911", detected: true)
        }
        if found(floodNow, in: q) {
            return EmergencyAlert(headline: "Get to higher ground now.",
                                  detail: "Don’t walk, swim or drive through floodwater: 6 inches of moving water can knock you down. Call 911 if you’re trapped.",
                                  number: "911", numberLabel: "Call 911", detected: true)
        }
        if !calm, found(fireMaybe, in: q) {
            return EmergencyAlert(headline: "Get out and stay out, then call 911.",
                                  detail: "Don’t go back inside for anything. Close doors behind you if you can.",
                                  number: "911", numberLabel: "Call 911", detected: true)
        }
        if now(urgentNow, urgentMaybe) {
            var alert = general
            alert.detected = true
            return alert
        }
        return nil
    }

    #if DEBUG
    /// Sample questions and whether each should raise the alert. Checked at launch in debug builds (see `selfCheck`).
    static let samples: [(question: String, urgent: Bool)] = [
        ("How do I get rid of poison ivy in my yard?", false),
        ("Signs of heat stroke in a child", false),
        ("Keyboard keystroke shortcuts for my Mac", false),
        ("When is tornado season in Kansas?", false),
        ("How to prevent choking in toddlers", false),
        ("What is carbon monoxide?", false),
        ("Choking hazards for babies", false),
        ("Where should I put a carbon monoxide detector?", false),
        ("Is poison oak contagious?", false),
        ("How do I treat food poisoning at home?", false),
        ("Best firewood for a wood stove", false),
        ("How do I build a tornado shelter?", false),
        ("What are the warning signs of a stroke?", false),
        ("How do I stop a nosebleed?", false),
        ("Heart attack symptoms in women", false),
        ("What is anaphylaxis?", false),
        ("My son swallowed a button battery", true),
        ("My toddler drank bleach", true),
        ("I smell gas in the kitchen", true),
        ("The carbon monoxide alarm is going off", true),
        ("My husband is having a heart attack", true),
        ("She's not breathing", true),
        ("Baby is choking on a grape", true),
        ("He won't stop bleeding from his leg", true),
        ("Grease fire on the stove what do I do", true),
        ("There's a tornado warning, where do we go?", true),
        ("We're trapped in the basement", true),
        ("I want to kill myself", true),
        ("My dad passed out and won't wake up", true),
        ("I think my mom is having a stroke, her face is drooping", true),
        ("My child has heat stroke", true),
        ("Chest pain and sweating right now", true),
    ]

    /// Runs `samples` and returns one line per question, marking any that came out wrong.
    static func selfCheck() -> [String] {
        samples.map { sample in
            let fired = detect(in: sample.question) != nil
            return "\(fired == sample.urgent ? "ok  " : "FAIL") \(fired ? "ALERT" : "calm ") \(sample.question)"
        }
    }
    #endif
}
