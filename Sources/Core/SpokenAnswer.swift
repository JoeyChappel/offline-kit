import Foundation

/// Turns a streamed answer into clean sentences to read aloud: no citation markers, markdown symbols or links,
/// and the "Not from the library:" heading said in words.
enum SpokenAnswer {
    /// What the listener hears in place of the "Not from the library:" heading.
    static let notFromLibrary = "The next part is not from your library. It's general knowledge, not checked against your saved references."

    /// Clean text for the synthesizer.
    static func clean(_ raw: String) -> String {
        var text = raw
        // Links: keep the words, drop the address. Then bare addresses.
        text = replace(#"\[([^\]]+)\]\((?:[^)]*)\)"#, in: text, with: "$1")
        text = replace(#"(?i)\b(?:https?://|www\.)\S+"#, in: text, with: "")
        // Citations: [3], [1, 2], [1][2], and a stray "[3" cut off mid-stream.
        text = replace(#"\[\s*\d{1,2}(?:\s*[,–-]\s*\d{1,2})*\s*\]"#, in: text, with: "")
        text = replace(#"\[\s*\d{0,2}\s*$"#, in: text, with: "")
        // Markdown symbols.
        text = replace(#"(?m)^\s{0,3}#{1,6}\s*"#, in: text, with: "")           // headings
        text = replace(#"(?m)^\s*>\s?"#, in: text, with: "")                     // quotes
        text = replace(#"(?m)^\s*[-*+•]\s+"#, in: text, with: "")               // bullets
        text = replace(#"(?m)^\s*(\d{1,2})[.)]\s+"#, in: text, with: "Step $1. ") // numbered steps
        text = replace(#"(?m)^\s*(?:-{3,}|\*{3,}|_{3,})\s*$"#, in: text, with: "") // rules
        text = replace(#"\*\*|__|`+|~~"#, in: text, with: "")
        text = replace(#"(?<![\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?![\w*])"#, in: text, with: "$1")
        text = replace(#"(?<!\w)_(?!\s)([^_\n]+?)(?<!\s)_(?!\w)"#, in: text, with: "$1")
        text = text.replacingOccurrences(of: "*", with: "")
        // The heading for general knowledge, said in words (any capitalization, with or without the colon).
        text = replace(#"(?i)not from the library\s*:?"#, in: text, with: notFromLibrary)
        // Emergency numbers digit by digit, the way people say them.
        text = replace(#"\b911\b"#, in: text, with: "9 1 1")
        text = replace(#"\b988\b"#, in: text, with: "9 8 8")
        // Tidy what the removals left behind.
        text = replace(#"[ \t]+([.,;:!?])"#, in: text, with: "$1")
        text = replace(#"\(\s*\)"#, in: text, with: "")
        text = replace(#"[ \t]{2,}"#, in: text, with: " ")
        text = replace(#"\n{2,}"#, in: text, with: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the complete sentences in `text` end: after the last line break or sentence end that's followed by
    /// more text. Everything before the returned index can be spoken now; the rest may still be streaming.
    static func speakableEnd(in text: String) -> String.Index {
        var end = text.startIndex
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            let next = text.index(after: i)
            if c == "\n" {
                end = next
            } else if ".!?".contains(c), next < text.endIndex, text[next] == " " || text[next] == "\n",
                      !isAbbreviationOrNumber(before: i, in: text) {
                end = next
            }
            i = next
        }
        return end
    }

    /// "1." at the start of a step, "e.g." and "Dr." aren't sentence ends.
    private static func isAbbreviationOrNumber(before period: String.Index, in text: String) -> Bool {
        guard text[period] == "." else { return false }
        var start = period
        while start > text.startIndex {
            let prev = text.index(before: start)
            if text[prev].isWhitespace { break }
            start = prev
        }
        let word = text[start..<period].lowercased()
        if word.isEmpty { return false }
        if word.allSatisfy(\.isNumber) { return true }
        return ["e.g", "i.e", "dr", "mr", "mrs", "ms", "st", "vs", "etc", "approx", "no", "fig", "oz", "lb", "lbs", "tsp", "tbsp"].contains(word)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}

/// Feeds a streaming answer to a reader one finished sentence at a time.
struct SpokenAnswerStream {
    /// The raw text already handed out.
    private(set) var consumed = ""

    /// New speakable text since the last call. When `final`, everything left. When the answer was restarted
    /// (a retry with fewer sources), `restarted` is true and the caller should drop what it queued.
    mutating func next(answer: String, final: Bool) -> (text: String, restarted: Bool) {
        var restarted = false
        if !answer.hasPrefix(consumed) {
            consumed = ""
            restarted = true
        }
        let rest = String(answer.dropFirst(consumed.count))
        let chunk = final ? rest : String(rest[..<SpokenAnswer.speakableEnd(in: rest)])
        consumed += chunk
        return (SpokenAnswer.clean(chunk), restarted)
    }

    mutating func reset() { consumed = "" }
}
