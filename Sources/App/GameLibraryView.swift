import SwiftUI
import UniformTypeIdentifiers

private enum GameShelf: Hashable {
    case all, favorites, saved, system(GameSystem), game(Game), genre(String), publisher(String)
    var title: String {
        switch self {
        case .genre(let name): name
        case .publisher(let name): "From \(name)"
        case .all: "All games"
        case .favorites: "Favorites"
        case .saved: "Saved progress"
        case .system(let system): system.name
        case .game(let game): game.title
        }
    }
}

struct GamesView: View {
    @Environment(Library.self) private var library
    @Environment(GameLibrary.self) private var games
    @State private var importing = false
    @State private var importingFolder = false
    @State private var importError: String?
    /// What Add Games skipped or renamed, and why.
    @State private var importReport: String?
    @State private var query = ""
    @State private var path: [GameShelf] = []
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var playing: GameRef?
    #endif

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    KitHeading(eyebrow: "THE GAMES SHELF", title: "A little time to play.",
                               subtitle: "Your favorites, ready for a quiet moment. Everything plays on this device.")
                    FlowLayout(spacing: 8) {
                        Pill(text: "Works offline", symbol: "checkmark.shield", tint: .accentColor)
                        Pill(text: "\(games.games.count) games", symbol: "gamecontroller")
                        #if os(macOS)
                        Pill(text: "Keyboard or controller", symbol: "keyboard")
                        #else
                        Pill(text: "Touch or controller", symbol: "hand.tap")
                        #endif
                    }
                    if games.games.isEmpty && query.isEmpty { emptyCard; findGames }
                    if !query.isEmpty {
                        GameShelfGrid(games: matchingGames, favorites: games.favorites)
                        if matchingGames.isEmpty { ContentUnavailableView.search(text: query) }
                    } else {
                        if !recentGames.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack { Text("Jump back in").font(.title3.bold()); Spacer() }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                                    ForEach(recentGames) { game in
                                        Button { play(game, game.canResume) } label: {
                                            RecentGameCard(game: game, date: games.lastPlayed[game.id])
                                        }.buttonStyle(.plain)
                                        .accessibilityLabel("\(game.canResume ? "Resume" : "Play") \(game.title), \(game.system.name)")
                                    }
                                }
                            }
                        }
                        HStack(spacing: 12) {
                            collection("Favorites", count: games.favorites.count, symbol: "heart.fill", route: .favorites)
                            collection("Saved progress", count: games.games.filter(\.canResume).count, symbol: "bookmark.fill", route: .saved)
                        }
                        // Only systems that have games: eight "No games yet" cards would bury the shelf.
                        let systems = GameSystem.allCases.filter { system in games.games.contains { $0.system == system } }
                        if !systems.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Browse by system").font(.title3.bold())
                                    Spacer()
                                    NavigationLink("All games", value: GameShelf.all).font(.callout)
                                }
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 12)], spacing: 12) {
                                    ForEach(systems) { system in
                                        NavigationLink(value: GameShelf.system(system)) {
                                            GameSystemCard(system: system, count: games.games.filter { $0.system == system }.count)
                                        }.buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                        // From approved Organize with AI details (Kit Catalog.json in the library).
                        groupSection("Browse by genre", field: .genre) { GameShelf.genre($0) }
                        groupSection("By publisher", field: .creator) { GameShelf.publisher($0) }
                        if !games.games.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("On your shelf").font(.title3.bold())
                                    Spacer()
                                    NavigationLink("View all", value: GameShelf.all).font(.callout)
                                }
                                GameShelfGrid(games: Array(games.games.prefix(8)), favorites: games.favorites)
                            }
                        }
                    }
                    help
                    if !games.games.isEmpty { findGames }
                }
                .padding(24)
                .frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(Design.canvas)
            .navigationTitle("Play")
            .searchable(text: $query, prompt: "Find a game or system")
            .navigationDestination(for: GameShelf.self) { shelf in
                if case .game(let game) = shelf {
                    GameDetailView(game: game, play: play)
                } else {
                    // A ScummVM game is a folder, so that shelf's Add button picks a folder.
                    GameCollectionView(shelf: shelf, addGames: { if shelf == .system(.scummvm) { importingFolder = true } else { importing = true } })
                }
            }
            .toolbar {
                #if os(macOS)
                ToolbarItem { FindMyMediaButton(kind: .game) }
                ToolbarItem { OrganizeButton(scope: .game) }
                #endif
                ToolbarItem {
                    Menu("Add Games", systemImage: "plus") {
                        Button("Add Game Files…", systemImage: "doc.badge.plus") { importing = true }
                        Button("Add ScummVM Game Folder…", systemImage: "folder.badge.plus") { importingFolder = true }
                    } primaryAction: { importing = true }
                    .help("Add game files (.gb, .gbc, .gba, .nes, .pce, DOS .zip or .dosz), or a ScummVM game’s folder")
                }
            }
        }
        .task(id: library.folders.map(\.path).joined(separator: "|")) { await games.reload(library: library); KitCatalog.shared.reload(library) }
        #if DEBUG
        // Test hook: -importGames "/a.nes|/b.gb" adds each file in its own task, close together, as Add Game Files… does.
        .task {
            #if os(macOS)
            WindowShots.startIfRequested()
            #endif
            // Test hook: -openGame <path> shows that game's page.
            if let given = UserDefaults.standard.string(forKey: "openGame") {
                let open = URL(fileURLWithPath: given).standardizedFileURL.resolvingSymlinksInPath().path
                for _ in 0..<20 where !games.games.contains(where: { $0.url.path == open }) { try? await Task.sleep(for: .milliseconds(250)) }
                try? await Task.sleep(for: .seconds(1))
                if let game = games.games.first(where: { $0.url.path == open }) { path = [.game(game)] }
            }
            guard KitLocation.testHome != nil, let paths = UserDefaults.standard.string(forKey: "importGames") else { return }
            try? await Task.sleep(for: .seconds(3))
            // With -importTogether YES they're added in one go instead, with one report, as choosing several files does.
            if UserDefaults.standard.bool(forKey: "importTogether") {
                importReport = await games.importGames(paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) }, library: library).message
                return
            }
            for path in paths.split(separator: "|") {
                Task { await games.importGames([URL(fileURLWithPath: String(path))], library: library) }
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        #endif
        .fileImporter(isPresented: $importing,
                      allowedContentTypes: GameSystem.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.data],
                      allowsMultipleSelection: true) { result in
            Task {
                do { importReport = await games.importGames(try result.get(), library: library).message }
                catch { importError = error.localizedDescription }
            }
        }
        // A ScummVM game is a folder of data files; it's checked, then copied whole into Games/ScummVM.
        .background(Color.clear.fileImporter(isPresented: $importingFolder, allowedContentTypes: [.folder],
                                             allowsMultipleSelection: true) { result in
            Task {
                do { importReport = await games.importGames(try result.get(), library: library).message }
                catch { importError = error.localizedDescription }
            }
        })
        .overlay(alignment: .bottom) {
            if let adding = games.adding {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(adding).font(.callout.weight(.medium)).lineLimit(1)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: games.adding)
        .alert("Adding games", isPresented: Binding(get: { importReport != nil }, set: { if !$0 { importReport = nil } })) {
            Button("OK") { importReport = nil }
        } message: { Text(importReport ?? "") }
        .alert("Games need your attention", isPresented: Binding(get: { importError != nil || games.issue != nil }, set: {
            if !$0 { importError = nil; games.issue = nil }
        })) { Button("OK") { importError = nil; games.issue = nil } }
        message: { Text(importError ?? games.issue ?? "") }
        #if os(iOS)
        .fullScreenCover(item: $playing, onDismiss: { Task { await games.reload(library: library) } }) { ref in
            if let game = ref.game { PlayerView(game: game, resumeSavedState: ref.resume) }
        }
        #else
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            Task { await games.reload(library: library) }
        }
        #endif
    }

    /// Genre or publisher groups with their game counts, biggest first. Empty until games are organized.
    @ViewBuilder private func groupSection(_ title: String, field: CatalogDetails.Key, route: @escaping (String) -> GameShelf) -> some View {
        let names = Dictionary(grouping: games.games.compactMap { KitCatalog.shared.value(KitCatalog.gameKey($0), field) }, by: { $0 })
            .map { ($0.key, $0.value.count) }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
        if !names.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.title3.bold())
                FlowLayout(spacing: 8) {
                    ForEach(names, id: \.0) { name, count in
                        NavigationLink(value: route(name)) { Pill(text: "\(name) · \(count)", symbol: field == .genre ? "square.grid.2x2" : "building.2") }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var matchingGames: [Game] {
        games.games.filter { ($0.title + " " + $0.system.name).localizedCaseInsensitiveContains(query) }
    }

    private var recentGames: [Game] {
        Array(games.games.filter { games.lastPlayed[$0.id] != nil }
            .sorted { (games.lastPlayed[$0.id] ?? .distantPast) > (games.lastPlayed[$1.id] ?? .distantPast) }.prefix(3))
    }

    /// The game counts as played once it has really started (GameSession posts .gameDidStart).
    private func play(_ game: Game, _ resume: Bool) {
        let ref = GameRef(path: game.url.path, resume: resume)
        #if os(macOS)
        openWindow(value: ref)
        #else
        playing = ref
        #endif
    }

    private func collection(_ title: String, count: Int, symbol: String, route: GameShelf) -> some View {
        NavigationLink(value: route) {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline).foregroundStyle(.primary)
                    Text("\(count) \(count == 1 ? "game" : "games")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            }.card(padding: 16)
        }.buttonStyle(.plain)
    }

    private var findGames: some View {
        FindMoreCard(title: "Where to find games",
                     intro: "People still make new games for these systems and share many of them free, and some classic DOS and adventure games are now free too. Download a game file (.gb, .gbc, .gba, .nes, .pce, or a DOS game’s .zip), or a ScummVM game’s folder, then add it with Add Games. A download zipped around one game file is unzipped for you.",
                     links: FindMore.games,
                     footnote: "Use homemade games like these, or games you own. Copies of store-bought games shared online are illegal, so Offline Kit doesn’t link to them. These links open in your browser and need internet.")
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make room for a little fun.").font(.system(.title2, design: .rounded, weight: .semibold))
            Text("Offline Kit plays Game Boy, Game Boy Color, Game Boy Advance, NES and PC Engine game files (.gb, .gbc, .gba, .nes, .pce), DOS games (.zip or .dosz) and ScummVM adventure games (a game’s folder). Use game files you copied from cartridges you own, or free games from the links below. Games and saves stay with your library.")
                .foregroundStyle(.secondary)
            Button("Add your first game", systemImage: "plus.circle.fill") { importing = true }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }.card(padding: 22)
    }

    private var help: some View {
        DisclosureGroup("Adding games & using controls") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add .gb, .gbc, .gba, .nes or .pce files with Add Games. Your place is saved beside each game, so it can travel with your drive.")
                Text("DOS games: add the game’s .zip (it needs a program inside) or a .dosz file. Zips placed by hand go in the Games/DOS folder. If a game has several programs, DOSBox Pure asks which to start.")
                Text("ScummVM adventure games: choose Add ScummVM Game Folder and pick the folder holding the game’s files, or put the folder inside Games/ScummVM. ScummVM works out which game it is.")
                Text("Play game files copied from cartridges you own, or games their makers share freely. See Where to find games for free homemade ones.")
                #if os(macOS)
                Text("Arrow keys move. X and Z are A and B. Return starts; Space selects. Controllers work too.")
                Text("DOS and ScummVM games take the keyboard and mouse directly. If a DOS game says it needs a joystick, choose Joystick on its page.")
                Text("In ScummVM, save and load from the game’s menu: the Game Menu button, or fn-F5 on a Mac laptop.")
                Button("Show Games Folder", systemImage: "folder") {
                    let folder = GameLibrary.importFolder
                    do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); NSWorkspace.shared.open(folder) }
                    catch { importError = error.localizedDescription }
                }
                #else
                Text("Use the on-screen controls or connect a game controller. Save your place from the player’s menu.")
                Text("In DOS and ScummVM games, the picture works like a touchpad: tap to click. In ScummVM, touch and hold to right-click.")
                #endif
            }.font(.callout).foregroundStyle(.secondary).padding(.top, 12)
        }.card(padding: 18)
    }
}

private struct GameSystemCard: View {
    let system: GameSystem
    let count: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 18) {
            CartridgeBadge(system: system).frame(width: 60, height: 68)
            VStack(alignment: .leading, spacing: 6) {
                Text(system.name).font(.headline).foregroundStyle(.primary)
                Text(count == 0 ? "No games yet" : "\(count) \(count == 1 ? "game" : "games") ready to play")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .card(padding: 20)
        .overlay(RoundedRectangle(cornerRadius: Design.corner).strokeBorder(hovering ? system.tint.opacity(0.5) : .clear))
        .onHover { hovering = $0 }
    }
}

private struct CartridgeBadge: View {
    let system: GameSystem
    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 3) {
                ForEach(0..<5, id: \.self) { _ in Capsule().fill(system.tint.opacity(0.28)).frame(width: 4, height: 8) }
            }
            Image(systemName: symbol).font(.title3).foregroundStyle(system.tint)
            Text(shortName).font(.caption2.weight(.heavy)).foregroundStyle(system.tint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(system.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }
    private var symbol: String {
        switch system {
        case .nes, .atari2600, .pcEngine: "tv"
        case .dos: "desktopcomputer"
        case .scummvm: "cursorarrow.click.2"
        case .gameBoy, .gameBoyColor, .gameBoyAdvance: "gamecontroller.fill"
        }
    }
    private var shortName: String {
        switch system {
        case .gameBoy: "GB"; case .gameBoyColor: "COLOR"; case .gameBoyAdvance: "ADVANCE"; case .nes: "NES"
        case .atari2600: "2600"; case .pcEngine: "PCE"; case .dos: "DOS"; case .scummvm: "SCUMM"
        }
    }
}

private struct GameCollectionView: View {
    @Environment(GameLibrary.self) private var library
    let shelf: GameShelf
    let addGames: () -> Void
    @State private var query = ""
    @State private var sort: GameSort = .title
    private enum GameSort: String, CaseIterable { case title = "Title", recent = "Recently played" }

    private var collection: [Game] {
        let games = library.games.filter { game in
            switch shelf {
            case .all: true
            case .favorites: library.favorites.contains(game.id)
            case .saved: game.canResume
            case .system(let system): game.system == system
            case .genre(let name): KitCatalog.shared.value(KitCatalog.gameKey(game), .genre) == name
            case .publisher(let name): KitCatalog.shared.value(KitCatalog.gameKey(game), .creator) == name
            case .game: false
            }
        }.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        return games.sorted {
            if sort == .recent {
                let a = library.lastPlayed[$0.id] ?? .distantPast, b = library.lastPlayed[$1.id] ?? .distantPast
                if a != b { return a > b }
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                KitHeading(eyebrow: "GAMES / YOUR COLLECTION", title: shelf.title,
                           subtitle: "Choose a game to see its saved place and play options.")
                HStack {
                    Text("\(collection.count) \(collection.count == 1 ? "game" : "games")").foregroundStyle(.secondary)
                    Spacer()
                    Picker("Sort", selection: $sort) { ForEach(GameSort.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.menu).fixedSize()
                }
                if collection.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty ? "Nothing on this shelf yet" : "No matching games", systemImage: "gamecontroller")
                    } description: {
                        Text(emptyDescription)
                    } actions: {
                        if shelf != .favorites && shelf != .saved { Button("Add Games", action: addGames) }
                    }
                } else { GameShelfGrid(games: collection, favorites: library.favorites) }
            }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Design.canvas)
        .navigationTitle(shelf.title)
        .searchable(text: $query, prompt: "Search \(shelf.title.lowercased())")
    }

    private var emptyDescription: String {
        if !query.isEmpty { return "Try a shorter name or a different spelling." }
        switch shelf {
        case .favorites: return "Use the heart on a game’s detail page to keep it here."
        case .saved: return "Save your place from the player, or just close a game: games you can resume appear here."
        default: return "Add game files for this system from your collection."
        }
    }
}

private struct GameShelfGrid: View {
    @Environment(GameLibrary.self) private var library
    let games: [Game]
    let favorites: Set<String>
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 16)], alignment: .leading, spacing: 18) {
            ForEach(games) { game in
                NavigationLink(value: GameShelf.game(game)) { GameTile(game: game, favorite: favorites.contains(game.id)) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(favorites.contains(game.id) ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart") {
                            library.toggleFavorite(game)
                        }
                        ShowInFinderButton(url: game.url)
                        SendToPhoneButton(game: game)
                    }
            }
        }
    }
}

private struct GameArtwork: View {
    let game: Game
    var body: some View {
        ZStack {
            game.system.tint.opacity(0.12)
            if let thumbnail {
                thumbnail.resizable().interpolation(.none).aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 9) {
                    CartridgeBadge(system: game.system).frame(width: 70, height: 80)
                    Text(game.system.name).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }.padding(18)
            }
        }
        .aspectRatio(1.4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
    private var thumbnail: Image? {
        #if os(macOS)
        NSImage(contentsOf: game.thumbnailURL).map { Image(nsImage: $0) }
        #else
        UIImage(contentsOfFile: game.thumbnailURL.path).map { Image(uiImage: $0) }
        #endif
    }
}

private struct GameTile: View {
    let game: Game
    let favorite: Bool
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GameArtwork(game: game)
                .overlay(alignment: .topTrailing) {
                    if favorite {
                        Image(systemName: "heart.fill").font(.caption).foregroundStyle(Color.accentColor)
                            .padding(7).background(.regularMaterial, in: Circle()).padding(8)
                    }
                }
            Text(game.title).font(.headline).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
            Text(game.canResume ? "\(game.system.name) · Saved place" : game.system.name)
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Design.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Design.border, lineWidth: 0.5))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
    }
}

private struct RecentGameCard: View {
    let game: Game
    let date: Date?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GameArtwork(game: game)
            Text(game.title).font(.headline).foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.leading)
            HStack {
                Label(game.canResume ? "Resume" : "Play again", systemImage: game.canResume ? "play.fill" : "arrow.clockwise")
                    .font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                Spacer()
                if let date { Text(date, style: .relative).font(.caption).foregroundStyle(.secondary) }
            }
        }.card(padding: 14)
    }
}

private struct GameDetailView: View {
    @Environment(GameLibrary.self) private var library
    @Environment(Library.self) private var kit
    @Environment(\.dismiss) private var dismiss
    /// The game as it was when opened; `game` reads the library's copy so a new save or picture shows up.
    private let shown: Game
    let play: (Game, Bool) -> Void
    @State private var dosControls: GameLibrary.DOSControls = .keyboard
    @State private var confirmRemove = false
    init(game: Game, play: @escaping (Game, Bool) -> Void) { shown = game; self.play = play }
    private var game: Game { library.games.first { $0.id == shown.id } ?? shown }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                GameArtwork(game: game).frame(maxWidth: 520)
                VStack(alignment: .leading, spacing: 10) {
                    Text(game.system.name.uppercased()).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(Color.accentColor)
                    Text(game.title).font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(Design.ink)
                }
                FlowLayout(spacing: 8) {
                    Pill(text: "Works offline", symbol: "checkmark.shield", tint: .accentColor)
                    if game.canResume { Pill(text: "Saved place available", symbol: "bookmark") }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { playActions }
                    VStack(alignment: .leading, spacing: 12) { playActions }
                }
                if game.canResume {
                    Text("Resume carries on from where you left off. Play starts from the beginning and keeps your saves.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Label(game.system.controlsHint, systemImage: "keyboard")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if game.system == .dos {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Controls", selection: Binding(get: { dosControls }, set: { changeControls($0) })) {
                            Text("Keyboard & mouse").tag(GameLibrary.DOSControls.keyboard)
                            Text("Joystick or game pad").tag(GameLibrary.DOSControls.joystick)
                        }
                        .pickerStyle(.menu).fixedSize()
                        Text("Choose Joystick if the game says a joystick is required. Then the arrow keys move, Z fires and X is the second button.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                LabeledContent("System", value: game.system.name)
                if let date = library.lastPlayed[game.id] { LabeledContent("Last played", value: date.formatted(date: .abbreviated, time: .shortened)) }
                Label("Saves stay beside this game and travel with its drive.", systemImage: "externaldrive")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Design.canvas)
        .navigationTitle(game.title)
        .onAppear { dosControls = library.dosControls(for: game) }
        .toolbar {
            #if os(macOS)
            SendToPhoneButton(game: game)
            #endif
            Button(library.favorites.contains(game.id) ? "Remove from Favorites" : "Add to Favorites",
                   systemImage: library.favorites.contains(game.id) ? "heart.fill" : "heart") { library.toggleFavorite(game) }
            Button("Remove Game", systemImage: "trash") { confirmRemove = true }
                .help("Move this game to the Trash")
        }
        .confirmationDialog("Move \(game.title) to the Trash?", isPresented: $confirmRemove) {
            Button("Move to Trash", role: .destructive) {
                if GameSession.current?.game.id == game.id { GameSession.current?.stop() }
                let removed = game
                Task {
                    await library.remove(removed, library: kit)
                    if !library.games.contains(where: { $0.id == removed.id }) { dismiss() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its saves stay in the Saves folder, so adding the game again brings them back.")
        }
    }

    /// Saved beside the game. A game that's playing right now restarts with the new controls.
    private func changeControls(_ controls: GameLibrary.DOSControls) {
        guard controls != dosControls else { return }
        dosControls = controls
        library.setDOSControls(controls, for: game)
        if let session = GameSession.current, session.game.id == game.id { session.restart() }
    }

    @ViewBuilder private var playActions: some View {
        if game.canResume {
            Button("Resume", systemImage: "play.fill") { play(game, true) }.buttonStyle(.borderedProminent).controlSize(.large)
            Button("Play from the Start", systemImage: "gamecontroller") { play(game, false) }.buttonStyle(.bordered).controlSize(.large)
        } else {
            Button("Play", systemImage: "play.fill") { play(game, false) }.buttonStyle(.borderedProminent).controlSize(.large)
        }
    }
}
