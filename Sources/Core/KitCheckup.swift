import Foundation

/// Kit checkup: how old each reference is, what space the library uses, and what's broken.
/// Everything here reads the disk only; fixes live in `KitCheckup.Fix` and run only after the person confirms.
enum KitCheckup {
    /// References older than this get flagged. Kiwix rebuilds most archives every few months.
    static let defaultStaleMonths = 12

    // MARK: Ages

    struct Dated: Identifiable, Sendable, Hashable {
        enum Kind: String, Sendable { case reference, map, model }
        let url: URL
        let title: String
        let kind: Kind
        let size: Int64
        /// When the content was made: the ZIM "Date" metadata, else the date in the file name.
        let contentDate: Date?
        /// Where the date came from, said plainly ("archive date", "file name", "file saved").
        let dateSource: String
        var id: String { url.path }

        func monthsOld(now: Date = Date()) -> Int? {
            guard let contentDate else { return nil }
            return Calendar(identifier: .gregorian).dateComponents([.month], from: contentDate, to: now).month
        }

        func isStale(months: Int, now: Date = Date()) -> Bool {
            guard kind != .model, let age = monthsOld(now: now) else { return false }
            return age >= months
        }
    }

    /// "2024-08-15" or "2024-08" from metadata, or the "_2024-08" in a Kiwix file name.
    static func parseDate(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count >= 2, (1990...2100).contains(parts[0]), (1...12).contains(parts[1]) else { return nil }
        return DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: .gmt,
                              year: parts[0], month: parts[1], day: parts.count > 2 ? parts[2] : 1).date
    }

    static func dateInFileName(_ name: String) -> Date? {
        guard let range = name.range(of: #"_(\d{4}-\d{2})\.zim$"#, options: .regularExpression) else { return nil }
        return parseDate(String(name[range].dropFirst().prefix(7)))
    }

    /// Reads each archive's content date. Runs off the main thread (metadata reads touch the disk).
    nonisolated static func ages(of books: [(archive: ZimArchive, url: URL, size: Int64)], models: [(url: URL, title: String, size: Int64)]) -> [Dated] {
        var list: [Dated] = books.map { book in
            let isMap = book.archive.name.hasPrefix("maps_") || book.url.lastPathComponent.hasPrefix("maps_")
            if let date = parseDate(book.archive.metadata("Date")) {
                return Dated(url: book.url, title: book.archive.title, kind: isMap ? .map : .reference, size: book.size,
                             contentDate: date, dateSource: "archive date")
            }
            let fromName = dateInFileName(book.url.lastPathComponent)
            return Dated(url: book.url, title: book.archive.title, kind: isMap ? .map : .reference, size: book.size,
                         contentDate: fromName, dateSource: fromName == nil ? "no date in the file" : "file name")
        }
        // GGUF model files carry no build date. The date the file was saved is shown, never flagged.
        for model in models {
            let saved = (try? model.url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            list.append(Dated(url: model.url, title: model.title, kind: .model, size: model.size,
                              contentDate: saved, dateSource: saved == nil ? "no date in the file" : "file saved"))
        }
        return list.sorted { ($0.contentDate ?? .distantPast) < ($1.contentDate ?? .distantPast) }
    }

    // MARK: Space

    enum SpaceKind: String, CaseIterable, Identifiable, Sendable {
        case references, maps, media, games, models, documents, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .references: "References"
            case .maps: "Maps"
            case .media: "Watch, listen and read"
            case .games: "Games"
            case .models: "Answer models"
            case .documents: "Documents"
            case .other: "Other"
            }
        }
        var symbol: String {
            switch self {
            case .references: "books.vertical"
            case .maps: "map"
            case .media: "play.rectangle"
            case .games: "gamecontroller"
            case .models: "cpu"
            case .documents: "doc.text"
            case .other: "folder"
            }
        }
    }

    struct Space: Identifiable, Sendable {
        let folder: URL
        let driveName: String
        let free: Int64
        let capacity: Int64
        var bytes: [SpaceKind: Int64]
        var id: String { folder.path }
        var total: Int64 { bytes.values.reduce(0, +) }
        /// Under 5 GB or under 5% of the drive.
        var isLow: Bool { free < 5_000_000_000 || (capacity > 0 && Double(free) / Double(capacity) < 0.05) }
    }

    static func kind(of url: URL, in library: URL) -> SpaceKind {
        let relative = url.standardizedFileURL.path.dropFirst(library.standardizedFileURL.path.count + 1)
        let top = relative.split(separator: "/").first.map(String.init) ?? ""
        switch top {
        case "Media": return .media
        case "Games": return .games
        case "Models": return .models
        case "Documents": return .documents
        default:
            let name = url.lastPathComponent
            if url.pathExtension.lowercased() == "zim" { return name.hasPrefix("maps_") ? .maps : .references }
            return .other
        }
    }

    nonisolated static func space(of library: URL) -> Space {
        let fm = FileManager.default
        var bytes: [SpaceKind: Int64] = [:]
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        if let walker = fm.enumerator(at: library, includingPropertiesForKeys: keys, options: []) {
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                if url.lastPathComponent.hasPrefix("._") { continue }
                bytes[kind(of: url, in: library), default: 0] += Int64(values.fileSize ?? 0)
            }
        }
        let volume = try? library.resourceValues(forKeys: [.volumeLocalizedNameKey, .volumeAvailableCapacityKey,
                                                            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
        let free = max(volume?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(volume?.volumeAvailableCapacity ?? 0))
        return Space(folder: library, driveName: volume?.volumeLocalizedName ?? "This device", free: free,
                     capacity: Int64(volume?.volumeTotalCapacity ?? 0), bytes: bytes)
    }

    // MARK: Health

    struct BrokenLink: Identifiable, Sendable, Hashable {
        let link: URL
        let target: String
        var id: String { link.path }
    }

    /// One unfinished download: its partial file and the saved progress beside it.
    struct Partial: Identifiable, Sendable, Hashable {
        let fileName: String          // what it would be called when finished
        let folder: URL
        let files: [URL]              // .part, .okdl, .aria2 pieces on disk
        let size: Int64
        var id: String { folder.path + "/" + fileName }
    }

    /// An older copy of an archive that also has a newer copy installed (left by a refresh that was interrupted).
    struct OlderCopy: Identifiable, Sendable, Hashable {
        let old: URL
        let newer: URL
        let size: Int64
        var id: String { old.path }
    }

    struct Health: Sendable {
        var brokenLinks: [BrokenLink] = []
        var partials: [Partial] = []
        var olderCopies: [OlderCopy] = []
    }

    static let partialExtensions: Set<String> = [ChunkedDownload.partExtension, ChunkedDownload.stateExtension, "aria2", "okcopy"]

    /// Broken symlinks anywhere in the library, and partial downloads.
    nonisolated static func health(of libraries: [URL]) -> Health {
        let fm = FileManager.default
        var health = Health()
        var partials: [String: (folder: URL, name: String, files: [URL], size: Int64)] = [:]
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .fileSizeKey]
        for library in libraries {
            guard let walker = fm.enumerator(at: library, includingPropertiesForKeys: keys, options: []) else { continue }
            for case let url as URL in walker {
                let name = url.lastPathComponent
                if name.hasPrefix("._") || name == ".Trashes" || name == ".Spotlight-V100" || name == ".fseventsd" {
                    walker.skipDescendants(); continue
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true {
                    // fileExists follows the link: false means its target is gone (a drive moved or was renamed).
                    if !fm.fileExists(atPath: url.path) {
                        let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? "?"
                        health.brokenLinks.append(BrokenLink(link: url, target: target))
                    }
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard partialExtensions.contains(ext) else { continue }
                let finished = url.deletingPathExtension().lastPathComponent
                let key = url.deletingLastPathComponent().path + "/" + finished
                var entry = partials[key] ?? (url.deletingLastPathComponent(), finished, [], 0)
                entry.files.append(url)
                entry.size += Int64(values?.fileSize ?? 0)
                partials[key] = entry
            }
        }
        health.partials = partials.values
            .map { Partial(fileName: $0.name, folder: $0.folder, files: $0.files.sorted { $0.path < $1.path }, size: $0.size) }
            .sorted { $0.fileName < $1.fileName }
        health.brokenLinks.sort { $0.link.path < $1.link.path }
        return health
    }

    /// The part of a Kiwix file name that stays the same between versions: "wikipedia_en_medicine_maxi".
    static func seriesKey(_ fileName: String) -> String? {
        guard let range = fileName.range(of: #"_\d{4}-\d{2}\.zim$"#, options: .regularExpression) else { return nil }
        return String(fileName[..<range.lowerBound])
    }

    /// Archives installed twice: the same series in two dated files.
    static func olderCopies(_ files: [(url: URL, size: Int64)]) -> [OlderCopy] {
        var bySeries: [String: [(url: URL, size: Int64)]] = [:]
        for file in files {
            guard let key = seriesKey(file.url.lastPathComponent) else { continue }
            bySeries[key, default: []].append(file)
        }
        var result: [OlderCopy] = []
        for (_, group) in bySeries where group.count > 1 {
            let sorted = group.sorted { $0.url.lastPathComponent > $1.url.lastPathComponent }   // newest date first
            for old in sorted.dropFirst() { result.append(OlderCopy(old: old.url, newer: sorted[0].url, size: old.size)) }
        }
        return result.sorted { $0.old.lastPathComponent < $1.old.lastPathComponent }
    }

    // MARK: Fixes

    /// Removes the given files and links. Only paths the person saw in the list are passed in.
    /// A broken symlink is removed itself; its (missing) target is never touched.
    nonisolated static func remove(_ urls: [URL]) -> (removed: Int, failed: [(URL, String)]) {
        var removed = 0
        var failed: [(URL, String)] = []
        for url in urls {
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
                // exFAT keeps a "._name" companion beside each file.
                let companion = url.deletingLastPathComponent().appending(path: "._" + url.lastPathComponent)
                if (try? companion.checkResourceIsReachable()) == true { try? FileManager.default.removeItem(at: companion) }
            } catch {
                failed.append((url, error.localizedDescription))
            }
        }
        return (removed, failed)
    }

    // MARK: Area

    private static let usStates: [String] = [
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado", "connecticut", "delaware", "florida",
        "georgia", "hawaii", "idaho", "illinois", "indiana", "iowa", "kansas", "kentucky", "louisiana", "maine",
        "maryland", "massachusetts", "michigan", "minnesota", "mississippi", "missouri", "montana", "nebraska",
        "nevada", "new hampshire", "new jersey", "new mexico", "new york", "north carolina", "north dakota", "ohio",
        "oklahoma", "oregon", "pennsylvania", "rhode island", "south carolina", "south dakota", "tennessee", "texas",
        "utah", "vermont", "virginia", "washington", "west virginia", "wisconsin", "wyoming", "usa", "united states",
    ]
    private static let usAbbreviations: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME",
        "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR", "PA",
        "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY", "US", "USA", "DC",
    ]

    /// The Kiwix map for the place written in Prepare › Home ("Springfield, Illinois" → the United States map).
    /// `mapNames` are the maps the catalog has. Nil when the place doesn't name a country or US state we know.
    static func mapName(forArea area: String, mapNames: Set<String>) -> String? {
        let text = area.lowercased()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let words = area.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let us = "maps_en_united-states-of-america"
        if usStates.contains(where: { contains(text, word: $0) }) || words.contains(where: { usAbbreviations.contains($0) }) {
            // "Georgia" is a state and a country; a US place usually names the state, so the US wins.
            return mapNames.contains(us) ? us : nil
        }
        let countries = mapNames.filter { $0.hasPrefix("maps_en_") && !MapRegions.wholeContinents.contains(MapRegions.slug($0)) }
        return countries.sorted { $0.count > $1.count }.first { name in
            contains(text, word: MapRegions.slug(name).replacingOccurrences(of: "-", with: " "))
        }
    }

    private static func contains(_ text: String, word: String) -> Bool {
        text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#, options: .regularExpression) != nil
    }
}
