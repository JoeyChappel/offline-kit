import Foundation
import Observation

// Details "Organize with AI" fills in (genre, studio, year, series…), saved in a file inside each library folder
// ("Kit Catalog.json") so they travel with the drive. Nothing here renames or moves media files.

/// One filled-in detail and where it came from.
struct CatalogField: Codable, Hashable, Sendable {
    enum Source: String, Codable, Sendable {
        case file       // the file's own tags (ID3, MP4, EPUB, ROM header)
        case library    // an article in the offline library (Wikipedia)
        case aiGuess    // the model's own knowledge: labeled "AI guess" everywhere it shows
        case user       // typed or corrected by a person: never replaced by a re-run
    }
    var value: String
    var source: Source
    /// The library article it came from, for `.library`.
    var article: String? = nil

    var label: String {
        switch source {
        case .file: "From the file"
        case .library: article.map { "From “\($0)”" } ?? "From your library"
        case .aiGuess: "AI guess"
        case .user: "Your edit"
        }
    }
}

/// The details the organizer knows about. Each is optional; nil means unknown.
struct CatalogDetails: Codable, Hashable, Sendable {
    var genre: CatalogField?
    var subgenre: CatalogField?
    /// Studio, publisher, developer or author, depending on the kind of item.
    var creator: CatalogField?
    var year: CatalogField?
    var series: CatalogField?
    var seriesOrder: CatalogField?
    /// G, PG, Teen or Mature (for a future kid mode).
    var ageRating: CatalogField?
    var summary: CatalogField?

    enum Key: String, CaseIterable, Codable, Sendable, Identifiable {
        case genre, subgenre, creator, year, series, seriesOrder, ageRating, summary
        var id: String { rawValue }
        func label(for kind: CatalogKind) -> String {
            switch self {
            case .genre: "Genre"
            case .subgenre: "Sub-genre"
            case .creator: kind.creatorLabel
            case .year: "Year"
            case .series: "Series"
            case .seriesOrder: "Number in series"
            case .ageRating: "Age rating"
            case .summary: "Description"
            }
        }
    }

    subscript(key: Key) -> CatalogField? {
        get {
            switch key {
            case .genre: genre
            case .subgenre: subgenre
            case .creator: creator
            case .year: year
            case .series: series
            case .seriesOrder: seriesOrder
            case .ageRating: ageRating
            case .summary: summary
            }
        }
        set {
            switch key {
            case .genre: genre = newValue
            case .subgenre: subgenre = newValue
            case .creator: creator = newValue
            case .year: year = newValue
            case .series: series = newValue
            case .seriesOrder: seriesOrder = newValue
            case .ageRating: ageRating = newValue
            case .summary: summary = newValue
            }
        }
    }

    var isEmpty: Bool { Key.allCases.allSatisfy { self[$0] == nil } }
    var guessedKeys: [Key] { Key.allCases.filter { self[$0]?.source == .aiGuess } }

    static let ageRatings = ["G", "PG", "Teen", "Mature"]
}

/// What kind of thing an item is, for prompts, labels and review sections.
enum CatalogKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case video, music, audiobook, book, game
    var id: String { rawValue }
    var creatorLabel: String {
        switch self {
        case .video: "Studio"
        case .music: "Label or artist"
        case .audiobook, .book: "Author"
        case .game: "Publisher or developer"
        }
    }
    var section: String {
        switch self {
        case .video: "Watch"
        case .music: "Music"
        case .audiobook: "Audiobooks"
        case .book: "Books"
        case .game: "Play"
        }
    }
    /// The word Wikipedia puts in brackets to tell same-named articles apart.
    var disambiguators: [String] {
        switch self {
        case .video: ["film", "TV series", "short film", "animated film"]
        case .music: ["album", "band", "soundtrack"]
        case .audiobook, .book: ["novel", "book", "novella", "short story"]
        case .game: ["video game"]
        }
    }
}

/// A suggestion waiting in the review screen. Nothing changes in the catalog until it's approved.
struct CatalogSuggestion: Codable, Hashable, Sendable, Identifiable {
    var key: String
    var title: String
    var kind: CatalogKind
    var proposed: CatalogDetails
    /// The article the library grounding used, if any.
    var article: String?
    var created = Date()
    var id: String { key }
}

/// The file stored in each library folder.
struct CatalogFile: Codable, Sendable {
    var version = 1
    var note = "Offline Kit catalog details (genre, studio, year, series). Written by Organize with AI and your edits. Safe to delete."
    var details: [String: CatalogDetails] = [:]
    var suggestions: [String: CatalogSuggestion] = [:]
}

@MainActor @Observable
final class KitCatalog {
    static let shared = KitCatalog()
    nonisolated static let fileName = "Kit Catalog.json"

    /// Approved details by catalog key ("media:<progress key>" or "game:<path under Games>").
    private(set) var details: [String: CatalogDetails] = [:]
    /// Waiting for review, by catalog key.
    private(set) var suggestions: [String: CatalogSuggestion] = [:]
    /// Which library folder each key is saved in.
    @ObservationIgnored private var owners: [String: URL] = [:]
    @ObservationIgnored private var loadedFolders: [String] = []
    private(set) var saveError: String?

    nonisolated static func mediaKey(_ item: MediaItem) -> String { "media:" + item.progressKey }
    nonisolated static func gameKey(_ game: Game) -> String {
        let root = GameLibrary.gamesRoot(containing: game.url).path
        let path = game.url.path
        return "game:" + (path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : game.url.lastPathComponent)
    }

    /// Reads every library folder's file. Cheap: the files are small. Call before reading `details`.
    func load(folders: [URL]) {
        let paths = folders.map { $0.standardizedFileURL.path }
        var details: [String: CatalogDetails] = [:], suggestions: [String: CatalogSuggestion] = [:], owners: [String: URL] = [:]
        for folder in folders {
            let url = folder.appending(path: Self.fileName)
            guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder.catalog.decode(CatalogFile.self, from: data) else { continue }
            for (key, value) in file.details where details[key] == nil { details[key] = value; owners[key] = folder }
            for (key, value) in file.suggestions where suggestions[key] == nil { suggestions[key] = value; owners[key] = owners[key] ?? folder }
        }
        self.details = details
        self.suggestions = suggestions
        self.owners = owners
        loadedFolders = paths
    }

    /// Library folders on this device: each Mac library folder, or the iPhone's Documents.
    static func folders(_ library: Library) -> [URL] {
        #if os(macOS)
        var list = library.folders
        let primary = KitStorage.primaryLibrary
        if !list.contains(where: { $0.standardizedFileURL.path == primary.standardizedFileURL.path }) { list.insert(primary, at: 0) }
        return list
        #else
        return [URL.documentsDirectory]
        #endif
    }

    func reload(_ library: Library) { load(folders: Self.folders(library)) }

    // MARK: Changing things

    func addSuggestion(_ suggestion: CatalogSuggestion, owner: URL) {
        suggestions[suggestion.key] = suggestion
        owners[suggestion.key] = owner
        save(owner)
    }

    /// An AI guess alone never sets an age rating: it has to come from the file, a library article or a person.
    nonisolated static func applies(_ field: CatalogDetails.Key, _ value: CatalogField) -> Bool {
        !(field == .ageRating && value.source == .aiGuess)
    }

    /// Applies a suggestion as shown (with any edits), or only the fields in `only` when given (approving field
    /// by field; the fields left out are dropped). Fields a person already set are kept.
    func approve(_ key: String, edited: CatalogDetails? = nil, only: Set<CatalogDetails.Key>? = nil) {
        guard let suggestion = suggestions[key] else { return }
        checkpoint([key], label: "Approve “\(suggestion.title)”")
        let fields = CatalogDetails.Key.allCases.filter { only?.contains($0) ?? true }
        apply(key, edited ?? suggestion.proposed, fields: fields)
        suggestions[key] = nil
        if let owner = owners[key] { save(owner) }
    }

    /// Applies only what's grounded: details from the files and from library articles. AI guesses stay waiting
    /// for a look, item by item. Returns how many suggestions still have guesses waiting.
    @discardableResult
    func approveAll(kind: CatalogKind?) -> Int {
        let keys = suggestions.values.filter { kind == nil || $0.kind == kind }.map(\.key)
        guard !keys.isEmpty else { return 0 }
        checkpoint(keys, label: "Approve All")
        let touched = Set(keys.compactMap { owners[$0] })
        var waiting = 0
        for key in keys {
            guard let suggestion = suggestions[key] else { continue }
            let grounded = CatalogDetails.Key.allCases.filter { suggestion.proposed[$0].map { $0.source != .aiGuess } ?? false }
            apply(key, suggestion.proposed, fields: grounded)
            var rest = suggestion.proposed
            for field in grounded { rest[field] = nil }
            // An AI age rating on its own is never used, so it doesn't keep a suggestion waiting.
            if rest.ageRating?.source == .aiGuess { rest.ageRating = nil }
            if rest.isEmpty { suggestions[key] = nil } else { suggestions[key]?.proposed = rest; waiting += 1 }
        }
        touched.forEach(save)
        return waiting
    }

    private func apply(_ key: String, _ proposed: CatalogDetails, fields: [CatalogDetails.Key]) {
        var current = details[key] ?? CatalogDetails()
        for field in fields where current[field]?.source != .user {
            if let value = proposed[field], Self.applies(field, value) { current[field] = value }
        }
        details[key] = current.isEmpty ? nil : current
    }

    func skip(_ key: String) {
        guard let suggestion = suggestions[key] else { return }
        checkpoint([key], label: "Skip “\(suggestion.title)”")
        suggestions[key] = nil
        if let owner = owners[key] { save(owner) }
    }

    // MARK: Undo

    private struct Checkpoint {
        let label: String
        let details: [String: CatalogDetails?]
        let suggestions: [String: CatalogSuggestion?]
    }
    @ObservationIgnored private var lastCheckpoint: Checkpoint?
    /// What "Undo" would take back ("Approve All"), or nil when there's nothing to undo.
    private(set) var undoLabel: String?

    /// Remembers how these items were before a change, for Undo. Only the last change can be undone.
    func checkpoint(_ keys: [String], label: String) {
        var d: [String: CatalogDetails?] = [:], s: [String: CatalogSuggestion?] = [:]
        for key in keys { d[key] = details[key]; s[key] = suggestions[key] }
        lastCheckpoint = Checkpoint(label: label, details: d, suggestions: s)
        undoLabel = label
    }

    /// Puts back the items the last approve, skip or edit changed, as they were just before it.
    func undo() {
        guard let last = lastCheckpoint else { return }
        for (key, value) in last.details { details[key] = value }
        for (key, value) in last.suggestions { suggestions[key] = value }
        Set(last.details.keys.compactMap { owners[$0] }).forEach(save)
        lastCheckpoint = nil
        undoLabel = nil
    }

    /// A person's own value. It wins over every automatic source and is never overwritten by a re-run.
    /// An empty value clears the field (and keeps it cleared).
    func setByUser(_ key: String, field: CatalogDetails.Key, value: String, owner: URL, undoable: Bool = true) {
        // Each edit is its own undo step (a caller that already took a checkpoint for this change passes false).
        if undoable { checkpoint([key], label: "Edit") }
        var current = details[key] ?? CatalogDetails()
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        current[field] = CatalogField(value: trimmed, source: .user)
        details[key] = current
        owners[key] = owners[key] ?? owner
        if let owner = owners[key] { save(owner) }
    }

    func owner(_ key: String) -> URL? { owners[key] }

    private func save(_ folder: URL) {
        let path = folder.standardizedFileURL.path
        var file = CatalogFile()
        for (key, value) in details where owners[key]?.standardizedFileURL.path == path { file.details[key] = value }
        for (key, value) in suggestions where owners[key]?.standardizedFileURL.path == path { file.suggestions[key] = value }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try JSONEncoder.catalog.encode(file).write(to: folder.appending(path: Self.fileName), options: .atomic)
            saveError = nil
        } catch {
            saveError = "Couldn’t save catalog details to \(folder.lastPathComponent): \(error.localizedDescription)"
        }
    }

    // MARK: Reading

    /// Approved value as text (empty values a person cleared count as nil).
    func value(_ key: String, _ field: CatalogDetails.Key) -> String? {
        guard let text = details[key]?[field]?.value, !text.isEmpty else { return nil }
        return text
    }
}

extension JSONEncoder {
    static var catalog: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var catalog: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
