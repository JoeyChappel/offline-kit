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
        case .saved: "Continue playing"
        case .system(let system): system.name
        case .game(let game): game.title
        }
    }
}

struct GamesView: View {
    @Environment(Library.self) private var library
    @Environment(GameLibrary.self) private var games
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importing = false
    @State private var importingFolder = false
    @State private var importError: String?
    /// What Add Games skipped or renamed, and why.
    @State private var importReport: String?
    @State private var query = ""
    @State private var path: [GameShelf] = []
    /// False until the first scan of the Games folders has finished, so the shelves show placeholders, not an empty page.
    @State private var scanned = false
    @State private var showingControls = false
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #else
    @State private var playing: GameRef?
    #endif

    private var isLoading: Bool { !scanned && games.games.isEmpty }

    var body: some View {
        NavigationStack(path: $path) {
            HitPausingScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    KitHeading(eyebrow: "THE GAMES SHELF", title: "A little time to play.",
                               subtitle: "Your favorites, ready for a quiet moment. Everything plays on this device.")
                    FlowLayout(spacing: 8) {
                        Pill(text: "Works offline", symbol: "checkmark.shield", tint: .accentColor)
                        if !games.games.isEmpty { Pill(text: "\(games.games.count) \(games.games.count == 1 ? "game" : "games")", symbol: "gamecontroller") }
                        #if os(macOS)
                        Pill(text: "Keyboard or controller", symbol: "keyboard")
                        #else
                        Pill(text: "Touch or controller", symbol: "hand.tap")
                        #endif
                    }
                    if isLoading {
                        loadingShelves
                    } else if games.games.isEmpty && query.isEmpty {
                        firstGamePanel
                    } else if !query.isEmpty {
                        GameShelfGrid(games: matchingGames, favorites: games.favorites)
                        if matchingGames.isEmpty { ContentUnavailableView.search(text: query) }
                    } else {
                        shelves
                    }
                }
                .padding(24)
                .frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
                .animation(Motion.gentle(reduceMotion), value: games.games.count)
                .animation(Motion.gentle(reduceMotion), value: games.favorites.count)
                .animation(Motion.gentle(reduceMotion), value: games.lastPlayed.count)
                .animation(Motion.gentle(reduceMotion), value: scanned)
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
        .task(id: library.folders.map(\.path).joined(separator: "|")) { await games.reload(library: library); KitCatalog.shared.reload(library); scanned = true }
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
        // LibraryWatcher already rescans on changes; this only catches what it can't see (a drive that came back
        // while the app was in the back), and skips the scan when no Games folder changed.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            games.refreshSaves()
            Task { await games.reloadIfChanged(library: library) }
        }
        #endif
    }

    // MARK: Shelves

    private var shelves: some View {
        let rows = games.shelves
        let continuing = rows.continuing, favorites = rows.favorites, recent = rows.recent
        var order = 0
        func next() -> Double { defer { order += 1 }; return Double(min(order, 6)) * 0.06 }
        return VStack(alignment: .leading, spacing: 30) {
            if !continuing.isEmpty {
                shelf("Continue playing", symbol: "play.circle.fill", count: continuing.count, route: .saved) {
                    ForEach(continuing.prefix(10), id: \.0.id) { game, date in
                        Button { play(game, true) } label: { ContinueCard(game: game, date: date) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Resume \(game.title), \(game.system.name), saved \(date.formatted(.relative(presentation: .named)))")
                    }
                }.appearFade(delay: next())
            }
            addGamesBar.appearFade(delay: next())
            if !favorites.isEmpty {
                shelf("Favorites", symbol: "heart.fill", count: favorites.count, route: .favorites) { tiles(favorites) }
                    .appearFade(delay: next())
            }
            if !recent.isEmpty {
                shelf("Recently played", symbol: "clock", count: nil, route: nil) { tiles(Array(recent.prefix(10))) }
                    .appearFade(delay: next())
            }
            ForEach(rows.systems, id: \.system) { system, list in
                shelf(system.name, symbol: system.artSymbol, count: list.count, route: .system(system), tint: system.tint) { tiles(list) }
                    .appearFade(delay: next())
            }
            // From approved Organize with AI details (Kit Catalog.json in the library).
            groupSection("Browse by genre", field: .genre) { GameShelf.genre($0) }
            groupSection("By publisher", field: .creator) { GameShelf.publisher($0) }
            findGames
            HStack { Spacer(); controlsButton; Spacer() }
        }
    }

    private func tiles(_ list: [Game]) -> some View {
        ForEach(list.prefix(14)) { game in
            GameTileLink(game: game, favorite: games.favorites.contains(game.id)).frame(width: 172)
        }
    }

    /// A titled row that scrolls sideways, with a link to the full list.
    private func shelf<Content: View>(_ title: String, symbol: String, count: Int?, route: GameShelf?, tint: Color = .accentColor,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbol).font(.callout).foregroundStyle(tint).accessibilityHidden(true)
                Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                if let count { Text("\(count)").font(.callout).foregroundStyle(.secondary) }
                Spacer()
                if let route { NavigationLink("See all", value: route).font(.callout) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }.padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }
    }

    private var loadingShelves: some View {
        VStack(alignment: .leading, spacing: 30) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    SkeletonBlock(width: 160, height: 18, corner: 5)
                    SkeletonShelf(count: 4, cardWidth: 172, cardHeight: 124, corner: 14)
                }
            }
        }
    }

    // MARK: Adding games

    private func importDropped(_ urls: [URL]) {
        Task { importReport = await games.importGames(urls, library: library).message }
    }

    /// The first thing a new library shows: where games go, what plays, where to find some, and the controls.
    private var firstGamePanel: some View {
        VStack(alignment: .leading, spacing: 22) {
            GameDropZone(onDrop: importDropped) {
                VStack(spacing: 14) {
                    Image(systemName: "gamecontroller.fill").font(.system(size: 38)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                    Text("Add your first game").font(.system(.title2, design: .rounded, weight: .semibold))
                    Text("Drop game files here, or choose them yourself. They are copied into your library and play offline.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    FlowLayout(spacing: 10) {
                        Button("Choose Files…", systemImage: "doc.badge.plus") { importing = true }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Button("Choose ScummVM Folder…", systemImage: "folder.badge.plus") { importingFolder = true }
                            .buttonStyle(.bordered).controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 34).padding(.horizontal, 24)
            }
            .appearFade()

            VStack(alignment: .leading, spacing: 12) {
                Text("What plays here").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 10)], alignment: .leading, spacing: 10) {
                    ForEach(GameSystem.playable) { system in
                        HStack(spacing: 12) {
                            Image(systemName: system.artSymbol).font(.body.weight(.semibold)).foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                                .background(LinearGradient(colors: [system.tint, system.tint.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(system.name).font(.callout.weight(.semibold))
                                Text(system.addHint).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .card(padding: 18)
            .appearFade(delay: 0.06)

            findGames.appearFade(delay: 0.12)

            VStack(alignment: .leading, spacing: 12) {
                Label("Controls", systemImage: "keyboard").font(.headline)
                ControlsHelp(showFolder: showGamesFolder)
            }
            .card(padding: 18)
            .appearFade(delay: 0.18)
        }
    }

    /// With games on the shelf: a small drop target and button, with controls and the full list close by.
    private var addGamesBar: some View {
        GameDropZone(onDrop: importDropped, corner: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { addBarText; Spacer(minLength: 8); addBarButtons }
                VStack(alignment: .leading, spacing: 12) { addBarText; addBarButtons }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
    }

    private var addBarText: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down").font(.title3).foregroundStyle(Color.accentColor).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Add games").font(.headline)
                Text("Drop game files here, or choose them.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var addBarButtons: some View {
        HStack(spacing: 8) {
            Menu("Choose Files…", systemImage: "plus") {
                Button("Add Game Files…", systemImage: "doc.badge.plus") { importing = true }
                Button("Add ScummVM Game Folder…", systemImage: "folder.badge.plus") { importingFolder = true }
            } primaryAction: { importing = true }
            .menuStyle(.button).buttonStyle(.borderedProminent).fixedSize()
            controlsButton
            NavigationLink(value: GameShelf.all) { Label("All games", systemImage: "square.grid.2x2") }.buttonStyle(.bordered)
        }
    }

    private var controlsButton: some View {
        Button("Controls", systemImage: "keyboard") { showingControls = true }
            .buttonStyle(.bordered)
            .popover(isPresented: $showingControls, arrowEdge: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Controls").font(.headline)
                        ControlsHelp(showFolder: showGamesFolder)
                    }.padding(18)
                }
                .frame(minWidth: 320, idealWidth: 400, maxWidth: 440, minHeight: 200, idealHeight: 420, maxHeight: 520)
            }
    }

    private func showGamesFolder() {
        #if os(macOS)
        let folder = GameLibrary.importFolder
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); NSWorkspace.shared.open(folder) }
        catch { importError = error.localizedDescription }
        #endif
    }

    /// Genre or publisher groups with their game counts, biggest first. Empty until games are organized.
    @ViewBuilder private func groupSection(_ title: String, field: CatalogDetails.Key, route: @escaping (String) -> GameShelf) -> some View {
        // Nothing to group until Organize with AI has approved some details.
        let names = KitCatalog.shared.details.isEmpty ? [] : Dictionary(grouping: games.games.compactMap { KitCatalog.shared.value(KitCatalog.gameKey($0), field) }, by: { $0 })
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

    /// The game counts as played once it has really started (GameSession posts .gameDidStart).
    private func play(_ game: Game, _ resume: Bool) {
        let ref = GameRef(path: game.url.path, resume: resume)
        #if os(macOS)
        openWindow(value: ref)
        #else
        playing = ref
        #endif
    }

    private var findGames: some View {
        FindMoreCard(title: "Where to find games",
                     intro: "People still make new games for these systems and share many of them free, and some classic DOS and adventure games are now free too. Download a game file (.gb, .gbc, .gba, .nes, .pce, or a DOS game’s .zip), or a ScummVM game’s folder, then add it with Add Games. A download zipped around one game file is unzipped for you.",
                     links: FindMore.games,
                     footnote: "Use homemade games like these, or games you own. Copies of store-bought games shared online are illegal, so Offline Kit doesn’t link to them. These links open in your browser and need internet.")
    }
}

// MARK: - Adding and controls

extension GameSystem {
    /// Atari 2600 games aren't played any more, so they aren't offered.
    fileprivate static var playable: [GameSystem] { allCases.filter { $0 != .atari2600 } }

    /// What to add for this system.
    fileprivate var addHint: String {
        switch self {
        case .gameBoy: ".gb files"
        case .gameBoyColor: ".gbc files"
        case .gameBoyAdvance: ".gba files"
        case .nes: ".nes files"
        case .atari2600: ""
        case .pcEngine: ".pce files"
        case .dos: "A game’s .zip or .dosz file"
        case .scummvm: "A game’s folder"
        }
    }

    fileprivate var artSymbol: String {
        switch self {
        case .gameBoy: "dpad.fill"
        case .gameBoyColor: "paintpalette.fill"
        case .gameBoyAdvance: "bolt.fill"
        case .nes: "tv.fill"
        case .atari2600: "gamecontroller.fill"
        case .pcEngine: "memorychip.fill"
        case .dos: "desktopcomputer"
        case .scummvm: "map.fill"
        }
    }

    fileprivate var artShortName: String {
        switch self {
        case .gameBoy: "GAME BOY"; case .gameBoyColor: "GB COLOR"; case .gameBoyAdvance: "GB ADVANCE"; case .nes: "NES"
        case .atari2600: "ATARI"; case .pcEngine: "PC ENGINE"; case .dos: "DOS"; case .scummvm: "SCUMMVM"
        }
    }
}

/// A dashed area that takes dropped game files. The window's own drop target asks where files go; this one adds games.
private struct GameDropZone<Content: View>: View {
    let onDrop: ([URL]) -> Void
    var corner: CGFloat = 18
    @ViewBuilder var content: Content
    @State private var targeted = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        content
            .background(Color.accentColor.opacity(targeted ? 0.14 : 0.05), in: shape)
            .overlay(shape.strokeBorder(targeted ? Color.accentColor : Color.accentColor.opacity(0.35),
                                        style: StrokeStyle(lineWidth: targeted ? 2.5 : 1.5, dash: [8, 6])))
            .animation(Motion.quick, value: targeted)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers { if let url = await provider.droppedFileURL() { urls.append(url) } }
                    if !urls.isEmpty { onDrop(urls) }
                }
                return true
            }
    }
}

private extension NSItemProvider {
    func droppedFileURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}

/// Keyboard, controller and saving tips, as plain lines.
private struct ControlsHelp: View {
    let showFolder: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            #if os(macOS)
            line("keyboard", "Keyboard", "Arrow keys move. X and Z are A and B. Return starts and Space selects.")
            line("gamecontroller", "Controller", "Most game controllers work as soon as they are connected.")
            line("desktopcomputer", "DOS and ScummVM", "These take the keyboard and mouse directly. If a DOS game says it needs a joystick, choose Joystick on its page. In ScummVM, save and load from the game’s menu: the Game Menu button, or fn-F5 on a Mac laptop.")
            #else
            line("hand.tap", "Touch", "Use the on-screen controls. Save your place from the player’s menu.")
            line("gamecontroller", "Controller", "Connect a game controller and it works right away.")
            line("desktopcomputer", "DOS and ScummVM", "The picture works like a touchpad: tap to click. In ScummVM, touch and hold to right-click.")
            #endif
            line("externaldrive", "Saves", "Your place is saved beside each game, so it can travel with your drive.")
            #if os(macOS)
            Button("Show Games Folder", systemImage: "folder", action: showFolder)
            #endif
        }
    }

    private func line(_ symbol: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 22).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
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
    let games: [Game]
    let favorites: Set<String>
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 16)], alignment: .leading, spacing: 18) {
            ForEach(games) { game in GameTileLink(game: game, favorite: favorites.contains(game.id)) }
        }
    }
}

/// A tile that opens the game's page, with its right-click menu.
private struct GameTileLink: View {
    @Environment(GameLibrary.self) private var library
    let game: Game
    let favorite: Bool
    var body: some View {
        NavigationLink(value: GameShelf.game(game)) { GameTile(game: game, favorite: favorite) }
            .buttonStyle(.plain)
            .contextMenu {
                Button(favorite ? "Remove from Favorites" : "Add to Favorites", systemImage: "heart") { library.toggleFavorite(game) }
                ShowInFinderButton(url: game.url)
                SendToPhoneButton(game: game)
            }
    }
}

/// The game's saved picture when it has one (its last frame), else its generated title screen (GameTitleCards), else
/// its system's colors and symbol with the title set on it.
private struct GameArtwork: View {
    let game: Game
    @State private var loaded: CGImage?
    private static let pixels = 768
    private var titleScreen: String? { GameArtStore.shared.titleScreen(for: game) }
    var body: some View {
        ZStack {
            if let thumbnail {
                game.system.tint.opacity(0.12)
                thumbnail.resizable().interpolation(.none).aspectRatio(contentMode: .fit)
            } else {
                SystemArt(game: game)
            }
        }
        .aspectRatio(1.4, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
        // Read and shrunk off the main thread by the shared cache, and again when a new save changes the picture
        // or a title screen arrives.
        .task(id: "\(game.id)|\(game.savedStamp)|\(titleScreen ?? "")") {
            for path in [game.thumbnailURL.path, titleScreen].compactMap({ $0 }) {
                if let hit = ImageCache.shared.cached(path, pixels: Self.pixels) { loaded = hit; return }
                let result = await ImageCache.shared.image(path, pixels: Self.pixels)
                guard !Task.isCancelled else { return }
                if let result { loaded = result; return }
            }
            loaded = nil
        }
    }
    private var thumbnail: Image? {
        let image = loaded ?? ImageCache.shared.cached(game.thumbnailURL.path, pixels: Self.pixels)
            ?? titleScreen.flatMap { ImageCache.shared.cached($0, pixels: Self.pixels) }
        return image.map { Image(decorative: $0, scale: 1) }
    }
}

/// Stand-in cover: each system has its own color and symbol, and the title sits on it like a label.
private struct SystemArt: View {
    let game: Game
    var body: some View {
        let tint = game.system.tint
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .bottomLeading) {
                LinearGradient(colors: [tint.opacity(0.95), tint.mix(with: .black, by: 0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: game.system.artSymbol)
                    .font(.system(size: w * 0.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.16))
                    .rotationEffect(.degrees(-10))
                    .offset(x: w * 0.52, y: -geo.size.height * 0.12)
                LinearGradient(colors: [.clear, .black.opacity(0.4)], startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    Text(game.system.artShortName)
                        .font(.system(size: max(8, w * 0.055), weight: .heavy)).tracking(1)
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.black.opacity(0.22), in: Capsule())
                    Spacer(minLength: 4)
                    Text(game.title)
                        .font(.system(size: max(12, min(26, w * 0.11)), weight: .bold, design: .rounded))
                        .foregroundStyle(.white).lineLimit(3).minimumScaleFactor(0.7)
                        .multilineTextAlignment(.leading).shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
                .padding(w * 0.07)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .clipped()
        }
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
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Design.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Design.border, lineWidth: 0.5))
        .hoverLift(hovering: $hovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.title), \(game.system.name)\(game.canResume ? ", saved place" : "")\(favorite ? ", favorite" : "")")
    }
}

/// A game with a saved place: its picture, and how long ago it was left.
private struct ContinueCard: View {
    let game: Game
    let date: Date
    @State private var hovering = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GameArtwork(game: game)
            Text(game.title).font(.headline).foregroundStyle(.primary).lineLimit(1)
            HStack(spacing: 6) {
                Label("Resume", systemImage: "play.fill").font(.callout.weight(.semibold)).foregroundStyle(Color.accentColor)
                Spacer(minLength: 4)
                if date != .distantPast {
                    Text(date.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .padding(12)
        .frame(width: 252)
        .background(Design.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(hovering ? Color.accentColor.opacity(0.6) : Design.border, lineWidth: 0.5))
        .hoverLift(hovering: $hovering)
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
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 26) {
                        GameArtwork(game: game).frame(width: 300)
                        introduction.frame(minWidth: 350, maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 20) {
                        GameArtwork(game: game).frame(maxWidth: 360)
                        introduction
                    }
                }
                controlsGuide
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 18) {
                        savedPlaceCard.frame(minWidth: 250, maxWidth: .infinity)
                        detailsCard.frame(minWidth: 250, maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 18) { savedPlaceCard; detailsCard }
                }
            }.padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
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

    private var savedDate: Date? {
        guard game.canResume, let url = game.resumeStateURL else { return nil }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(game.system.name.uppercased()).font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(Color.accentColor)
                Text(game.title).font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(Design.ink)
            }
            FlowLayout(spacing: 8) {
                Pill(text: "Works offline", symbol: "checkmark.shield", tint: .accentColor)
                if game.canResume { Pill(text: "Saved place available", symbol: "bookmark") }
                if let date = savedDate {
                    Text("Saved \(date.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                        .help(date.formatted(date: .abbreviated, time: .shortened))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { playActions }
                VStack(alignment: .leading, spacing: 12) { playActions }
            }
            if game.system.hasSaveStates {
                Text(game.canResume ? "Resume picks up \(savedDate.map { "your place, saved \($0.formatted(.relative(presentation: .named)))" } ?? "your latest saved place"). Longer sessions save automatically." : "Longer sessions save automatically. You can also save your place from the player.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Save and load from the game’s own menu.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var controlsGuide: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("How to play").font(.title2.bold()).accessibilityAddTraits(.isHeader)
            #if os(macOS)
            FlowLayout(spacing: 18) {
                switch game.system {
                case .scummvm:
                    key("Mouse", action: "Point and click")
                    key("fn-F5", action: "Game menu")
                    key("Esc", action: "Skip a scene")
                case .dos:
                    if dosControls == .joystick {
                        key("↑ ↓ ← →", action: "Move")
                        key("Z", action: "Fire")
                        key("X", action: "Button 2")
                    } else {
                        key("Keyboard", action: "Direct input")
                    }
                    key("Mouse", action: "Move and click")
                case .atari2600:
                    key("↑ ↓ ← →", action: "Move")
                    key("Z / X", action: "Fire")
                    key("Return", action: "Game Reset")
                    key("Space", action: "Game Select")
                case .pcEngine:
                    key("↑ ↓ ← →", action: "Move")
                    key("X", action: "I")
                    key("Z", action: "II")
                    key("Return", action: "Run")
                    key("Space", action: "Select")
                default:
                    key("↑ ↓ ← →", action: "Move")
                    key("X", action: "A")
                    key("Z", action: "B")
                    if game.system.hasShoulderButtons { key("Q / W", action: "L / R") }
                    key("Return", action: "Start")
                    key("Space", action: "Select")
                }
            }
            if game.system == .scummvm {
                Text("Use the Game Menu button to save or load. On a Mac laptop, fn-F5 opens the same menu.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if game.system == .dos {
                Text(dosControls == .joystick ? "Other keys still go straight to the game. A game controller works as the joystick too." : "Click the picture if keys stop reaching the game.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Game controllers work too.").font(.callout).foregroundStyle(.secondary)
            }
            #else
            let hint = game.system == .dos
                ? (dosControls == .joystick ? "Tap the picture to click. The on-screen direction pad or a connected game controller moves the joystick." : "Tap the picture to click. Choose Joystick below for games that need a joystick.")
                : game.system.controlsHint
            Label(hint, systemImage: "hand.tap").font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !game.system.usesKeyboardAndMouse {
                Text(touchButtonHint).font(.callout).foregroundStyle(.secondary)
            }
            #endif
            if game.system == .dos { dosControlPicker }
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 20)
    }

    private var touchButtonHint: String {
        switch game.system {
        case .pcEngine: "On-screen A and B play buttons I and II. Start is Run; Select is Select."
        case .atari2600: "On-screen B fires. Start is Game Reset; Select is Game Select."
        case .gameBoyAdvance: "The on-screen pad includes A, B, L, R, Start and Select."
        default: "Move with the on-screen direction pad; use A, B, Start and Select."
        }
    }

    private func key(_ keys: String, action: String) -> some View {
        HStack(spacing: 10) {
            Text(keys).font(.system(.callout, design: .monospaced, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Design.canvas, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(Design.border) }
            Text(action).font(.callout)
        }.accessibilityElement(children: .combine)
    }

    private var dosControlPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Controls", selection: Binding(get: { dosControls }, set: { changeControls($0) })) {
                Text("Keyboard & mouse").tag(GameLibrary.DOSControls.keyboard)
                Text("Joystick or game pad").tag(GameLibrary.DOSControls.joystick)
            }.pickerStyle(.menu)
            Text("Choose Joystick if the game says a joystick is required.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var savedPlaceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Saved place", systemImage: "externaldrive").font(.headline)
            Text("Saves stay beside this game and travel with its drive.").font(.callout).foregroundStyle(.secondary)
            if !game.system.hasSaveStates {
                Text("This system uses the game’s own save menu; Resume isn’t available.").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 18)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Game details", systemImage: "desktopcomputer").font(.headline)
            LabeledContent("System", value: game.system.name)
            if let date = library.lastPlayed[game.id] { LabeledContent("Last played", value: date.formatted(date: .abbreviated, time: .shortened)) }
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 18)
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
