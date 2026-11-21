import SwiftUI
import UniformTypeIdentifiers

@main
struct OfflineKitiOSApp: App {
    @State private var library = Library()
    @State private var model = AskModel()
    @State private var downloads = DownloadManager()
    @State private var games = GameLibrary()
    @State private var media = MediaLibrary()
    @State private var audiobooks = AudiobookDownloads()
    @State private var household = Household()
    @State private var nowPlaying = NowPlaying()
    @State private var starterFilms = StarterFilms()

    var body: some Scene {
        WindowGroup {
            IOSRoot()
                .environment(library)
                .environment(model)
                .environment(downloads)
                .environment(games)
                .environment(media)
                .environment(audiobooks)
                .environment(household)
                .environment(nowPlaying)
                .environment(starterFilms)
                .task {
                    downloads.onInstalled = {
                        KitChanges.shared.modelsChanged()
                        Task { await library.reload(); await media.reload(library: library) }
                    }
                    await library.reload()
                    // First launch: copy the bundled classic books into the kit.
                    if await StarterBooks.installIfNeeded() { await media.reload(library: library) }
                    downloads.restore(from: library.folders)
                    downloads.resumeAll()
                    // Send to iPhone: things downloaded from the Mac show up in Watch, Books, Play and Library.
                    MacTransfers.shared.onItemFinished = { Task { await library.reload(); await media.reload(library: library); await games.reload(library: library) } }
                    MacTransfers.shared.restore()
                }
        }
        .backgroundTask(.urlSession(MacTransfers.sessionID)) { await MacTransfers.shared.handleBackgroundEvents() }
    }
}

/// iPhone: tabs for Ask, Library and Settings. iPad gets the Mac-style sidebar via RootView.
struct IOSRoot: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(Library.self) private var library
    @Environment(MediaLibrary.self) private var media
    @Environment(GameLibrary.self) private var games
    @Environment(\.scenePhase) private var phase
    @State private var autoPlay: GameRef?

    var body: some View {
        Group {
            if sizeClass == .regular {
                RootView()
            } else {
                PhoneTabs()
            }
        }
        // Files dropped in via the Files app or Finder show up when the app comes back.
        .onChange(of: phase) {
            // Leaving the foreground: pause the game and save, since it would otherwise play on unseen and never save.
            guard phase == .active else { GameSession.current?.pauseAndSave(); return }
            GameSession.current?.windowFocusChanged(true)
            KitChanges.shared.documentsChanged()
            Task { await library.reload(); await media.reload(library: library); await games.reload(library: library) }
        }
        #if DEBUG
        // Test hook: -autoPlay /path/to/game opens the player straight away.
        .fullScreenCover(item: $autoPlay) { ref in if let game = ref.game { PlayerView(game: game) } }
        .onAppear { if let path = UserDefaults.standard.string(forKey: "autoPlay") { autoPlay = GameRef(path: path) } }
        #endif
    }
}

struct PhoneTabs: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(Household.self) private var household
    @Environment(AskModel.self) private var ask
    @State private var sheetArticle: ArticleRef?
    @State private var navigation = KitNavigation()

    var body: some View {
        @Bindable var navigation = navigation
        TabView(selection: $navigation.selection) {
            Tab("Ask", systemImage: "bubble.left", value: SidebarItem.ask as SidebarItem?) {
                NavigationStack { AskView() }
                    .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
                    // In an emergency, hide the tab bar so nothing pulls attention away.
                    .toolbar(ask.isFullEmergency ? .hidden : .automatic, for: .tabBar)
            }
            Tab("Prepare", systemImage: "checklist", value: SidebarItem.prepare as SidebarItem?) {
                NavigationStack { PrepareView() }
                    .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
            }
            .badge(household.data.extra.suppliesNeedingAttention())
            Tab("Library", systemImage: "books.vertical", value: SidebarItem.library as SidebarItem?) {
                PhoneLibrary()
                    .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
            }
            Tab("Watch", systemImage: "play.rectangle.on.rectangle", value: SidebarItem.media as SidebarItem?) {
                WatchListenView()
                    .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
            }
            Tab("Play", systemImage: "gamecontroller", value: SidebarItem.games as SidebarItem?) {
                GamesView()
                    .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
            }
            Tab("Get", systemImage: "arrow.down.circle", value: SidebarItem.resources as SidebarItem?) {
                NavigationStack { GetResourcesView() }
                    .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
            }
            .badge(downloads.activeCount)
            Tab("Settings", systemImage: "gearshape", value: SidebarItem.settings as SidebarItem?) {
                NavigationStack { SettingsView().navigationTitle("Settings") }
                    .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
            }
        }
        .modifier(FirstRunPresentation())
        #if DEBUG
        // Test hook: -startSection prepare opens the Prepare tab.
        .onAppear { if UserDefaults.standard.string(forKey: "startSection") == "prepare" { navigation.selection = .prepare } }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .openGetResources)) { _ in navigation.getResources(nil) }
        .onChange(of: ask.isFullEmergency) { _, emergency in if emergency { navigation.selection = .ask } }
        .environment(navigation)
        .environment(\.openArticle, OpenArticleAction { sheetArticle = $0 })
        .sheet(item: $sheetArticle) { ref in
            NavigationStack {
                ReaderView(ref: ref)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheetArticle = nil } } }
            }
        }
        #if DEBUG
        // Test hook: -startSection prepare opens the Prepare tab.
        .onAppear { if UserDefaults.standard.string(forKey: "startSection") == "prepare" { navigation.selection = .prepare } }
        #endif
    }
}

struct PhoneLibrary: View {
    var body: some View { LibraryBrowser() }
}
