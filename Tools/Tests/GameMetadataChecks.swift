import Foundation

enum KitLocation { static let portableLibrary: URL? = nil }
@MainActor final class Library {
    let folders: [URL]
    init(_ folders: [URL]) { self.folders = folders }
}

@main struct GameMetadataChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "OfflineKit-model-checks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appending(path: "Games")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: "Test_Game.gb")
        try Data([0]).write(to: url) // Metadata and scanning fixture only; never loaded into an emulator.
        let game = Game(url: url, system: .gameBoy)
        precondition(game.title == "Test Game")
        precondition(game.savesFolder == folder.resolvingSymlinksInPath().appending(path: "Saves", directoryHint: .isDirectory))
        let oldRef = try JSONDecoder().decode(GameRef.self, from: Data("{\"path\":\"/test/game.gb\"}".utf8))
        precondition(!oldRef.resume, "Old restored game windows must still decode")
        let newRef = GameRef(path: url.path, resume: true)
        let roundTrip = try JSONDecoder().decode(GameRef.self, from: JSONEncoder().encode(newRef))
        precondition(roundTrip.resume)
        let library = Library([root]), games = GameLibrary()
        await games.reload(library: library)
        precondition(games.games.count == 1)
        games.toggleFavorite(game)
        games.recordPlayed(game)
        precondition(games.favorites.contains(game.id) && games.lastPlayed[game.id] != nil)
        let fresh = GameLibrary()
        await fresh.reload(library: library)
        if !fresh.favorites.contains(game.id) || fresh.lastPlayed[game.id] == nil {
            let metadata = (try? String(contentsOf: game.metadataURL, encoding: .utf8)) ?? "missing"
            let diagnostic = "Metadata: \(metadata)\nExpected: \(game.id)\nFound: \(fresh.games.map(\.id))\nFavorites: \(fresh.favorites)\nRecent: \(fresh.lastPlayed)\n"
            FileHandle.standardError.write(Data(diagnostic.utf8))
            exit(1)
        }
        precondition(fresh.favorites.contains(game.id) && fresh.lastPlayed[game.id] != nil, "Preferences travel beside the game")
        fresh.toggleFavorite(game)
        await games.reload(library: library)
        precondition(!games.favorites.contains(game.id))
        precondition(games.lastPlayed[game.id] != nil, "Removing a favorite must preserve play history")
        try Data([1]).write(to: game.stateURL)
        precondition(game.hasSaveState)
        precondition(GameLibrary.scan([folder]).count == 1, "Save files must not appear as games")
        precondition(games.issue == nil && fresh.issue == nil)
        print("PASS: system scanning, portable metadata, favorite persistence, play history, saved-place detection and backward-compatible game references.")
    }
}
