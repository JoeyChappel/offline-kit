import SwiftUI
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import IOKit.ps
#endif

// MARK: - Rules

/// Where a picture comes from, strongest first. Generated art only ever fills a gap.
enum ArtworkSource: Int, CaseIterable, Comparable, Sendable {
    /// Chosen in the app ("Choose Cover Art…", "Use Generated Cover"): cover-custom.jpg or "Movie.cover.jpg".
    case custom
    /// Art that came beside the files: cover.jpg, cover.png or folder.jpg in an album folder.
    case sidecar
    /// Art inside the files: audio tags, an EPUB's cover, a PDF's first page.
    case embedded
    /// The frame an unfinished video was stopped on (Keep Watching shows where you left off).
    case still
    /// Made by Offline Kit: a movie's title card or best frame, a typographic cover, a game's title screen.
    case generated
    /// The quick frame read with the details (a tenth of the way into a video), until generated art is ready.
    case automatic

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// What kind of generated art an item has, kept in `MediaInfo.art` so the background pass does each file once.
enum GeneratedArt: String, Sendable {
    case titleCard, frame, cover
    /// Looked at and nothing was made (a video with no readable frames, or art that came with the files).
    case none
}

enum ArtworkRules {
    /// The picture to show from what's available, by `ArtworkSource` order.
    static func pick(_ candidates: [ArtworkSource: String]) -> (source: ArtworkSource, path: String)? {
        for source in ArtworkSource.allCases { if let path = candidates[source] { return (source, path) } }
        return nil
    }

    /// Whether the background pass should make art for an item. A card shows `item.cover ?? info.thumb`, so an item with
    /// a custom or sidecar cover never needs it; a video's own thumb is only the automatic frame, so videos always get
    /// a better one; music and books only when the files carry no art. PDFs keep their first page.
    static func wantsGenerated(kind: MediaItem.Kind, hasCover: Bool, thumb: String?, art: String?, isPDF: Bool) -> Bool {
        guard !hasCover, art == nil else { return false }
        switch kind {
        case .video: return true
        case .audio: return thumb == nil
        case .book: return thumb == nil && !isPDF
        }
    }

    /// What `MediaInfo.thumb` should hold once generated art exists (the card's own cover, when set, still comes first).
    /// A video's still stays while it's unfinished; generated art replaces the automatic frame; art from the files stays.
    static func thumb(kind: MediaItem.Kind, current: String?, currentArt: String?, still: String?, generated: String) -> String {
        if kind == .video { return still ?? generated }
        if let current, currentArt == nil || currentArt == GeneratedArt.none.rawValue { return current }
        return generated
    }

    /// A game's shelf picture: the last frame of a real game first, then a generated title screen. Nil shows SystemArt.
    static func gamePicture(played: String?, generated: String?) -> String? { played ?? generated }

    /// Generated art is named after the source file's path, size and modification date, so a replaced file gets new art
    /// and the same file never pays twice. `kind` keeps a game's title screen and a movie's card apart.
    static func key(path: String, size: Int, modified: Double, kind: String) -> String {
        SHA256.hash(data: Data("art-v1|\(kind)|\(path)|\(size)|\(modified)".utf8)).prefix(12)
            .map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func key(for url: URL, kind: String) -> String? {
        var url = url
        url.removeAllCachedResourceValues()   // a URL remembers what it read; the file may have changed since
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else { return nil }
        return key(path: url.standardizedFileURL.path, size: values.fileSize ?? 0,
                   modified: values.contentModificationDate?.timeIntervalSince1970 ?? 0, kind: kind)
    }
}

// MARK: - When the background pass may run

/// Why making artwork is waiting. It's quiet work: it only runs plugged in or above half a charge, never in Low Power
/// Mode or when the device is hot, and steps aside while Ask answers, something plays or a game runs.
enum ArtworkPause: Equatable, Sendable {
    case user, lowPower, battery, hot, asking, playing, game
}

struct ArtworkConditions: Sendable {
    var userPaused = false
    var lowPower = false
    var pluggedIn = true
    /// 0…1, nil when there's no battery (a desktop Mac).
    var battery: Double?
    var thermal: ProcessInfo.ThermalState = .nominal
    var asking = false
    var playing = false
    var game = false

    func pause() -> ArtworkPause? {
        if userPaused { return .user }
        if lowPower { return .lowPower }
        if !pluggedIn, let battery, battery < 0.5 { return .battery }
        if thermal == .serious || thermal == .critical { return .hot }
        if game { return .game }
        if asking { return .asking }
        if playing { return .playing }
        return nil
    }

    /// The device's side of it: Low Power Mode, power source and charge, temperature.
    @MainActor static func current() -> ArtworkConditions {
        var c = ArtworkConditions()
        c.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        c.thermal = ProcessInfo.processInfo.thermalState
        #if os(macOS)
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? { c.pluggedIn = type == kIOPMACPowerKey }
            if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
                for source in list {
                    guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                          d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                          let now = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
                    c.battery = Double(now) / Double(max)
                }
            }
        }
        #elseif canImport(UIKit) && !os(tvOS)
        let device = UIDevice.current
        device.isBatteryMonitoringEnabled = true
        c.pluggedIn = device.batteryState == .charging || device.batteryState == .full
        if device.batteryLevel >= 0 { c.battery = Double(device.batteryLevel) }
        #endif
        return c
    }
}

// MARK: - Background pass

/// Makes artwork for media that has none, once per file, in the background: title cards or the best frame for movies
/// (MovieArtwork), typographic covers for albums and books (GeneratedCovers), title screens for cartridge games
/// (GameTitleCards). Results go to the caches folder and into the details cache, so every screen, Share on Wi-Fi and
/// the Apple TV show them like any other picture.
@MainActor @Observable
final class AutoArtwork {
    static let shared = AutoArtwork()

    /// This pass: how many items are done and how many it found to do. Both 0 when there's nothing to do.
    private(set) var done = 0
    private(set) var total = 0
    /// Why it's waiting, or nil while working (or idle).
    private(set) var pause: ArtworkPause?
    private(set) var userPaused = KitSettings.shared.bool(forKey: "artworkPaused") ?? false
    /// How long each kind of item took, for Kit Care's details and the logs.
    private(set) var lastTiming: String?

    @ObservationIgnored private weak var media: MediaLibrary?
    @ObservationIgnored private weak var games: GameLibrary?
    @ObservationIgnored private weak var nowPlaying: NowPlaying?
    @ObservationIgnored private var library: Library?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var again = false
    /// Items finished since the details cache was last saved.
    @ObservationIgnored private var unsaved = 0

    var isWorking: Bool { worker != nil && total > 0 }

    private init() {}

    func attach(media: MediaLibrary, games: GameLibrary, nowPlaying: NowPlaying?, library: Library) {
        self.media = media
        self.games = games
        self.nowPlaying = nowPlaying
        self.library = library
        #if DEBUG
        // Test hook: -artworkOff YES leaves the shelves as the files have them (before/after screenshots).
        if UserDefaults.standard.bool(forKey: "artworkOff") { return }
        #endif
        observe()
        scheduleSoon()
    }

    func setPaused(_ paused: Bool) {
        userPaused = paused
        KitSettings.shared.set(paused, forKey: "artworkPaused")
        if !paused { scheduleSoon(after: .zero) }
    }

    /// Runs a pass a few seconds after the library settles, so a scan's batches don't each start one.
    private func observe() {
        withObservationTracking {
            _ = media?.revision
            _ = games?.games
        } onChange: {
            Task { @MainActor in
                AutoArtwork.shared.observe()
                AutoArtwork.shared.scheduleSoon()
            }
        }
    }

    private func scheduleSoon(after delay: Duration = .seconds(4)) {
        if worker != nil { again = true; return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.worker == nil else { return }
            self.worker = Task(priority: .utility) { [weak self] in
                await self?.run()
                self?.worker = nil
            }
        }
    }

    // MARK: Jobs

    enum Job {
        case movie(MediaItem, title: String)
        case cover(MediaItem, GeneratedCovers.Request)
        case game(Game)
    }

    /// What still needs art: media from the details already on screen, games from a look at the caches off the main thread.
    private func jobs() async -> [Job] {
        var list: [Job] = []
        if let media {
            for item in media.items where item.unavailable == nil {
                let info = media.info[item.progressKey]
                // Details not read yet: the next pass picks it up.
                guard let info, info.source != nil else { continue }
                let isPDF = item.kind == .book && item.tracks[0].pathExtension.lowercased() == "pdf"
                guard ArtworkRules.wantsGenerated(kind: item.kind, hasCover: item.cover != nil, thumb: info.thumb,
                                                  art: info.art, isPDF: isPDF) else { continue }
                if item.kind == .video {
                    list.append(.movie(item, title: MediaCatalog.displayTitle(item.title)))
                } else {
                    list.append(.cover(item, GeneratedCovers.request(for: item, info: info)))
                }
            }
        }
        if let games, !games.games.isEmpty {
            let all = games.games
            let survey = await Task.detached(priority: .utility) { GameTitleCards.survey(all) }.value
            for (id, path) in survey.made where GameArtStore.shared.titleScreens[id] != path { GameArtStore.shared.titleScreens[id] = path }
            list += survey.todo.map { .game($0) }
        }
        return list
    }

    private func run() async {
        repeat {
            again = false
            let list = await jobs()
            total = list.count
            done = 0
            var timings: [String: [Double]] = [:]
            for job in list {
                guard await waitUntilAllowed() else { break }
                let started = Date()
                let label: String
                switch job {
                case .movie(let item, let title):
                    label = "movie"
                    let result = await MovieArtwork.generate(item.tracks[0], title: title)
                    finish(item, result.map { ($0.path, $0.art) } ?? (nil, .none))
                case .cover(let item, let request):
                    label = "cover"
                    let path = await GeneratedCovers.generate(request, source: item.tracks[0])
                    finish(item, (path, path == nil ? .none : .cover))
                case .game(let game):
                    label = "game"
                    let path = await GameTitleCards.generate(game)
                    if let path { GameArtStore.shared.titleScreens[game.id] = path }
                    #if DEBUG
                    NSLog("Artwork: title screen for %@: %@", game.title, path ?? "none")
                    #endif
                }
                timings[label, default: []].append(Date().timeIntervalSince(started))
                done += 1
                // A breath between items, so the work stays in the background.
                try? await Task.sleep(for: .milliseconds(150))
            }
            if unsaved > 0 { unsaved = 0; await Task.detached(priority: .utility) { MediaInfoStore.shared.saveNow() }.value }
            if !timings.isEmpty {
                lastTiming = timings.sorted { $0.key < $1.key }.map { label, values in
                    String(format: "%@ %d × %.2f s avg (max %.2f s)", label, values.count, values.reduce(0, +) / Double(values.count), values.max() ?? 0)
                }.joined(separator: ", ")
                #if DEBUG
                NSLog("Artwork: %@", lastTiming ?? "")
                #endif
            }
            if let games, !games.games.isEmpty {
                let current = games.games
                await Task.detached(priority: .background) { GameTitleCards.prune(keeping: current) }.value
            }
        } while again && !userPaused
        total = 0
        done = 0
        pause = nil
    }

    /// Waits while the pass should rest; false if the user paused it.
    private func waitUntilAllowed() async -> Bool {
        while true {
            var c = ArtworkConditions.current()
            c.userPaused = userPaused
            c.asking = AnswerIndex.shared.isAsking
            c.playing = nowPlaying?.playback?.isPlaying == true
            c.game = GameSession.current != nil
            pause = c.pause()
            if pause == .user { return false }
            if pause == nil { return true }
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return false }
        }
    }

    private func finish(_ item: MediaItem, _ result: (path: String?, art: GeneratedArt)) {
        media?.setGeneratedArtwork(result.path, art: result.art, for: item)
        unsaved += 1
        let save = unsaved >= 20
        if save { unsaved = 0 }
        Task.detached(priority: .utility) {
            MediaInfoStore.shared.recordArtwork(item, thumb: result.path, art: result.art)
            if save { MediaInfoStore.shared.saveNow() }
        }
    }

    // MARK: Cover menu actions

    /// "Pick Another Frame": the next frame from the ranked list the movie pass kept.
    func pickAnotherFrame(_ item: MediaItem) {
        Task {
            guard let made = await MovieArtwork.nextFrame(item.tracks[0]) else { return }
            finish(item, (made.path, made.art))
        }
    }

    /// "Reset Artwork": the movie's own best choice again (forgets "Pick Another Frame").
    func resetFrame(_ item: MediaItem) {
        Task {
            guard let made = await MovieArtwork.resetPick(item.tracks[0]) else { return }
            finish(item, (made.path, made.art))
        }
    }

    /// "Use Generated Cover": a typographic cover saved as the item's own cover, over the art that came with it.
    /// "Use Original Art" takes it away again.
    func useGeneratedCover(_ item: MediaItem) {
        guard let media, let library else { return }
        let request = GeneratedCovers.request(for: item, info: media.info[item.progressKey])
        Task {
            let image = await Task.detached(priority: .userInitiated) { GeneratedCovers.draw(request) }.value
            guard let image else { return }
            try? MediaCover.set(image, for: item)
            await media.reload(library: library)
        }
    }

    static func canPickFrame(_ item: MediaItem, info: MediaInfo?) -> Bool {
        item.kind == .video && item.unavailable == nil && !MediaCover.hasCustom(item)
            && (info?.art == GeneratedArt.titleCard.rawValue || info?.art == GeneratedArt.frame.rawValue)
    }

    static func canUseGeneratedCover(_ item: MediaItem, info: MediaInfo?) -> Bool {
        item.kind != .video && item.unavailable == nil && !MediaCover.hasCustom(item)
            && info?.art != GeneratedArt.cover.rawValue && (item.cover != nil || info?.thumb != nil)
    }

    static func canResetFrame(_ item: MediaItem, info: MediaInfo?) -> Bool {
        canPickFrame(item, info: info) && MovieArtwork.hasPick(item.tracks[0])
    }

    // MARK: Kit Care

    /// "Making artwork, 12 of 140", "Paused on battery", "Artwork is up to date".
    var summary: String {
        switch pause {
        case .user?: return "Paused"
        case .lowPower?: return "Paused in Low Power Mode"
        case .battery?: return "Paused on battery"
        case .hot?: return "Paused while the device cools down"
        case .asking?: return "Waiting while Ask answers"
        case .playing?: return "Waiting while something plays"
        case .game?: return "Waiting while a game is playing"
        case nil: break
        }
        if userPaused { return "Paused" }
        if total > 0 { return "Making artwork, \(min(done + 1, total)) of \(total)" }
        return "Artwork is up to date"
    }
}

/// Generated title screens by game path, so shelves redraw when one is ready.
@MainActor @Observable
final class GameArtStore {
    static let shared = GameArtStore()
    var titleScreens: [String: String] = [:]
    private init() {}

    /// The shelf picture to try after the game's own last frame.
    func titleScreen(for game: Game) -> String? {
        if let known = titleScreens[game.id] { return known }
        return GameTitleCards.cachedPath(for: game)
    }
}

// MARK: - Writing pictures

enum ArtworkFiles {
    /// Generated media art sits with the other automatic thumbnails, so the details cache's prune removes it with them.
    nonisolated static var folder: URL { MediaInfoStore.folder.appending(path: "thumbs", directoryHint: .isDirectory) }

    @discardableResult
    nonisolated static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.85) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.deletingLastPathComponent().appending(path: ".\(UUID().uuidString).tmp")
        guard let destination = CGImageDestinationCreateWithURL(temp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: temp); return false }
        if (try? FileManager.default.replaceItemAt(url, withItemAt: temp)) == nil {
            try? FileManager.default.removeItem(at: temp)
            return FileManager.default.fileExists(atPath: url.path)
        }
        return true
    }

    @discardableResult
    nonisolated static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

// MARK: - Kit Care

/// Kit Care › References: one line on the artwork pass ("Making artwork, 12 of 140") with Pause and Resume.
struct ArtworkCard: View {
    @State private var artwork = AutoArtwork.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            KitCardHeader(symbol: "photo.on.rectangle.angled", title: "Artwork",
                          subtitle: "Title cards, covers and title screens for media that came without art. Your own covers always come first.")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { status; Spacer(minLength: 8); control }
                VStack(alignment: .leading, spacing: 10) { status; control }
            }
        }
        .card(padding: 18)
    }

    private var status: some View {
        HStack(spacing: 10) {
            Label(artwork.summary, systemImage: symbol)
                .font(.callout.weight(.medium))
                .foregroundStyle(artwork.pause != nil || artwork.userPaused ? Color.orange : .primary)
            if artwork.total > 0, artwork.pause == nil {
                ProgressView(value: Double(artwork.done), total: Double(max(1, artwork.total)))
                    .frame(width: 70)
                    .accessibilityHidden(true)
            }
        }
    }

    private var control: some View {
        Group {
            if artwork.userPaused {
                Button("Resume", systemImage: "play") { artwork.setPaused(false) }
            } else {
                Button("Pause", systemImage: "pause") { artwork.setPaused(true) }
                    .disabled(artwork.total == 0)
            }
        }
        .buttonStyle(.bordered)
    }

    private var symbol: String {
        if artwork.userPaused || artwork.pause == .user { return "pause.circle" }
        switch artwork.pause {
        case .battery?: return "battery.25"
        case .lowPower?: return "leaf"
        case .hot?: return "thermometer.medium"
        case .some: return "hourglass"
        case nil: return artwork.total > 0 ? "arrow.triangle.2.circlepath" : "checkmark.circle"
        }
    }
}
