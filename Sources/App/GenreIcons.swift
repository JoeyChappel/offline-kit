import Foundation

/// An SF Symbol for a genre or category name. Genres come from files and the catalog, so the match is by keyword,
/// with a plain tag when nothing fits. All symbols are available on macOS, iOS and tvOS 26.
enum GenreIcon {
    static func symbol(for name: String) -> String {
        // Keys match at the start of a word, so "rap" finds "rap" but not "biography", and "children" finds "Children's".
        let words = " " + String(name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }) + " "
        for (keys, symbol) in table where keys.contains(where: { words.contains(" " + $0.replacingOccurrences(of: "-", with: " ")) }) {
            return symbol
        }
        return "tag"
    }

    /// First match wins, so specific words come before broad ones ("science fiction" before "science").
    private static let table: [([String], String)] = [
        (["science fiction", "sci-fi", "scifi", "space"], "sparkles"),
        (["fantasy", "fairy", "magic", "myth", "legend"], "wand.and.stars"),
        (["mystery", "detective", "crime", "thriller", "suspense"], "magnifyingglass"),
        (["horror", "ghost", "gothic"], "moon.stars"),
        (["adventure", "exploration", "travel"], "map"),
        (["animal", "pet", "wildlife"], "pawprint"),
        (["children", "kids", "family", "juvenile", "picture book"], "teddybear"),
        (["nature", "essay", "garden", "outdoor", "environment"], "leaf"),
        (["romance", "love"], "heart"),
        (["comedy", "humor", "humour", "funny", "satire"], "theatermasks"),
        (["drama", "play", "theater", "theatre"], "theatermasks"),
        (["documentary", "nonfiction", "non-fiction", "true story"], "globe.americas"),
        (["history", "historical", "biography", "memoir", "war"], "building.columns"),
        (["poetry", "poem", "verse"], "text.quote"),
        (["philosophy", "religion", "spiritual"], "lightbulb"),
        (["science", "physics", "biology", "chemistry", "astronomy"], "atom"),
        (["math"], "function"),
        (["animation", "cartoon", "anime"], "paintpalette"),
        (["action", "western"], "flame"),
        (["education", "learning", "lecture", "course", "how-to", "how to"], "graduationcap"),
        (["cooking", "food", "recipe"], "fork.knife"),
        (["health", "medical", "medicine", "fitness"], "cross.case"),
        (["sport"], "figure.run"),
        (["music", "musical", "concert"], "music.note"),
        (["classical", "orchestra", "symphony", "opera"], "music.quarternote.3"),
        (["jazz", "blues", "soul"], "music.mic"),
        (["electronic", "dance", "techno", "ambient", "house"], "waveform"),
        (["folk", "country", "acoustic", "bluegrass"], "guitars"),
        (["rock", "metal", "punk", "alternative", "indie"], "bolt"),
        (["pop"], "star"),
        (["hip hop", "hip-hop", "rap", "rnb"], "headphones"),
        (["soundtrack", "score"], "film"),
        (["audiobook", "story", "stories", "tale", "fiction", "novel", "classic", "literature"], "book.closed"),
        (["short", "film", "movie", "feature"], "film"),
        (["home video", "family video", "personal"], "video"),
        (["podcast", "talk", "radio"], "mic"),
    ]
}
