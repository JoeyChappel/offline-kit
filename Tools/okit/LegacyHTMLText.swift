import Foundation

/// The answer index's HTML-to-text before the byte scanner (regular expressions), kept in okit to check the new one
/// gives the same passages: okit --html-check <file.zim>.
enum LegacyHTMLText {
    private static let dropBlocks = try! NSRegularExpression(
        pattern: "<(script|style|head|nav|footer|figure|table|sup)\\b[^>]*>.*?</\\1>",
        options: [.caseInsensitive, .dotMatchesLineSeparators])
    private static let breaks = try! NSRegularExpression(
        pattern: "</?(p|br|li|h[1-6]|div|section|tr|dd|dt|blockquote)\\b[^>]*>", options: .caseInsensitive)
    private static let tags = try! NSRegularExpression(pattern: "<[^>]+>")
    private static let numericEntity = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
    private static let spaces = try! NSRegularExpression(pattern: "[ \\t\\u00A0]+")
    private static let refMarks = try! NSRegularExpression(pattern: "\\[(\\d+|citation needed|edit)\\]")

    static func stripTags(_ s: String) -> String {
        replace(tags, in: s, with: "")
    }

    static func paragraphs(_ html: String, minLength: Int = 80) -> [String] {
        var s = html
        // Tables can nest; strip the innermost a few times.
        for _ in 0..<4 {
            let next = replace(dropBlocks, in: s, with: " ")
            if next.utf8.count == s.utf8.count { break }   // nothing left to strip
            s = next
        }
        s = replace(breaks, in: s, with: "\n")
        s = replace(tags, in: s, with: "")
        s = decodeEntities(s)
        s = replace(refMarks, in: s, with: "")
        s = replace(spaces, in: s, with: " ")
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= minLength }
    }

    private static let headingOpen = try! NSRegularExpression(pattern: "<h[2-6]\\b[^>]*>", options: .caseInsensitive)

    /// Paragraphs in reading order, each with the heading of the section it's in (nil before the first heading:
    /// the lead). Same cleanup as `paragraphs`.
    static func sections(_ html: String, minLength: Int = 80) -> [(heading: String?, text: String)] {
        var s = html
        for _ in 0..<4 {
            let next = replace(dropBlocks, in: s, with: " ")
            if next.utf8.count == s.utf8.count { break }
            s = next
        }
        s = replace(headingOpen, in: s, with: "\n\u{1}")
        s = replace(breaks, in: s, with: "\n")
        s = replace(tags, in: s, with: "")
        s = decodeEntities(s)
        s = replace(refMarks, in: s, with: "")
        s = replace(spaces, in: s, with: " ")
        var heading: String?
        var out: [(heading: String?, text: String)] = []
        for line in s.components(separatedBy: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("\u{1}") {
                let h = text.dropFirst().trimmingCharacters(in: .whitespaces)
                if !h.isEmpty { heading = h }
            } else if text.count >= minLength {
                out.append((heading, text))
            }
        }
        return out
    }

    private static func replace(_ re: NSRegularExpression, in s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t)
    }

    static func decodeEntities(_ input: String) -> String {
        var s = input
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
                       "&apos;": "'", "&ndash;": "-", "&mdash;": "-", "&minus;": "-", "&deg;": "°", "&times;": "×"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in numericEntity.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let code = UInt32(num, radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                out.unicodeScalars.append(scalar)
            }
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// The lead cut as it was (String searches).
    static func leadHTML(_ html: String) -> String {
        var searchFrom = html.startIndex
        while let heading = html.range(of: "<h2", options: .caseInsensitive, range: searchFrom..<html.endIndex) {
            if html.range(of: "<p", options: .caseInsensitive, range: html.startIndex..<heading.lowerBound) != nil {
                return String(html[..<heading.lowerBound])
            }
            searchFrom = heading.upperBound
        }
        return html
    }
}
