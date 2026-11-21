import SwiftUI

struct OpenArticleAction {
    let handler: (ArticleRef) -> Void
    func callAsFunction(_ ref: ArticleRef) { handler(ref) }
}

extension EnvironmentValues {
    @Entry var openArticle = OpenArticleAction { _ in }
}

enum SidebarItem: Hashable {
    case ask
    case library
    case archives
    case area(SubjectArea)
    case settings
    case resources
    case kit
    case games
    case media
    case share
    case prepare
    case audiobooks
    case music
    case books
    case book(String)
}

#if os(macOS)
/// Settings buttons that act on the main window (Welcome, Kit Care, Get Resources, update sheet) work even when
/// that window is closed: it is reopened first, and the action runs once RootView has appeared and is listening.
@MainActor enum MainWindow {
    static let id = "main"
    private static var openCount = 0
    private static var pending: (() -> Void)?

    static func run(openWindow: OpenWindowAction, _ action: @escaping () -> Void) {
        if openCount > 0 {
            DispatchQueue.main.async(execute: action)
        } else {
            pending = action
            openWindow(id: id)
        }
    }

    static func didAppear() {
        openCount += 1
        guard let action = pending else { return }
        pending = nil
        // Let the window finish setting up its listeners before the action fires.
        Task { try? await Task.sleep(for: .milliseconds(400)); action() }
    }

    static func didDisappear() { openCount = max(0, openCount - 1) }
}
#endif

struct RootView: View {
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(AskModel.self) private var ask
    @Environment(NowPlaying.self) private var nowPlaying
    @Environment(Household.self) private var household
    @State private var navigation = KitNavigation()
    @State private var columns: NavigationSplitViewVisibility = .all
    /// The Library page shows every area, so the sidebar's list starts folded away.
    @State private var showAreas = false
    #if os(macOS)
    @State private var importer = DropImporter()
    #endif
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    #else
    @State private var sheetArticle: ArticleRef?
    #endif

    @ViewBuilder private var detail: some View {
        switch navigation.selection {
        case .resources: GetResourcesView()
        case .kit: KitCareView()
        case .library: LibraryBrowser()
        case .archives: LibraryBrowser(archives: true).id("archives")
        case .area(let area): LibraryBrowser(area: area).id(area)
        case .games: GamesView()
        case .media: WatchListenView(section: .video).id("watch")
        case .audiobooks: WatchListenView(section: .audiobooks).id("audiobooks")
        case .music: WatchListenView(section: .music).id("music")
        case .books: WatchListenView(section: .books).id("books")
        case .share:
            #if os(macOS)
            ShareView()
            #else
            AskView()
            #endif
        case .settings: SettingsView()
        case .prepare: PrepareView()
        case .book(let id):
            if let book = library.book(id) { BookView(book: book).id(book.id) }
            else { LibraryBrowser() }
        default: AskView()
        }
    }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView(columnVisibility: $columns) {
            List(selection: $navigation.selection) {
                Section {
                    Label("Ask", systemImage: "bubble.left").tag(SidebarItem.ask)
                    Label("Library", systemImage: "books.vertical").tag(SidebarItem.library)
                    Label("Get Resources", systemImage: "arrow.down.circle")
                        .badge(downloads.activeCount).tag(SidebarItem.resources)
                    Label("Kit Care", systemImage: "stethoscope").tag(SidebarItem.kit)
                    Label("Watch", systemImage: "play.rectangle.on.rectangle").tag(SidebarItem.media)
                    Label("Audiobooks", systemImage: "headphones").tag(SidebarItem.audiobooks)
                    Label("Music", systemImage: "music.note").tag(SidebarItem.music)
                    Label("Books", systemImage: "book").tag(SidebarItem.books)
                    Label("Play", systemImage: "gamecontroller").tag(SidebarItem.games)
                    Label("Prepare", systemImage: "checklist")
                        .badge(household.data.extra.suppliesNeedingAttention()).tag(SidebarItem.prepare)
                }
                Section("Browse by area", isExpanded: $showAreas) {
                    ForEach(SubjectArea.allCases) { area in
                        Label(area.title, systemImage: area.symbol).tag(SidebarItem.area(area))
                    }
                }
                Section("Your collection") {
                    Label("All downloads", systemImage: "book.closed").tag(SidebarItem.archives)
                }
                #if os(macOS)
                Section("Share") {
                    Label("Share on Wi-Fi", systemImage: "wifi").tag(SidebarItem.share)
                }
                #endif
            }
            .scrollContentBackground(.hidden)
            .background(Design.sidebar)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    #if os(macOS)
                    UpdateSidebarCard()
                    #endif
                    DownloadStatusCard { navigation.getResources(nil) }
                    Divider().padding(.top, downloads.summary == nil ? 0 : 10)
                    LibraryFooter()
                    #if os(macOS)
                    SettingsLink { Label("Settings", systemImage: "gearshape") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 14)
                    #endif
                }.background(Design.sidebar)
            }
            .navigationTitle("Offline Kit")
            .toolbar {
                ToolbarItem {
                    Button { Task { await library.reload() } } label: {
                        Label("Rescan Library", systemImage: "arrow.clockwise")
                    }
                    .disabled(library.isLoading)
                    .help("Look for new or removed archives")
                }
            }
            #if os(macOS)
            .navigationSplitViewColumnWidth(min: 220, ideal: 250)
            #endif
        } detail: {
            detail
                // What's playing keeps going, shrunk to a bar, while people move around the app.
                .safeAreaInset(edge: .bottom) { MiniPlayerBar() }
        }
        #if os(macOS)
        .onAppear { MainWindow.didAppear() }
        .onDisappear { MainWindow.didDisappear() }
        #endif
        .modifier(FirstRunPresentation())
        .modifier(PrivateUnlockPresentation())
        #if os(macOS)
        .sheet(isPresented: Binding(get: { AppUpdater.shared.showingSheet }, set: { AppUpdater.shared.showingSheet = $0 })) {
            UpdateSheet()
        }
        #endif
        #if DEBUG
        // Test hook: -noAnimations YES, for window snapshots taken while the display sleeps (animations wait on it).
        .transaction { if UserDefaults.standard.bool(forKey: "noAnimations") { $0.disablesAnimations = true; $0.animation = nil } }
        #endif
        #if os(macOS)
        .acceptsKitDrops(importer)
        #if DEBUG
        // Test hook: -thenOpen library switches sections after 8 seconds (to check the mini player).
        .task {
            guard UserDefaults.standard.string(forKey: "thenOpen") == "library" else { return }
            try? await Task.sleep(for: .seconds(8))
            navigation.selection = .library
        }
        // Test hook: -dropFiles "/path/a|/path/b" acts as if those files were dropped on the window.
        .task {
            guard let paths = UserDefaults.standard.string(forKey: "dropFiles") else { return }
            try? await Task.sleep(for: .seconds(1))
            importer.receive(paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) })
        }
        #endif
        #endif
        // When someone presses Emergency, hide the sidebar and everything else so Ask has the whole window.
        // An alert raised by a question's words is smaller and leaves the sidebar alone.
        .onChange(of: ask.isFullEmergency) { _, emergency in
            columns = emergency ? .detailOnly : .all
            if emergency { navigation.selection = .ask }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openGetResources)) { _ in navigation.getResources(nil) }
        .onReceive(NotificationCenter.default.publisher(for: .openKitCopy)) { _ in
            navigation.wantsKitCopy = true
            navigation.selection = .kit
        }
        .environment(navigation)
        #if DEBUG
        // Test hook: -startSection media|games|resources|share opens that section.
        .onAppear {
            switch UserDefaults.standard.string(forKey: "startSection") {
            case "ask": navigation.selection = .ask
            case "library": navigation.selection = .library
            case "archives": navigation.selection = .archives
            #if os(macOS)
            case "settings": openSettings()
            #endif
            case "media": navigation.selection = .media
            case "audiobooks": navigation.selection = .audiobooks
            case "music": navigation.selection = .music
            case "books": navigation.selection = .books
            case "games": navigation.selection = .games
            case "resources": navigation.selection = .resources
            case "kit": navigation.selection = .kit
            case "maps": navigation.getResources(.world)
            case "prepare": navigation.selection = .prepare
            case "share": navigation.selection = .share
            default: break
            }
            // Test hook: -cycleSections N clicks through Watch, Audiobooks, Music and Books N times, one a second.
            if let rounds = Int(UserDefaults.standard.string(forKey: "cycleSections") ?? "") {
                Task {
                    try? await Task.sleep(for: .seconds(6))
                    let order: [SidebarItem] = [.media, .audiobooks, .music, .books]
                    for step in 0..<(rounds * order.count) {
                        NSLog("CYCLE %@", "\(order[step % order.count])")
                        navigation.selection = order[step % order.count]
                        try? await Task.sleep(for: .seconds(1))
                    }
                    NSLog("CYCLE done")
                }
            }
        }
        #endif
        #if os(macOS)
        #if DEBUG
        .onAppear {
            if let path = UserDefaults.standard.string(forKey: "autoPlay") { openWindow(value: GameRef(path: path)) }
            if UserDefaults.standard.string(forKey: "autoAsk") != nil { navigation.selection = .ask }
            if let area = UserDefaults.standard.string(forKey: "autoBrowse").flatMap(SubjectArea.init(rawValue:)) {
                navigation.selection = .area(area)
            }
        }
        #endif
        .environment(\.openArticle, OpenArticleAction { openWindow(value: $0) })
        #else
        .environment(\.openArticle, OpenArticleAction { sheetArticle = $0 })
        .sheet(item: $sheetArticle) { ref in
            NavigationStack {
                ReaderView(ref: ref)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sheetArticle = nil } } }
            }
        }
        #endif
    }

    static func prettyName(_ url: URL) -> String {
        let base = url.deletingPathExtension().lastPathComponent
        let trimmed = base.replacingOccurrences(of: #"_\d{4}-\d{2}$"#, with: "", options: .regularExpression)
        return trimmed.replacingOccurrences(of: "_", with: " ")
    }
}

/// Totals and where the archives live, pinned under the sidebar.
struct LibraryFooter: View {
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        let total = library.books.reduce(Int64(0)) { $0 + $1.fileSize }
        let drives = Set(library.books.compactMap { $0.isOnExternalDrive ? $0.volumeName : nil }).sorted()
        HStack(spacing: 8) {
            if library.isLoading {
                ProgressView().controlSize(.small)
                Text("Scanning…")
            } else {
                Image(systemName: KitLocation.isPortable ? "externaldrive.fill" : "internaldrive")
                VStack(alignment: .leading, spacing: 1) {
                    Text(library.books.isEmpty ? (downloads.summary?.isRunning == true ? "Downloading your library…" : "Nothing saved yet")
                         : "\(library.books.count) \(library.books.count == 1 ? "reference" : "references") · \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
                    if KitLocation.isPortable {
                        Text("Running from \(KitLocation.portableVolumeName ?? "drive")")
                    } else if !drives.isEmpty {
                        Text("This Mac + \(drives.joined(separator: ", "))")
                    } else {
                        Text("On this device")
                    }
                }
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

struct BookRow: View {
    let book: Book
    var body: some View {
        // A Label (like the documents rows), so a Mac List sizes the row for both lines and the whole icon.
        Label {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.shortTitle).lineLimit(1)
                    Text("\(Int(book.archive.articleCount).compact) \(book.archive.articleCount == 1 ? "article" : "articles") · \(ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if book.isOnExternalDrive {
                    Image(systemName: "externaldrive")
                        .font(.caption).foregroundStyle(.tertiary)
                        .help("On \(book.volumeName ?? "an external drive")")
                }
            }
        } icon: {
            BookIcon(book: book, size: 24)
        }
        .padding(.vertical, 3)
    }
}

struct BookIcon: View {
    let book: Book
    var size: CGFloat = 22

    var body: some View {
        Group {
            if let image {
                image.resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: fallbackSymbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(Color.accentColor.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    }

    private var image: Image? {
        guard let data = book.archive.illustration else { return nil }
        #if os(macOS)
        return NSImage(data: data).map { Image(nsImage: $0) }
        #else
        return UIImage(data: data).map { Image(uiImage: $0) }
        #endif
    }

    private var fallbackSymbol: String {
        switch book.kind {
        case .encyclopedia: "book.closed.fill"
        case .guides: "wrench.and.screwdriver.fill"
        case .survival: "shield.lefthalf.filled"
        case .community: "bubble.left.and.bubble.right.fill"
        case .other: "doc.text.fill"
        }
    }
}

/// Browse one archive: its main page, plus title search.
struct BookView: View {
    let book: Book
    @State private var current: ArticleRef?
    @State private var query = ""
    @State private var suggestions: [ZimHit] = []
    @State private var reader = ReaderState()

    var body: some View {
        Group {
            if let current {
                ArticleWebView(ref: current, state: reader)
            } else {
                ContentUnavailableView("No main page", systemImage: "book.closed",
                                       description: Text("Search for an article by title."))
            }
        }
        .navigationTitle(book.title)
        .searchable(text: $query, prompt: "Search \(book.title)")
        .searchSuggestions {
            ForEach(suggestions, id: \.path) { hit in
                Button(hit.title) {
                    current = ArticleRef(bookID: book.id, path: hit.path, title: hit.title)
                    query = ""
                }
            }
        }
        .onSubmit(of: .search) {
            if let first = suggestions.first {
                current = ArticleRef(bookID: book.id, path: first.path, title: first.title)
                query = ""
            }
        }
        .task(id: query) {
            let q = query, archive = book.archive
            suggestions = q.isEmpty ? [] : await Task.detached { archive.suggest(q, limit: 12) }.value
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { reader.back() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!reader.canGoBack)
                Button { reader.forward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!reader.canGoForward)
                Button { current = book.mainPage } label: { Label("Home", systemImage: "house") }
            }
            ToolbarItem(placement: .primaryAction) { SaveGuideButton(ref: reader.current ?? current) }
        }
        .onAppear { if current == nil { current = book.mainPage } }
    }
}
