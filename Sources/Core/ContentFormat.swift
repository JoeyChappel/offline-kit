import Foundation

/// What kind of thing a pack or archive is, for the "Books · Video · Audio" filters.
enum ContentFormat: String, CaseIterable, Identifiable, Sendable {
    case reference, books, video, audio, games, maps, interactive
    var id: String { rawValue }

    var label: String {
        switch self {
        case .reference: "Reference"
        case .books: "Books"
        case .video: "Video"
        case .audio: "Audio"
        case .games: "Games"
        case .maps: "Maps"
        case .interactive: "Interactive"
        }
    }

    var symbol: String {
        switch self {
        case .reference: "text.book.closed"
        case .books: "books.vertical"
        case .video: "play.rectangle"
        case .audio: "headphones"
        case .games: "gamecontroller"
        case .maps: "map"
        case .interactive: "hand.tap"
        }
    }

    /// Classifies a Kiwix archive by its catalog name (e.g. "ted_mul_ted-ed", "gutenberg_en_lcc-pz").
    init(archiveName raw: String) {
        let n = raw.lowercased()
        if n.hasPrefix("gutenberg") || n.hasPrefix("wikibooks") || n.contains("onemorelibrary") || n.hasPrefix("wikisource") {
            self = .books
        } else if n.hasPrefix("ted_") || n.hasPrefix("crashcourse") || n.hasPrefix("khanacademy") || n.contains("prepper")
                    || n.hasPrefix("lrnselfreliance") || n.hasPrefix("voa_") || n.hasPrefix("coreyms") || n.hasPrefix("s2underground") {
            self = .video
        } else if n.contains("audiobook") {
            self = .audio
        } else if n.hasPrefix("maps_") {
            self = .maps
        } else if n.hasPrefix("phet") {
            self = .interactive
        } else {
            self = .reference
        }
    }
}
