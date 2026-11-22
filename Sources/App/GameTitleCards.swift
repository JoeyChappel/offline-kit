import Foundation
import CoreGraphics

/// The one emulator slot, shared by games and title-screen captures. libretro callbacks go through one global core
/// (see RetroCore), so only one core can run in the process: a capture claims the slot only while no game is running,
/// and a game that starts asks a running capture to stop and waits (briefly) until its core is gone.
final class GameArtworkGate: @unchecked Sendable {
    static let shared = GameArtworkGate()
    private let condition = NSCondition()
    private var capturing = false
    private var abort = false

    /// Called by GameSession.start before it loads its core: stops a capture and waits up to two seconds for its core
    /// to be released (it checks between frames, so this is normally a few milliseconds).
    func gameWillStart() {
        condition.lock()
        defer { condition.unlock() }
        abort = true
        let deadline = Date().addingTimeInterval(2)
        while capturing && condition.wait(until: deadline) {}
    }

    /// Claims the slot for a capture. Call on the main actor after checking that no game session is running, so a game
    /// starting (also on the main actor) can't slip in between.
    func beginCapture() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard !capturing else { return false }
        capturing = true
        abort = false
        return true
    }

    /// True once a game wants the slot: the capture stops at the next frame.
    var shouldAbort: Bool { condition.lock(); defer { condition.unlock() }; return abort }

    /// The capture's core is released.
    func endCapture() {
        condition.lock()
        capturing = false
        condition.broadcast()
        condition.unlock()
    }

    var isCapturing: Bool { condition.lock(); defer { condition.unlock() }; return capturing }
}

/// Title screens for cartridge games with no picture yet. The game runs headless (no window, no sound, no input) as fast
/// as it will for up to 12 seconds of game time, frames are kept at 1, 2, 3, 4, 6, 8, 10 and 12 seconds, and the best
/// one becomes the shelf picture until the game is played (its last frame wins then).
///
/// Safety: the player's saves are never read or written. The core's save and system folders are a throwaway temp folder,
/// no battery save, state or autosave is loaded or written, and nothing is pressed. Each capture stops after 3 seconds
/// of real time, or at once when a game starts (GameArtworkGate). A capture is marked "trying" before it starts, so a
/// game that crashes its emulator is never tried again. DOS and ScummVM keep their stand-in art.
enum GameTitleCards {
    static func supports(_ system: GameSystem) -> Bool {
        [.nes, .gameBoy, .gameBoyColor, .gameBoyAdvance, .pcEngine].contains(system)
    }

    static let capturePoints: [Double] = [1, 2, 3, 4, 6, 8, 10, 12]
    static let wallLimit: Double = 3

    nonisolated static var folder: URL { MediaInfoStore.folder.appending(path: "game-art", directoryHint: .isDirectory) }

    struct Record: Codable {
        /// "ok", "none" (nothing usable), "trying" (started; if still "trying" later, the emulator crashed).
        var status: String
        var source: String
        var file: String?
        var seconds: Double?
        var pickedAt: Double?
    }

    private final class Memo: @unchecked Sendable {
        let lock = NSLock()
        var paths: [String: String] = [:]
    }
    private static let memo = Memo()

    nonisolated static func key(_ game: Game) -> String? { ArtworkRules.key(for: game.url, kind: "game") }

    nonisolated static func readRecord(_ key: String) -> Record? {
        (try? Data(contentsOf: folder.appending(path: "\(key).json"))).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    nonisolated static func writeRecord(_ record: Record, key: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(record).write(to: folder.appending(path: "\(key).json"), options: .atomic)
    }

    /// True when this game was looked at before (whatever came of it), or already has a picture from being played.
    nonisolated static func isKnown(_ game: Game) -> Bool {
        if FileManager.default.fileExists(atPath: game.thumbnailURL.path) { return true }
        guard let key = key(game), let record = readRecord(key) else { return false }
        if record.status == "ok", let file = record.file {
            let path = folder.appending(path: file).path
            guard FileManager.default.fileExists(atPath: path) else { return false }
            memo.lock.withLock { memo.paths[game.id] = path }
        }
        return true
    }

    /// The title screen already made for this game, from memory (no disk access, for views).
    nonisolated static func cachedPath(for game: Game) -> String? { memo.lock.withLock { memo.paths[game.id] } }

    /// The shelf picture for sharing: the played game's last frame, else the title screen. Reads the disk.
    nonisolated static func shelfPicture(for game: Game) -> URL? {
        if FileManager.default.fileExists(atPath: game.thumbnailURL.path) { return game.thumbnailURL }
        if let known = cachedPath(for: game) { return URL(fileURLWithPath: known) }
        guard let key = key(game), let record = readRecord(key), record.status == "ok", let file = record.file else { return nil }
        let url = folder.appending(path: file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The games still to look at, and the title screens already made (game id → path). Reads the disk: call off the main thread.
    nonisolated static func survey(_ games: [Game]) -> (todo: [Game], made: [String: String]) {
        var todo: [Game] = []
        var made: [String: String] = [:]
        for game in games where supports(game.system) {
            if isKnown(game) { if let path = cachedPath(for: game) { made[game.id] = path } } else { todo.append(game) }
        }
        return (todo, made)
    }

    // MARK: Capture

    /// Makes the title screen for one game. Nil when a game is running (try again later) or nothing usable was found.
    @MainActor static func generate(_ game: Game) async -> String? {
        // Checked together on the main actor, where games start, so a game can't start between the two.
        guard GameSession.current == nil, GameArtworkGate.shared.beginCapture() else { return nil }
        guard let frameworks = Bundle.main.privateFrameworksURL else { GameArtworkGate.shared.endCapture(); return nil }
        let core = frameworks.appending(path: "\(game.system.coreName).framework/\(game.system.coreName)").path
        return await Task.detached(priority: .utility) { () -> String? in
            guard let key = key(game) else { GameArtworkGate.shared.endCapture(); return nil }
            if readRecord(key)?.status == "trying" {
                // Started before and never finished: the emulator crashed on this game. Never again.
                writeRecord(Record(status: "none", source: game.url.path, file: nil, seconds: nil), key: key)
                GameArtworkGate.shared.endCapture()
                return nil
            }
            writeRecord(Record(status: "trying", source: game.url.path, file: nil, seconds: nil), key: key)
            let started = Date()
            let outcome = capture(game, corePath: core, gate: GameArtworkGate.shared)
            GameArtworkGate.shared.endCapture()
            switch outcome {
            case .aborted:
                // Someone started playing: not this game's fault, so it's tried again another time.
                try? FileManager.default.removeItem(at: folder.appending(path: "\(key).json"))
                return nil
            case .failed:
                writeRecord(Record(status: "none", source: game.url.path, file: nil, seconds: Date().timeIntervalSince(started)), key: key)
                return nil
            case .frames(let shots):
                let infos = shots.map { shot in
                    ShotInfo(seconds: shot.seconds, stats: FrameStats.measure(shot.image, width: 160),
                             text: FrameText.read(upscaled(shot.image) ?? shot.image, accurate: true).map(\.text))
                }
                guard let index = choose(infos, title: game.title) else {
                    writeRecord(Record(status: "none", source: game.url.path, file: nil, seconds: Date().timeIntervalSince(started)), key: key)
                    return nil
                }
                let file = "\(key).png"
                let url = folder.appending(path: file)
                guard ArtworkFiles.writePNG(shots[index].image, to: url) else { return nil }
                writeRecord(Record(status: "ok", source: game.url.path, file: file, seconds: Date().timeIntervalSince(started),
                                   pickedAt: shots[index].seconds), key: key)
                memo.lock.withLock { memo.paths[game.id] = url.path }
                return url.path
            }
        }.value
    }

    enum Outcome {
        case frames([(seconds: Double, image: CGImage)])
        case aborted
        case failed
    }

    private final class Latest: @unchecked Sendable { var image: CGImage? }

    /// Runs the game headless and keeps frames at the capture points. The caller holds the gate.
    nonisolated static func capture(_ game: Game, corePath: String, gate: GameArtworkGate,
                                    points: [Double] = capturePoints, wallLimit: Double = wallLimit) -> Outcome {
        let temp = FileManager.default.temporaryDirectory.appending(path: "okit-title-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        var shots: [(Double, CGImage)] = []
        var aborted = false
        autoreleasepool {
            // Throwaway folders for everything the core might read or write; the player's Saves folder is never named.
            guard let core = try? RetroCore(libraryPath: corePath, options: game.system.coreOptions,
                                            systemDirectory: temp.path, saveDirectory: temp.path) else { return }
            core.portDevice = 1
            guard (try? core.loadGame(atPath: game.url.path, systemDirectory: temp.path, saveDirectory: temp.path)) != nil else { return }
            let fps = core.framesPerSecond > 1 ? core.framesPerSecond : 60
            let targets = points.map { Int(($0 * fps).rounded()) }
            let latest = Latest()
            let started = Date()
            var next = 0
            var frame = 0
            while next < targets.count {
                if gate.shouldAbort { aborted = true; break }
                if Date().timeIntervalSince(started) > wallLimit || core.shutdownRequested { break }
                frame += 1
                let wanted = frame == targets[next]
                if wanted { core.frameHandler = { latest.image = $0 } }
                core.runFrame()
                if wanted {
                    core.frameHandler = nil
                    if let image = latest.image.flatMap(copy) { shots.append((points[next], image)) }
                    latest.image = nil
                    next += 1
                }
            }
            core.frameHandler = nil
            core.unloadGame()
        }
        if aborted { return .aborted }
        return shots.isEmpty ? .failed : .frames(shots)
    }

    /// A copy that owns its pixels (the core's frames come from a reused buffer pool).
    private static func copy(_ image: CGImage) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Pixel art four times as big, with hard edges, so Vision can read 8-pixel lettering.
    static func upscaled(_ image: CGImage, by factor: Int = 4) -> CGImage? {
        let w = image.width * factor, h = image.height * factor
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return context.makeImage()
    }

    // MARK: Choosing

    struct ShotInfo: Sendable {
        var seconds: Double
        var stats: FrameStats?
        var text: [String]
    }

    /// The frame to keep: the one that shows the game's title, else the most detailed frame that isn't blank or a
    /// publisher's splash. Nil when every frame is blank or a splash.
    static func choose(_ shots: [ShotInfo], title: String) -> Int? {
        let usable = shots.indices.filter { i in
            guard let stats = shots[i].stats, !FrameCheck.isBlank(stats) else { return false }
            return !isSplash(shots[i].text, title: title)
        }
        guard !usable.isEmpty else { return nil }
        func detail(_ i: Int) -> Double { (shots[i].stats?.detail ?? 0) + (shots[i].stats?.deviation ?? 0) * 0.5 }
        let titled = usable.map { ($0, TitleMatch.score(shots[$0].text.joined(separator: " "), title: title)) }.filter { $0.1 >= 0.6 }
        if let best = titled.max(by: { $0.1 != $1.1 ? $0.1 < $1.1 : detail($0.0) < detail($1.0) }) { return best.0 }
        return usable.max { detail($0) < detail($1) }
    }

    /// A publisher's or licensor's splash ("LICENSED BY NINTENDO", "HUDSON SOFT PRESENTS", "© 1990 …") with little
    /// else on it. A screen that also shows the title or "PRESS START" is a title screen, not a splash.
    static func isSplash(_ text: [String], title: String) -> Bool {
        let joined = text.joined(separator: " ")
        guard !joined.isEmpty else { return false }
        if !title.isEmpty, TitleMatch.score(joined, title: title) >= 0.6 { return false }
        let lower = " " + joined.lowercased().map { $0.isLetter || $0.isNumber || $0 == "©" ? $0 : " " }.map(String.init).joined() + " "
        let titleScreen = ["press start", "push start", "press any", "start game", "game start", "1 player", "2 player",
                           "new game", "continue", "options"]
        if titleScreen.contains(where: { lower.contains(" \($0) ") }) { return false }
        let phrases = ["licensed by", "licensed from", "license", "licensed", "presents", "presented by", "present", "nintendo", "sega",
                       "©", "copyright", "all rights reserved", "rights reserved", "produced by", "developed by", "published by",
                       "programmed by", "trademark", "tm", "c", "seal", "quality", "warning", "inc", "ltd", "co", "corp", "soft",
                       "software", "games", "entertainment", "hudson", "nec", "konami", "capcom", "namco", "taito"]
        let markers = ["licensed", "license", "presents", "present", "nintendo", "sega", "©", "copyright", "rights reserved",
                       "produced by", "developed by", "published by", "programmed by", "trademark", "seal of quality"]
        guard markers.contains(where: { lower.contains(" \($0) ") || ($0 == "©" && lower.contains("©")) }) || lower.contains(" c ") else { return false }
        var rest = lower
        for phrase in phrases.sorted(by: { $0.count > $1.count }) { rest = rest.replacingOccurrences(of: " \(phrase) ", with: "  ") }
        let words = rest.split(separator: " ").filter { word in !(word.count == 4 && word.allSatisfy(\.isNumber)) && word != "©" }
        return words.count <= 6
    }

    // MARK: Prune

    /// Forgets title screens for games that are gone. Games on a drive that's just unplugged keep theirs.
    nonisolated static func prune(keeping games: [Game]) {
        let keys = Set(games.compactMap(key))
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            guard !keys.contains(key), let record = readRecord(key), !record.source.hasPrefix("/Volumes/") else { continue }
            try? fm.removeItem(at: file)
            try? fm.removeItem(at: folder.appending(path: "\(key).png"))
        }
    }
}
