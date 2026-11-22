import SwiftUI
import AVFoundation

// MARK: - Items

/// Something to watch, listen to or read: a video file, an audiobook/album (a folder of audio tracks),
/// or a book (an EPUB or PDF).
struct MediaItem: Identifiable, Hashable {
    enum Kind: String { case video, audio, book }
    let kind: Kind
    let title: String
    let tracks: [URL]        // one for a video, chapters for an audiobook
    let root: URL            // the Media folder this came from
    let cover: URL?
    var catalogKey: String? = nil
    /// Set for linked media whose drive or folder isn't there right now: where it lives ("My Drive").
    var unavailable: String? = nil
    /// The Find my media link this came from, for linked media kept outside the kit.
    var linkID: String? = nil
    /// Worked out once: the screens look items up by their key hundreds of times per redraw.
    private let pathKey: String

    nonisolated init(kind: Kind, title: String, tracks: [URL], root: URL, cover: URL?,
                     catalogKey: String? = nil, unavailable: String? = nil, linkID: String? = nil) {
        self.kind = kind
        self.title = title
        self.tracks = tracks
        self.root = root
        self.cover = cover
        self.catalogKey = catalogKey
        self.unavailable = unavailable
        self.linkID = linkID
        let base = root.standardizedFileURL.path
        let path = (kind == .audio && !MediaLibrary.holdsLooseTracks(tracks[0].deletingLastPathComponent(), root: root) ? tracks[0].deletingLastPathComponent() : tracks[0]).standardizedFileURL.path
        pathKey = path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }

    var id: String { tracks.first?.path ?? title }
    /// Key for saved progress, relative to the Media folder so it survives moving a drive between Macs.
    var progressKey: String { catalogKey ?? pathKey }

    /// Linked media whose drive is plugged in but whose file or folder isn't where it was.
    var isMissingLocally: Bool { unavailable == "its folder" || unavailable == "its file" }
    /// Short badge text: "Folder missing", "File missing" or "Connect My Drive".
    var unavailableBadge: String? {
        guard let place = unavailable else { return nil }
        return place == "its folder" ? "Folder missing" : place == "its file" ? "File missing" : "Connect \(place)"
    }
    /// One sentence for the detail page and alerts.
    var unavailableSentence: String? {
        guard let place = unavailable else { return nil }
        #if os(macOS)
        let locate = " If it moved, use Locate… to show the kit where it is now."
        #else
        let locate = ""
        #endif
        if place == "its folder" { return "This is linked to a folder that isn’t there right now." + locate }
        if place == "its file" { return "This is linked to a file that isn’t there right now." + locate }
        return "This is kept on \(place). Connect it to play."
    }
}

/// Where someone left off: which track and how far in.
struct MediaProgress: Codable, Equatable {
    var track: Int
    var seconds: Double
    var finished = false
    /// When it was last played, for "Keep Watching" order. Older saves don't have it.
    var updated: Date? = nil
}

// MARK: - Library

@MainActor @Observable
final class MediaLibrary {
    private(set) var items: [MediaItem] = [] { didSet { revision &+= 1 } }
    private(set) var progress: [String: MediaProgress] = [:] { didSet { revision &+= 1 } }
    /// Length, year, genre, date added and thumbnail for each item, by progress key.
    private(set) var info: [String: MediaInfo] = [:] { didSet { revision &+= 1 } }
    /// Goes up whenever items, details or progress change. Screens that work out lists from them (Watch & Listen)
    /// compare this one number to know when to work them out again, instead of walking the dictionaries.
    private(set) var revision = 0
    /// The frame each unfinished video was last stopped on, by progress key (see PlaybackStill).
    private var stills: [String: String] = [:]
    private var lastStill: [String: Date] = [:]

    nonisolated static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    nonisolated static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aiff", "flac"]
    nonisolated static let bookExtensions: Set<String> = ["epub", "pdf"]

    /// Single files that aren't part of an album or a chaptered audiobook: files directly in a Media folder, or in
    /// its Music, Songs or Audiobooks folder (where added songs and one-file audiobooks go). Each is its own item;
    /// any other folder of audio (Music/Artist/Album, Audiobooks/Title) is one album or audiobook.
    nonisolated static func holdsLooseTracks(_ folder: URL, root: URL) -> Bool {
        func trim(_ p: String) -> String { p.count > 1 && p.hasSuffix("/") ? String(p.dropLast()) : p }
        let f = trim(folder.standardizedFileURL.path), r = trim(root.standardizedFileURL.path)
        if f == r { return true }
        return (f as NSString).deletingLastPathComponent == r
            && ["music", "songs", "audiobooks"].contains((f as NSString).lastPathComponent.lowercased())
    }

    init() {
        if let data = KitSettings.shared.string(forKey: "mediaProgress")?.data(using: .utf8),
           let saved = try? JSONDecoder().decode([String: MediaProgress].self, from: data) {
            progress = saved
        }
        // Progress is written a few seconds late, so quitting or leaving the app writes whatever is waiting.
        #if os(macOS)
        let names = [NSApplication.willTerminateNotification]
        #else
        let names = [UIApplication.willTerminateNotification, UIApplication.didEnterBackgroundNotification]
        #endif
        for name in names {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushProgress() }
            }
        }
    }

    /// Writes waiting progress now, on this thread.
    func flushProgress() {
        guard persistDirty else { return }
        persistDirty = false
        var snapshot = progress
        for (key, value) in unpublished { snapshot[key] = value }
        if let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) {
            KitSettings.shared.set(text, forKey: "mediaProgress")
        }
        KitSettings.shared.flush()   // drive-mode settings are written after a pause; quitting can't wait for it
    }

    /// Each library's "Media" folder, plus the older ~/OfflineKit/Kids folder.
    func folders(from library: Library) -> [URL] {
        #if os(macOS)
        var list = library.folders.map { $0.appending(path: "Media", directoryHint: .isDirectory) }
        list.append(KitLocation.home.appending(path: "OfflineKit/Kids", directoryHint: .isDirectory))
        return list
        #else
        return [URL.documentsDirectory.appending(path: "Media", directoryHint: .isDirectory)]
        #endif
    }

    /// Where imports and audiobook downloads go: beside the app in drive mode, else this Mac or the phone.
    /// In the library they chose for their kit (often a USB drive), so it all travels together.
    static var importFolder: URL { KitStorage.media }

    /// One scan at a time: see ScanGate. Without it, a scan that started before a file was added could finish last
    /// and put back the old list.
    @ObservationIgnored private let scans = ScanGate()

    /// Rescans every Media folder. When it returns, `items`, `info` and the stills reflect the folders as they were
    /// after this call was made, even if another scan was already running.
    func reload(library: Library) async {
        scanning = true
        await scans.run { [weak self] in await self?.scan(library: library) }
        if !scans.isRunning { scanning = false }
        hasScanned = true
        lastScan = Date()
    }

    /// Opening a section: rescans only when the list is more than a minute old. Changes made in Finder, downloads,
    /// imports and drives coming and going rescan by themselves, so switching sections stays instant.
    func reloadIfStale(library: Library) async {
        guard !hasScanned || Date().timeIntervalSince(lastScan) > 60 else { return }
        await reload(library: library)
    }

    /// True while the folders are being read, for a "Looking through your media…" note.
    private(set) var scanning = false
    /// False until the first scan has finished: an empty list before then means "not read yet", not "nothing here".
    private(set) var hasScanned = false
    @ObservationIgnored private var lastScan = Date.distantPast

    private func scan(library: Library) async {
        MediaCover.forgetCustomAnswers()
        let roots = folders(from: library)
        #if os(macOS)
        let libraries = KitCatalog.folders(library)
        #else
        let libraries: [URL] = []
        #endif
        // Walking the folders is quick: it only lists files. Linked media (kept outside the kit, see Find my media)
        // joins as-is; a missing drive just marks it unavailable.
        let walked = await Task.detached(priority: .userInitiated) { () -> (found: [MediaItem], links: [LinkedMediaEntry], linked: [MediaItem]) in
            let links = LinkedMedia.load(libraries)
            return (Self.scan(roots), links, LinkedMedia.items(links))
        }.value
        let links = Dictionary(walked.links.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let saved = await Task.detached { PlaybackStill.saved() }.value

        // Albums are grouped by their tags. With the tags saved from last time that takes no reading; the very first
        // time it can take a while, so the folders are shown as found (one item per folder) until it's done.
        let tagsKnown = await AudioTags.allCached(walked.found)
        if !tagsKnown && items.isEmpty && !(walked.found + walked.linked).isEmpty {
            await showItems((walked.found + walked.linked).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
                            links: links, saved: saved, library: library, readRest: false)
        }
        let organized = await Task.detached(priority: .userInitiated) { await AudioTags.organize(walked.found) }.value
        let all = (organized + walked.linked).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let keys = await showItems(all, links: links, saved: saved, library: library, readRest: true)
        // Details for files that are gone (and their thumbnails) can go now that this scan has seen what's there.
        let complete = roots.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
        await Task.detached(priority: .utility) {
            MediaInfoStore.shared.prune(keeping: keys, complete: complete)
            AudioTags.pruneMissing()
        }.value
    }

    /// Puts the list on screen right away with whatever details are known (saved ones, or a stand-in for each new
    /// file), then reads the rest in batches that fill in thumbnails, lengths and titles as they finish.
    /// Returns the info-cache keys in use.
    @discardableResult
    private func showItems(_ items: [MediaItem], links: [String: LinkedMediaEntry], saved: [String: String],
                           library: Library, readRest: Bool) async -> Set<String> {
        let local = items.filter { $0.unavailable == nil }
        let lookup = await MediaInfoStore.shared.lookup(local)
        var info = lookup.found
        // What's on screen already beats a stand-in for a file that changed.
        for (key, stand) in lookup.provisional { info[key] = self.info[key] ?? stand }
        for item in items where item.unavailable != nil && info[item.progressKey] == nil {
            let link = item.linkID.flatMap { links[$0] }
            var value = MediaInfo(duration: nil, year: MediaCatalog.year(in: item.title), genre: nil, added: link?.added ?? .distantPast, thumb: nil)
            if item.kind == .book { value.author = link?.creator } else { value.artist = link?.creator }
            info[item.progressKey] = value
        }
        // Approvals and edits made during the scan are in the catalog file already, so they're applied here.
        Self.applyCatalog(library: library, items: items, info: &info)
        publish(items: items, info: &info, saved: saved)
        guard readRest, !lookup.missing.isEmpty else { return lookup.keys }
        let byKey = Dictionary(items.map { ($0.progressKey, $0) }, uniquingKeysWith: { a, _ in a })
        await MediaInfoStore.shared.read(lookup.missing) { [weak self] batch in
            guard let self else { return }
            var batch = batch
            let known = batch.keys.compactMap { byKey[$0] }
            Self.applyCatalog(items: known, info: &batch, catalog: KitCatalog.shared)
            for (key, var value) in batch {
                // A frame captured while the scan ran is newer than the one on disk when the scan looked.
                if let path = self.stills[key] ?? saved[PlaybackStill.hash(key)], self.progress[key]?.finished == false,
                   byKey[key]?.kind == .video, FileManager.default.fileExists(atPath: path) { value.thumb = path }
                if self.info[key] != value { self.info[key] = value }
            }
        }
        return lookup.keys
    }

    /// Sets the list, details and "where you left off" pictures, changing only what's different:
    /// an unchanged rescan mustn't redraw every card.
    private func publish(items: [MediaItem], info: inout [String: MediaInfo], saved: [String: String]) {
        var stills: [String: String] = [:]
        for item in items where item.kind == .video {
            let key = item.progressKey
            guard progress[key]?.finished == false else { continue }
            // A frame captured while the scan ran is newer than the one on disk when the scan looked.
            guard let path = self.stills[key] ?? saved[PlaybackStill.hash(key)],
                  FileManager.default.fileExists(atPath: path) else { continue }
            stills[key] = path
            info[key]?.thumb = path
        }
        if self.items != items { self.items = items }
        if self.info != info { self.info = info }
        if self.stills != stills { self.stills = stills }
    }

    /// Approved "Organize with AI" details and people's own edits, laid over what the files say.
    /// Never written to the shared info cache: the catalog file in the library is the only record.
    func applyCatalog(library: Library) {
        var info = self.info
        Self.applyCatalog(library: library, items: items, info: &info)
        self.info = info
    }

    private static func applyCatalog(library: Library, items: [MediaItem], info: inout [String: MediaInfo]) {
        let catalog = KitCatalog.shared
        catalog.reload(library)
        applyCatalog(items: items, info: &info, catalog: catalog)
    }

    /// The same overlay without reading the catalog file again, for batches that arrive during a scan.
    private static func applyCatalog(items: [MediaItem], info: inout [String: MediaInfo], catalog: KitCatalog) {
        for item in items {
            let key = KitCatalog.mediaKey(item)
            guard catalog.details[key] != nil, var value = info[item.progressKey] else { continue }
            if let genre = catalog.value(key, .genre) { value.genre = genre }
            if let text = catalog.value(key, .year), let year = Int(text.prefix(4)) { value.year = year }
            value.subgenre = catalog.value(key, .subgenre)
            value.studio = catalog.value(key, .creator)
            value.series = catalog.value(key, .series)
            value.seriesOrder = catalog.value(key, .seriesOrder).flatMap { Double($0) }
            value.ageRating = catalog.value(key, .ageRating)
            value.summary = catalog.value(key, .summary)
            value.guessed = catalog.details[key]?.guessedKeys.map(\.rawValue)
            info[item.progressKey] = value
        }
    }

    /// Keeps the "where you left off" picture in step with progress. `now` is set when playback pauses or closes;
    /// during playback (and from the web view or Apple TV) it refreshes at most every 30 seconds.
    private func updateStill(_ item: MediaItem, _ value: MediaProgress, now: Bool) {
        let key = item.progressKey
        if value.finished || value.seconds < 3 {
            guard let old = stills.removeValue(forKey: key) else { return }
            try? FileManager.default.removeItem(atPath: old)
            info[key]?.thumb = MediaInfoStore.shared.cachedThumb(item)
            return
        }
        guard now || Date().timeIntervalSince(lastStill[key] ?? .distantPast) > 30 else { return }
        lastStill[key] = Date()
        let file = item.tracks[min(value.track, item.tracks.count - 1)]
        Task {
            guard let path = await PlaybackStill.capture(file, at: value.seconds, key: key) else { return }
            // Finished or started over while the frame was being read: drop it.
            guard let current = progress[key], !current.finished, current.seconds >= 3 else {
                try? FileManager.default.removeItem(atPath: path); return
            }
            if let old = stills[key], old != path { try? FileManager.default.removeItem(atPath: old) }
            stills[key] = path
            info[key]?.thumb = path
        }
    }

    /// Generated art is ready (AutoArtwork): shown unless the item has its own cover, a video shows where it was stopped,
    /// or the files brought art of their own (see ArtworkRules).
    func setGeneratedArtwork(_ path: String?, art: GeneratedArt, for item: MediaItem) {
        let key = item.progressKey
        guard var value = info[key] else { return }
        value.art = art.rawValue
        if let path {
            value.thumb = ArtworkRules.thumb(kind: item.kind, current: value.thumb, currentArt: info[key]?.art,
                                             still: item.kind == .video ? stills[key] : nil, generated: path)
        }
        if info[key] != value { info[key] = value }
    }

    /// The featured item and rows for the Netflix-style screens.
    /// `includeBooks: false` for the web view and Apple TV, which can't open books yet.
    func catalog(filter: MediaFilter = .all, includeBooks: Bool = true) -> (featured: MediaItem?, shelves: [MediaShelf]) {
        MediaCatalog.build(items: includeBooks ? items : items.filter { $0.kind != .book }, progress: progress, info: info, filter: filter)
    }

    nonisolated static func scan(_ roots: [URL]) -> [MediaItem] {
        var items: [MediaItem] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for root in roots {
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { continue }
            var audioByFolder: [URL: [URL]] = [:]
            for case let url as URL in walker {
                if url.lastPathComponent.hasPrefix("._") || url.pathExtension == "part" { continue }
                let ext = url.pathExtension.lowercased()
                if videoExtensions.contains(ext) {
                    guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                    items.append(MediaItem(kind: .video, title: prettyTitle(url.deletingPathExtension().lastPathComponent),
                                           tracks: [url], root: root, cover: MediaCover.sidecar(for: url)))
                } else if audioExtensions.contains(ext) {
                    audioByFolder[url.deletingLastPathComponent(), default: []].append(url)
                } else if bookExtensions.contains(ext) {
                    guard seen.insert(url.standardizedFileURL.path).inserted else { continue }
                    let plain = prettyTitle(url.deletingPathExtension().lastPathComponent)
                    // An EPUB's own title is kept with its details, so only a new or changed book is opened here.
                    var title = plain
                    if ext == "epub" {
                        if let known = MediaInfoStore.shared.cachedBookTitle(url) { title = known.isEmpty ? plain : known }
                        else { title = EPUBBook.open(url)?.0.title ?? plain }
                    }
                    items.append(MediaItem(kind: .book, title: title, tracks: [url], root: root, cover: MediaCover.sidecar(for: url)))
                }
            }
            for (folder, tracks) in audioByFolder {
                let sorted = tracks.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                // Loose files (in Media, Media/Music or Media/Songs) are each their own item; a folder of tracks is one album or audiobook.
                if holdsLooseTracks(folder, root: root) {
                    for track in sorted {
                        items.append(MediaItem(kind: .audio, title: prettyTitle(track.deletingPathExtension().lastPathComponent),
                                               tracks: [track], root: root, cover: MediaCover.sidecar(for: track)))
                    }
                } else {
                    guard seen.insert(folder.standardizedFileURL.path).inserted else { continue }
                    // A cover chosen in the app comes first, then art that came with the files.
                    let cover = ["cover-custom.jpg", "cover.jpg", "cover.png", "folder.jpg"].map { folder.appending(path: $0) }
                        .first { fm.fileExists(atPath: $0.path) }
                    items.append(MediaItem(kind: .audio, title: prettyTitle(folder.lastPathComponent),
                                           tracks: sorted, root: root, cover: cover))
                }
            }
        }
        return dedupeBooks(items).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The same book twice (a starter classic and a copy someone added to Books) shows once: same title, same
    /// kind of file and same size. The copy outside the starter "Classics" folder wins.
    nonisolated static func dedupeBooks(_ items: [MediaItem]) -> [MediaItem] {
        var kept: [String: Int] = [:]
        var out: [MediaItem] = []
        for item in items {
            guard item.kind == .book, let file = item.tracks.first else { out.append(item); continue }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let key = "\(item.title.lowercased())|\(file.pathExtension.lowercased())|\(size)"
            if let index = kept[key] {
                let starter = { (url: URL) in url.deletingLastPathComponent().lastPathComponent == "Classics" }
                if starter(out[index].tracks[0]) && !starter(file) { out[index] = item }
                continue
            }
            kept[key] = out.count
            out.append(item)
        }
        return out
    }

    nonisolated static func prettyTitle(_ raw: String) -> String {
        raw.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"^\d+\s*[-.]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// The listening speed each audiobook was last set to, by progress key.
    @ObservationIgnored private lazy var rates: [String: Float] = {
        KitSettings.shared.string(forKey: "mediaRates").flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String: Float].self, from: $0) } ?? [:]
    }()

    func savedRate(for item: MediaItem) -> Float { rates[item.progressKey] ?? 1 }

    func saveRate(_ rate: Float, for item: MediaItem) {
        guard savedRate(for: item) != rate else { return }
        rates[item.progressKey] = rate == 1 ? nil : rate
        if let data = try? JSONEncoder().encode(rates), let text = String(data: data, encoding: .utf8) {
            KitSettings.shared.set(text, forKey: "mediaRates")
        }
    }

    /// Where saved positions that haven't been published yet wait (see saveProgress).
    @ObservationIgnored private var unpublished: [String: MediaProgress] = [:]
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var persistDirty = false

    /// Remembers where someone is. Playback calls this every few seconds, so it stays cheap:
    /// - a save that says nothing new (same place) changes nothing and writes nothing;
    /// - while playing, a few seconds of progress within the same chapter is held back from `progress`, so the screens
    ///   reading it don't redraw every tick; pausing, stopping and changing chapter publish it right away;
    /// - the settings file is written a moment later, off the main thread, and covers every save made meanwhile.
    func saveProgress(_ value: MediaProgress, for item: MediaItem, stopped: Bool = false, duration: Double? = nil) {
        let key = item.progressKey
        // Credits and outros count as the end (see `atTheFinishLine`).
        let adjusted = Self.applyingFinishLine(value, item: item, duration: duration ?? knownDuration(of: item, track: value.track))
        let known = unpublished[key] ?? progress[key]
        let same = known.map { $0.track == adjusted.track && $0.seconds == adjusted.seconds && $0.finished == adjusted.finished } ?? false
        if item.kind == .video { updateStill(item, adjusted, now: stopped) }
        guard !same else { return }
        var value = adjusted
        value.updated = Date()
        let shown = progress[key]
        let quiet = !stopped && item.kind != .book && !value.finished && shown != nil && shown?.finished == false && (shown?.seconds ?? 0) >= 3
            && shown?.track == value.track && abs((shown?.seconds ?? 0) - value.seconds) < 30
        if quiet {
            unpublished[key] = value
        } else {
            unpublished[key] = nil
            progress[key] = value
        }
        persist(soon: stopped)
    }

    /// The length of one track as the scan found it, for callers that don't have the player at hand (the web app, a phone).
    private func knownDuration(of item: MediaItem, track: Int) -> Double? {
        let details = info[item.progressKey]
        if item.tracks.count == 1 { return details?.duration }
        guard let tracks = details?.tracks, tracks.indices.contains(track) else { return nil }
        return tracks[track].duration
    }

    /// True once playback is far enough into the last video or audio track that what's left is credits or an outro:
    /// 95% through, or, for anything over ten minutes, the last minute. Such an item counts as finished, so it leaves
    /// Keep Watching and Continue instead of sitting there at 99%.
    nonisolated static func atTheFinishLine(position: Double, duration: Double) -> Bool {
        guard duration > 0, position.isFinite else { return false }
        return position / duration >= 0.95 || (duration >= 600 && duration - position <= 60)
    }

    /// The same save, marked finished when it's at the finish line of the last track. Books decide this themselves.
    nonisolated static func applyingFinishLine(_ value: MediaProgress, item: MediaItem, duration: Double?) -> MediaProgress {
        guard !value.finished, item.kind != .book, value.track == item.tracks.count - 1,
              let duration, atTheFinishLine(position: value.seconds, duration: duration) else { return value }
        return MediaProgress(track: value.track, seconds: 0, finished: true, updated: value.updated)
    }

    /// Writes the progress file once a moment from now (sooner when playback has just stopped). Saves that arrive
    /// in the meantime are covered by the same write, and encoding and writing happen off the main thread.
    private func persist(soon: Bool) {
        persistDirty = true
        guard persistTask == nil else { return }
        persistTask = Task { [weak self] in
            try? await Task.sleep(for: soon ? .milliseconds(300) : .seconds(3))
            while let self, self.persistDirty {
                self.persistDirty = false
                var snapshot = self.progress
                for (key, value) in self.unpublished { snapshot[key] = value }
                await Task.detached(priority: .utility) {
                    if let data = try? JSONEncoder().encode(snapshot), let text = String(data: data, encoding: .utf8) {
                        KitSettings.shared.set(text, forKey: "mediaProgress")
                    }
                }.value
            }
            self?.persistTask = nil
        }
    }

    /// Copies picked files into the kit: into `subfolder` of Media ("Books", "Audiobooks", "Music", or "" for videos),
    /// so each lands in the right section. A file that's already there (same name and contents) isn't copied again
    /// and is counted in the result; a different file with the same name is kept beside it as "Name 2".
    @discardableResult
    func importFiles(_ urls: [URL], into subfolder: String = "", library: Library) async throws -> Int {
        let media = Self.importFolder
        let dest = subfolder.isEmpty ? media : media.appending(path: subfolder, directoryHint: .isDirectory)
        library.adopt(media.deletingLastPathComponent())
        // Copied off the main thread (movies are big). Whatever was copied before a failure still shows up:
        // the rescan runs either way.
        let result = await Task.detached(priority: .userInitiated) { () -> (Int, Error?) in
            let fm = FileManager.default
            var already = 0
            do {
                try fm.createDirectory(at: dest, withIntermediateDirectories: true)
                for url in urls {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    var target = dest.appending(path: url.lastPathComponent)
                    if fm.fileExists(atPath: target.path) {
                        if Self.sameFile(target, url) { already += 1; continue }
                        let base = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
                        for n in 2...999 {
                            let candidate = dest.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                            if !fm.fileExists(atPath: candidate.path) { target = candidate; break }
                        }
                    }
                    // Copied under a .part name first so a failed copy never leaves a truncated file that looks playable.
                    let temp = dest.appending(path: target.lastPathComponent + ".part")
                    try? fm.removeItem(at: temp)
                    do {
                        try fm.copyItem(at: url, to: temp)
                        try fm.moveItem(at: temp, to: target)
                    } catch {
                        try? fm.removeItem(at: temp)
                        throw error
                    }
                }
                return (already, nil)
            } catch { return (already, error) }
        }.value
        await reload(library: library)
        if let error = result.1 { throw error }
        return result.0
    }

    /// Same size and the same checksum (sampled for very big files).
    nonisolated static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let size = { (url: URL) in Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1) }
        let sa = size(a)
        guard sa >= 0, sa == size(b) else { return false }
        guard let fa = FileChecksum.fingerprint(a, size: sa) else { return false }
        return fa == FileChecksum.fingerprint(b, size: sa)
    }
}

// MARK: - LibriVox

/// A public-domain audiobook from LibriVox (volunteer readings), downloaded chapter by chapter from the Internet Archive.
struct LibriVoxBook: Identifiable, Hashable {
    let id: Int              // LibriVox project id
    let title: String
    let author: String
    let seconds: Int
    let ages: String

    var folderName: String { title.replacingOccurrences(of: "/", with: "-") }
    /// LibriVox chapter files are 64 kbps MP3: about 8 KB per second.
    var estimatedBytes: Int64 { Int64(seconds) * 8_000 }
    var duration: String {
        Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    static let picks: [LibriVoxBook] = [
        .init(id: 15229, title: "The Tale of Peter Rabbit and Others", author: "Beatrix Potter", seconds: 10_653, ages: "3+"),
        .init(id: 17468, title: "Winnie-the-Pooh", author: "A. A. Milne", seconds: 10_469, ages: "4+"),
        .init(id: 9041, title: "Aesop's Fables", author: "Aesop", seconds: 16_166, ages: "4+"),
        .init(id: 585, title: "Just So Stories", author: "Rudyard Kipling", seconds: 12_781, ages: "5+"),
        .init(id: 200, title: "Alice's Adventures in Wonderland", author: "Lewis Carroll", seconds: 10_731, ages: "6+"),
        .init(id: 816, title: "Peter Pan", author: "J. M. Barrie", seconds: 18_249, ages: "6+"),
        .init(id: 375, title: "Grimms' Fairy Tales", author: "Brothers Grimm", seconds: 37_952, ages: "6+"),
        .init(id: 8105, title: "Pinocchio", author: "Carlo Collodi", seconds: 18_179, ages: "6+"),
        .init(id: 14233, title: "Heidi", author: "Johanna Spyri", seconds: 20_059, ages: "7+"),
        .init(id: 155, title: "Black Beauty", author: "Anna Sewell", seconds: 22_497, ages: "8+"),
        .init(id: 449, title: "Treasure Island", author: "Robert Louis Stevenson", seconds: 27_008, ages: "9+"),
        .init(id: 146, title: "Anne of Green Gables", author: "L. M. Montgomery", seconds: 37_811, ages: "9+"),
    ]
}

/// Downloads LibriVox audiobooks one at a time into Media/Audiobooks/<title>/.
@MainActor @Observable
final class AudiobookDownloads {
    enum State: Equatable { case queued, downloading(Double), done, failed(String) }
    private(set) var states: [Int: State] = [:]
    private var queue: [LibriVoxBook] = []
    private var running = false
    var onFinished: (() -> Void)?

    func folder(for book: LibriVoxBook) -> URL {
        MediaLibrary.importFolder.appending(path: "Audiobooks/\(book.folderName)", directoryHint: .isDirectory)
    }

    func isInstalled(_ book: LibriVoxBook) -> Bool {
        FileManager.default.fileExists(atPath: folder(for: book).appending(path: ".complete").path)
    }

    func get(_ book: LibriVoxBook) {
        // A finished book that has since been deleted can be fetched again; only block while it's queued or downloading.
        switch states[book.id] {
        case .queued?, .downloading?: return
        case .done? where isInstalled(book): return
        default: break
        }
        states[book.id] = .queued
        queue.append(book)
        if !running { Task { await run() } }
    }

    private var currentTask: Task<Void, Error>?
    private var currentBook: Int?

    /// Stops a download that is waiting or running. What it had fetched so far is removed, so no half-finished book shows up.
    func cancel(_ book: LibriVoxBook) {
        if let index = queue.firstIndex(where: { $0.id == book.id }) {
            queue.remove(at: index)
            states[book.id] = nil
        } else if currentBook == book.id {
            currentTask?.cancel()
        }
    }

    /// The reason a download failed, in plain words.
    nonisolated static func reason(for error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
                return "Needs internet to download"
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return "Couldn’t make a safe connection to LibriVox"
            default: break
            }
        }
        if ns.domain == NSCocoaErrorDomain && ns.code == NSFileWriteOutOfSpaceError { return "Not enough room on the drive" }
        if error is URLError || (error as? DecodingError) != nil { return "LibriVox didn’t answer properly. Try again in a little while" }
        return "Couldn’t finish the download. Try again in a little while"
    }

    private func run() async {
        running = true
        while !queue.isEmpty {
            let book = queue.removeFirst()
            let task = Task { try await download(book) }
            currentTask = task
            currentBook = book.id
            do {
                try await task.value
                states[book.id] = .done
                onFinished?()
            } catch is CancellationError {
                discardPartial(book)
            } catch let error as URLError where error.code == .cancelled {
                discardPartial(book)
            } catch {
                states[book.id] = .failed(Self.reason(for: error))
            }
            currentTask = nil
            currentBook = nil
        }
        running = false
    }

    private func discardPartial(_ book: LibriVoxBook) {
        states[book.id] = nil
        if !isInstalled(book) { try? FileManager.default.removeItem(at: folder(for: book)) }
    }

    private struct Sections: Decodable {
        struct Section: Decodable { let section_number: String; let title: String; let listen_url: String; let playtime: String? }
        let sections: [Section]
    }

    /// LibriVox's track links can be plain http (archive.org); fetch them over https instead.
    private static func secure(_ link: String) -> URL? {
        guard var parts = URLComponents(string: link) else { return nil }
        if parts.scheme == "http" { parts.scheme = "https" }
        guard parts.scheme == "https", parts.host?.isEmpty == false else { return nil }   // never file:// or other schemes
        return parts.url
    }

    private func download(_ book: LibriVoxBook) async throws {
        states[book.id] = .downloading(0)
        var request = URLRequest(url: URL(string: "https://librivox.org/api/feed/audiotracks?project_id=\(book.id)&format=json")!)
        request.setValue(ProductLookup.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let sections = try JSONDecoder().decode(Sections.self, from: data).sections
        guard !sections.isEmpty else { throw URLError(.resourceUnavailable) }
        let dest = folder(for: book)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for (i, section) in sections.enumerated() {
            let number = String(format: "%02d", Int(section.section_number) ?? i + 1)
            let name = "\(number) - \(section.title.replacingOccurrences(of: "/", with: "-")).mp3"
            let target = dest.appending(path: name)
            if !FileManager.default.fileExists(atPath: target.path), let url = Self.secure(section.listen_url) {
                var req = URLRequest(url: url)
                req.setValue(ProductLookup.userAgent, forHTTPHeaderField: "User-Agent")
                let (temp, response) = try await URLSession.shared.download(for: req)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                try FileManager.default.moveItem(at: temp, to: target)
            }
            states[book.id] = .downloading(Double(i + 1) / Double(sections.count))
        }
        try Data("LibriVox project \(book.id): \(book.title) by \(book.author). Public domain recording from librivox.org.\n".utf8)
            .write(to: dest.appending(path: ".complete"))
    }
}

// MARK: - Player

/// Plays one item, moves through chapters and remembers the position.
@MainActor @Observable
final class MediaPlayback {
    let item: MediaItem
    let player = AVPlayer()
    private(set) var track = 0
    private(set) var current: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var sleepDeadline: Date?
    private(set) var sleepAtChapterEnd = false
    private(set) var finished = false
    /// Why the current file can't be played, in plain words. Nil while it plays (or is still opening).
    private(set) var problem: String?
    private var shuffleOrder: [Int]?
    /// Listening speed. Remembered per audiobook, so a book set to 1.5× opens at 1.5× next time.
    var rate: Float = 1 {
        didSet {
            if isPlaying { player.rate = rate }
            if item.kind == .audio && rate != oldValue { library?.saveRate(rate, for: item) }
            announce()
        }
    }

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private weak var library: MediaLibrary?
    @ObservationIgnored private var lastSaved = Date.distantPast
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    /// How long before a sleep timer ends the sound fades out.
    nonisolated static let sleepFade: Double = 25

    init(item: MediaItem, library: MediaLibrary) {
        self.item = item
        self.library = library
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: item.kind == .video ? .moviePlayback : .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        if item.kind == .audio { rate = library.savedRate(for: item) }
        let saved = library.progress[item.progressKey]
        let startTrack = saved.map { $0.finished ? 0 : min($0.track, item.tracks.count - 1) } ?? 0
        load(track: startTrack, at: saved.flatMap { $0.finished ? nil : $0.seconds } ?? 0)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    func cleanUp() {
        save(force: true)
        player.pause()
        SystemMediaControls.shared.clear(self)
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        statusObservation = nil
        player.volume = 1
    }

    /// An album or song rather than an audiobook.
    var isMusic: Bool {
        item.kind == .audio && library.map { MediaCatalog.category(item, $0.info[item.progressKey]) == .music } == true
    }

    var trackTitle: String {
        item.tracks.count > 1 ? MediaLibrary.prettyTitle(item.tracks[track].deletingPathExtension().lastPathComponent) : item.title
    }

    func load(track index: Int, at seconds: Double = 0, play: Bool = false) {
        guard item.tracks.indices.contains(index) else { return }
        if player.currentItem != nil { save(force: true) }
        finished = false
        problem = nil
        track = index
        let playerItem = AVPlayerItem(url: item.tracks[index])
        player.replaceCurrentItem(with: playerItem)
        // A file that can't be opened never says so by itself: the player just stays black. Watch for it.
        statusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            let reason = observed.error
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === observed else { return }
                self.problem = Self.reason(for: reason)
                self.isPlaying = false
                self.announce()
            }
        }
        if seconds > 1 { player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) }
        current = seconds
        duration = 0
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackEnded() }
        }
        Task { [weak self] in
            if let d = try? await playerItem.asset.load(.duration), d.isNumeric, self?.player.currentItem === playerItem {
                self?.duration = d.seconds
                self?.announce()
            }
        }
        if play { self.play() } else { announce() }
    }

    /// Keeps the keyboard's media keys, Control Center and the Lock Screen in step with this player.
    private func announce() {
        SystemMediaControls.shared.update(self, info: library?.info[item.progressKey])
    }

    /// What to tell someone about a file that won't open. The system's own wording is for programmers.
    private static func reason(for error: Error?) -> String {
        if let error = error as NSError?, error.domain == NSURLErrorDomain || error.code == NSFileReadNoSuchFileError {
            return "The file isn’t where the kit expects it. It may have been moved, or its drive unplugged."
        }
        return "It may be damaged, still copying, or in a format this device can’t play."
    }

    /// Stops after some minutes or at the end of the chapter. Either way the sound fades out over the last
    /// `sleepFade` seconds, so it doesn't cut off. Calling it with nothing cancels the timer.
    func setSleep(minutes: Int? = nil, endOfChapter: Bool = false) {
        sleepDeadline = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        sleepAtChapterEnd = endOfChapter
        if sleepDeadline == nil && !endOfChapter { player.volume = 1 }
    }

    /// Seconds until the sleep timer stops playback, if one is set and counting.
    private var sleepRemaining: Double? {
        if let deadline = sleepDeadline { return deadline.timeIntervalSinceNow }
        if sleepAtChapterEnd, duration > 0 { return (duration - current) / Double(max(rate, 0.1)) }
        return nil
    }

    private func fadeForSleep() {
        guard let remaining = sleepRemaining else { if player.volume != 1 { player.volume = 1 }; return }
        let volume = Float(min(1, max(0, remaining / Self.sleepFade)))
        if abs(player.volume - volume) > 0.02 { player.volume = volume }
    }

    func play() {
        if finished { shuffleOrder = nil; load(track: 0) }
        player.playImmediately(atRate: rate); isPlaying = true; announce() }
    func pause() { player.pause(); isPlaying = false; save(force: true); announce() }
    func toggle() { isPlaying ? pause() : play() }

    func skip(_ seconds: Double) {
        let target = max(0, min(duration > 0 ? duration - 1 : .greatestFiniteMagnitude, current + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        current = target
        announce()
    }

    func seek(to fraction: Double) {
        guard duration > 0 else { return }
        let target = duration * fraction
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        current = target
        announce()
    }

    var nextTrack: Int? {
        let order = shuffleOrder ?? Array(item.tracks.indices)
        guard let position = order.firstIndex(of: track), position + 1 < order.count else { return nil }
        return order[position + 1]
    }
    func shuffle() {
        let order = Array(item.tracks.indices).shuffled()
        shuffleOrder = order
        if let first = order.first { load(track: first, play: true) }
    }
    func next() { if let nextTrack { load(track: nextTrack, play: isPlaying) } }
    func previous() {
        let order = shuffleOrder ?? Array(item.tracks.indices)
        let position = order.firstIndex(of: track) ?? 0
        if current > 5 || position == 0 { player.seek(to: .zero); current = 0; announce() }
        else { load(track: order[position - 1], play: isPlaying) }
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite else { return }
        current = seconds
        if let deadline = sleepDeadline, Date() >= deadline { setSleep(); pause(); player.volume = 1 } else { fadeForSleep() }
        if let d = player.currentItem?.duration.seconds, d.isFinite { duration = d }
        // The system player's own controls can pause or play too; keep the mini player in step.
        let playing = player.rate != 0
        if playing != isPlaying { isPlaying = playing; announce() }
        save(force: false)
    }

    private func trackEnded() {
        let shouldSleep = sleepAtChapterEnd
        if shouldSleep { setSleep(); pause(); player.volume = 1 }
        if let nextTrack {
            load(track: nextTrack, play: !shouldSleep)
        } else {
            isPlaying = false
            finished = true
            announce()
            library?.saveProgress(MediaProgress(track: track, seconds: 0, finished: true), for: item)
        }
    }

    private func save(force: Bool) {
        guard force || Date().timeIntervalSince(lastSaved) > 5 else { return }
        lastSaved = Date()
        library?.saveProgress(MediaProgress(track: track, seconds: finished ? 0 : current, finished: finished), for: item, stopped: force,
                              duration: duration > 0 ? duration : nil)
    }
}
