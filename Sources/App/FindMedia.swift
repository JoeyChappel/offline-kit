#if os(macOS)
import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import AppKit

// "Find my media": looks through folders the person picks for videos, music, audiobooks, books and games,
// lets them ask for what they want in plain words, and adds the picks to the kit: linked where they are,
// copied, or moved (copy, check, then the original goes to the Trash, only after they confirm the list).
// Everything runs on this Mac; the request is read by the local model when one is set up.

/// One thing found on the Mac: a video, an album or audiobook (a folder of tracks), a book or a game.
struct FoundMedia: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, CaseIterable, Identifiable {
        case music, audiobook, video, book, game
        var id: String { rawValue }
        var label: String {
            switch self {
            case .music: "Albums and songs"
            case .audiobook: "Audiobooks"
            case .video: "Videos"
            case .book: "Books"
            case .game: "Games"
            }
        }
        var symbol: String {
            switch self {
            case .music: "music.note"
            case .audiobook: "headphones"
            case .video: "film"
            case .book: "book.closed"
            case .game: "gamecontroller"
            }
        }
    }
    enum InKit: Hashable, Sendable {
        case no, copy(String), linked
        /// Some of an album's or audiobook's tracks are in the kit already: how many of how many.
        case partly(Int, Int)
        /// Not in the kit, or only partly: adding it brings the rest.
        var addable: Bool { switch self { case .no, .partly: true; default: false } }
    }

    let id: String
    var kind: Kind
    var title: String
    var creator: String? = nil
    /// The heading it's grouped under: an artist, an author or a series folder.
    var collection: String? = nil
    var files: [URL]
    /// The album or audiobook folder.
    var folder: URL? = nil
    var bytes: Int64 = 0
    /// A small picture: folder art, embedded artwork or an EPUB cover.
    var cover: Data? = nil
    /// Copy-protected (FairPlay) purchases: they won't play outside Apple's apps.
    var protected = false
    var inKit: InKit = .no
    var year: Int? = nil
    var genre: String? = nil
    /// Lowercased names and tags the request is matched against.
    var searchText = ""
    /// Words from the request it matched, for the "Matched" line.
    var matched: [String] = []

    var location: String {
        let path = (folder ?? files.first?.deletingLastPathComponent())?.path ?? ""
        return path.replacingOccurrences(of: KitLocation.home.path, with: "~")
    }
}

struct FindLocation: Identifiable, Hashable {
    let url: URL
    let name: String
    let symbol: String
    var id: String { url.path }
    /// macOS asks before an app reads Desktop, Documents, Downloads, external drives and network shares.
    var asksPermission: Bool {
        let home = KitLocation.home.path
        return ["Desktop", "Documents", "Downloads"].contains { url.path == home + "/" + $0 || url.path.hasPrefix(home + "/" + $0 + "/") }
            || url.path.hasPrefix("/Volumes/")
    }
}

@MainActor @Observable
final class MediaFinder {
    static let shared = MediaFinder()

    enum Phase: Equatable { case choosing, scanning, reading, ready, adding, done }
    enum AddMode: String, CaseIterable, Identifiable {
        case keep, copy, move
        var id: String { rawValue }
        var label: String {
            switch self {
            case .keep: "Keep where it is"
            case .copy: "Copy into the kit"
            case .move: "Move into the kit"
            }
        }
        var detail: String {
            switch self {
            case .keep: "The kit remembers where it is. If it’s on a drive that’s unplugged, it shows as unavailable until you plug it in."
            case .copy: "A copy goes into your kit’s library, so it travels with the kit. The originals stay put."
            case .move: "Copied into the kit and checked, then the originals go to the Trash. You’ll see the list first."
            }
        }
    }

    var locations: [FindLocation] = []
    var chosen: Set<String> = []
    private(set) var phase: Phase = .choosing
    private(set) var looked = 0
    private(set) var currentFolder = ""
    private(set) var found: [FoundMedia] = []
    private(set) var skippedCloud = 0
    /// Places macOS didn't let Offline Kit read (permission turned off in Privacy & Security).
    private(set) var denied: [String] = []
    var selection: Set<String> = []
    var mode: AddMode = .copy
    var kindFilter: FoundMedia.Kind?

    // Asking for something
    var request = ""
    private(set) var searching = false
    private(set) var searchNote: String?
    /// Ranked ids when a request is active; nil shows everything.
    private(set) var ranked: [String]?
    private(set) var terms: [String] = []

    // Adding
    private(set) var added = 0
    private(set) var toAdd = 0
    private(set) var addingName = ""
    private(set) var failures: [String] = []
    private(set) var summary = ""

    @ObservationIgnored private var task: Task<Void, Never>?

    init() { refreshLocations() }

    func refreshLocations() {
        let home = KitLocation.home
        var list: [FindLocation] = [
            .init(url: home.appending(path: "Music", directoryHint: .isDirectory), name: "Music", symbol: "music.note.house"),
            .init(url: home.appending(path: "Movies", directoryHint: .isDirectory), name: "Movies", symbol: "film"),
            .init(url: home.appending(path: "Downloads", directoryHint: .isDirectory), name: "Downloads", symbol: "arrow.down.circle"),
            .init(url: home.appending(path: "Documents", directoryHint: .isDirectory), name: "Documents", symbol: "doc"),
            .init(url: home.appending(path: "Desktop", directoryHint: .isDirectory), name: "Desktop", symbol: "menubar.dock.rectangle"),
        ].filter { FileManager.default.fileExists(atPath: $0.url.path) }
        for volume in Self.externalVolumes() { list.append(.init(url: volume, name: volume.lastPathComponent, symbol: "externaldrive")) }
        // Folders added with "Choose a folder…" stay in the list.
        for location in locations where !list.contains(where: { $0.id == location.id }) { list.append(location) }
        locations = list
        if chosen.isEmpty { chosen = Set(list.filter { $0.symbol != "externaldrive" }.map(\.id)) }
    }

    /// Drives under /Volumes other than this Mac's own disk. In the isolated test mode only test drives ("OKTest…").
    nonisolated static func externalVolumes() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? []
        return names.sorted().compactMap { name in
            let url = URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true)
            if url.resolvingSymlinksInPath().path == "/" { return nil }
            if KitLocation.testHome != nil && !name.hasPrefix("OKTest") { return nil }
            return url
        }
    }

    func addFolder(_ url: URL) {
        let location = FindLocation(url: url, name: url.lastPathComponent, symbol: "folder")
        if !locations.contains(location) { locations.append(location) }
        chosen.insert(location.id)
    }

    // MARK: Scanning

    func scan(library: Library, media: MediaLibrary, games: GameLibrary) {
        task?.cancel()
        let roots = locations.filter { chosen.contains($0.id) }.map(\.url)
        guard !roots.isEmpty else { return }
        phase = .scanning; looked = 0; found = []; selection = []; ranked = nil; terms = []; searchNote = nil; skippedCloud = 0; denied = []
        // The kit's own folders aren't searched: what's there is already in the kit.
        let kitFolders = (library.folders + [KitStorage.primaryLibrary]).map { $0.standardizedFileURL.path }
        let kitFiles = media.items.filter { $0.unavailable == nil && $0.linkID == nil }.flatMap(\.tracks) + games.games.map(\.url)
        let linked = Set(media.items.filter { $0.linkID != nil }.flatMap { $0.tracks.map(\.path) })
        task = Task { [weak self] in
            let walk = await Task.detached(priority: .userInitiated) { () -> ([URL], Int, [String]) in
                Self.walk(roots, skipping: kitFolders) { count, folder in
                    Task { @MainActor in self?.looked = count; self?.currentFolder = folder }
                }
            }.value
            guard let self, !Task.isCancelled else { return }
            self.skippedCloud = walk.1
            self.denied = walk.2
            self.phase = .reading
            self.looked = 0
            let groups = Self.group(walk.0, roots: roots)
            let kitIndex = await Task.detached { Self.sizeIndex(kitFiles) }.value
            var results: [FoundMedia] = []
            results.reserveCapacity(groups.count)
            // Tags, covers and "already in the kit" checks, a few at a time.
            await withTaskGroup(of: FoundMedia.self) { group in
                var next = groups.makeIterator()
                func add() { if let item = next.next() { group.addTask { await Self.enrich(item, kitIndex: kitIndex, linked: linked, roots: roots) } } }
                for _ in 0..<4 { add() }
                for await item in group {
                    results.append(item)
                    self.looked = results.count
                    self.currentFolder = item.title
                    if Task.isCancelled { group.cancelAll(); break }
                    add()
                }
            }
            guard !Task.isCancelled else { return }
            self.found = results.sorted { ($0.kind.rawValue, $0.collection ?? "", $0.title) < ($1.kind.rawValue, $1.collection ?? "", $1.title) }
            self.phase = .ready
        }
    }

    func cancel() {
        task?.cancel(); task = nil
        if phase == .scanning || phase == .reading { phase = found.isEmpty ? .choosing : .ready }
    }

    /// Every media and game file under the roots. Skips app bundles and other packages (the Photos library),
    /// ~/Library, system folders, the Trash, the kit's own folders and iCloud files that aren't downloaded.
    nonisolated static func walk(_ roots: [URL], skipping kitFolders: [String], progress: @escaping @Sendable (Int, String) -> Void) -> ([URL], Int, [String]) {
        let fm = FileManager.default
        let home = KitLocation.home.path
        let skipPaths = Set([home + "/Library", "/System", "/Library", "/Applications", "/private", "/usr", "/bin", "/sbin",
                             "/opt", "/cores", "/dev", "/Volumes"] + kitFolders)
        let skipNames: Set<String> = [".Trash", ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100",
                                      "node_modules", ".git", "Saves", "Photos Library.photoslibrary"]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let mediaExtensions = MediaLibrary.videoExtensions.union(MediaLibrary.audioExtensions).union(MediaLibrary.bookExtensions).union(["m4p"])
        var files: [URL] = [], seen = Set<String>(), count = 0, cloud = 0, denied: [String] = []
        for root in roots {
            // The first read of Desktop, Documents, Downloads or a drive is where macOS asks. If it was turned off,
            // the folder reads as forbidden (the enumerator would just come back empty), so say so instead.
            progress(count, root.path.replacingOccurrences(of: home, with: "~"))
            do { _ = try fm.contentsOfDirectory(atPath: root.path) } catch {
                let ns = error as NSError, underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
                if ns.code == NSFileReadNoPermissionError || underlying?.code == Int(EPERM) || underlying?.code == Int(EACCES) {
                    denied.append(root.lastPathComponent)
                }
                continue
            }
            guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in walker {
                if Task.isCancelled { return (files, cloud, denied) }
                count += 1
                let path = url.standardizedFileURL.path
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if (skipPaths.contains(path) && path != root.standardizedFileURL.path)
                        || skipNames.contains(url.lastPathComponent) || values?.isPackage == true || url.pathExtension == "app" {
                        walker.skipDescendants()
                        continue
                    }
                    if count % 150 == 0 { progress(count, path.replacingOccurrences(of: home, with: "~")) }
                    // A ScummVM game is a folder inside a "ScummVM" folder.
                    if GameSystem(file: url) == .scummvm { files.append(url); walker.skipDescendants() }
                    continue
                }
                if values?.isUbiquitousItem == true, values?.ubiquitousItemDownloadingStatus != .current { cloud += 1; continue }
                if url.lastPathComponent.hasPrefix("._") || url.pathExtension == "part" { continue }
                let ext = url.pathExtension.lowercased()
                guard mediaExtensions.contains(ext) || GameSystem(file: url) != nil else { continue }
                if seen.insert(path).inserted { files.append(url) }
            }
        }
        progress(count, "")
        return (files, cloud, denied)
    }

    /// Files into items: a folder of audio tracks is one album or audiobook; loose tracks in a chosen folder
    /// (~/Downloads/song.mp3) are each their own; every video, book and game is its own.
    nonisolated static func group(_ files: [URL], roots: [URL]) -> [FoundMedia] {
        let rootPaths = Set(roots.map { $0.standardizedFileURL.path })
        var items: [FoundMedia] = []
        var audioByFolder: [URL: [URL]] = [:]
        for url in files {
            let ext = url.pathExtension.lowercased()
            if MediaLibrary.audioExtensions.contains(ext) || ext == "m4p" {
                audioByFolder[url.deletingLastPathComponent(), default: []].append(url)
            } else if MediaLibrary.videoExtensions.contains(ext) {
                items.append(FoundMedia(id: url.path, kind: .video, title: MediaLibrary.prettyTitle(url.deletingPathExtension().lastPathComponent), files: [url]))
            } else if MediaLibrary.bookExtensions.contains(ext) {
                items.append(FoundMedia(id: url.path, kind: .book, title: MediaLibrary.prettyTitle(url.deletingPathExtension().lastPathComponent), files: [url]))
            } else if let system = GameSystem(file: url) {
                items.append(FoundMedia(id: url.path, kind: .game, title: Game(url: url, system: system).title, creator: system.name, files: [url]))
            }
        }
        for (folder, tracks) in audioByFolder {
            let sorted = tracks.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            if rootPaths.contains(folder.standardizedFileURL.path) || sorted.count == 1 && sorted[0].pathExtension.lowercased() == "m4b" {
                for track in sorted {
                    items.append(FoundMedia(id: track.path, kind: .music, title: MediaLibrary.prettyTitle(track.deletingPathExtension().lastPathComponent), files: [track]))
                }
            } else {
                items.append(FoundMedia(id: folder.path, kind: .music, title: MediaLibrary.prettyTitle(folder.lastPathComponent), files: sorted, folder: folder))
            }
        }
        return items
    }

    /// Kit files by size, for the "already in the kit" check.
    nonisolated static func sizeIndex(_ files: [URL]) -> [Int64: [URL]] {
        var index: [Int64: [URL]] = [:]
        for url in files {
            guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { continue }
            index[Int64(size), default: []].append(url)
        }
        return index
    }

    private nonisolated static let genericFolders: Set<String> = [
        "music", "movies", "downloads", "documents", "desktop", "audiobooks", "audio books", "books", "ebooks", "videos",
        "media", "itunes", "itunes media", "tv shows", "home videos", "compilations", "unknown artist", "unknown album",
        "games", "roms", "library", "dos", "scummvm",
    ]

    /// Reads tags (AVFoundation metadata, EPUB metadata), the cover, copy protection and whether it's already in the kit.
    nonisolated static func enrich(_ base: FoundMedia, kitIndex: [Int64: [URL]], linked: Set<String>, roots: [URL]) async -> FoundMedia {
        var item = base
        let fm = FileManager.default
        let rootNames = Set(roots.map { $0.lastPathComponent.lowercased() })
        func meaningful(_ folder: URL?) -> String? {
            guard let name = folder?.lastPathComponent, !genericFolders.contains(name.lowercased()), !rootNames.contains(name.lowercased()),
                  folder?.path != KitLocation.home.path, folder?.path != "/" else { return nil }
            return MediaLibrary.prettyTitle(name)
        }
        item.bytes = item.files.reduce(0) { $0 + KitTransfer.size(of: $1) }
        var words: [String] = [item.title] + item.files.map { $0.deletingPathExtension().lastPathComponent }
        // Folder names count too ("Music/The Beatles/Abbey Road").
        if let first = item.files.first {
            words += first.deletingLastPathComponent().pathComponents.suffix(4)
        }

        switch item.kind {
        case .music:
            let first = item.files[0]
            let tag = await AudioTags.read(first)
            if item.files.contains(where: { $0.pathExtension.lowercased() == "m4p" }) { item.protected = true }
            if item.folder != nil, let album = tag.album, !album.isEmpty { item.title = album }
            else if item.folder == nil, let title = tag.title, !title.isEmpty { item.title = title }
            item.creator = tag.albumArtist ?? tag.artist ?? meaningful(item.folder?.deletingLastPathComponent())
            item.year = tag.year
            item.genre = tag.genre
            words += [tag.album, tag.artist, tag.albumArtist, tag.genre, tag.title].compactMap { $0 }
            // Track titles, so "the one with Yesterday" can find the album. Up to 40 per folder.
            for track in item.files.dropFirst().prefix(40) {
                let t = await AudioTags.read(track)
                words += [t.title, t.artist].compactMap { $0 }
            }
            // Audiobook or music: the same rules as the library (m4b, an Audiobooks folder, a spoken-word genre, chapters).
            let probe = MediaItem(kind: .audio, title: item.title, tracks: item.files, root: item.files[0].deletingLastPathComponent(), cover: nil)
            let info = MediaInfo(duration: tag.duration.map { $0 * Double(item.files.count) }, year: tag.year, genre: tag.genre, added: Date(), thumb: nil)
            if MediaCatalog.category(probe, info) == .audiobooks { item.kind = .audiobook }
            if let folder = item.folder {
                let art = ["cover.jpg", "cover.png", "folder.jpg", "Folder.jpg", "front.jpg"].map { folder.appending(path: $0) }.first { fm.fileExists(atPath: $0.path) }
                item.cover = art.flatMap { try? Data(contentsOf: $0) }.flatMap(thumbnail)
            }
            if item.cover == nil, let data = tag.artwork { item.cover = thumbnail(data) }
            item.collection = item.kind == .audiobook ? (meaningful(item.folder?.deletingLastPathComponent()) ?? item.creator) : item.creator
        case .video:
            let asset = AVURLAsset(url: item.files[0])
            if (try? await asset.load(.hasProtectedContent)) == true || item.files[0].pathExtension.lowercased() == "m4p" { item.protected = true }
            for entry in (try? await asset.load(.metadata)) ?? [] {
                let common = entry.commonKey?.rawValue.lowercased() ?? ""
                if common == "artwork", item.cover == nil, let data = try? await entry.load(.dataValue) { item.cover = thumbnail(data); continue }
                guard let value = try? await entry.load(.stringValue), !value.isEmpty else { continue }
                let id = entry.identifier?.rawValue.lowercased() ?? ""
                if common == "title" { item.title = value }
                else if common == "artist" || common == "creator" { item.creator = value }
                else if id.contains("genre") || id.contains("gen") { item.genre = value }
                else if id.contains("year") || id.contains("day") || id.contains("date") { item.year = Int(value.prefix(4)) }
                words.append(value)
            }
            if item.year == nil { item.year = MediaCatalog.year(in: item.title) }
            if item.cover == nil, let sidecar = MediaCover.sidecar(for: item.files[0]) { item.cover = (try? Data(contentsOf: sidecar)).flatMap(thumbnail) }
            item.collection = meaningful(item.files[0].deletingLastPathComponent())
        case .book:
            let url = item.files[0]
            if url.pathExtension.lowercased() == "epub", let (book, zip) = EPUBBook.open(url) {
                item.title = book.title
                item.creator = book.author
                item.genre = MediaInfoStore.friendlyGenre(book.subjects)
                words += [book.title, book.author].compactMap { $0 } + book.subjects
                if let cover = book.coverPath, let data = zip.data(cover) { item.cover = thumbnail(data) }
            } else if let doc = PDFDocument(url: url) {
                let attributes = doc.documentAttributes ?? [:]
                if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String, title.count > 2 { words.append(title) }
                item.creator = attributes[PDFDocumentAttribute.authorAttribute] as? String
                words += [item.creator].compactMap { $0 }
            }
            item.collection = meaningful(url.deletingLastPathComponent()) ?? item.creator
        case .game:
            item.collection = item.creator   // the system
        case .audiobook:
            break
        }
        item.searchText = words.joined(separator: " ").lowercased()

        // Already in the kit: every file linked at this very path, or a kit file with the same size and checksum.
        // Some but not all of an album's tracks: "Partly in kit", and adding it brings the rest.
        if !item.files.isEmpty {
            if item.files.allSatisfy({ linked.contains($0.path) }) { item.inKit = .linked }
            else {
                var copies: [String] = []
                for file in item.files {
                    if linked.contains(file.path) { copies.append(file.lastPathComponent); continue }
                    let size = KitTransfer.size(of: file)
                    guard let candidates = kitIndex[size], let mine = FileChecksum.fingerprint(file, size: size) else { continue }
                    if let match = candidates.first(where: { $0.path != file.path && FileChecksum.fingerprint($0, size: size) == mine }) {
                        copies.append(match.lastPathComponent)
                    }
                }
                if copies.count == item.files.count { item.inKit = .copy(copies[0]) }
                else if !copies.isEmpty { item.inKit = .partly(copies.count, item.files.count) }
            }
        }
        return item
    }

    nonisolated static func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                         kCGImageSourceThumbnailMaxPixelSize: 220,
                                                                         kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? output as Data : nil
    }

    // MARK: Asking for something

    /// "my Beatles albums" → search words and kinds (by the local model when there is one), matched against
    /// names and tags, then the model picks which of the closest matches really fit. Nothing leaves this Mac.
    func ask(_ text: String, model: AskModel) {
        let request = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty else { clearRequest(); return }
        searching = true
        kindFilter = nil   // the request decides what kinds it's about
        searchNote = nil
        Task {
            let engine = await model.resolveEngine()
            var (terms, kinds) = Self.keywordTerms(request)
            var usedModel = false
            if let engine, let parsed = await Self.modelTerms(request, engine: engine) {
                usedModel = true
                terms = Array(NSOrderedSet(array: (parsed.terms + terms).map { $0.lowercased() })) as? [String] ?? terms
                if !parsed.kinds.isEmpty { kinds = parsed.kinds }
            }
            // "my games", "all my audiobooks": no names to look for, so everything of that kind.
            let scored = terms.isEmpty && !kinds.isEmpty
                ? found.filter { kinds.contains($0.kind) && !$0.protected }.map { ($0, 1.0, [$0.kind.label.lowercased()]) }
                : Self.score(found, terms: terms, kinds: kinds)
            var order = scored.map(\.0.id)
            var matched: [String: [String]] = Dictionary(uniqueKeysWithValues: scored.map { ($0.0.id, $0.2) })
            if let engine, scored.count > 1, !terms.isEmpty {
                let top = Array(scored.prefix(40)).map(\.0)
                if let picks = await Self.modelPick(request, candidates: top, engine: engine), !picks.isEmpty {
                    let chosen = picks.compactMap { top.indices.contains($0) ? top[$0].id : nil }
                    order = chosen + order.filter { !chosen.contains($0) }
                    for id in chosen where matched[id]?.isEmpty ?? true { matched[id] = ["picked by the model"] }
                    searchNote = "\(chosen.count) best \(chosen.count == 1 ? "match" : "matches") picked by AI, then other possible matches."
                }
            }
            for index in found.indices { found[index].matched = matched[found[index].id] ?? [] }
            self.terms = terms
            ranked = order
            if searchNote == nil, terms.isEmpty, !kinds.isEmpty {
                searchNote = "Showing all \(kinds.map { $0.label.lowercased() }.joined(separator: " and ")) found."
            }
            if searchNote == nil {
                searchNote = order.isEmpty ? "Nothing matched. Try an artist, title or folder name." :
                    usedModel || engine != nil ? "Matched by name and tags\(usedModel ? ", with help from AI" : "")." :
                    "Matched by name and tags. Set up Ask’s answer model for smarter matching."
            }
            selection = Set(order.filter { id in
                found.first { $0.id == id }.map { !$0.protected && $0.inKit.addable } ?? false
            }.prefix(60))
            searching = false
        }
    }

    func clearRequest() {
        request = ""; ranked = nil; terms = []; searchNote = nil
        for index in found.indices { found[index].matched = [] }
    }

    private static let fillerWords: Set<String> = ["my", "the", "all", "our", "some", "find", "files", "file", "album", "albums",
        "song", "songs", "music", "audiobook", "audiobooks", "audio", "book", "books", "movie", "movies", "film", "films", "video",
        "videos", "game", "games", "rom", "roms", "ebook", "ebooks", "somewhere", "have", "i", "know", "these", "those", "and", "of", "by"]

    nonisolated static func keywordTerms(_ request: String) -> ([String], [FoundMedia.Kind]) {
        let lower = request.lowercased()
        var kinds: [FoundMedia.Kind] = []
        if lower.range(of: #"\b(album|albums|songs?|music|tracks?)\b"#, options: .regularExpression) != nil { kinds.append(.music) }
        if lower.contains("audiobook") || lower.contains("audio book") { kinds.append(.audiobook) }
        if lower.range(of: #"\b(movies?|films?|videos?|shows?|episodes?)\b"#, options: .regularExpression) != nil { kinds.append(.video) }
        if lower.range(of: #"\b(e?books?|novels?|pdfs?|epubs?)\b"#, options: .regularExpression) != nil && !lower.contains("audiobook") { kinds.append(.book) }
        if lower.range(of: #"\b(games?|roms?)\b"#, options: .regularExpression) != nil { kinds.append(.game) }
        let words = lower.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 2 && !fillerWords.contains($0) }
        var terms: [String] = []
        if words.count > 1 { terms.append(words.joined(separator: " ")) }
        terms += words
        return (terms, kinds)
    }

    private static let termInstructions = """
    You turn a request for media files on a computer into search words. Reply with JSON only, no other text:
    {"terms": ["..."], "kinds": ["..."]}
    terms: up to 12 lowercase words or short phrases to look for in file names, folder names and tags: the artist, \
    author, series or title they asked for, common alternate spellings, and well-known titles in that series or by \
    that artist. Leave out words like my, albums, songs, files, find.
    kinds: any of "music", "audiobook", "video", "book", "game" the request is about, or [] if it doesn't say.
    """

    nonisolated static func modelTerms(_ request: String, engine: AnswerEngine) async -> (terms: [String], kinds: [FoundMedia.Kind])? {
        guard let reply = await complete(engine, instructions: termInstructions, prompt: "Request: \(request)"),
              let json = MediaOrganizer.jsonObject(in: reply) else { return nil }
        let terms = (json["terms"] as? [Any] ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.count >= 2 && !fillerWords.contains($0) }.prefix(12)
        let kinds = (json["kinds"] as? [String] ?? []).compactMap { FoundMedia.Kind(rawValue: $0.lowercased()) }
        return terms.isEmpty ? nil : (Array(terms), kinds)
    }

    nonisolated static func score(_ items: [FoundMedia], terms: [String], kinds: [FoundMedia.Kind]) -> [(FoundMedia, Double, [String])] {
        guard !terms.isEmpty else { return [] }
        var out: [(FoundMedia, Double, [String])] = []
        for item in items {
            var score = 0.0, hits: [String] = []
            for term in terms {
                if item.searchText.contains(term) { score += term.contains(" ") ? 4 : 2; hits.append(term); continue }
                let parts = term.split(separator: " ").map(String.init).filter { $0.count >= 3 && !fillerWords.contains($0) }
                let found = parts.filter { item.searchText.contains($0) }
                if !parts.isEmpty && !found.isEmpty { score += Double(found.count) / Double(parts.count); hits += found }
            }
            guard score > 0 else { continue }
            if !kinds.isEmpty && !kinds.contains(item.kind) && !(kinds.contains(.audiobook) && item.kind == .music) { score *= 0.3 }
            out.append((item, score, Array(NSOrderedSet(array: hits)) as? [String] ?? hits))
        }
        return out.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title < $1.0.title }
    }

    private static let pickInstructions = """
    Someone is looking for media files on their computer. You get their request and a numbered list of files and \
    folders that were found. Reply with only the numbers of the items that match the request, best match first, \
    separated by commas. Reply NONE if nothing matches. Judge only from the names, tags and folders shown.
    """

    nonisolated static func modelPick(_ request: String, candidates: [FoundMedia], engine: AnswerEngine) async -> [Int]? {
        let list = candidates.enumerated().map { index, item in
            var line = "\(index + 1). [\(item.kind.rawValue)] \(item.title)"
            if let creator = item.creator { line += " — \(creator)" }
            if let year = item.year { line += " (\(year))" }
            line += " · folder: \(item.location.split(separator: "/").suffix(3).joined(separator: "/"))"
            return line
        }.joined(separator: "\n")
        guard let reply = await complete(engine, instructions: pickInstructions, prompt: "Request: \(request)\n\nFound:\n\(list)") else { return nil }
        if reply.uppercased().contains("NONE") { return [] }
        var seen = Set<Int>()
        return reply.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Int($0) }
            .filter { $0 >= 1 && $0 <= candidates.count && seen.insert($0).inserted }.map { $0 - 1 }
    }

    nonisolated static func complete(_ engine: AnswerEngine, instructions: String, prompt: String) async -> String? {
        var reply = ""
        do { for try await text in engine.stream(instructions: instructions, prompt: prompt) { reply = text } } catch { return nil }
        return reply.isEmpty ? nil : reply
    }

    // MARK: Showing

    /// What the list shows: the request's matches in order (or everything), within the kind filter.
    var visible: [FoundMedia] {
        let byID = Dictionary(uniqueKeysWithValues: found.map { ($0.id, $0) })
        let list = ranked.map { $0.compactMap { byID[$0] } } ?? found.filter { !$0.protected }
        return list.filter { kindFilter == nil || $0.kind == kindFilter }
    }
    var protectedItems: [FoundMedia] { found.filter(\.protected) }
    var selectedItems: [FoundMedia] { found.filter { selection.contains($0.id) && !$0.protected } }

    /// Files a move would take from where they are now (each goes to the Trash after its copy checks out).
    var filesToRemove: [URL] { selectedItems.flatMap(\.files) }

    // MARK: Adding

    func add(library: Library, media: MediaLibrary, games: GameLibrary) {
        let items = selectedItems
        guard !items.isEmpty else { return }
        phase = .adding; added = 0; toAdd = items.count; failures = []; summary = ""; stopping = false
        let stop = StopFlag()
        stopFlag = stop
        let mode = self.mode
        let mediaFolder = KitStorage.media, gamesFolder = KitStorage.games, primary = KitStorage.primaryLibrary
        library.adopt(primary)
        Task {
            var linkedCount = 0, copiedCount = 0
            var links: [LinkedMediaEntry] = []
            var finished: Set<String> = []
            for item in items {
                if stop.isSet { break }
                addingName = item.title
                // Games are always copied: their saves need to live in the kit, beside the game.
                if mode == .keep && item.kind != .game {
                    links.append(LinkedMediaEntry(kind: item.kind == .video ? .video : item.kind == .book ? .book : .audio,
                                                  title: item.title, creator: item.creator, folder: item.folder?.path, tracks: item.files.map(\.path),
                                                  volume: LinkedMedia.volumeName(item.files[0].path)))
                } else {
                    let move = mode == .move
                    let (errors, complete) = await Task.detached(priority: .userInitiated) { () -> ([String], Bool) in
                        var errors: [String] = []
                        // Stop finishes the file being copied, then stops before the next one.
                        for file in item.files {
                            if stop.isSet { return (errors, false) }
                            let target = Self.uniqueTarget(Self.destination(for: item, file: file, media: mediaFolder, games: gamesFolder), source: file)
                            if let error = KitTransfer.transfer(file, to: target, move: move, replace: false) { errors.append(error) }
                        }
                        // Folder art comes along as a copy (it stays in the original folder).
                        if let folder = item.folder, let first = item.files.first {
                            let targetFolder = Self.destination(for: item, file: first, media: mediaFolder, games: gamesFolder).deletingLastPathComponent()
                            for name in ["cover.jpg", "cover.png", "folder.jpg"] where FileManager.default.fileExists(atPath: folder.appending(path: name).path) {
                                _ = KitTransfer.transfer(folder.appending(path: name), to: targetFolder.appending(path: name), move: false, replace: false)
                            }
                        }
                        return (errors, true)
                    }.value
                    failures += errors
                    guard complete else { break }
                    if errors.isEmpty { copiedCount += 1 }
                }
                finished.insert(item.id)
                added += 1
            }
            if !links.isEmpty {
                do { linkedCount = try LinkedMedia.add(links, to: primary) }
                catch { failures.append("Couldn’t save the list of linked media: \(error.localizedDescription)") }
            }
            await media.reload(library: library)
            await games.reload(library: library)
            var parts: [String] = []
            if linkedCount > 0 { parts.append("\(linkedCount) linked where \(linkedCount == 1 ? "it is" : "they are")") }
            if copiedCount > 0 { parts.append("\(copiedCount) \(mode == .move ? "moved" : "copied") into the kit") }
            summary = parts.isEmpty ? "Nothing new was added." : parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst() + "."
            if stop.isSet { summary = "Stopped after \(finished.count) of \(items.count). " + summary }
            // Mark what's in the kit now.
            let done = finished
            for index in found.indices where done.contains(found[index].id) {
                found[index].inKit = mode == .keep && found[index].kind != .game ? .linked : .copy(found[index].files[0].lastPathComponent)
            }
            selection.subtract(done)
            if mode == .move { found.removeAll { done.contains($0.id) && $0.inKit != .linked && !FileManager.default.fileExists(atPath: $0.files[0].path) } }
            phase = .done
        }
    }

    /// Where a file goes in the kit, following the library's own layout.
    nonisolated static func destination(for item: FoundMedia, file: URL, media: URL, games: URL) -> URL {
        func clean(_ name: String) -> String {
            let trimmed = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-").trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Untitled" : String(trimmed.prefix(120))
        }
        switch item.kind {
        case .video: return media.appending(path: file.lastPathComponent)
        case .book: return media.appending(path: "Books", directoryHint: .isDirectory).appending(path: file.lastPathComponent)
        case .music:
            guard item.folder != nil else { return media.appending(path: "Music", directoryHint: .isDirectory).appending(path: file.lastPathComponent) }
            return media.appending(path: "Music/\(clean(item.creator ?? "Unknown artist"))/\(clean(item.title))", directoryHint: .isDirectory)
                .appending(path: file.lastPathComponent)
        case .audiobook:
            let folder = media.appending(path: "Audiobooks", directoryHint: .isDirectory)
            guard item.folder != nil else { return folder.appending(path: file.lastPathComponent) }
            return folder.appending(path: clean(item.title), directoryHint: .isDirectory).appending(path: file.lastPathComponent)
        case .game:
            let sub = GameLibrary.importSubfolder(for: file) ?? ""
            return (sub.isEmpty ? games : games.appending(path: sub, directoryHint: .isDirectory)).appending(path: file.lastPathComponent)
        }
    }

    /// Never replaces a different file of the same name: "Name 2.mp4". The same file (size and checksum) is reused.
    nonisolated static func uniqueTarget(_ target: URL, source: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { return target }
        if KitTransfer.verify(target, matches: source) { return target }
        let base = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
        for n in 2...999 {
            let candidate = target.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return target
    }

    func reset() { cancel(); phase = .choosing; found = []; selection = []; clearRequest() }

    #if DEBUG
    /// Test mode only: what was found, in the order shown, written beside the stand-in home folder.
    func writeTestReport() {
        guard let home = KitLocation.testHome else { return }
        let rows: [[String: Any]] = (ranked.map { ids in ids.compactMap { id in found.first { $0.id == id } } } ?? found).map { item in
            var row: [String: Any] = ["kind": item.kind.rawValue, "title": item.title, "files": item.files.count, "location": item.location,
                                      "protected": item.protected, "selected": selection.contains(item.id), "matched": item.matched]
            row["creator"] = item.creator; row["collection"] = item.collection; row["year"] = item.year; row["genre"] = item.genre
            row["cover"] = item.cover != nil
            switch item.inKit { case .no: row["inKit"] = "no"; case .linked: row["inKit"] = "linked"; case .copy(let name): row["inKit"] = "copy of " + name; case .partly(let have, let of): row["inKit"] = "partly \(have)/\(of)" }
            return row
        }
        let report: [String: Any] = ["summary": summary, "failures": failures, "request": request, "terms": terms, "note": searchNote ?? "", "skippedCloud": skippedCloud, "items": rows]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: home.appending(path: "debug-find.json"))
        }
    }
    #endif
    func finishAdding() { phase = .ready; summary = ""; failures = [] }

    /// Stops adding once the file being copied is finished, so nothing is left half-copied.
    func stopAdding() { stopping = true; stopFlag?.set() }
    private(set) var stopping = false
    @ObservationIgnored private var stopFlag: StopFlag?
}

/// A stop request that a background copy checks between files.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

// MARK: - Button

/// "Find My Media", for Play, Get Resources and anywhere else that needs it. Opens the sheet over this view.
struct FindMyMediaButton: View {
    var kind: FoundMedia.Kind? = nil
    var title = "Find My Media"
    @State private var showing = false
    var body: some View {
        Button(title, systemImage: "sparkle.magnifyingglass") { showing = true }
            .help("Look through this Mac’s folders and drives for videos, music, audiobooks, books and games to add")
            .sheet(isPresented: $showing) { FindMediaSheet(startKind: kind) }
    }
}

/// "Organize with AI" for Play (Watch & Listen has its own toolbar button).
struct OrganizeButton: View {
    var scope: CatalogKind? = nil
    @State private var showing = false
    var body: some View {
        Button("Organize with AI", systemImage: "sparkles") { showing = true }
            .help("Fill in genre, publisher, year and series, with a review before anything changes")
            .sheet(isPresented: $showing) { OrganizeSheet(startScope: scope) }
    }
}

// MARK: - Sheet

struct FindMediaSheet: View {
    var startKind: FoundMedia.Kind? = nil
    @Environment(Library.self) private var library
    @Environment(MediaLibrary.self) private var media
    @Environment(GameLibrary.self) private var games
    @Environment(AskModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var finder = MediaFinder.shared
    @State private var confirmingMove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(24)
            Divider()
            Group {
                switch finder.phase {
                case .choosing: chooser
                case .scanning, .reading: scanning
                case .ready, .adding, .done: results
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer.padding(18)
        }
        // Fits the smallest window (520 points tall): the lists scroll, the header and footer stay.
        .frame(minWidth: 640, idealWidth: 860, minHeight: 420, idealHeight: 720)
        .onAppear {
            finder.refreshLocations()
            if let startKind, finder.phase == .choosing || finder.phase == .ready { finder.kindFilter = startKind }
            #if DEBUG
            if KitLocation.testHome != nil, let request = UserDefaults.standard.string(forKey: "findMedia"), request != "open", finder.phase == .choosing {
                finder.chosen = Set(finder.locations.map(\.id))
                finder.scan(library: library, media: media, games: games)
                Task {
                    while finder.phase != .ready { try? await Task.sleep(for: .milliseconds(200)) }
                    if !request.isEmpty { finder.request = request; finder.ask(request, model: model) }
                    while finder.searching { try? await Task.sleep(for: .milliseconds(200)) }
                    // -findMediaAdd keep|copy|move adds the selected matches (a move shows its confirmation first).
                    if let mode = UserDefaults.standard.string(forKey: "findMediaAdd").flatMap(MediaFinder.AddMode.init(rawValue:)) {
                        finder.mode = mode
                        if mode == .move { confirmingMove = true; try? await Task.sleep(for: .seconds(6)); confirmingMove = false }
                        finder.add(library: library, media: media, games: games)
                        while finder.phase == .adding { try? await Task.sleep(for: .milliseconds(200)) }
                    }
                    finder.writeTestReport()
                }
            }
            #endif
        }
        .sheet(isPresented: $confirmingMove) { moveConfirmation }
    }

    @ViewBuilder private var header: some View {
        if finder.phase == .choosing {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkle.magnifyingglass").font(.title).foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Find my media").font(.title.bold())
                        Text("Choose where to look. Review what’s found before adding it.").font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Label("Choose locations", systemImage: "1.circle.fill").foregroundStyle(.tint)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    Label("Review media", systemImage: "2.circle").foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    Label("Add to kit", systemImage: "3.circle").foregroundStyle(.secondary)
                }.font(.caption.weight(.semibold))
            }
        } else { standardHeader }
    }

    private var standardHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "sparkle.magnifyingglass").font(.largeTitle).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text("Find my media").font(.title.bold())
                Text("Look through this Mac’s folders and drives for videos, music, audiobooks, books and games, then add what you want to your kit. Nothing is moved unless you choose Move and confirm the list.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Choosing where to look

    private var selectedLocationCount: Int { finder.locations.filter { finder.chosen.contains($0.id) }.count }

    private var chooser: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    locationChoices.frame(minWidth: 340, maxWidth: .infinity)
                    searchInformation.frame(minWidth: 240, maxWidth: 300)
                }
                VStack(alignment: .leading, spacing: 18) { locationChoices; searchInformation }
            }.padding(24)
        }
    }

    private var locationChoices: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Folders and drives").font(.headline)
            if finder.locations.isEmpty {
                Text("Choose a folder to look in.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(finder.locations) { location in
                Toggle(isOn: Binding(get: { finder.chosen.contains(location.id) },
                                     set: { if $0 { finder.chosen.insert(location.id) } else { finder.chosen.remove(location.id) } })) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location.name).font(.callout.weight(.semibold))
                            Text(location.url.path.replacingOccurrences(of: KitLocation.home.path, with: "~")
                                 + (location.asksPermission ? " · macOS asks first" : "")).font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: location.symbol).foregroundStyle(Color.accentColor) }
                }.toggleStyle(.checkbox)
            }
            Button("Choose a Folder…", systemImage: "folder.badge.plus") { chooseFolder() }.buttonStyle(.bordered)
        }.card(padding: 18)
    }

    private var searchInformation: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                Label("Looking only", systemImage: "eye").font(.headline)
                Text("Searching reads files. Nothing is added or moved at this step.").font(.callout).foregroundStyle(.secondary)
                if finder.locations.contains(where: { $0.asksPermission && finder.chosen.contains($0.id) }) {
                    Label("macOS may ask to allow access to selected folders or drives.", systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                DisclosureGroup("Permission details") {
                    Text("The first time Offline Kit looks in Desktop, Documents, Downloads or a drive, macOS asks whether to allow it. Choose Allow so it can look. Offline Kit only reads what’s there, and nothing is moved unless you choose Move and confirm. You can change this later in System Settings › Privacy & Security › Files and Folders.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
                }
            }.card(padding: 18)
            VStack(alignment: .leading, spacing: 10) {
                Label("What won’t be found", systemImage: "info.circle").font(.headline)
                Text("Skipped automatically: apps, your Library folder, system folders, the Photos library, the Trash, the kit’s own folders, and iCloud files that aren’t downloaded to this Mac. Songs streamed from Apple Music aren’t files, so they can’t be found.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.card(padding: 18)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Look Here"
        if panel.runModal() == .OK { panel.urls.forEach(finder.addFolder) }
    }

    // MARK: Scanning

    private var scanning: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView().controlSize(.large)
            Text(finder.phase == .scanning ? "Looking through \(finder.looked.formatted()) files and folders…" : "Reading tags and covers: \(finder.looked.formatted()) found so far…")
                .font(.headline).monospacedDigit()
            Text(finder.currentFolder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 520)
            if finder.phase == .scanning && finder.locations.contains(where: { $0.asksPermission && finder.chosen.contains($0.id) }) {
                Text("If macOS asks whether Offline Kit can see a folder or drive, choose Allow. It only reads files.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520)
            }
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    // MARK: Results

    private var results: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("What are you looking for? Try “my Beatles albums” or “the Harry Potter audiobooks”", text: $finder.request)
                        .textFieldStyle(.roundedBorder).onSubmit { finder.ask(finder.request, model: model) }
                    Button("Find") { finder.ask(finder.request, model: model) }.disabled(finder.searching || finder.request.isEmpty)
                    if finder.ranked != nil { Button("Show All") { finder.clearRequest() } }
                }
                HStack(spacing: 8) {
                    if finder.searching { ProgressView().controlSize(.small); Text("Looking for matches…").font(.caption).foregroundStyle(.secondary) }
                    else if let note = finder.searchNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Picker("Show", selection: $finder.kindFilter) {
                        Text("Everything").tag(FoundMedia.Kind?.none)
                        ForEach(FoundMedia.Kind.allCases) { Text($0.label).tag(Optional($0)) }
                    }.fixedSize()
                }
                if !finder.terms.isEmpty {
                    Text("Searched for: " + finder.terms.prefix(12).joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
            }.padding(.horizontal, 24).padding(.vertical, 14)
            Divider()
            List {
                if finder.found.isEmpty {
                    Text("Nothing to add was found in those places.").foregroundStyle(.secondary)
                }
                if !finder.denied.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("macOS didn’t let Offline Kit look in \(ListFormatter.localizedString(byJoining: finder.denied)).", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                        Text("To include \(finder.denied.count == 1 ? "it" : "them"), turn on Offline Kit in System Settings › Privacy & Security › Files and Folders, then look again.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        Button("Open Privacy & Security") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
                if finder.skippedCloud > 0 {
                    Label("\(finder.skippedCloud) iCloud \(finder.skippedCloud == 1 ? "file isn’t" : "files aren’t") downloaded to this Mac and \(finder.skippedCloud == 1 ? "was" : "were") skipped.", systemImage: "icloud.slash")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(sections, id: \.0) { title, items in
                    Section {
                        ForEach(groupedRows(items), id: \.0) { collection, rows in
                            if let header = collection {
                                Text(header).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                            }
                            ForEach(rows) { row($0) }
                        }
                    } header: {
                        HStack {
                            Text(title)
                            Spacer()
                            let ids = items.filter { !$0.protected && $0.inKit.addable }.map(\.id)
                            if !ids.isEmpty {
                                Button(ids.allSatisfy(finder.selection.contains) ? "Deselect all" : "Select all") {
                                    if ids.allSatisfy(finder.selection.contains) { finder.selection.subtract(ids) } else { finder.selection.formUnion(ids) }
                                }.buttonStyle(.link).font(.caption)
                            }
                        }
                    }
                }
                if !finder.protectedItems.isEmpty && finder.ranked == nil {
                    Section("Won’t play here") {
                        Label("These are copy-protected purchases from the iTunes Store. They only play in Apple’s apps, so they aren’t added.", systemImage: "lock.fill")
                            .font(.callout).foregroundStyle(.orange)
                        ForEach(finder.protectedItems) { row($0) }
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var sections: [(String, [FoundMedia])] {
        let visible = finder.visible
        if finder.ranked != nil { return visible.isEmpty ? [] : [("Matches", visible)] }
        return FoundMedia.Kind.allCases.compactMap { kind in
            let list = visible.filter { $0.kind == kind }
            return list.isEmpty ? nil : (kind.label, list)
        }
    }

    /// Artists, authors and series with two or more items get a heading; the rest follow under "Other".
    private func groupedRows(_ items: [FoundMedia]) -> [(String?, [FoundMedia])] {
        guard finder.ranked == nil else { return [(nil, items)] }
        var order: [String] = [], groups: [String: [FoundMedia]] = [:], singles: [FoundMedia] = []
        for item in items {
            guard let name = item.collection, items.filter({ $0.collection == name }).count > 1 else { singles.append(item); continue }
            if groups[name] == nil { order.append(name) }
            groups[name, default: []].append(item)
        }
        var out: [(String?, [FoundMedia])] = order.map { ($0, groups[$0] ?? []) }
        if !singles.isEmpty { out.append((order.isEmpty ? nil : "Other", singles)) }
        return out
    }

    private func row(_ item: FoundMedia) -> some View {
        let selectable = !item.protected && finder.phase != .adding
        return HStack(spacing: 12) {
            Toggle("", isOn: Binding(get: { finder.selection.contains(item.id) },
                                     set: { if $0 { finder.selection.insert(item.id) } else { finder.selection.remove(item.id) } }))
                .toggleStyle(.checkbox).labelsHidden().disabled(!selectable)
            cover(item).frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                Text(detail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(item.location).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            switch item.inKit {
            case .linked: Pill(text: "Linked already", symbol: "link")
            case .copy: Pill(text: "Already in kit", symbol: "checkmark", tint: .accentColor)
            case .partly(let have, let of): Pill(text: "Partly in kit · \(have) of \(of)", symbol: "circle.lefthalf.filled")
            case .no: if item.protected { Pill(text: "Copy-protected", symbol: "lock.fill", tint: .orange) }
            }
        }
        .padding(.vertical, 2)
        .help({
            switch item.inKit {
            case .no: return item.files.first?.path ?? ""
            case .copy(let name): return "The kit has the same file (same size and checksum): \(name)"
            case .partly(let have, let of): return "\(have) of the \(of) tracks are in the kit already. Adding it brings the rest."
            case .linked: return "Already linked to the kit"
            }
        }())
    }

    private func detail(_ item: FoundMedia) -> String {
        var bits: [String] = []
        if let creator = item.creator { bits.append(creator) }
        if let year = item.year { bits.append(String(year)) }
        if item.files.count > 1 { bits.append("\(item.files.count) \(item.kind == .audiobook ? "chapters" : "tracks")") }
        bits.append(ByteCountFormatter.string(fromByteCount: item.bytes, countStyle: .file))
        if !item.matched.isEmpty { bits.append("matched " + item.matched.prefix(3).joined(separator: ", ")) }
        return bits.joined(separator: " · ")
    }

    @ViewBuilder private func cover(_ item: FoundMedia) -> some View {
        if let data = item.cover, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: MediaTheme.posterColors(item.title), startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: item.kind.symbol).foregroundStyle(.white)
            }
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        switch finder.phase {
        case .choosing:
            HStack {
                Text("\(selectedLocationCount) \(selectedLocationCount == 1 ? "location" : "locations") selected").font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Look for Media") { finder.scan(library: library, media: media, games: games) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(finder.chosen.isEmpty)
            }
        case .scanning, .reading:
            HStack {
                Text("You can close this window; looking continues in the background.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Stop Looking") { finder.cancel() }
                Button("Close") { dismiss() }
            }
        case .adding:
            HStack(spacing: 14) {
                ProgressView(value: Double(finder.added), total: Double(max(finder.toAdd, 1))) {
                    Text(finder.stopping ? "Stopping after this file…" : "Adding \(finder.addingName)…").lineLimit(1)
                }
                Button("Stop", systemImage: "stop.fill") { finder.stopAdding() }
                    .disabled(finder.stopping)
                    .help("Finish the file being copied, then stop. What’s copied so far stays in the kit.")
            }
        case .done:
            VStack(alignment: .leading, spacing: 8) {
                Label(finder.summary, systemImage: finder.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(finder.failures.isEmpty ? Color.accentColor : .orange)
                ForEach(finder.failures, id: \.self) { Text($0).font(.callout) }
                HStack { Spacer(); Button("Add More") { finder.finishAdding() }; Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent) }
            }
        case .ready:
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Picker("Add as", selection: $finder.mode) { ForEach(MediaFinder.AddMode.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).frame(maxWidth: 440).labelsHidden()
                    Spacer()
                    if !finder.selectedItems.isEmpty {
                        Text("\(finder.selectedItems.count) selected · \(ByteCountFormatter.string(fromByteCount: finder.selectedItems.reduce(0) { $0 + $1.bytes }, countStyle: .file))")
                            .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                Text(finder.mode.detail + (finder.mode == .keep && finder.selectedItems.contains { $0.kind == .game } ? " Games are copied instead, so their saves stay with the kit." : ""))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Look Somewhere Else") { finder.reset() }
                    Spacer()
                    Button("Close") { dismiss() }
                    Button(finder.mode == .move ? "Review Move…" : finder.mode == .keep ? "Link to Kit" : "Copy to Kit") {
                        if finder.mode == .move { confirmingMove = true } else { finder.add(library: library, media: media, games: games) }
                    }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(finder.selectedItems.isEmpty)
                }
            }
        }
    }

    private var moveConfirmation: some View {
        let files = finder.filesToRemove
        return VStack(alignment: .leading, spacing: 14) {
            Label("Move \(files.count) \(files.count == 1 ? "file" : "files") into the kit?", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.bold()).foregroundStyle(.primary)
            Text("Each file is copied into \(KitStorage.primaryLibrary.path.replacingOccurrences(of: KitLocation.home.path, with: "~")) and checked (same size and checksum). Only then does the original go to the Trash. On the same drive it’s simply moved. These originals will no longer be where they are now:")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List(files, id: \.self) { url in
                Text(url.path.replacingOccurrences(of: KitLocation.home.path, with: "~")).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
            }
            .frame(minHeight: 160, maxHeight: 320)
            Text("Cover pictures and any other files in those folders stay where they are.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { confirmingMove = false }.keyboardShortcut(.cancelAction)
                Button("Move \(files.count) \(files.count == 1 ? "File" : "Files")", role: .destructive) {
                    confirmingMove = false
                    finder.add(library: library, media: media, games: games)
                }
            }
        }
        .padding(24).frame(width: 620)
    }
}
#endif
