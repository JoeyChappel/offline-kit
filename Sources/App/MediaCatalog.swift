import Foundation
import AVFoundation
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import PDFKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Details read from each file

/// What the files themselves say: length, year, genre, when it was added, and a picture.
struct MediaInfo: Codable, Hashable, Sendable {
    var duration: Double?        // seconds (all chapters for an audiobook)
    var year: Int?
    var genre: String?
    var added: Date
    var thumb: String?           // path to a cached JPEG still (videos), or the cover art (audio)
    var author: String? = nil    // books
    var artist: String? = nil
    var albumArtist: String? = nil
    var album: String? = nil
    var narrator: String? = nil
    var tracks: [MediaTrackInfo]? = nil
    var parts: Int? = nil        // books: chapters (EPUB) or pages (PDF)
    // Approved Organize with AI details (from the library's Kit Catalog.json), filled in after reading files.
    var subgenre: String? = nil
    var studio: String? = nil    // studio, publisher, developer or author
    var series: String? = nil
    var seriesOrder: Double? = nil
    var ageRating: String? = nil
    var summary: String? = nil
    /// Which of those are the model's own guess ("genre", "creator"…), shown with an "AI guess" label.
    var guessed: [String]? = nil
    /// The first file's path, so the cache can tell which entries belong to files that are gone.
    var source: String? = nil
    /// An EPUB's own title, kept so a rescan doesn't have to open every book just to name it ("" when it has none).
    var bookTitle: String? = nil
}

/// Reads and caches MediaInfo. Thumbnails are a still from about a tenth of the way in, so they aren't black.
final class MediaInfoStore: @unchecked Sendable {
    static let shared = MediaInfoStore()

    private let lock = NSLock()
    private var cache: [String: MediaInfo] = [:]
    private var loaded = false
    static var folder: URL { KitLocation.caches.appending(path: "OfflineKit/media-info", directoryHint: .isDirectory) }
    private static var file: URL { folder.appending(path: "info.json") }

    /// The automatic picture for an item, without reading the file again.
    func cachedThumb(_ item: MediaItem) -> String? {
        loadIfNeeded()
        return lock.withLock { cache[Self.cacheKey(item)]?.thumb }
    }

    /// A book's own title from the cache, so a rescan doesn't open the EPUB again. "" means it was opened and has none.
    func cachedBookTitle(_ url: URL) -> String? {
        loadIfNeeded()
        return lock.withLock { cache[Self.cacheKey(tracks: [url])]?.bookTitle }
    }

    /// What the cache already knows about these items, with nothing read from the files: details by progress key,
    /// a stand-in for each item that still has to be read, and the cache keys in use (for pruning).
    struct Lookup: Sendable {
        var found: [String: MediaInfo] = [:]
        var missing: [MediaItem] = []
        var provisional: [String: MediaInfo] = [:]
        var keys: Set<String> = []
    }
    func lookup(_ items: [MediaItem]) async -> Lookup {
        loadIfNeeded()
        var result = Lookup()
        for item in items {
            let key = Self.cacheKey(item)
            result.keys.insert(key)
            let isEPUB = item.kind == .book && item.tracks[0].pathExtension.lowercased() == "epub"
            if var hit = lock.withLock({ cache[key] }), !(isEPUB && hit.bookTitle == nil) {
                if hit.source == nil {
                    // Entries from before the source was recorded get it now, so they can be pruned when the file goes.
                    hit.source = item.tracks[0].path
                    let updated = hit
                    lock.withLock { cache[key] = updated }
                }
                result.found[item.progressKey] = hit
            } else {
                result.missing.append(item)
                result.provisional[item.progressKey] = Self.placeholder(item)
            }
        }
        return result
    }

    /// What can be said about an item before its files are read: the date it was added, its cover and a year in its name.
    nonisolated static func placeholder(_ item: MediaItem) -> MediaInfo {
        let added = (try? item.tracks[0].resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey]))
            .flatMap { $0.addedToDirectoryDate ?? $0.creationDate } ?? Date()
        return MediaInfo(duration: nil, year: MediaCatalog.year(in: item.title), genre: nil, added: added, thumb: item.cover?.path)
    }

    /// Reads new or changed files in the background (3 at a time) and hands each batch of finished details to
    /// `onBatch`, so the screen fills in as the work goes instead of waiting for the last file.
    func read(_ items: [MediaItem], batch: Int = 40, onBatch: @MainActor @Sendable ([String: MediaInfo]) -> Void) async {
        guard !items.isEmpty else { return }
        var pending: [String: MediaInfo] = [:]
        var lastFlush = Date()
        var sinceSave = 0
        await withTaskGroup(of: (String, String, MediaInfo).self) { group in
            var next = items.makeIterator()
            func addNext() { if let item = next.next() { group.addTask { (item.progressKey, Self.cacheKey(item), await Self.read(item)) } } }
            for _ in 0..<3 { addNext() }
            for await (progressKey, key, info) in group {
                lock.withLock { cache[key] = info }
                pending[progressKey] = info
                sinceSave += 1
                addNext()
                // Each flush redraws the screens and works the shelves out again, so a fast first scan hands over details
                // a few times a second, not after every 40 files.
                let sinceFlush = Date().timeIntervalSince(lastFlush)
                if (pending.count >= batch && sinceFlush > 0.5) || sinceFlush > 1.5 {
                    let ready = pending
                    pending = [:]
                    lastFlush = Date()
                    await onBatch(ready)
                    // Saved along the way, so quitting in the middle of a big first scan doesn't lose it all.
                    if sinceSave >= 200 { sinceSave = 0; save() }
                }
            }
        }
        if !pending.isEmpty { await onBatch(pending) }
        save()
    }

    /// Forgets details (and their pictures) for files that are gone. Entries for drives that are just unplugged stay.
    /// `complete` is true when every Media folder was there to scan, which makes entries from before sources were kept safe to drop.
    func prune(keeping keys: Set<String>, complete: Bool) {
        loadIfNeeded()
        let fm = FileManager.default
        let thumbs = Self.folder.appending(path: "thumbs", directoryHint: .isDirectory).path + "/"
        let doomed: [(String, String?)] = lock.withLock {
            cache.compactMap { key, info in
                guard !keys.contains(key) else { return nil }
                if let source = info.source {
                    guard !source.hasPrefix("/Volumes/") else { return nil }
                } else if !complete { return nil }
                return (key, info.thumb)
            }
        }
        guard !doomed.isEmpty else { return }
        lock.withLock { for (key, _) in doomed { cache[key] = nil } }
        let keep = lock.withLock { Set(cache.values.compactMap(\.thumb)) }
        for (_, thumb) in doomed {
            if let thumb, thumb.hasPrefix(thumbs), !keep.contains(thumb) { try? fm.removeItem(atPath: thumb) }
        }
        save()
    }

    private func loadIfNeeded() {
        lock.withLock {
            guard !loaded else { return }
            loaded = true
            if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([String: MediaInfo].self, from: data) {
                cache = saved
            }
        }
    }

    private let saving = NSLock()
    private func save() {
        // One write at a time; the final save at the end of a scan always runs after the others have finished.
        guard saving.try() else { return }
        defer { saving.unlock() }
        let snapshot = lock.withLock { cache }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(snapshot).write(to: Self.file, options: .atomic)
    }

    /// Changes when the file changes, so a replaced movie gets a new thumbnail.
    /// Library-catalog subjects ("Buried treasure--Fiction", "Holmes, Sherlock (Fictitious character)--Fiction")
    /// become a short, shared set of genres people browse by.
    static func friendlyGenre(_ subjects: [String]) -> String? {
        guard !subjects.isEmpty else { return nil }
        let text = subjects.joined(separator: " | ").lowercased()
        let rules: [(String, [String])] = [
            ("Mystery", ["detective", "mystery", "holmes", "crime"]),
            ("Science Fiction & Horror", ["science fiction", "horror", "monsters", "frankenstein", "gothic"]),
            ("Fantasy", ["fantasy", "fairy", "magic", "imaginary places", "oz (imaginary"]),
            ("Animal Stories", ["animals", "dogs", "horses", "wolves", "toads", "moles", "rats"]),
            ("Adventure", ["adventure", "pirates", "buried treasure", "shipwreck", "survival", "castaways", "islands"]),
            ("Nature & Essays", ["nature", "simple living", "solitude", "essays", "philosophy"]),
            ("Children’s", ["children", "juvenile", "orphans", "girls", "boys"]),
            ("Romance & Family", ["love stories", "courtship", "domestic fiction", "sisters", "families", "young women", "marriage"]),
        ]
        return rules.first { rule in rule.1.contains(where: text.contains) }?.0 ?? "Classics"
    }

    private static func cacheKey(_ item: MediaItem) -> String { cacheKey(tracks: item.tracks) }
    private static func cacheKey(tracks: [URL]) -> String {
        let revisions = tracks.map { url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(url.path)|\(values?.fileSize ?? 0)|\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\n")
        // Bump the version when what's read from files changes, so cached details are read again.
        return "v7|" + SHA256.hash(data: Data(revisions.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ item: MediaItem) async -> MediaInfo {
        let first = item.tracks[0]
        var info = placeholder(item)
        info.source = first.path
        if item.kind == .book {
            readBook(item, into: &info)
            if info.genre == nil { info.genre = folderGenre(item) }
            return info
        }
        if item.kind == .audio {
            var details: [MediaTrackInfo] = []
            var wantsArtwork = info.thumb == nil
            for url in item.tracks {
                let tag = await AudioTags.read(url)
                details.append(MediaTrackInfo(title: tag.title ?? MediaLibrary.prettyTitle(url.deletingPathExtension().lastPathComponent),
                                              duration: tag.duration, artist: tag.artist))
                if info.artist == nil { info.artist = tag.artist }
                if info.albumArtist == nil { info.albumArtist = tag.albumArtist }
                if info.album == nil { info.album = tag.album }
                if info.genre == nil { info.genre = tag.genre }
                if info.year == nil { info.year = tag.year }
                if wantsArtwork, let art = await AudioTags.artwork(url) {
                    wantsArtwork = false
                    let dest = folder.appending(path: "thumbs/\(thumbName(cacheKey(item))).jpg")
                    try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if let source = CGImageSourceCreateWithData(art as CFData, nil),
                       let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 900] as CFDictionary),
                       writeJPEG(image, to: dest) { info.thumb = dest.path }
                }
            }
            info.tracks = details
            info.duration = details.compactMap(\.duration).reduce(0, +)
            if info.artist == nil {
                let holder = first.deletingLastPathComponent().deletingLastPathComponent()
                let candidate = holder.lastPathComponent
                if !["music", "audiobooks", "media", "library", "kids"].contains(candidate.lowercased()), holder.path.hasPrefix(item.root.path + "/") {
                    info.artist = MediaLibrary.prettyTitle(candidate)
                }
            }
            if info.genre == nil { info.genre = folderGenre(item) }
            return info
        }
        let asset = AVURLAsset(url: first)
        if let metadata = try? await asset.load(.metadata) {
            for entry in metadata {
                guard let id = entry.identifier else { continue }
                if [.iTunesMetadataUserGenre, .quickTimeMetadataGenre, .id3MetadataContentType].contains(id),
                   let genre = try? await entry.load(.stringValue), !genre.isEmpty, info.genre == nil {
                    info.genre = genre
                }
                if info.year == nil, [.quickTimeMetadataYear, .iTunesMetadataReleaseDate, .id3MetadataYear].contains(id),
                   let text = try? await entry.load(.stringValue), let year = Int(text.prefix(4)), year > 1800 {
                    info.year = year
                }
            }
        }
        if info.genre == nil { info.genre = folderGenre(item) }
        if item.kind == .video {
            if let duration = try? await asset.load(.duration), duration.seconds.isFinite {
                info.duration = duration.seconds
                info.thumb = await thumbnail(asset, at: duration.seconds, key: cacheKey(item)) ?? info.thumb
            }
        } else {
            var total = 0.0
            for track in item.tracks.prefix(80) {
                if let d = try? await AVURLAsset(url: track).load(.duration), d.seconds.isFinite { total += d.seconds }
            }
            info.duration = total > 0 ? total : nil
        }
        return info
    }

    /// The folder it sits in, when that isn't the Media folder itself ("Blender Films", "Westerns").
    private static func folderGenre(_ item: MediaItem) -> String? {
        if item.kind == .audio {
            let folder = item.tracks[0].deletingLastPathComponent()
            let relative = folder.path.replacingOccurrences(of: item.root.path + "/", with: "").split(separator: "/").map(String.init)
            if let marker = relative.firstIndex(where: { ["music", "albums", "songs", "audiobooks", "librivox"].contains($0.lowercased()) }) {
                let rest = Array(relative.dropFirst(marker + 1))
                let music = ["music", "albums", "songs"].contains(relative[marker].lowercased())
                // Music/<artist>/<album> is an artist hierarchy, not a genre. A genre requires another folder level.
                return rest.count >= (music ? 3 : 2) ? MediaLibrary.prettyTitle(rest[0]) : nil
            }
        }
        let holder = item.kind == .audio ? item.tracks[0].deletingLastPathComponent().deletingLastPathComponent() : item.tracks[0].deletingLastPathComponent()
        guard holder.standardizedFileURL.path != item.root.standardizedFileURL.path,
              holder.standardizedFileURL.path.hasPrefix(item.root.standardizedFileURL.path) else { return nil }
        let name = MediaLibrary.prettyTitle(holder.lastPathComponent)
        // Folders that only say what kind of thing it is aren't genres (Music and Audiobooks have their own rows).
        return ["audiobooks", "audio books", "media", "music", "songs", "albums", "videos", "movies", "books", "ebooks"].contains(name.lowercased()) ? nil : name
    }

    /// Author, subject, chapter or page count, and the cover (from the EPUB, or the PDF's first page).
    private static func readBook(_ item: MediaItem, into info: inout MediaInfo) {
        let url = item.tracks[0]
        let thumbURL = folder.appending(path: "thumbs/\(thumbName(cacheKey(item))).jpg")
        try? FileManager.default.createDirectory(at: thumbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if url.pathExtension.lowercased() == "epub" {
            guard let (book, zip) = EPUBBook.open(url) else { info.bookTitle = ""; return }
            info.bookTitle = book.title
            info.author = book.author
            info.genre = friendlyGenre(book.subjects)
            info.parts = book.chapters.count
            if let cover = book.coverPath, let data = zip.data(cover),
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: 900] as CFDictionary),
               writeJPEG(image, to: thumbURL) { info.thumb = thumbURL.path }
        } else if let doc = PDFDocument(url: url) {
            info.author = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String
            info.parts = doc.pageCount
            if let page = doc.page(at: 0) {
                let picture = page.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox)
                #if os(macOS)
                let image = picture.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                let image = picture.cgImage
                #endif
                if let image, writeJPEG(image, to: thumbURL) { info.thumb = thumbURL.path }
            }
        }
    }

    private static func thumbName(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    private static func thumbnail(_ asset: AVURLAsset, at duration: Double, key: String) async -> String? {
        let name = SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        let url = folder.appending(path: "thumbs/\(name).jpg")
        if FileManager.default.fileExists(atPath: url.path) { return url.path }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let second = min(max(duration * 0.1, min(5, duration / 2)), 180)
        guard let image = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image else { return nil }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url.path : nil
    }
}

// MARK: - Rows

struct MediaShelf: Identifiable {
    let title: String
    let items: [MediaItem]
    var id: String { title }
}

/// What the Watch & Listen filter shows.
enum MediaFilter: String, CaseIterable, Identifiable {
    case all, video, audiobooks, music, books
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .video: "Video"
        case .audiobooks: "Audiobooks"
        case .music: "Music"
        case .books: "Books"
        }
    }
}

/// The Netflix-style rows, built the same way for the Mac, iPhone, web view and Apple TV.
enum MediaCatalog {
    /// Video, audiobook or music. Audio is an audiobook when it says so (.m4b files, an "Audiobooks" folder,
    /// a spoken-word genre tag, chapter-named or very long tracks); otherwise it's music.
    static func category(_ item: MediaItem, _ info: MediaInfo?) -> MediaFilter {
        if item.kind == .book { return .books }
        guard item.kind == .audio else { return .video }
        // The screens ask this thousands of times per redraw; the answer only changes with the item or its tags.
        let key = CategoryKey(id: item.id, tracks: item.tracks.count, genre: info?.genre, duration: info?.duration)
        if let known = categories.lock.withLock({ categories.values[key] }) { return known }
        let answer = audioCategory(item, info)
        categories.lock.withLock {
            if categories.values.count > 20_000 { categories.values.removeAll() }
            categories.values[key] = answer
        }
        return answer
    }

    private struct CategoryKey: Hashable {
        let id: String
        let tracks: Int
        let genre: String?
        let duration: Double?
    }
    private final class CategoryCache: @unchecked Sendable {
        let lock = NSLock()
        var values: [CategoryKey: MediaFilter] = [:]
    }
    private static let categories = CategoryCache()

    private static func audioCategory(_ item: MediaItem, _ info: MediaInfo?) -> MediaFilter {
        if item.tracks.contains(where: { $0.pathExtension.lowercased() == "m4b" }) { return .audiobooks }
        let path = item.tracks[0].deletingLastPathComponent().pathComponents.map { $0.lowercased() }
        if path.contains(where: { $0.contains("audiobook") || $0 == "books" || $0 == "librivox" }) { return .audiobooks }
        if path.contains(where: { $0 == "music" || $0 == "songs" || $0 == "albums" }) { return .music }
        if let genre = info?.genre?.lowercased() {
            let spoken = ["audiobook", "audio book", "speech", "spoken", "book", "literature", "stories", "story", "podcast", "drama"]
            return spoken.contains(where: genre.contains) ? .audiobooks : .music
        }
        let names = item.tracks.map { $0.deletingPathExtension().lastPathComponent.lowercased() }
        let chapterish = names.filter { $0.range(of: #"chapter|chap\.|\bch\s?\d|\bpart\s?\d|\bbook\s?\d"#, options: .regularExpression) != nil }
        if item.tracks.count > 1, chapterish.count * 2 >= names.count { return .audiobooks }
        if let d = info?.duration, d / Double(item.tracks.count) > 15 * 60 { return .audiobooks }
        return .music
    }

    static func year(in title: String) -> Int? {
        guard let match = title.range(of: #"\((1[89]|20)\d{2}\)"#, options: .regularExpression) else { return nil }
        return Int(title[match].dropFirst().dropLast())
    }

    /// "Tears of Steel (2012)" → "Tears of Steel".
    static func displayTitle(_ title: String) -> String {
        // A regex replace per call, and cards ask for it on every redraw: remember each answer.
        if let known = displayTitles.get(title) { return known }
        let answer = title.replacingOccurrences(of: #"\s*\((1[89]|20)\d{2}\)\s*$"#, with: "", options: .regularExpression)
        displayTitles.set(title, answer)
        return answer
    }
    private static let displayTitles = StringMemo()

    /// A small thread-safe string-to-string memo for work the screens repeat on every redraw (regexes, formatters).
    final class StringMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String] = [:]
        func get(_ key: String) -> String? { lock.withLock { values[key] } }
        func set(_ key: String, _ value: String) {
            lock.withLock {
                if values.count > 20_000 { values.removeAll() }
                values[key] = value
            }
        }
    }

    static func isInProgress(_ p: MediaProgress?, kind: MediaItem.Kind = .video) -> Bool {
        guard let p, !p.finished else { return false }
        // Books store how far down the chapter as 0…1 in `seconds`.
        if kind == .book { return p.track > 0 || p.seconds > 0.01 }
        return p.seconds > 5 || p.track > 0
    }

    /// How far through, 0…1, when known.
    static func fraction(_ item: MediaItem, _ p: MediaProgress?, _ info: MediaInfo?) -> Double? {
        guard let p, isInProgress(p, kind: item.kind) else { return nil }
        if item.kind == .book {
            guard let parts = info?.parts, parts > 0 else { return nil }
            return min(1, (Double(p.track) + (item.tracks[0].pathExtension.lowercased() == "pdf" ? 0 : p.seconds)) / Double(parts))
        }
        if item.tracks.count > 1 {
            if let durations = info?.tracks?.map({ $0.duration ?? 0 }), durations.count == item.tracks.count,
               durations.allSatisfy({ $0 > 0 }) {
                return min(1, max(0, (durations.prefix(max(0, p.track)).reduce(0, +) + p.seconds) / durations.reduce(0, +)))
            }
            return min(1, max(0, Double(p.track) / Double(item.tracks.count)))
        }
        guard let d = info?.duration, d > 0 else { return nil }
        return min(1, p.seconds / d)
    }

    /// "2012 · 12 min · Animation", "Audiobook · 9 chapters · 2 hr 58 min".
    static func meta(_ item: MediaItem, _ info: MediaInfo?) -> String {
        // The duration text comes from a formatter built on each call; remember the line per item and its details.
        let key = "\(item.id)|\(item.tracks.count)|\(category(item, info).rawValue)|\(info?.year ?? 0)|\(info?.duration ?? -1)|\(info?.genre ?? "")|\(info?.author ?? "")|\(info?.parts ?? -1)"
        if let known = metas.get(key) { return known }
        let line = makeMeta(item, info)
        metas.set(key, line)
        return line
    }
    private static let metas = StringMemo()

    private static func makeMeta(_ item: MediaItem, _ info: MediaInfo?) -> String {
        var bits: [String] = []
        if item.kind == .book {
            bits.append("Book")
            if let author = info?.author, !author.isEmpty { bits.append(author) }
            if let parts = info?.parts { bits.append(item.tracks[0].pathExtension.lowercased() == "pdf" ? "\(parts) page\(parts == 1 ? "" : "s")" : "\(parts) chapter\(parts == 1 ? "" : "s")") }
            if let genre = info?.genre { bits.append(genre) }
            return bits.joined(separator: " · ")
        }
        if let year = info?.year { bits.append(String(year)) }
        if item.kind == .audio {
            if category(item, info) == .audiobooks {
                bits.append(item.tracks.count > 1 ? "Audiobook · \(item.tracks.count) chapters" : "Audiobook")
            } else {
                bits.append(item.tracks.count > 1 ? "Album · \(item.tracks.count) songs" : "Song")
            }
        }
        if let d = info?.duration, d > 0 {
            bits.append(d < 60 ? "Under 1 min" : Duration.seconds(d).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated, maximumUnitCount: 2)))
        }
        if let genre = info?.genre { bits.append(genre) }
        return bits.joined(separator: " · ")
    }

    static func build(items all: [MediaItem], progress: [String: MediaProgress], info: [String: MediaInfo],
                      filter: MediaFilter = .all, genre: String? = nil, query: String = "",
                      sort: MediaSort = .title, unfinished: Bool = false) -> (featured: MediaItem?, shelves: [MediaShelf]) {
        let selected = select(all, info: info, progress: progress, filter: filter, genre: genre, query: query, sort: sort, unfinished: unfinished)
        guard !selected.isEmpty else { return (nil, []) }
        if genre != nil || !query.isEmpty || sort != .title || unfinished {
            return (nil, [MediaShelf(title: genre ?? (query.isEmpty ? filter.label : "Search results"), items: selected)])
        }
        // Linked media on a drive that isn't plugged in gets one row of its own at the end, nowhere else.
        let items = selected.filter { $0.unavailable == nil }
        let away = selected.filter { $0.unavailable != nil }
        guard !items.isEmpty else { return (nil, [MediaShelf(title: "On a drive that isn’t connected", items: away)]) }
        let p = { (item: MediaItem) in progress[item.progressKey] }
        let i = { (item: MediaItem) in info[item.progressKey] }
        let updated = { (item: MediaItem) in p(item)?.updated ?? .distantPast }
        let added = { (item: MediaItem) in i(item)?.added ?? .distantPast }

        let isMusic = { (item: MediaItem) in category(item, i(item)) == .music }
        // Shelves listed by title share one sort of the whole library (done the first time one needs it), and each
        // shelf just orders its items by their place in it.
        var titleRanks: [String: Int]?
        func byTitle(_ list: [MediaItem]) -> [MediaItem] {
            if titleRanks == nil {
                let titles = items.map(\.title)
                let order = items.indices.sorted { a, b in
                    let c = titles[a].localizedStandardCompare(titles[b])
                    return c == .orderedSame ? a < b : c == .orderedAscending
                }
                var ranks: [String: Int] = [:]
                for (place, index) in order.enumerated() where ranks[items[index].id] == nil { ranks[items[index].id] = place }
                titleRanks = ranks
            }
            let ranks = titleRanks ?? [:]
            return list.sorted { (ranks[$0.id] ?? 0) < (ranks[$1.id] ?? 0) }
        }
        // Music is played again and again, and books are read, so both get their own rows.
        let stories = items.filter { !isMusic($0) && $0.kind != .book }
        let books = items.filter { $0.kind == .book }
        let reading = books.filter { isInProgress(p($0), kind: .book) }.sorted { updated($0) > updated($1) }
        let inProgress = stories.filter { isInProgress(p($0)) }.sorted { updated($0) > updated($1) }
        let unwatched = stories.filter { p($0) == nil || (!isInProgress(p($0)) && p($0)?.finished != true) }
        let finished = stories.filter { p($0)?.finished == true }.sorted { updated($0) > updated($1) }
        let newest = items.sorted { added($0) > added($1) }
        let music = items.filter(isMusic)

        let featured = inProgress.first ?? reading.first ?? unwatched.max { added($0) < added($1) } ?? newest.first

        var shelves: [MediaShelf] = []
        func add(_ title: String, _ list: [MediaItem]) { if !list.isEmpty { shelves.append(MediaShelf(title: title, items: list)) } }

        add("Keep Watching", inProgress.filter { $0.kind == .video })
        add("Keep Listening", inProgress.filter { $0.kind == .audio })
        add("Keep Reading", reading)
        add("Recently Played", music.filter { p($0) != nil }.sorted { updated($0) > updated($1) })

        // What's Next: things not started yet, leading with the genre they watched last.
        let lastGenre = (inProgress.first ?? finished.first).flatMap { i($0)?.genre }
        add("What’s Next", unwatched.sorted { a, b in
            let ga = lastGenre != nil && i(a)?.genre == lastGenre, gb = lastGenre != nil && i(b)?.genre == lastGenre
            return ga != gb ? ga : added(a) > added(b)
        })
        if items.count >= 4 { add("Recently Added", newest) }

        // Genres from the files' own tags or their folders, biggest first.
        var byGenre: [String: [MediaItem]] = [:]
        for item in items { if let g = i(item)?.genre { byGenre[g, default: []].append(item) } }
        for (genre, list) in byGenre.sorted(by: { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }) {
            add(genre, byTitle(list))
        }

        // Series in order, then "More from <studio or author>", from approved Organize with AI details.
        for (name, list) in seriesGroups(items, info: info) { add(name, list) }
        for (name, list) in creatorGroups(items, info: info).prefix(6) { add("More from \(name)", list) }

        // Ready-made groups.
        let videos = items.filter { $0.kind == .video }
        add("Short Films", videos.filter { (i($0)?.duration ?? .infinity) < 20 * 60 })
        add("Movies", videos.filter { (i($0)?.duration ?? 0) >= 40 * 60 })
        add("Audiobooks", items.filter { $0.kind == .audio && !isMusic($0) })
        add("Music", byTitle(music))
        add("Books", byTitle(books))

        add("Watch Again", finished)
        add("On a drive that isn’t connected", away)
        return (featured, shelves)
    }

    /// Series with at least two items, in series order (then title).
    static func seriesGroups(_ items: [MediaItem], info: [String: MediaInfo]) -> [(String, [MediaItem])] {
        let grouped = Dictionary(grouping: items.filter { info[$0.progressKey]?.series != nil }) { info[$0.progressKey]!.series! }
        return grouped.filter { $0.value.count >= 2 }.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { name, list in
            (name, list.sorted { a, b in
                let x = info[a.progressKey]?.seriesOrder ?? .infinity, y = info[b.progressKey]?.seriesOrder ?? .infinity
                return x != y ? x < y : a.title.localizedStandardCompare(b.title) == .orderedAscending
            })
        }
    }

    /// Studios, publishers and authors with at least two items, biggest first. Music has its own artist pages.
    static func creatorGroups(_ items: [MediaItem], info: [String: MediaInfo]) -> [(String, [MediaItem])] {
        let candidates = items.filter { info[$0.progressKey]?.studio != nil && category($0, info[$0.progressKey]) != .music }
        let grouped = Dictionary(grouping: candidates) { info[$0.progressKey]!.studio! }
        return grouped.filter { $0.value.count >= 2 }
            .sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
            .map { ($0.key, $0.value.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }) }
    }
}
