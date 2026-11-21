import SwiftUI
import AVFoundation
import GameController
import ImageIO
import UniformTypeIdentifiers
import QuartzCore

// MARK: - Games and systems

enum GameSystem: String, CaseIterable, Codable, Identifiable {
    case gameBoy, gameBoyColor, gameBoyAdvance, nes, atari2600, pcEngine, dos, scummvm
    var id: String { rawValue }

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "gb": self = .gameBoy
        case "gbc": self = .gameBoyColor
        case "gba": self = .gameBoyAdvance
        case "nes": self = .nes
        case "pce": self = .pcEngine
        case "dosz": self = .dos
        case "scummvm": self = .scummvm
        default: return nil
        }
    }

    static var fileExtensions: [String] { ["gb", "gbc", "gba", "nes", "pce", "dosz", "zip", "scummvm"] }

    /// Folders that hold the games of one system whose files are too generic to claim anywhere else.
    nonisolated static let dosFolder = "DOS"
    nonisolated static let scummvmFolder = "ScummVM"
    /// Files a "DOS" folder may hold directly: zipped games, programs and disk images (DOSBox Pure opens them all).
    nonisolated static let dosFolderExtensions: Set<String> = ["zip", "exe", "com", "bat", "iso", "cue", "img", "ima", "vhd"]

    /// Like init(fileExtension:), plus the rules for generic files:
    /// - Atari 2600 games (.a26, small .bin) aren't played any more: the Stella core's license (GPL with no
    ///   version named) can't be confirmed compatible with the app's GPLv3. The case stays so saved data still loads.
    /// - DOS: a .dosz file anywhere (DOSBox Pure's name for a zipped DOS game), or a .zip, .exe, .com, .bat or disk image
    ///   directly inside a folder named "DOS". A plain .zip elsewhere could be anything, so it isn't claimed.
    /// - ScummVM: each folder directly inside a folder named "ScummVM" is one game (ScummVM detects which from its files),
    ///   or a .scummvm file (ScummVM's own shortcut, holding a game ID) beside a game's files.
    nonisolated init?(file url: URL) {
        let ext = url.pathExtension.lowercased()
        let parent = url.deletingLastPathComponent().lastPathComponent
        if Self.isSystemFile(url) { return nil }
        if parent.caseInsensitiveCompare(Self.scummvmFolder) == .orderedSame,
           (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            self = .scummvm
        } else if parent.caseInsensitiveCompare(Self.dosFolder) == .orderedSame {
            guard ext == "dosz" || Self.dosFolderExtensions.contains(ext) else { return nil }
            self = .dos
        } else {
            self.init(fileExtension: url.pathExtension)
        }
    }

    /// Game files' extensions, for zips that hold one game (.bin is left out: inside a zip it could be anything).
    nonisolated static let romExtensions: Set<String> = ["gb", "gbc", "gba", "nes", "pce"]

    /// Emulator system files ("gba_bios.bin") sit beside games but aren't games. Matched as a word, so "Symbiosis" is fine.
    nonisolated static func isSystemFile(_ url: URL) -> Bool {
        url.lastPathComponent.range(of: #"(^|[^a-z])bios([^a-z]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// ScummVM saves from each game's own menu; it has no save states, so Save, Load and Resume don't apply.
    var hasSaveStates: Bool { self != .scummvm }

    /// DOS and ScummVM games take a keyboard and mouse (or taps) instead of only a game pad.
    var usesKeyboardAndMouse: Bool { self == .dos || self == .scummvm }

    /// Settings handed to the emulator (libretro core options). Taps work like a laptop touchpad on iPhone and iPad.
    var coreOptions: [String: String] {
        switch self {
        case .dos:
            // menu_time 0: when the game's program exits, the core says so (RETRO_ENVIRONMENT_SHUTDOWN) instead of
            // showing its own start menu again, and the app shows "The game has ended".
            #if os(iOS)
            ["dosbox_pure_mouse_input": "pad", "dosbox_pure_menu_time": "0"]
            #else
            ["dosbox_pure_mouse_input": "true", "dosbox_pure_menu_time": "0"]
            #endif
        case .scummvm:
            // The core only draws in software if this is answered; left unset it expects an OpenGL context.
            #if os(iOS)
            ["scummvm_pointer_device": "pointer", "scummvm_video_hw_acceleration": "disabled"]
            #else
            ["scummvm_pointer_device": "mouse", "scummvm_mouse_speed": "1.0", "scummvm_video_hw_acceleration": "disabled"]
            #endif
        default: [:]
        }
    }

    var name: String {
        switch self {
        case .gameBoy: "Game Boy"
        case .gameBoyColor: "Game Boy Color"
        case .gameBoyAdvance: "Game Boy Advance"
        case .nes: "NES"
        case .atari2600: "Atari 2600"
        case .pcEngine: "PC Engine"
        case .dos: "DOS"
        case .scummvm: "ScummVM"
        }
    }

    /// The libretro core framework that plays this system.
    var coreName: String {
        switch self {
        case .nes: "fceumm_libretro"
        case .atari2600: "stella_libretro"
        case .pcEngine: "mednafen_pce_fast_libretro"
        case .dos: "dosbox_pure_libretro"
        case .scummvm: "scummvm_libretro"
        case .gameBoy, .gameBoyColor, .gameBoyAdvance: "mgba_libretro"
        }
    }

    /// Screen shape: handhelds use their own screens; the Atari, DOS PCs and ScummVM's adventures drew to 4:3 screens,
    /// and 6:5 is the PC Engine shape its emulator (Mednafen) uses.
    var aspectRatio: CGFloat {
        switch self {
        case .gameBoyAdvance: 1.5
        case .nes: 16.0 / 15.0
        case .atari2600, .dos, .scummvm: 4.0 / 3.0
        case .pcEngine: 6.0 / 5.0
        case .gameBoy, .gameBoyColor: 10.0 / 9.0
        }
    }
    var hasShoulderButtons: Bool { self == .gameBoyAdvance }
    /// "a Game Boy game", "an NES game", for sentences.
    var aGame: String { [.nes, .atari2600].contains(self) ? "an \(name) game" : "a \(name) game" }

    var tint: Color {
        switch self {
        case .gameBoy: Color(red: 0.45, green: 0.55, blue: 0.25)
        case .gameBoyColor: Color(red: 0.55, green: 0.30, blue: 0.70)
        case .gameBoyAdvance: Color(red: 0.25, green: 0.35, blue: 0.75)
        case .nes: Color(red: 0.75, green: 0.20, blue: 0.20)
        case .atari2600: Color(red: 0.80, green: 0.45, blue: 0.15)
        case .pcEngine: Color(red: 0.20, green: 0.55, blue: 0.60)
        case .dos: Color(red: 0.35, green: 0.42, blue: 0.52)
        case .scummvm: Color(red: 0.42, green: 0.58, blue: 0.18)
        }
    }
}

struct Game: Identifiable, Hashable {
    let url: URL
    let system: GameSystem
    /// When the saved place and its picture last changed, as of the last scan. Part of equality, so a new save
    /// redraws cards and detail screens (they read the save files from disk).
    private(set) var savedStamp: Double = 0
    init(url: URL, system: GameSystem) {
        self.url = url.standardizedFileURL.resolvingSymlinksInPath()
        self.system = system
    }
    var id: String { url.path }
    var ref: GameRef { GameRef(path: url.path) }

    /// The name without its extension. A ScummVM game folder's whole name counts ("Queen v1.1" keeps its ".1").
    private var baseName: String {
        system == .scummvm && url.pathExtension.lowercased() != "scummvm"
            ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }

    var title: String {
        baseName
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Saves live in a "Saves" folder beside the games, so they travel with the drive. They're named after the whole
    /// file name ("Tetris.gb.srm"), so "Tetris.gb" and "Tetris.gbc" keep separate saves.
    var savesFolder: URL { GameLibrary.gamesRoot(containing: url).appending(path: "Saves", directoryHint: .isDirectory) }
    private var saveBase: URL { savesFolder.appending(path: url.lastPathComponent) }
    var batterySaveURL: URL { saveBase.appendingPathExtension("srm") }
    /// The place saved with Save (⌘S).
    var stateURL: URL { saveBase.appendingPathExtension("state") }
    /// Where the player left off, written when the game window closes or the app quits.
    var autosaveURL: URL { saveBase.appendingPathExtension("autosave") }
    var thumbnailURL: URL { saveBase.appendingPathExtension("png") }
    var metadataURL: URL { savesFolder.appending(path: url.lastPathComponent + ".metadata.json") }
    var hasSaveState: Bool { FileManager.default.fileExists(atPath: stateURL.path) }
    /// A saved place or an autosave exists, so Resume can pick the game up again.
    var canResume: Bool { system.hasSaveStates && resumeStateURL != nil }
    /// The newer of the saved place and the autosave.
    var resumeStateURL: URL? {
        [stateURL, autosaveURL].compactMap { url -> (URL, Date)? in
            guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate else { return nil }
            return (url, date)
        }.max { $0.1 < $1.1 }?.0
    }

    /// Saves from before they were named after the whole file name ("Tetris.srm") move to the new names. When two
    /// games share a name ("Tetris.gb" and "Tetris.gbc"), the first one found takes the old saves.
    nonisolated func migrateLegacySaves() {
        let legacy = savesFolder.appending(path: baseName)
        guard legacy.lastPathComponent != saveBase.lastPathComponent else { return }
        let fm = FileManager.default
        for ext in ["srm", "state", "png"] {
            let old = legacy.appendingPathExtension(ext), new = saveBase.appendingPathExtension(ext)
            if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) { try? fm.moveItem(at: old, to: new) }
        }
    }

    /// This game with `savedStamp` read from its save files.
    nonisolated func stamped() -> Game {
        var game = self
        let dates = [stateURL, autosaveURL, thumbnailURL].map {
            (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        }
        game.savedStamp = dates.reduce(0, +)
        return game
    }
}

/// Opens a game window. Equal for the same game whatever `resume` says, so Play and Resume on a game that's already
/// open bring its window forward instead of opening a second one.
struct GameRef: Codable, Hashable, Identifiable {
    let path: String
    var resume: Bool = false
    static func == (a: GameRef, b: GameRef) -> Bool { a.path == b.path }
    func hash(into hasher: inout Hasher) { hasher.combine(path) }
    init(path: String, resume: Bool = false) { self.path = path; self.resume = resume }
    private enum CodingKeys: String, CodingKey { case path, resume }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        resume = try container.decodeIfPresent(Bool.self, forKey: .resume) ?? false
    }
    var id: String { path }
    var game: Game? {
        let url = URL(fileURLWithPath: path)
        return GameSystem(file: url).map { Game(url: url, system: $0) }
    }
}

extension Notification.Name {
    /// Posted by a game window (object: the game's path) once its game has really started, so it counts as played.
    static let gameDidStart = Notification.Name("GameSessionDidStart")
}

// MARK: - Library of games

@MainActor @Observable
final class GameLibrary {
    private(set) var games: [Game] = []
    private(set) var favorites: Set<String> = []
    private(set) var lastPlayed: [String: Date] = [:]
    var issue: String?
    /// What Add Games is copying right now ("Adding Beneath a Steel Sky…"), or nil.
    private(set) var adding: String?

    /// How a DOS game is played: the keyboard and mouse go straight to DOS, or player 1 is a two-button joystick
    /// (arrow keys and Z/X, or a game controller) for games that say a joystick is required.
    enum DOSControls: String, Codable, CaseIterable { case keyboard, joystick }

    struct Metadata: Codable {
        var favorite = false
        var lastPlayed: Date?
        var dosControls: DOSControls?
    }

    init() {
        // A game window says when its game really started, so a file that fails to open isn't counted as played.
        NotificationCenter.default.addObserver(forName: .gameDidStart, object: nil, queue: .main) { [weak self] note in
            guard let path = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let self, let game = self.games.first(where: { $0.url.path == path }) ?? GameRef(path: path).game else { return }
                self.recordPlayed(game)
            }
        }
    }

    func dosControls(for game: Game) -> DOSControls { metadata(for: game).dosControls ?? .keyboard }

    func setDOSControls(_ controls: DOSControls, for game: Game) {
        var data = metadata(for: game)
        data.dosControls = controls
        do {
            try save(data, for: game)
            edits += 1
        } catch { issue = "Couldn’t save the controls setting: \(error.localizedDescription)" }
    }

    /// Moves the game (file or ScummVM folder) to the Trash. Its saves stay in the Saves folder, so adding it again
    /// brings them back.
    func remove(_ game: Game, library: Library) async {
        do { try FileManager.default.trashItem(at: game.url, resultingItemURL: nil) }
        catch { issue = "Couldn’t move \(game.title) to the Trash: \(error.localizedDescription)" }
        await reload(library: library)
    }

    func toggleFavorite(_ game: Game) {
        var data = metadata(for: game)
        data.favorite.toggle()
        do {
            try save(data, for: game)
            if data.favorite { favorites.insert(game.id) } else { favorites.remove(game.id) }
            edits += 1
        } catch { issue = "Couldn’t save the favorite: \(error.localizedDescription)" }
    }

    func recordPlayed(_ game: Game) {
        var data = metadata(for: game)
        data.lastPlayed = Date()
        do {
            try save(data, for: game)
            lastPlayed[game.id] = data.lastPlayed
            edits += 1
        } catch { issue = "Couldn’t save the recent-game history: \(error.localizedDescription)" }
    }

    private func metadata(for game: Game) -> Metadata { Self.metadata(for: game) }

    nonisolated static func metadata(for game: Game) -> Metadata {
        (try? Data(contentsOf: game.metadataURL)).flatMap { try? JSONDecoder().decode(Metadata.self, from: $0) } ?? Metadata()
    }

    private func save(_ metadata: Metadata, for game: Game) throws {
        try FileManager.default.createDirectory(at: game.savesFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(metadata).write(to: game.metadataURL, options: .atomic)
    }

    /// Every Library folder's "Games" subfolder.
    func folders(from library: Library) -> [URL] {
        #if os(macOS)
        return library.folders.map { $0.appending(path: "Games", directoryHint: .isDirectory) }
        #else
        return [URL.documentsDirectory.appending(path: "Games", directoryHint: .isDirectory)]
        #endif
    }

    /// Where imported games go: beside the app in drive mode, else this Mac (or the iPhone's Documents).
    /// In the library they chose for their kit (often a USB drive), so it all travels together.
    static var importFolder: URL { KitStorage.games }

    /// The "Games" folder a game file sits under (games can be in console subfolders).
    nonisolated static func gamesRoot(containing url: URL) -> URL {
        var dir = url.deletingLastPathComponent()
        while dir.path != "/" {
            if dir.lastPathComponent == "Games" { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return url.deletingLastPathComponent()
    }

    /// One scan at a time: see ScanGate. Without it, a scan that started before a game was added could finish last
    /// and put back the old list.
    @ObservationIgnored private let scans = ScanGate()
    /// Bumped by favorites and play history saved here, so a scan that read the files before the change
    /// doesn't put the old values back.
    @ObservationIgnored private var edits = 0

    /// Rescans every Games folder. When it returns, `games` reflects the folders as they were after this call was made.
    func reload(library: Library) async {
        await scans.run { [weak self] in await self?.scan(library: library) }
    }

    private func scan(library: Library) async {
        let folders = folders(from: library)
        let editsBefore = edits
        let result = await Task.detached(priority: .userInitiated) {
            let games = Self.scan(folders)
            var favorites = Set<String>(), recent: [String: Date] = [:]
            for game in games {
                guard let data = try? Data(contentsOf: game.metadataURL),
                      let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { continue }
                if metadata.favorite { favorites.insert(game.id) }
                if let date = metadata.lastPlayed { recent[game.id] = date }
            }
            return (games, favorites, recent)
        }.value
        games = result.0
        if edits == editsBefore {
            favorites = result.1
            lastPlayed = result.2
        } else {
            // A favorite or play changed while the files were read: keep what's on screen and read them again.
            scans.runAgain()
        }
    }

    nonisolated static func scan(_ folders: [URL]) -> [Game] {
        var found: [Game] = []
        var seen = Set<String>()
        for folder in folders {
            guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker {
                if url.lastPathComponent == "Saves" { walker.skipDescendants(); continue }
                if url.lastPathComponent.hasPrefix("._") { continue }
                // An unpacked folder inside DOS isn't offered (add the game's .zip instead); its files aren't games.
                if url.deletingLastPathComponent().lastPathComponent.caseInsensitiveCompare(GameSystem.dosFolder) == .orderedSame,
                   (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    walker.skipDescendants(); continue
                }
                guard let system = GameSystem(file: url) else { continue }
                // A ScummVM game folder is one game; its data files (some end in .bin) aren't games of their own.
                if system == .scummvm && url.pathExtension.lowercased() != "scummvm" { walker.skipDescendants() }
                guard seen.insert(url.lastPathComponent.lowercased()).inserted else { continue }
                let game = Game(url: url, system: system)
                game.migrateLegacySaves()
                found.append(game.stamped())
            }
        }
        return found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// What Add Games did with each chosen file, for one message afterwards.
    struct ImportReport {
        var added: [String] = []
        /// A different game already had the name, so the copy got a new one ("Tetris 2.gb").
        var renamed: [(from: String, to: String)] = []
        var skipped: [(name: String, reason: String)] = []

        /// Something the person should read: anything skipped or renamed. Nil when every file went in as it was.
        var message: String? {
            guard !skipped.isEmpty || !renamed.isEmpty else { return nil }
            var lines: [String] = []
            lines.append(added.isEmpty ? "No games were added." : "Added \(added.count) \(added.count == 1 ? "game" : "games").")
            for item in renamed { lines.append("\(item.from) was added as “\(item.to)”, because a different game already has that name.") }
            for item in skipped { lines.append("Skipped \(item.name): \(item.reason)") }
            return lines.joined(separator: "\n\n")
        }
    }

    private enum ImportOutcome: Sendable {
        case added(String), renamed(String, String), skipped(String, String)
    }

    /// Copies game files into the import folder and says what happened to each one.
    /// - A folder becomes a ScummVM game (Games/ScummVM/<folder>), once it looks like one game's files.
    /// - A .zip holding a DOS program, or an .exe, .com or .bat, goes to Games/DOS.
    /// - A .zip holding exactly one game file (.gb .gbc .gba .nes .pce) is unzipped: just that file is added.
    /// - A name already taken by a different game gets a number ("Tetris 2.gb"); the very same file is skipped.
    @discardableResult
    func importGames(_ urls: [URL], library: Library) async -> ImportReport {
        let root = Self.importFolder
        library.adopt(root.deletingLastPathComponent())
        var report = ImportReport()
        // Copied off the main thread (a DOS game or ScummVM folder can be big), one at a time so the progress
        // line can name each. Whatever was copied before a failure still shows up: the rescan runs either way.
        for (index, url) in urls.enumerated() {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            let name = isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
            adding = urls.count > 1 ? "Adding \(name) (\(index + 1) of \(urls.count))…" : "Adding \(name)…"
            let outcome = await Task.detached(priority: .userInitiated) { Self.importOne(url, into: root) }.value
            switch outcome {
            case .added(let name): report.added.append(name)
            case .renamed(let from, let to): report.added.append(to); report.renamed.append((from, to))
            case .skipped(let name, let reason): report.skipped.append((name, reason))
            }
        }
        adding = nil
        await reload(library: library)
        return report
    }

    nonisolated private static func importOne(_ url: URL, into root: URL) -> ImportOutcome {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let ext = url.pathExtension.lowercased()
        do {
            if isFolder {
                if let problem = scummVMFolderProblem(url) { return .skipped(name, problem) }
                return try place(url, in: root.appending(path: GameSystem.scummvmFolder, directoryHint: .isDirectory))
            }
            if ext == "zip" {
                if zipHoldsDOSProgram(url) { return try place(url, in: root.appending(path: GameSystem.dosFolder, directoryHint: .isDirectory)) }
                return try unzipOneGame(url, into: root)
            }
            if ["exe", "com", "bat"].contains(ext) {
                return try place(url, in: root.appending(path: GameSystem.dosFolder, directoryHint: .isDirectory))
            }
            if GameSystem.isSystemFile(url) {
                return .skipped(name, "it’s an emulator system file (BIOS), not a game. Offline Kit doesn’t need it.")
            }
            if ext == "a26" || ext == "bin" {
                return .skipped(name, "Offline Kit doesn’t play Atari 2600 games or disc images.")
            }
            guard GameSystem(file: url) != nil else {
                return .skipped(name, "Offline Kit can’t play this kind of file. It plays .gb, .gbc, .gba, .nes and .pce game files, DOS games in a .zip, and ScummVM game folders.")
            }
            return try place(url, in: root)
        } catch {
            return .skipped(name, "it couldn’t be copied (\(error.localizedDescription)).")
        }
    }

    /// Copies a file or folder into `folder`, renaming it if a different game has its name.
    nonisolated private static func place(_ source: URL, in folder: URL) throws -> ImportOutcome {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = source.lastPathComponent
        guard let target = uniqueTarget(named: name, in: folder, isSame: { sameItem($0, source) }) else {
            return .skipped(name, "it’s already on your shelf.")
        }
        try FileManager.default.copyItem(at: source, to: target)
        return target.lastPathComponent == name ? .added(name) : .renamed(name, target.lastPathComponent)
    }

    /// A free name in `folder`: the name itself, else "Name 2.ext", "Name 3.ext"… Nil when an item of that name
    /// is already the same game, so there's nothing to add.
    nonisolated static func uniqueTarget(named name: String, in folder: URL, isSame: (URL) -> Bool) -> URL? {
        let fm = FileManager.default
        let first = folder.appending(path: name)
        guard fm.fileExists(atPath: first.path) else { return first }
        if isSame(first) { return nil }
        let ext = (name as NSString).pathExtension, base = (name as NSString).deletingPathExtension
        for n in 2...999 {
            let candidate = folder.appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            if isSame(candidate) { return nil }
        }
        return nil
    }

    /// Same size and checksum (files), or the same files with the same sizes (folders).
    nonisolated static func sameItem(_ a: URL, _ b: URL) -> Bool {
        func folderSignature(_ url: URL) -> [String: Int]? {
            guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return nil }
            var files: [String: Int] = [:]
            for case let file as URL in walker {
                guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                files[String(file.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count))] = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if files.count > 5000 { return nil }
            }
            return files
        }
        let aFolder = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let bFolder = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard aFolder == bFolder else { return false }
        if aFolder { return folderSignature(a).map { $0 == folderSignature(b) } ?? false }
        let size = { (url: URL) in (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1 }
        guard size(a) == size(b), let x = FileChecksum.sha256(a), let y = FileChecksum.sha256(b) else { return false }
        return x == y
    }

    /// A zip holding one game file: that file is taken out and added. Anything else is explained.
    nonisolated private static func unzipOneGame(_ url: URL, into root: URL) throws -> ImportOutcome {
        let name = url.lastPathComponent
        let unzipFirst = "Offline Kit can’t open this zip. If it holds a game, unzip it first (double-click it in Finder), then add the file inside."
        guard let zip = ZipReader(url: url) else { return .skipped(name, unzipFirst) }
        let games = zip.entries.keys.filter { entry in
            let file = (entry as NSString).lastPathComponent
            return !entry.hasPrefix("__MACOSX/") && !file.hasPrefix("._") && !entry.hasSuffix("/")
                && GameSystem.romExtensions.contains((file as NSString).pathExtension.lowercased())
        }
        guard !games.isEmpty else {
            return .skipped(name, "there’s no game Offline Kit can play inside. If it holds a game, unzip it first (double-click it in Finder), then add the file inside.")
        }
        guard games.count == 1, let entry = games.first else {
            return .skipped(name, "it holds \(games.count) games. Unzip it first (double-click it in Finder), then add the games you want.")
        }
        guard let data = zip.data(entry) else { return .skipped(name, unzipFirst) }
        let file = (entry as NSString).lastPathComponent
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        guard let target = uniqueTarget(named: file, in: root, isSame: { (try? Data(contentsOf: $0)) == data }) else {
            return .skipped(name, "the game inside, \(file), is already on your shelf.")
        }
        try data.write(to: target, options: .withoutOverwriting)
        return target.lastPathComponent == file ? .added(file) : .renamed("\(file) (from \(name))", target.lastPathComponent)
    }

    /// Why a folder chosen with Add ScummVM Game Folder isn't one game's files, or nil if it may well be. ScummVM itself
    /// works out which game it is when it's played; this only keeps out folders that clearly aren't a game.
    nonisolated static func scummVMFolderProblem(_ url: URL) -> String? {
        let fileLimit = 2_000, byteLimit: Int64 = 2_000_000_000
        // Documents, pictures, music, video and installers: a folder of only these isn't a game.
        let notGameData: Set<String> = ["txt", "pdf", "rtf", "doc", "docx", "md", "htm", "html", "jpg", "jpeg", "png", "heic",
            "gif", "tif", "tiff", "bmp", "webp", "mov", "mp4", "m4v", "avi", "mkv", "mp3", "m4a", "aac", "flac", "wav",
            "xls", "xlsx", "csv", "pages", "numbers", "key", "ppt", "pptx", "epub", "zip", "rar", "7z", "dmg", "pkg",
            "exe", "dll", "url", "webloc", "ico", "icns", "lnk", "ini", "cfg", "log", "nfo", "diz", "json", "plist"]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            return "Offline Kit couldn’t look inside this folder."
        }
        var files = 0, bytes: Int64 = 0, hasData = false, zips = 0
        for case let file as URL in walker {
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            files += 1
            bytes += Int64(values?.fileSize ?? 0)
            if files > fileLimit {
                return "it has more than 2,000 files, which is too many for one adventure game. Choose the folder that holds just the game’s files."
            }
            if bytes > byteLimit {
                return "it’s larger than 2 GB, which is too big for one adventure game. Choose the folder that holds just the game’s files."
            }
            let ext = file.pathExtension.lowercased()
            if ext == "zip" { zips += 1 }
            if !notGameData.contains(ext) { hasData = true }
        }
        if files == 0 { return "the folder is empty." }
        if !hasData {
            return zips > 0
                ? "it holds a .zip file. Unzip it first (double-click it in Finder), then add the folder that comes out."
                : "it holds only documents, pictures or music, not a game’s data files. Choose the folder with the game’s files."
        }
        return nil
    }

    /// Where an added file belongs under Games: "" for the top, "DOS", "ScummVM", or nil if it isn't a game.
    nonisolated static func importSubfolder(for url: URL) -> String? {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return GameSystem.scummvmFolder }
        switch url.pathExtension.lowercased() {
        case "zip": return zipHoldsDOSProgram(url) ? GameSystem.dosFolder : nil
        case "exe", "com", "bat": return GameSystem.dosFolder
        default: return GameSystem(file: url) != nil ? "" : nil
        }
    }

    /// True when a zip's table of contents lists a DOS program (.exe, .com or .bat). Reads only the zip's directory.
    nonisolated static func zipHoldsDOSProgram(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size >= 22 else { return false }
        let tailLength = min(size, 65_557)   // end record (22 bytes) plus the longest comment
        try? handle.seek(toOffset: size - tailLength)
        guard let tail = try? handle.read(upToCount: Int(tailLength)) else { return false }
        let bytes = [UInt8](tail)
        func u16(_ b: [UInt8], _ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ b: [UInt8], _ i: Int) -> Int { u16(b, i) | u16(b, i + 2) << 16 }
        guard let end = stride(from: bytes.count - 22, through: 0, by: -1).first(where: { u32(bytes, $0) == 0x0605_4b50 }) else { return false }
        let directorySize = u32(bytes, end + 12), directoryOffset = u32(bytes, end + 16)
        guard directorySize > 0, directorySize < 16_000_000, UInt64(directoryOffset + directorySize) <= size else { return false }
        try? handle.seek(toOffset: UInt64(directoryOffset))
        guard let data = try? handle.read(upToCount: directorySize) else { return false }
        let directory = [UInt8](data)
        var i = 0
        while i + 46 <= directory.count, u32(directory, i) == 0x0201_4b50 {
            let nameLength = u16(directory, i + 28), extraLength = u16(directory, i + 30), commentLength = u16(directory, i + 32)
            guard i + 46 + nameLength <= directory.count else { break }
            let name = String(decoding: directory[(i + 46)..<(i + 46 + nameLength)], as: UTF8.self).lowercased()
            if name.hasSuffix(".exe") || name.hasSuffix(".com") || name.hasSuffix(".bat") { return true }
            i += 46 + nameLength + extraLength + commentLength
        }
        return false
    }
}

// MARK: - Session

/// Thread-safe flags shared with the emulation thread.
private final class SessionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _running = true
    private var _paused = false
    var running: Bool { get { lock.withLock { _running } } set { lock.withLock { _running = newValue } } }
    var paused: Bool { get { lock.withLock { _paused } } set { lock.withLock { _paused = newValue } } }
    let done = DispatchSemaphore(value: 0)
}

/// Messages the core sent while a game was loading (ScummVM says "Game not found" when it doesn't recognize a folder).
private final class LoadMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var texts: [String] = []
    func append(_ text: String) { lock.withLock { texts.append(text) } }
    func contains(_ text: String) -> Bool { lock.withLock { texts.contains { $0.localizedCaseInsensitiveContains(text) } } }
}

/// The layer the game draws into, letterboxed. Pixel-sharp (nearest-neighbour) when the picture is blown up 3x or
/// more, or by a whole number; smoothed below that, where uneven pixel sizes make small text unreadable.
final class GameDisplay {
    let layer: CALayer = {
        let layer = CALayer()
        layer.magnificationFilter = .nearest
        // The view is already sized to the system's screen shape; stretch to it, since Atari 2600 and PC Engine
        // pixels weren't square on a TV.
        layer.contentsGravity = .resize
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        return layer
    }()
    var lastImage: CGImage?
    /// The view's size in screen pixels (points times the display's scale).
    private var viewPixels: CGSize = .zero
    private var imageSize: CGSize = .zero
    #if os(macOS)
    /// The keyboard-and-mouse view (DOS and ScummVM), which takes keys back when something else had focus.
    weak var inputView: NSView?
    #endif

    func viewResized(_ pixels: CGSize) {
        viewPixels = pixels
        updateFilter()
    }

    func imageChanged(_ image: CGImage) {
        let size = CGSize(width: image.width, height: image.height)
        guard size != imageSize else { return }
        imageSize = size
        updateFilter()
    }

    private func updateFilter() {
        guard imageSize.width > 0, imageSize.height > 0, viewPixels.width > 0 else { return }
        let sx = viewPixels.width / imageSize.width, sy = viewPixels.height / imageSize.height
        func whole(_ s: CGFloat) -> Bool { abs(s - s.rounded()) < 0.03 }
        let sharp = min(sx, sy) >= 3 || (whole(sx) && whole(sy))
        let filter: CALayerContentsFilter = sharp ? .nearest : .linear
        guard layer.magnificationFilter != filter else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.magnificationFilter = filter
        CATransaction.commit()
    }
}

/// One running game: loads the emulator core, runs it on its own thread at the console's frame rate,
/// plays its audio, takes input and keeps saves.
@MainActor @Observable
final class GameSession {
    static private(set) weak var current: GameSession?

    /// Why the game stopped by itself.
    enum Ending: Equatable {
        /// The game quit (a DOS program exited, or ScummVM's Quit).
        case finished
        /// Another game started; only one plays at a time.
        case replaced
    }

    struct Failure: Equatable {
        let title: String
        let message: String
        /// Show in Finder makes sense: the file is there but didn't open.
        var showFile = true
    }

    let game: Game
    let display = GameDisplay()
    private(set) var failure: Failure?
    private(set) var ending: Ending?
    private(set) var isPaused = false
    /// Paused because the window went to the back; it carries on when the window comes forward again.
    private(set) var autoPaused = false
    private(set) var isRunning = false
    private(set) var toast: String?
    /// DOS games set to joystick: arrow keys and Z/X play the joystick instead of going to DOS.
    private(set) var joystickMode = false

    @ObservationIgnored private var core: RetroCore?
    @ObservationIgnored private let coreLock = NSLock()
    @ObservationIgnored private let control = SessionControl()
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var autosave: Timer?
    @ObservationIgnored private var lastSaveRAM: Data?
    @ObservationIgnored private var framePending = false
    @ObservationIgnored private var resumeSavedState: Bool

    init(game: Game, resumeSavedState: Bool = false) {
        self.game = game
        self.resumeSavedState = resumeSavedState
        #if DEBUG
        // Test hook: -autoResume YES opens -autoPlay games at their saved place, as Resume does.
        if UserDefaults.standard.bool(forKey: "autoResume") { self.resumeSavedState = true }
        #endif
    }

    func start() {
        guard !isRunning else { return }
        if let other = GameSession.current, other !== self { other.stop(because: .replaced) }
        GameSession.current = self
        Self.stopOnQuit()
        failure = nil
        ending = nil
        control.running = true
        control.paused = false
        isPaused = false
        autoPaused = false
        do {
            try FileManager.default.createDirectory(at: game.savesFolder, withIntermediateDirectories: true)
            guard let frameworks = Bundle.main.privateFrameworksURL else { throw message("The emulator isn't installed in this build.") }
            let framework = frameworks.appending(path: "\(game.system.coreName).framework", directoryHint: .isDirectory)
            let binary = framework.appending(path: game.system.coreName)
            var systemFolder = game.savesFolder
            if game.system == .scummvm { systemFolder = try prepareScummVM(framework: framework) }
            let core = try RetroCore(libraryPath: binary.path, options: game.system.coreOptions,
                                     systemDirectory: systemFolder.path, saveDirectory: game.savesFolder.path)
            let loadMessages = LoadMessages()
            core.messageHandler = { [weak self] text in
                loadMessages.append(text)
                // ScummVM says this at every start (its launcher's look isn't bundled); it means nothing to a player.
                if text.localizedCaseInsensitiveContains("theme folder not found") { return }
                Task { @MainActor in self?.flash(text) }
            }
            joystickMode = game.system == .dos && GameLibrary.metadata(for: game).dosControls == .joystick
            // DOSBox Pure's "First 2 Button Joystick" controller: RETRO_DEVICE_SUBCLASS(RETRO_DEVICE_JOYPAD, 4).
            core.portDevice = joystickMode ? 0x501 : 1
            do {
                try core.loadGame(atPath: game.url.path, systemDirectory: systemFolder.path, saveDirectory: game.savesFolder.path)
            } catch {
                throw message("This file may be damaged or isn’t \(game.system.aGame). Try downloading it again.")
            }
            // ScummVM opens its own launcher when it doesn't recognize the folder. That launcher can browse the whole
            // Mac and isn't a game, so it's never shown.
            if game.system == .scummvm && loadMessages.contains("Game not found") {
                // ScummVM only sets itself up on its first frames; closing it before then crashes. A few frames with
                // nothing shown or heard let it start (into its launcher, unseen), so it can then close cleanly.
                for _ in 0..<3 { core.runFrame() }
                throw Failure(title: "ScummVM didn’t recognize the files in this folder",
                              message: "This folder may be missing some of the game’s files, or hold a game ScummVM can’t play. Check that it’s the folder with the game’s data files, or download the game again.")
            }
            if let saved = try? Data(contentsOf: game.batterySaveURL) {
                core.restoreSaveRAM(saved)
                lastSaveRAM = saved
            }
            core.frameHandler = { [weak self] image in self?.present(image) }
            self.core = core
            if resumeSavedState && game.system.hasSaveStates {
                resumeSavedState = false
                if let url = game.resumeStateURL, let savedState = try? Data(contentsOf: url), core.unserializeState(savedState) {
                    flash(url == game.autosaveURL ? "Picked up where you left off" : "Back to your saved place")
                } else { flash("Couldn’t go back to your place. The game started from the beginning.") }
            }
            startAudio(core)
            startThread(core)
            autosave = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.writeBatterySave() }
            }
            isRunning = true
            ControllerInput.shared.start()
            NotificationCenter.default.post(name: .gameDidStart, object: game.url.path)
            #if DEBUG
            debugSnapshots()
            #endif
        } catch let failure as Failure {
            self.failure = failure
            if GameSession.current === self { GameSession.current = nil }
        } catch {
            self.failure = Failure(title: "Couldn’t start \(game.title)", message: error.localizedDescription)
            if GameSession.current === self { GameSession.current = nil }
        }
    }

    /// Stops the game. Unless it ended by itself, where the player was is kept in the autosave (for systems with save
    /// states), so Resume and "Jump back in" pick it up again; NES, Atari and PC Engine games rarely save on their own.
    func stop() { stop(because: nil) }

    private func stop(because reason: Ending?) {
        guard isRunning else { return }
        isRunning = false
        autosave?.invalidate()
        control.running = false
        control.done.wait()
        engine?.stop()
        engine = nil
        if let reason { ending = reason }
        if ending != .finished { writeAutosave() }
        writeBatterySave()
        writeThumbnail()
        core?.frameHandler = nil
        core?.messageHandler = nil
        core = nil
        if GameSession.current === self { GameSession.current = nil }
    }

    /// Starts again from the beginning (after the game ended, or with new DOS controls).
    func restart() {
        stop(because: nil)
        // Restarting from scratch: the autosave just written would only bring back the old controls' game.
        resumeSavedState = false
        start()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        autoPaused = false
        control.paused = paused
        if paused { core?.releaseAllButtons() }
    }

    /// The window went to the back (paused) or came forward again (carries on, unless the player paused it).
    func windowFocusChanged(_ focused: Bool) {
        guard isRunning else { return }
        if !focused && !isPaused {
            setPaused(true)
            autoPaused = true
        } else if focused && autoPaused {
            setPaused(false)
        }
    }

    func reset() { withCore { $0.reset() } }

    func set(_ button: RetroButton, _ pressed: Bool) { core?.setButton(button, pressed: pressed) }

    // Keyboard and mouse (DOS and ScummVM). RetroCore queues these for the emulation thread.
    func key(_ keycode: UInt32, down: Bool, character: UInt32 = 0, modifiers: UInt16 = 0) {
        core?.setKey(keycode, pressed: down, character: character, modifiers: modifiers)
    }
    /// Lets go of every held key, button and mouse button (the window lost focus).
    func releaseInput() { core?.releaseAllButtons() }
    func moveMouse(dx: Double, dy: Double) { core?.moveMouseBy(x: dx, y: dy) }
    func pinMouseToCorner() { core?.pinMouseToCorner() }
    func mouseButton(_ button: RetroMouseButton, _ pressed: Bool) { core?.setMouseButton(button, pressed: pressed) }
    func scroll(_ notches: Int) { core?.scrollMouseWheel(notches) }
    /// x and y from -1 to 1 across the picture.
    func pointer(x: Double, y: Double, pressed: Bool) { core?.setPointerX(x, y: y, pressed: pressed) }

    /// ScummVM's game menu (save, load, options, quit) is on F5, which Mac laptops use for a media key.
    func openGameMenu() {
        if isPaused { setPaused(false) }
        key(286, down: true)   // RETROK_F5
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            key(286, down: false)
        }
    }

    func saveState() {
        guard let data = withCore({ $0.serializeState() }) ?? nil else {
            flash("This game can’t save your place here. Use the game’s own save, if it has one.")
            return
        }
        do {
            try data.write(to: game.stateURL, options: .atomic)
            writeThumbnail()
            flash("Saved your place")
        } catch {
            flash("Couldn’t save your place: \(error.localizedDescription)")
        }
    }

    func loadState() {
        guard let data = try? Data(contentsOf: game.stateURL) else {
            flash("You haven’t saved your place in this game yet. Use Save first.")
            return
        }
        let ok = withCore { $0.unserializeState(data) } ?? false
        flash(ok ? "Back to your saved place" : "Couldn’t go back to your saved place")
    }

    #if DEBUG
    @ObservationIgnored private var debugFrames = 0

    /// Test hook: launch with -gameSnapshot /path/prefix to save two frames (before and after pressing Start).
    private func debugSnapshots() {
        guard let prefix = UserDefaults.standard.string(forKey: "gameSnapshot") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            write(prefix + "-1.png")
            set(.start, true); try? await Task.sleep(for: .milliseconds(150)); set(.start, false)
            try? await Task.sleep(for: .seconds(1))
            set(.A, true); try? await Task.sleep(for: .milliseconds(150)); set(.A, false)
            try? await Task.sleep(for: .seconds(3))
            write(prefix + "-2.png")
            let audio = core?.queuedAudioFrames ?? -1
            try? "frames=\(debugFrames) fps=\(core?.framesPerSecond ?? 0) rate=\(core?.sampleRate ?? 0) audioQueued=\(audio) engine=\(engine?.isRunning ?? false)\n"
                .write(toFile: prefix + "-stats.txt", atomically: true, encoding: .utf8)
        }
        func write(_ path: String) {
            guard let image = display.lastImage,
                  let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
    }
    #endif

    // MARK: Internals

    /// The app is quitting: stop the game properly, so its autosave, in-game save and picture are written.
    private static var watchingQuit = false
    private static func stopOnQuit() {
        guard !watchingQuit else { return }
        watchingQuit = true
        #if os(macOS)
        let name = NSApplication.willTerminateNotification
        #else
        let name = UIApplication.willTerminateNotification
        #endif
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { GameSession.current?.stop() }
        }
    }

    private func withCore<T>(_ body: (RetroCore) -> T) -> T? {
        guard let core else { return nil }
        coreLock.lock()
        defer { coreLock.unlock() }
        return body(core)
    }

    /// ScummVM keeps its settings (scummvm.ini) in a "ScummVM" folder beside the saves, so they travel with the drive.
    /// Each launch points it at this game's Saves folder and at the engine data files that ship inside the core
    /// (sky.cpt, queen.tbl and the like), whose location changes when the app moves or updates.
    private func prepareScummVM(framework: URL) throws -> URL {
        let folder = game.savesFolder.appending(path: "ScummVM", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ini = folder.appending(path: "scummvm.ini")
        let extra = (Bundle(url: framework)?.resourceURL ?? framework).appending(path: "extra", directoryHint: .isDirectory)
        var ours = ["savepath=\(game.savesFolder.path)"]
        if FileManager.default.fileExists(atPath: extra.path) { ours.append("extrapath=\(extra.path)") }
        var lines: [String] = []
        var section = ""
        for line in ((try? String(contentsOf: ini, encoding: .utf8)) ?? "").components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { section = trimmed }
            if section == "[scummvm]" && (trimmed.hasPrefix("savepath=") || trimmed.hasPrefix("extrapath=")) { continue }
            lines.append(line)
        }
        if let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[scummvm]" }) {
            lines.insert(contentsOf: ours, at: header + 1)
        } else {
            lines = ["[scummvm]"] + ours + [""] + lines.filter { !$0.isEmpty }
        }
        try lines.joined(separator: "\n").write(to: ini, atomically: true, encoding: .utf8)
        return folder
    }

    private func message(_ text: String) -> NSError {
        NSError(domain: "Games", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }

    private func flash(_ text: String) {
        toast = text
        #if DEBUG
        // Test hook: -toastLog <path> keeps every message shown over the game, one per line.
        if let path = UserDefaults.standard.string(forKey: "toastLog"),
           let handle = FileHandle(forWritingAtPath: path) ?? (FileManager.default.createFile(atPath: path, contents: nil) ? FileHandle(forWritingAtPath: path) : nil) {
            handle.seekToEndOfFile()
            handle.write(Data((text + "\n").utf8))
            try? handle.close()
        }
        #endif
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(text.count > 40 ? 3 : 1.6))
            if toast == text { toast = nil }
        }
    }

    /// Called on the emulation thread; drops frames rather than queueing if the main thread is busy.
    nonisolated private func present(_ image: CGImage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            display.layer.contents = image
            CATransaction.commit()
            display.lastImage = image
            display.imageChanged(image)
            #if DEBUG
            debugFrames += 1
            #endif
        }
    }

    /// The core asked to close: the game quit by itself.
    private func coreFinished() {
        guard isRunning else { return }
        stop(because: .finished)
    }

    private func startThread(_ core: RetroCore) {
        let control = self.control, lock = coreLock
        let rate = core.sampleRate
        let thread = Thread { [weak self] in
            var next = CACurrentMediaTime()
            while control.running {
                if control.paused {
                    Thread.sleep(forTimeInterval: 0.02)
                    next = CACurrentMediaTime()
                    continue
                }
                lock.lock()
                core.runFrame()
                lock.unlock()
                if core.shutdownRequested {
                    Task { @MainActor in self?.coreFinished() }
                    break
                }
                next += 1.0 / max(1, core.framesPerSecond)   // DOS games change frame rate with video mode
                // Keep about 60 ms of audio queued so sound neither stutters nor lags.
                let queued = Double(core.queuedAudioFrames) / rate
                if queued > 0.12 { next += 0.002 } else if queued < 0.03 { next -= 0.001 }
                let wait = next - CACurrentMediaTime()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) } else if wait < -0.1 { next = CACurrentMediaTime() }
            }
            control.done.signal()
        }
        thread.name = "Emulator"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private func startAudio(_ core: RetroCore) {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        guard let format = AVAudioFormat(standardFormatWithSampleRate: core.sampleRate, channels: 2) else { return }
        let scratch = UnsafeMutablePointer<Int16>.allocate(capacity: 8192 * 2)
        let source = AVAudioSourceNode(format: format) { _, _, frameCount, bufferList -> OSStatus in
            let frames = min(Int(frameCount), 8192)
            core.readAudio(scratch, frames: frames)
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            for i in 0..<frames {
                left[i] = Float(scratch[i * 2]) / 32768
                right[i] = Float(scratch[i * 2 + 1]) / 32768
            }
            return noErr
        }
        let engine = AVAudioEngine()
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            flash("No sound: \(error.localizedDescription)")
        }
    }

    /// In-game (battery) saves: written when they change and when the game closes.
    private func writeBatterySave() {
        guard let data = withCore({ $0.saveRAM() }) ?? nil, data != lastSaveRAM else { return }
        if (try? data.write(to: game.batterySaveURL, options: .atomic)) != nil { lastSaveRAM = data }
    }

    /// Where the player left off, for Resume. Only once the game has drawn something (a game that never really
    /// ran has nothing worth keeping), and only for systems with save states.
    private func writeAutosave() {
        guard game.system.hasSaveStates, display.lastImage != nil,
              let data = withCore({ $0.serializeState() }) ?? nil else { return }
        try? data.write(to: game.autosaveURL, options: .atomic)
    }

    /// The last frame becomes the game's tile art on the shelf.
    private func writeThumbnail() {
        guard let image = display.lastImage,
              let dest = CGImageDestinationCreateWithURL(game.thumbnailURL as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}

extension GameSession.Failure: LocalizedError {
    var errorDescription: String? { message }
}

// MARK: - Game controllers

/// Routes Bluetooth controllers (Xbox, PlayStation, Switch Pro, MFi) to the running game.
/// Nintendo layout: the right face button is A, the bottom one is B.
@MainActor
final class ControllerInput {
    static let shared = ControllerInput()
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        GCController.controllers().forEach(attach)
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { ControllerInput.shared.attach(controller) }
        }
    }

    /// One controller's d-pad and left stick, tracked apart and combined, so a resting (drifting) stick can't let go
    /// of a direction held on the d-pad, and the other way round.
    private final class Directions {
        var dpad: Set<RetroButton> = []
        var stick: Set<RetroButton> = []
        var sent: Set<RetroButton> = []
    }

    /// Eight-way directions from an x/y position, ignoring anything within `deadZone` of the centre.
    nonisolated static func directions(x: Float, y: Float, deadZone: Float) -> Set<RetroButton> {
        guard hypot(x, y) > deadZone else { return [] }
        let angle = atan2(y, x) * 180 / .pi   // 0 = right, 90 = up
        var result: Set<RetroButton> = []
        if angle > 22.5 && angle < 157.5 { result.insert(.up) }
        if angle < -22.5 && angle > -157.5 { result.insert(.down) }
        if abs(angle) > 112.5 { result.insert(.left) }
        if abs(angle) < 67.5 { result.insert(.right) }
        return result
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        func bind(_ input: GCControllerButtonInput?, _ button: RetroButton) {
            input?.pressedChangedHandler = { _, _, pressed in
                MainActor.assumeIsolated { GameSession.current?.set(button, pressed) }
            }
        }
        bind(pad.buttonA, .B)
        bind(pad.buttonB, .A)
        bind(pad.buttonX, .Y)
        bind(pad.buttonY, .X)
        bind(pad.leftShoulder, .L)
        bind(pad.rightShoulder, .R)
        bind(pad.buttonMenu, .start)
        bind(pad.buttonOptions, .select)
        let state = Directions()
        func update() {
            guard let session = GameSession.current else { return }
            let held = state.dpad.union(state.stick)
            for button in [RetroButton.up, .down, .left, .right] where held.contains(button) != state.sent.contains(button) {
                session.set(button, held.contains(button))
            }
            state.sent = held
        }
        pad.dpad.valueChangedHandler = { _, x, y in
            MainActor.assumeIsolated {
                state.dpad = Self.directions(x: x, y: y, deadZone: 0.5)
                update()
            }
        }
        pad.leftThumbstick.valueChangedHandler = { _, x, y in
            MainActor.assumeIsolated {
                state.stick = Self.directions(x: x, y: y, deadZone: 0.3)
                update()
            }
        }
    }
}
