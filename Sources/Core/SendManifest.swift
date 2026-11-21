import Foundation

/// "Send to iPhone": what the Mac has picked for phones to download over home Wi-Fi.
/// The Mac serves this at GET /api/send; phones fetch each file from `File.url` (HTTP Range supported, so downloads resume).
enum SendKind: String, Codable, CaseIterable, Sendable {
    case video, audio, book, document, game, archive

    var label: String {
        switch self {
        case .video: "Movie or show"
        case .audio: "Audiobook or music"
        case .book: "Book"
        case .document: "PDF"
        case .game: "Game"
        case .archive: "Reference"
        }
    }

    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "headphones"
        case .book: "book"
        case .document: "doc.richtext"
        case .game: "gamecontroller"
        case .archive: "books.vertical"
        }
    }
}

struct SendManifest: Codable, Sendable {
    var name: String
    var items: [Item]

    struct Item: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var kind: SendKind
        var title: String
        var detail: String?
        var added: Double
        var files: [File]
        /// Phones that have reported this item as downloaded.
        var receivedBy: [String]
        var size: Int64 { files.reduce(0) { $0 + $1.size } }
    }

    struct File: Codable, Hashable, Sendable {
        /// Where it goes, relative to the phone's library folder: "Media/Film.mp4", "Games/DOS/game.zip", "wikipedia.zim".
        var path: String
        var size: Int64
        /// Seconds since 1970. The phone stamps the copy with it, so a fresh archive isn't mistaken for one still downloading.
        var modified: Double
        /// Server path, e.g. "/api/send/file/<item>/<index>".
        var url: String
    }

    /// True for a destination path a phone may write: inside Media, Games or Documents, or a reference archive at the top.
    /// Never absolute, never "..", never hidden, so a confused or hostile server can't write anywhere else.
    static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0.hasPrefix(".") }) else { return false }
        if parts.count == 1 { return path.lowercased().hasSuffix(".zim") }
        return ["Media", "Games", "Documents"].contains(String(parts[0]))
    }
}
