import Foundation

/// Scores for Ask's answers in okit --ask-bench: whether a turn's sources are on topic, whether its citations
/// point at real sources, and whether it says "not in the library" when (and only when) it should.
///
/// Limits of the topic score, worth keeping in mind when reading it:
/// - It matches words, not meaning. "Can you get burned by boiling water on Everest?" is on topic for a burn
///   question (its title says "burned"), and a good article that names the topic only once in an unrelated title
///   ("Orthopedic boot" for a sprain) can be scored off topic.
/// - It sees the passage the model got, not the whole article: a leads-only index's lead may not name the
///   follow-up's subject ("ice") even when the article covers it.
/// - Synonyms (`synonyms`) cover the benchmark's topics, not English; a new question may need its own "|" words.
/// - It scores sources, not answers: the citation check (CitationChecker) and reading the answers do that.
enum AskQuality {
    /// One benchmark question and what an on-topic source for it is about.
    struct Question {
        let text: String
        /// Groups of word starts: a source is on topic when each group has one of its words. Empty: not scored.
        let topic: [[String]]
        /// The library doesn't cover it ("=> none"): the answer should say so.
        let uncovered: Bool
    }

    /// Conversations from a file: one question per line, "---" between conversations, "#" comments, and after
    /// "=>" the expected topic ("burn|scald; blister") or "none".
    static func conversations(file: String) -> [[Question]] {
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        var conversations: [[Question]] = [[]]
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line == "---" { if !conversations[conversations.count - 1].isEmpty { conversations.append([]) }; continue }
            if line.isEmpty || line.hasPrefix("#") { continue }
            conversations[conversations.count - 1].append(question(line))
        }
        return conversations.filter { !$0.isEmpty }
    }

    static func question(_ line: String) -> Question {
        let parts = line.components(separatedBy: "=>")
        let text = parts[0].trimmingCharacters(in: .whitespaces)
        guard parts.count > 1 else { return Question(text: text, topic: [], uncovered: false) }
        let spec = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
        if spec == "none" { return Question(text: text, topic: [], uncovered: true) }
        let groups = spec.split(separator: ";").map {
            $0.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }.filter { !$0.isEmpty }
        return Question(text: text, topic: groups, uncovered: false)
    }

    /// The old, strict test: every group has a word in the title or passage that starts with one of its entries,
    /// spelled exactly as listed.
    static func matches(_ text: String, topic: [[String]]) -> Bool {
        let lower = text.lowercased()
        return topic.allSatisfy { group in group.contains { startsWord(lower, $0) } }
    }

    /// The fairer test the benchmark scores with: every group (each entry widened by `synonyms`, and "nose bleed"
    /// also matching "nosebleed" and "nose-bleed") matches the title or passage, and the title names one of the
    /// groups or the passage names the first group, the subject, at least twice. A forum thread that mentions "cut"
    /// once while asking about elm shoots isn't about a cut; "Blister" for "burn|scald; blister" is.
    static func onTopic(title: String, text: String, topic: [[String]]) -> Bool {
        guard let subject = topic.first else { return false }
        let t = title.lowercased(), body = text.lowercased()
        let groups = topic.map(widened)
        guard groups.allSatisfy({ g in g.contains { startsWord(t, $0) || startsWord(body, $0) } }) else { return false }
        if groups.contains(where: { g in g.contains { startsWord(t, $0) } }) { return true }
        return widened(subject).reduce(0) { $0 + occurrences(body, $1) } >= 2
    }

    /// Words that name the same thing, both ways: an expected topic that lists one accepts the others. Word starts,
    /// like the topics themselves.
    static let synonyms: [[String]] = [
        ["burn", "scald"], ["child", "kid", "infant", "toddler", "baby", "pediatric", "paediatric"],
        ["fridge", "refrigerat"], ["freez", "frozen"], ["mold", "mould"], ["tire", "tyre"], ["faucet", "tap", "spigot"],
        ["nosebleed", "nose bleed", "epistaxis"], ["heart attack", "myocardial infarct"], ["faint", "syncope", "passed out"],
        ["vomit", "throw up", "throwing up"], ["wound", "lacerat", "gash"], ["gfci", "gfi", "ground fault"],
        ["outage", "blackout", "power cut", "power failure"], ["odor", "odour", "smell"], ["sprain", "twisted ankle"],
        ["hypotherm", "exposure"], ["wheez", "short of breath", "shortness of breath", "dyspn"], ["poultry", "chicken"],
        ["flashlight", "torch"], ["generator", "genset"], ["canning", "canned", "canner", "home preserv"],
    ]

    private static let synonymIndex: [String: [String]] = {
        var index: [String: [String]] = [:]
        for set in synonyms { for word in set { index[word, default: []] += set } }
        return index
    }()

    /// A group's entries with their synonyms and their one-word and hyphenated spellings.
    static func widened(_ group: [String]) -> [String] {
        var out: [String] = []
        for entry in group {
            for word in [entry] + (synonymIndex[entry] ?? []) {
                out.append(word)
                if word.contains(" ") {
                    out.append(word.replacingOccurrences(of: " ", with: ""))
                    out.append(word.replacingOccurrences(of: " ", with: "-"))
                }
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    private static func startsWord(_ text: String, _ start: String) -> Bool { occurrences(text, start, stopAt: 1) > 0 }

    /// How many words in the text start with `start` (up to `stopAt`).
    private static func occurrences(_ text: String, _ start: String, stopAt: Int = .max) -> Int {
        var from = text.startIndex, count = 0
        while count < stopAt, let r = text.range(of: start, range: from..<text.endIndex) {
            if r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter { count += 1 }
            from = r.upperBound
        }
        return count
    }

    /// The source numbers an answer cites: "[1]", "[2][3]", "[2, 3]", "[1-3]".
    static func citations(_ answer: String) -> [Int] {
        let pattern = try! NSRegularExpression(pattern: #"\[(\d+(?:\s*[,–-]\s*\d+)*)\]"#)
        var found: [Int] = []
        for m in pattern.matches(in: answer, range: NSRange(answer.startIndex..., in: answer)) {
            guard let r = Range(m.range(at: 1), in: answer) else { continue }
            let body = String(answer[r])
            for part in body.split(separator: ",") {
                let ends = part.split(whereSeparator: { $0 == "-" || $0 == "–" }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if ends.count == 2, ends[0] <= ends[1], ends[1] - ends[0] < 20 { found += Array(ends[0]...ends[1]) } else { found += ends }
            }
        }
        return found
    }

    /// The answer opens with Ask's "not in your library" sentence.
    static func saysNotFound(_ answer: String) -> Bool {
        let start = answer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().prefix(200)
        return start.contains("couldn't find this in your offline library") || start.contains("couldn’t find this in your offline library")
    }

    /// The answer repeats Ask's own instructions.
    static func echoes(_ answer: String) -> Bool { AskModel.echoesInstructions(answer) }
}
