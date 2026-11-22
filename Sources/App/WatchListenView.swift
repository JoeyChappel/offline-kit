import SwiftUI
import AVKit
import UniformTypeIdentifiers

/// What Start Over replaced.
private struct StartOverUndo: Identifiable {
    let id = UUID()
    let item: MediaItem
    let previous: MediaProgress
}

struct WatchListenView: View {
    /// Set for the sidebar's Watch, Audiobooks, Music and Books links: shows only that kind, without category chips.
    /// Nil on iPhone, where one Watch tab keeps the chips.
    let section: MediaFilter?
    @Environment(Library.self) private var library
    @Environment(MediaLibrary.self) private var media
    @Environment(AudiobookDownloads.self) private var audiobooks
    @Environment(NowPlaying.self) private var nowPlaying
    @State private var filter: MediaFilter
    @State private var genre: String?
    @State private var sort: MediaSort = .title
    @State private var query = ""
    /// `query` after the typing has paused for a moment: the lists are worked out from this one.
    @State private var appliedQuery = ""
    /// Shared by every Watch & Listen section, so coming back to one that is unchanged costs a lookup.
    private var derivedCache: WatchListenCache { .shared }
    @State private var unfinished = false
    @State private var musicBrowse: MusicBrowse = .albums
    @State private var artist: String?
    @State private var collection: MediaShelf?
    @State private var selected: MediaItem?
    @State private var playing: MediaItem?
    @State private var importing = false
    @State private var importError: String?
    @State private var more = false
    @State private var finding = false
    @State private var organizing = false
    @State private var unavailableMessage: String?
    @State private var dropTargeted = false
    /// The place Start Over just replaced, offered back for a few seconds.
    @State private var undoOffer: StartOverUndo?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if os(macOS)
    /// The window's drop sheet; + sends its picks there too.
    @Environment(DropImporter.self) private var dropImporter: DropImporter?
    #endif

    init(section: MediaFilter? = nil) {
        self.section = section
        _filter = State(initialValue: section ?? .all)
        #if DEBUG
        // Test hook: -watchFilter video|music|books|audiobooks opens the iPhone's Watch tab on that chip.
        if section == nil, let value = UserDefaults.standard.string(forKey: "watchFilter"),
           let chosen = MediaFilter.allCases.first(where: { $0.rawValue == value }) {
            _filter = State(initialValue: chosen)
        }
        // Test hook: -musicBrowse songs|artists|genres opens Music on that tab (for profiling the long lists).
        if section == .music, let value = UserDefaults.standard.string(forKey: "musicBrowse"),
           let browse = MusicBrowse.allCases.first(where: { $0.rawValue.lowercased() == value.lowercased() }) {
            _musicBrowse = State(initialValue: browse)
        }
        #endif
    }

    private var title: String {
        switch section {
        case nil, .all?: "Watch"
        case .video?: "Watch"
        case let other?: other.label
        }
    }

    /// Everything worked out from the library and the current filter, search and sort: done once per change of those
    /// (see WatchListenDerived), not once per row, tile or section that reads it.
    private var d: WatchListenDerived {
        let key = WatchListenCache.Key(revision: media.revision, filter: filter, genre: genre, query: appliedQuery, sort: sort,
                                       unfinished: unfinished, artist: artist, collectionID: collection?.id)
        return derivedCache.derived(key) {
            WatchListenDerived(items: media.items, info: media.info, progress: media.progress, filter: filter, genre: genre,
                               query: appliedQuery, sort: sort, unfinished: unfinished, artist: artist, collection: collection)
        }
    }
    private var filtered: [MediaItem] { d.filtered }
    private var browsing: Bool { genre != nil || !appliedQuery.isEmpty || sort != .title || unfinished || filter == .music || artist != nil || collection != nil }

    var body: some View {
        NavigationStack {
            #if os(macOS)
            if let playing {
                player(playing).toolbar { ToolbarItem(placement: .navigation) { Button(title, systemImage: "chevron.left") { self.playing = nil } } }
            } else { content }
            #else
            content.fullScreenCover(item: $playing) { item in
                NavigationStack { player(item).toolbar { ToolbarItem(placement: .topBarLeading) { Button("Minimize", systemImage: "chevron.down") { playing = nil } } } }
                    .overlay(alignment: .bottom) { undoToast }
                    .environment(\.colorScheme, .dark).tint(MediaTheme.accent)
            }
            #endif
        }
        #if os(macOS)
        .overlay(alignment: .bottom) { undoToast }
        #endif
        .onChange(of: filter) { genre = nil; artist = nil; collection = nil; selected = nil; sort = .title; query = ""; appliedQuery = "" }
        // Search waits for a pause in the typing; clearing it shows everything at once.
        .task(id: query) {
            guard query != appliedQuery else { return }
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
            }
            appliedQuery = query
        }
        .onChange(of: nowPlaying.expandRequest) { openRequested() }
        .onAppear(perform: openRequested)
        .task {
            audiobooks.onFinished = { Task { await media.reload(library: library) } }
            await media.reloadIfStale(library: library)
            #if DEBUG
            let defaults = UserDefaults.standard
            if let book = LibriVoxBook.picks.first(where: { $0.id == defaults.integer(forKey: "getAudiobook") }) {
                audiobooks.get(book)
                // Test hook: -cancelAudiobook S cancels that download S seconds after it starts.
                if let wait = Double(defaults.string(forKey: "cancelAudiobook") ?? "") {
                    try? await Task.sleep(for: .seconds(wait))
                    audiobooks.cancel(book)
                }
            }
            if let title = defaults.string(forKey: "playMedia"), let item = media.items.first(where: { $0.title == title }) {
                start(item)
                // Test hook: -playMediaRate 1.5 sets the listening speed (it should be remembered for that audiobook).
                if let rate = Float(defaults.string(forKey: "playMediaRate") ?? "") { nowPlaying.playback?.rate = rate }
                // Test hook: -playMediaAt S jumps S seconds into it after a moment (to cross the finish line).
                if let at = Double(defaults.string(forKey: "playMediaAt") ?? "") {
                    try? await Task.sleep(for: .seconds(2))
                    nowPlaying.playback?.skip(at - (nowPlaying.playback?.current ?? 0))
                }
                // Test hook: -playMediaSleep M starts a sleep timer of M minutes (with the fade), to see the label and the volume.
                if let minutes = Int(defaults.string(forKey: "playMediaSleep") ?? "") { nowPlaying.playback?.setSleep(minutes: minutes) }
            }
            // Test hook: -startOverMedia "<title>" starts that item over 3 seconds in, as Start Over does.
            if let title = defaults.string(forKey: "startOverMedia"), let item = media.items.first(where: { $0.title == title }) {
                try? await Task.sleep(for: .seconds(3))
                start(item, true)
            }
            if let title = defaults.string(forKey: "detailMedia") { selected = media.items.first { $0.title == title } }
            if let value = defaults.string(forKey: "mediaFilter"), let value = MediaFilter(rawValue: value) { filter = value }
            #if os(macOS)
            // Test hooks: -findMedia "<request>" scans every listed place and asks; -organizeMedia 1 runs Organize with AI.
            if defaults.string(forKey: "findMedia") != nil { finding = true }
            if defaults.bool(forKey: "organizeMedia") || defaults.bool(forKey: "organizeOpen") { organizing = true }
            if KitLocation.testHome != nil, defaults.bool(forKey: "organizeApproveAll") { KitCatalog.shared.reload(library); KitCatalog.shared.approveAll(kind: nil); media.applyCatalog(library: library) }
            // Test hook: -importMedia "/a.mp4|/b.mp4" imports each file in its own task, close together (as two quick adds would).
            if KitLocation.testHome != nil, let paths = defaults.string(forKey: "importMedia") {
                try? await Task.sleep(for: .seconds(3))
                for path in paths.split(separator: "|") {
                    Task { try? await media.importFiles([URL(fileURLWithPath: String(path))], library: library) }
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
            // Test hook: -setCover "Title|/picture.jpg" sets that item's cover art 8 seconds in, as Choose Cover Art… does.
            if KitLocation.testHome != nil, let value = defaults.string(forKey: "setCover"), let bar = value.firstIndex(of: "|") {
                try? await Task.sleep(for: .seconds(8))
                if let item = media.items.first(where: { $0.title == String(value[..<bar]) }) {
                    try? MediaCover.set(URL(fileURLWithPath: String(value[value.index(after: bar)...])), for: item)
                    await media.reload(library: library)
                }
            }
            #endif
            #endif
        }
        // Dropped files go through the window-wide drop sheet (see DropImport), which asks where each one belongs.
        .fileImporter(isPresented: $importing, allowedContentTypes: importTypes, allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else {
                if case .failure(let error) = result { importError = error.localizedDescription }
                return
            }
            #if os(macOS)
            // The same Copy or Move sheet as a drop: each file lands in this section's folder, and duplicates are caught.
            if let dropImporter { dropImporter.receive(urls, section: importSection); return }
            #endif
            Task {
                do {
                    let already = try await media.importFiles(urls, into: importSubfolder, library: library)
                    if already > 0 { importError = already == urls.count ? "\(already == 1 ? "That file is" : "Those files are") already in your kit." : "\(already) of the files were already in your kit, so they weren’t copied again." }
                } catch { importError = error.localizedDescription }
            }
        }
        .onChange(of: nowPlaying.collapseRequest) { playing = nil }
        .alert("Couldn’t add files", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) { Button("OK") { importError = nil } } message: { Text(importError ?? "") }
    }

    // MARK: Adding

    /// What + can pick in this section.
    private var importTypes: [UTType] {
        let video: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie]
        let audio: [UTType] = [.audio, .mp3, .mpeg4Audio]
        let books: [UTType] = [.epub, .pdf]
        switch filter {
        case .video: return video
        case .audiobooks: return audio + [.folder]
        case .music: return audio + [.folder]
        case .books: return books
        case .all: return video + audio + books
        }
    }
    #if os(macOS)
    private var importSection: ImportKind? {
        switch filter {
        case .video: .video
        case .audiobooks: .audiobook
        case .music: .audio
        case .books: .book
        case .all: nil
        }
    }
    #endif
    /// The Media subfolder + copies into on iPhone and iPad.
    private var importSubfolder: String {
        switch filter {
        case .audiobooks: "Audiobooks"
        case .music: "Music"
        case .books: "Books"
        case .video, .all: ""
        }
    }
    private var addHelp: String {
        switch filter {
        case .video: "Add videos from this Mac"
        case .audiobooks: "Add audiobook files or folders"
        case .music: "Add songs or album folders"
        case .books: "Add EPUB or PDF books"
        case .all: "Add videos, audio or books"
        }
    }

    @ViewBuilder private func player(_ item: MediaItem) -> some View {
        if item.kind == .book { BookReaderView(item: item) } else { MediaPlayerView(item: item, advance: { start($0, false, nil) }) }
    }

    private var content: some View {
        Group {
            if let selected {
                MediaItemDetail(item: selected, open: { self.selected = $0 }, play: start, close: { self.selected = nil })
                    .toolbar { ToolbarItem(placement: .navigation) { Button("Back", systemImage: "chevron.left") { self.selected = nil } } }
            } else { home }
        }
        .background { MediaForestBackground() }
        .mediaCoverPicker()
        .foregroundStyle(MediaTheme.ink)
        .tint(MediaTheme.accent)
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        .overlay(alignment: .bottom) { SendNoticeBanner() }
        #endif
        #if os(iOS)
        // The page has its own big title; a second one in the navigation bar showed twice once the picture reached the top.
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        #else
        .navigationTitle(title)
        #endif
        .toolbar {
            // A rescan with things already showing: a small spinner, so a change that's on its way doesn't look missed.
            ToolbarItem {
                if media.scanning && media.hasScanned {
                    ProgressView().controlSize(.small).help("Checking your media folders for changes…")
                }
            }
            #if os(macOS)
            ToolbarItem { Button("Find My Media", systemImage: "sparkle.magnifyingglass") { finding = true }.labelStyle(.titleAndIcon).help("Look through this Mac’s folders and drives for media to add") }
            ToolbarItem { Button("Organize", systemImage: "sparkles") { organizing = true }.labelStyle(.titleAndIcon).help("Organize with AI: fill in genre, studio, year and series, with a review before anything changes") }
            #endif
            ToolbarItem { Button("Add", systemImage: "plus") { importing = true }.labelStyle(.titleAndIcon).help(addHelp) }
        }
        #if os(macOS)
        .sheet(isPresented: $finding) { FindMediaSheet(startKind: findKind) }
        .sheet(isPresented: $organizing) { OrganizeSheet(startScope: organizeScope) }
        #endif
        .alert("Not connected", isPresented: Binding(get: { unavailableMessage != nil }, set: { if !$0 { unavailableMessage = nil } })) {
            Button("OK") { unavailableMessage = nil }
        } message: { Text(unavailableMessage ?? "") }
    }

    #if os(macOS)
    private var findKind: FoundMedia.Kind? {
        switch filter { case .video: .video; case .music: .music; case .audiobooks: .audiobook; case .books: .book; case .all: nil }
    }
    #endif
    private var organizeScope: CatalogKind? {
        switch filter { case .video: .video; case .music: .music; case .audiobooks: .audiobook; case .books: .book; case .all: nil }
    }

    /// Nothing of this section's kind in the kit yet (the starter books don't count for Watch, Audiobooks or Music).
    private var sectionIsEmpty: Bool {
        d.sectionIsEmpty
    }

    /// Nothing of this kind yet and nothing being searched for: the collection card is the whole screen.
    private var showingWelcome: Bool { sectionIsEmpty && appliedQuery.isEmpty && genre == nil }
    private var firstScan: Bool { media.scanning || !media.hasScanned }

    private var home: some View {
        ScrollViewReader { proxy in
        HitPausingScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                controls.padding(.horizontal, 24).padding(.top, 24)
                if let artist {
                    HStack { Button("Artists", systemImage: "chevron.left") { self.artist = nil }; Spacer() }.padding(.horizontal, 24)
                    Text(artist).font(.largeTitle.bold()).padding(.horizontal, 24)
                }
                if let collection {
                    HStack { Button("All shelves", systemImage: "chevron.left") { self.collection = nil }; Spacer() }.padding(.horizontal, 24)
                    Text(collection.title).font(.title.bold()).padding(.horizontal, 24)
                }
                if showingWelcome {
                    // Still reading the folders (a big library on a drive takes a moment): placeholders, not "nothing here".
                    if firstScan { loadingSkeleton }
                } else if filter == .music && musicBrowse == .artists && artist == nil {
                    artists
                } else if filter == .music && musicBrowse == .songs {
                    songList
                } else if filter == .music && musicBrowse == .genres && genre == nil {
                    genreGrid
                } else if browsing {
                    results
                } else {
                    let catalog = d.catalog
                    if let featured = catalog.featured {
                        MediaFeaturedBanner(item: featured, play: { start(featured, $0, nil) }, detail: { selected = featured })
                            .padding(.horizontal, 24)
                    }
                    ForEach(Array(catalog.shelves.enumerated()), id: \.element.id) { place, shelf in
                        // Only the shelves on the opening screen fade in; ones scrolled to later just appear.
                        MediaShelfRow(shelf: shelf, open: { selected = $0 }, seeAll: { collection = shelf }, animated: place < 4)
                    }
                }
                // (`filtered` sorts everything, so it is only asked when a search, genre or filter could have emptied it.)
                if !showingWelcome && (!appliedQuery.isEmpty || genre != nil) && filtered.isEmpty {
                    ContentUnavailableView.search(text: appliedQuery.isEmpty ? genre ?? "" : appliedQuery).padding()
                } else if !showingWelcome && unfinished && filtered.isEmpty {
                    ContentUnavailableView("Nothing unfinished", systemImage: "checkmark.circle",
                                           description: Text("Everything here is either finished or not started yet.")).padding()
                }
                if !(showingWelcome && firstScan) { collectionCard(proxy, prominent: showingWelcome) }
            }
            .padding(.bottom, 32)
            .animation(Motion.gentle(reduceMotion), value: genre)
            .animation(Motion.gentle(reduceMotion), value: filter)
            .animation(Motion.gentle(reduceMotion), value: musicBrowse)
            .animation(Motion.gentle(reduceMotion), value: collection?.id)
            .animation(Motion.gentle(reduceMotion), value: artist)
            .animation(Motion.gentle(reduceMotion), value: showingWelcome)
        }
        .refreshable { await media.reload(library: library) }
        }
    }

    /// Placeholders in the shape of the screen while the folders are first read: a banner, a title and a shelf.
    private var loadingSkeleton: some View {
        let card: (width: CGFloat, height: CGFloat, count: Int) = switch filter {
        case .video: (272, 153, 4)
        case .music: (180, 180, 5)
        default: (152, 228, 5)
        }
        return VStack(alignment: .leading, spacing: 22) {
            SkeletonBlock(height: 220, corner: 18)
            SkeletonBlock(width: 170, height: 22, corner: 6)
            SkeletonShelf(count: card.count, cardWidth: card.width, cardHeight: card.height)
                .frame(maxWidth: .infinity, alignment: .leading).clipped()
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Looking through your media")
    }

    // MARK: Add to your collection

    /// The heading and plain line for this section when it has nothing yet.
    private var welcome: (symbol: String, heading: String) {
        switch filter {
        case .audiobooks: ("headphones", "No audiobooks yet")
        case .music: ("music.note", "No music yet")
        case .books: ("book", "No books yet")
        case .video: ("film", "No movies yet")
        case .all: ("play.rectangle.on.rectangle", "Make room for a good story.")
        }
    }
    private var freeDetail: String {
        switch filter {
        case .video: "Free films to download and keep"
        case .audiobooks: "Free classics read by LibriVox volunteers"
        case .music: "Free music to download and keep"
        case .books: "Free public domain books"
        case .all: "Free films, audiobooks and books"
        }
    }

    /// Always visible. Three ways in: files, Find My Media, and the free sources. Empty sections show it large, with
    /// the section's welcome on top; a section with things in it shows it small at the bottom.
    private func collectionCard(_ proxy: ScrollViewProxy, prominent: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: prominent ? 20 : 16, style: .continuous)
        #if os(macOS)
        let dropLine = "Drop files here, or pick a way to add them."
        #else
        let dropLine = "Pick a way to add them."
        #endif
        return VStack(alignment: .leading, spacing: prominent ? 24 : 16) {
            if prominent {
                VStack(spacing: 10) {
                    Image(systemName: welcome.symbol).font(.system(size: 46)).foregroundStyle(MediaTheme.accent).accessibilityHidden(true)
                    Text(welcome.heading).font(.title2.bold())
                    Text("\(dropLine) Everything stays on this device and plays without internet.")
                        .foregroundStyle(MediaTheme.muted).multilineTextAlignment(.center).frame(maxWidth: 460)
                }.frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add to your collection").font(.title3.bold())
                    Text(dropLine).font(.callout).foregroundStyle(MediaTheme.muted)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { addChoices(proxy) }.fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 10) { addChoices(proxy) }
            }
            if more {
                VStack(alignment: .leading, spacing: 22) {
                    if filter == .all || filter == .video || filter == .books { StarterPackCard() }
                    if filter == .all || filter == .audiobooks { librivoxCard }
                    findMore
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(prominent ? 28 : 20)
        .frame(maxWidth: .infinity)
        .background(MediaTheme.surface, in: shape)
        .overlay(shape.strokeBorder(dropTargeted ? MediaTheme.accent : .white.opacity(0.08),
                                    style: StrokeStyle(lineWidth: dropTargeted ? 2.5 : 0.5, dash: dropTargeted ? [9, 6] : [])))
        .animation(Motion.gentle(reduceMotion), value: dropTargeted)
        .animation(Motion.gentle(reduceMotion), value: more)
        .padding(.horizontal, 24)
        .id("more")
        #if os(macOS)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let dropImporter else { return false }
            let section = importSection
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await Self.fileURL(from: provider) { urls.append(url) }
                }
                if !urls.isEmpty { dropImporter.receive(urls, section: section) }
            }
            return true
        }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add to your collection")
    }

    #if os(macOS)
    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
    #endif

    @ViewBuilder private func addChoices(_ proxy: ScrollViewProxy) -> some View {
        AddChoice(symbol: "plus.circle.fill", title: "Add files", detail: addHelp) { importing = true }
        #if os(macOS)
        AddChoice(symbol: "sparkle.magnifyingglass", title: "Find My Media", detail: "Look through this Mac’s folders and drives") { finding = true }
        #endif
        AddChoice(symbol: "arrow.down.circle.fill", title: "Free sources", detail: freeDetail, chevron: more ? "chevron.up" : "chevron.down", selected: more) {
            withAnimation(Motion.gentle(reduceMotion)) { more.toggle() }
            if more { Task { try? await Task.sleep(for: .milliseconds(200)); withAnimation(Motion.gentle(reduceMotion)) { proxy.scrollTo("more", anchor: .top) } } }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { Text(title).font(.title.bold()); Spacer(); searchField.frame(minWidth: 200, maxWidth: 360) }
                VStack(alignment: .leading, spacing: 14) { Text(title).font(.largeTitle.bold()); searchField }
            }
            if section == nil {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(MediaFilter.allCases) { option in
                        Button { withAnimation(Motion.gentle(reduceMotion)) { filter = option } } label: { Text(option.label).font(.callout.weight(.semibold)).padding(.horizontal, 17).padding(.vertical, 10) }
                            .buttonStyle(.plain).background(filter == option ? MediaTheme.accent : MediaTheme.surface, in: Capsule())
                            .foregroundStyle(filter == option ? MediaTheme.canvas : MediaTheme.ink)
                            .accessibilityAddTraits(filter == option ? .isSelected : [])
                    }
                }
            }
            // The chips scroll to the screen's edge, not to the page margin where "Music" and "Books" were cut off.
            .scrollClipDisabled()
            }
            if filter == .music {
                Picker("Browse music", selection: $musicBrowse) { ForEach(MusicBrowse.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).onChange(of: musicBrowse) { artist = nil; genre = nil }
            }
            if filter != .all {
                let names = d.genreNames
                if !names.isEmpty {
                    let counts = d.genreCounts
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(names, id: \.self) { name in
                                GenreTile(name: name, count: counts[name] ?? 0, selected: genre == name) { toggleGenre(name) }
                            }
                        }.padding(.vertical, 8).padding(.horizontal, 2)
                    }
                    .scrollClipDisabled()
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack { genrePicker; Spacer(); sorting }
                VStack(alignment: .leading, spacing: 12) { genrePicker; sorting }
            }
        }
    }
    private var searchField: some View {
        TextField("Search titles, artists and genres", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("Search \(title)")
    }
    /// Tiles are the way to pick a genre wherever they show (every section but All); the menu only stands in for them there.
    @ViewBuilder private var genrePicker: some View {
        let names = d.genreNames
        if filter == .all && !names.isEmpty {
            Menu {
                Button("All genres") { setGenre(nil) }
                ForEach(names, id: \.self) { name in Button(name, systemImage: GenreIcon.symbol(for: name)) { setGenre(name) } }
            } label: { Label(genre ?? "Browse genres", systemImage: genre.map(GenreIcon.symbol(for:)) ?? "square.grid.2x2").font(.callout) }
            .accessibilityLabel("Genre: \(genre ?? "All genres")")
        } else { Color.clear.frame(width: 0, height: 0) }
    }
    /// A tile or menu pick: choosing the genre that's already chosen clears it.
    private func toggleGenre(_ name: String) { setGenre(genre == name ? nil : name) }
    private func setGenre(_ name: String?) {
        withAnimation(Motion.gentle(reduceMotion)) { genre = name; collection = nil }
    }
    private var sorting: some View {
        HStack {
            if filter != .music { Toggle("Unfinished", isOn: $unfinished).toggleStyle(.button).font(.callout) }
            Menu {
                Picker("Sort by", selection: $sort) { ForEach(MediaSort.allCases) { Text($0.label).tag($0) } }
            } label: { Label(sort.label, systemImage: "arrow.up.arrow.down").font(.callout) }
            .accessibilityLabel("Sort by \(sort.label)")
        }
    }
    private var visibleItems: [MediaItem] { d.visibleItems }
    private var results: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(genre ?? (filter == .music ? (artist == nil ? "Albums" : "Albums by \(artist!)") : "Your collection")).font(.title2.bold())
                Spacer(); Text("\(visibleItems.count) \(visibleItems.count == 1 ? "item" : "items")").font(.callout).foregroundStyle(MediaTheme.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : (filter == .music || filter == .audiobooks ? 140 : 240)), spacing: 18)], alignment: .leading, spacing: 24) {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    Button { selected = item } label: { MediaCard(item: item, info: media.info[item.progressKey], progress: media.progress[item.progressKey]) }
                        .buttonStyle(.plain).mediaCardMenu(item)
                        .appearFade(delay: min(Double(index), 8) * 0.03, enabled: index < 24)
                }
            }
        }.padding(.horizontal, 24)
    }
    private var artists: some View {
        return LazyVStack(spacing: 10) {
            ForEach(d.artists) { group in
                let name = group.name
                Button { artist = name } label: {
                    HStack(spacing: 16) {
                        if let item = group.albums.first { MediaArtwork(item: item, info: media.info[item.progressKey]).frame(width: 64, height: 64).clipShape(Circle()) }
                        VStack(alignment: .leading) { Text(name).font(.headline); Text("\(group.albums.count) albums · \(group.songCount) songs").font(.caption).foregroundStyle(MediaTheme.muted) }.flattenedText()
                        Spacer(); Image(systemName: "chevron.right")
                    }.padding(14).background(MediaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 24)
    }
    private var songList: some View {
        LazyVStack(spacing: 0) {
            ForEach(d.songs) { song in
                let item = song.item
                let index = song.index
                Button { start(item, false, index) } label: {
                    HStack(spacing: 14) {
                        MediaArtwork(item: item, info: media.info[item.progressKey]).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 7))
                        let info = media.info[item.progressKey]
                        // The row's text in one drawing group (one GPU surface per row, not one per Text).
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) { Text(MediaCatalog.trackTitle(item, info, index)); Text("\(MediaCatalog.creator(info)) · \(MediaCatalog.title(item, info))").font(.caption).foregroundStyle(MediaTheme.muted) }
                            Spacer()
                            if let details = info?.tracks, details.indices.contains(index), let duration = details[index].duration { Text(MediaTheme.time(duration)).font(.caption).foregroundStyle(MediaTheme.muted) }
                        }.flattenedText()
                        Image(systemName: "play.fill").foregroundStyle(MediaTheme.accent)
                    }.padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
        }.padding(.horizontal, 24)
    }
    private var genreGrid: some View {
        let counts = d.genreCounts
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 14) {
            ForEach(d.genreNames, id: \.self) { name in
                GenreTile(name: name, count: counts[name] ?? 0, noun: "album", selected: genre == name, width: nil) { toggleGenre(name) }
            }
        }.padding(.horizontal, 24)
    }
    private func start(_ item: MediaItem, _ fromStart: Bool = false, _ track: Int? = nil) {
        if let place = item.unavailable {
            unavailableMessage = item.isMissingLocally
                ? "“\(item.title)” is linked to a \(place == "its file" ? "file" : "folder") that isn’t there right now. Open its details and choose Locate… if it moved."
                : "“\(item.title)” is kept on \(place). Connect \(place) to play it here."
            return
        }
        if item.kind == .book {
            // Start Over opens the book at the beginning.
            if fromStart { offerUndo(for: item); media.saveProgress(MediaProgress(track: 0, seconds: 0), for: item) }
        } else {
            if fromStart { nowPlaying.close(); offerUndo(for: item); media.saveProgress(MediaProgress(track: 0, seconds: 0), for: item) }
            nowPlaying.open(item, library: media, autoplay: true)
            if let track { if track == -1 { nowPlaying.playback?.shuffle() } else { nowPlaying.playback?.load(track: track, play: true) } }
        }
        playing = item
    }
    /// Start Over throws away a long place (hours into an audiobook). Keep it for a few seconds so Undo can bring it back.
    private func offerUndo(for item: MediaItem) {
        guard let previous = media.progress[item.progressKey], MediaCatalog.isInProgress(previous, kind: item.kind) else { undoOffer = nil; return }
        let offer = StartOverUndo(item: item, previous: previous)
        undoOffer = offer
        Task {
            try? await Task.sleep(for: .seconds(10))
            if undoOffer?.id == offer.id { undoOffer = nil }
        }
    }

    private func undoStartOver(_ offer: StartOverUndo) {
        undoOffer = nil
        let item = offer.item
        if item.kind == .book {
            // Close the reader first (it saves where it is when it goes), then put the old place back and reopen.
            playing = nil
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                media.saveProgress(offer.previous, for: item, stopped: true)
                playing = item
            }
        } else {
            nowPlaying.close()
            media.saveProgress(offer.previous, for: item, stopped: true)
            nowPlaying.open(item, library: media, autoplay: true)
        }
    }

    private var undoToast: some View {
        Group { undoToastContent }.animation(Motion.gentle(reduceMotion), value: undoOffer?.id)
    }

    @ViewBuilder private var undoToastContent: some View {
        if let offer = undoOffer {
            HStack(spacing: 14) {
                Text("Started “\(MediaCatalog.displayTitle(offer.item.title))” over").lineLimit(1)
                Button("Undo") { undoStartOver(offer) }.buttonStyle(.borderedProminent).controlSize(.small)
                    .accessibilityHint("Goes back to where you were")
            }
            .font(.callout)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(MediaTheme.surface, in: Capsule())
            .overlay(Capsule().strokeBorder(MediaTheme.muted.opacity(0.3), lineWidth: 0.5))
            .foregroundStyle(MediaTheme.ink).tint(MediaTheme.accent)
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
            .padding(.bottom, 90)   // above the mini player
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            .accessibilityElement(children: .contain)
        }
    }

    private func openRequested() {
        guard let item = nowPlaying.expandRequest else { return }
        nowPlaying.expandRequest = nil; playing = item
    }
    private var findMore: some View {
        FindMoreCard(title: "Where to find more",
                     intro: "Free films, audiobooks, music and books you can download once and keep. Drag them onto this window, or use +.",
                     links: (FindMore.watchAndListen + FindMore.books).filter { link in
                         switch filter {
                         case .video: ["Internet Archive films", "Blender Studio films"].contains(link.title)
                         case .audiobooks: link.title == "LibriVox"
                         case .music: link.title == "Musopen"
                         case .books: FindMore.books.contains { $0.id == link.id }
                         case .all: true
                         }
                     },
                     footnote: "Your own files work too: MP4, MOV, MP3, M4A, M4B, FLAC, EPUB and PDF. Movies and books bought from stores are usually locked to their own apps and won’t open here. These links open in your browser and need internet.")
    }

    private var librivoxCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "headphones")
                    .font(.title3).foregroundStyle(.tint)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free audiobooks for kids").font(.headline)
                    Text("Classic stories read by LibriVox volunteers, in the public domain in the US. Needs internet to download, then plays offline.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            ForEach(LibriVoxBook.picks) { book in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(book.title)
                        Text("\(book.author) · \(book.duration) · ages \(book.ages)").font(.caption).foregroundStyle(.secondary)
                        if case .failed(let reason)? = audiobooks.states[book.id], !audiobooks.isInstalled(book) {
                            Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer(minLength: 12)
                    trailing(book)
                }
                .padding(.vertical, 2)
            }
        }
        .card(padding: 18)
    }

    private func cancelButton(_ book: LibriVoxBook) -> some View {
        Button("Cancel") { audiobooks.cancel(book) }.buttonStyle(.bordered).controlSize(.small)
            .accessibilityLabel("Cancel download of \(book.title)")
    }

    @ViewBuilder private func trailing(_ book: LibriVoxBook) -> some View {
        if audiobooks.isInstalled(book) {
            Pill(text: "Saved", symbol: "checkmark", tint: .accentColor)
        } else {
            switch audiobooks.states[book.id] {
            case .queued:
                HStack(spacing: 8) { Pill(text: "Waiting", symbol: "clock"); cancelButton(book) }
            case .downloading(let f):
                HStack(spacing: 8) { Pill(text: "\(Int(f * 100))%", symbol: "arrow.down", tint: .accentColor); cancelButton(book) }
            case .failed: Button("Retry") { audiobooks.get(book) }.buttonStyle(.bordered)
            default:
                Button("Get · \(ByteCountFormatter.string(fromByteCount: book.estimatedBytes, countStyle: .file))") { audiobooks.get(book) }
                    .buttonStyle(.bordered)
            }
        }
    }
}

/// Remembers the last result of the library work for the current inputs, so a redraw that changes none of them
/// (hovering, scrolling, a progress tick elsewhere) costs a comparison, not a filter and sort of every item.
@MainActor
final class WatchListenCache {
    struct Key: Hashable {
        let revision: Int
        let filter: MediaFilter
        let genre: String?
        let query: String
        let sort: MediaSort
        let unfinished: Bool
        let artist: String?
        let collectionID: String?
    }
    static let shared = WatchListenCache()
    private var values: [Key: WatchListenDerived] = [:]
    private var revision = -1

    func derived(_ key: Key, make: () -> WatchListenDerived) -> WatchListenDerived {
        // Anything worked out for an older library is out of date: keep only the current revision's.
        if key.revision != revision { values.removeAll(); revision = key.revision }
        if let value = values[key] { return value }
        let made = make()
        if values.count >= 24 { values.removeAll() }
        values[key] = made
        return made
    }

    /// The key a section's opening screen asks for (no genre, search, artist or shelf; sorted by title).
    static func openingKey(revision: Int, filter: MediaFilter) -> Key {
        Key(revision: revision, filter: filter, genre: nil, query: "", sort: .title, unfinished: false, artist: nil, collectionID: nil)
    }

    /// Works out each section's opening lists off the main thread once the library has settled, so the first visit to
    /// Watch, Audiobooks, Music or Books finds them ready instead of filtering, grouping and sorting while it opens.
    func prewarm(_ media: MediaLibrary, filters: [MediaFilter]) async {
        let revision = media.revision, items = media.items, info = media.info, progress = media.progress
        guard !items.isEmpty else { return }
        let wanted = filters.filter { values[Self.openingKey(revision: revision, filter: $0)] == nil }
        guard !wanted.isEmpty else { return }
        let started = Date()
        let seeds = await Task.detached(priority: .utility) {
            wanted.map { (filter: $0, seed: WatchListenDerived.seed(items: items, info: info, progress: progress, filter: $0)) }
        }.value
        #if DEBUG
        NSLog("PREWARM %d sections, revision %d, %.0f ms in the background", seeds.count, revision, Date().timeIntervalSince(started) * 1000)
        #endif
        // A newer library arrived meanwhile: these are already out of date.
        guard !Task.isCancelled, media.revision == revision else { return }
        if revision != self.revision { values.removeAll(); self.revision = revision }
        for (filter, seed) in seeds {
            let key = Self.openingKey(revision: revision, filter: filter)
            guard values[key] == nil else { continue }
            if values.count >= 24 { values.removeAll() }
            values[key] = WatchListenDerived(items: items, info: info, progress: progress, filter: filter, genre: nil, query: "",
                                             sort: .title, unfinished: false, artist: nil, collection: nil, seed: seed)
        }
    }
}

/// Fills WatchListenCache in the background a moment after the media library changes (see `prewarm`). Lives in the
/// window's root view, beside the sections, and reads only the library's revision.
struct WatchListenPrewarm: ViewModifier {
    let filters: [MediaFilter]
    @Environment(MediaLibrary.self) private var media
    func body(content: Content) -> some View {
        content.task(id: media.revision) {
            // Waits for the library to settle (a first scan hands details over in batches) and for launch to finish.
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, media.hasScanned else { return }
            await WatchListenCache.shared.prewarm(media, filters: filters)
        }
    }
}

extension View {
    /// Works out the Watch & Listen sections' opening lists in the background (see WatchListenPrewarm).
    /// `filters`: the sections this window shows (the sidebar's four, or the phone's single Watch tab).
    func prewarmWatchListen(_ filters: [MediaFilter]) -> some View { modifier(WatchListenPrewarm(filters: filters)) }
}

/// A section's opening lists, worked out off the main thread (see WatchListenCache.prewarm).
struct WatchListenSeed: Sendable {
    var filtered: [MediaItem]?
    var catalog: (featured: MediaItem?, shelves: [MediaShelf])?
    var genreNames: [String]
    var genreCounts: [String: Int]
    var sectionIsEmpty: Bool
}

struct ArtistGroup: Identifiable {
    let name: String
    let albums: [MediaItem]
    let songCount: Int
    var id: String { name }
}

/// The lists Watch & Listen shows, each worked out the first time a screen asks for it and then kept.
@MainActor
final class WatchListenDerived {
    private let items: [MediaItem]
    private let info: [String: MediaInfo]
    private let progress: [String: MediaProgress]
    private let filter: MediaFilter
    private let genre: String?
    private let query: String
    private let sort: MediaSort
    private let unfinished: Bool
    private let artist: String?
    private let collection: MediaShelf?

    init(items: [MediaItem], info: [String: MediaInfo], progress: [String: MediaProgress], filter: MediaFilter, genre: String?,
         query: String, sort: MediaSort, unfinished: Bool, artist: String?, collection: MediaShelf?, seed: WatchListenSeed? = nil) {
        self.items = items; self.info = info; self.progress = progress; self.filter = filter; self.genre = genre
        self.query = query; self.sort = sort; self.unfinished = unfinished; self.artist = artist; self.collection = collection
        if let seed {
            if let filtered = seed.filtered { self.filtered = filtered }
            if let catalog = seed.catalog { self.catalog = catalog }
            genreNames = seed.genreNames
            genreCounts = seed.genreCounts
            sectionIsEmpty = seed.sectionIsEmpty
        }
    }

    /// What the opening screen of `filter` reads, worked out the same way as the lazy values below. Music opens on
    /// its album grid (the filtered list); the others on shelves.
    nonisolated static func seed(items: [MediaItem], info: [String: MediaInfo], progress: [String: MediaProgress], filter: MediaFilter) -> WatchListenSeed {
        let grid = filter == .music
        return WatchListenSeed(
            filtered: grid ? MediaCatalog.select(items, info: info, progress: progress, filter: filter, genre: nil, query: "", sort: .title, unfinished: false) : nil,
            catalog: grid ? nil : MediaCatalog.build(items: items, progress: progress, info: info, filter: filter),
            genreNames: MediaCatalog.genres(items, info: info, filter: filter),
            genreCounts: MediaCatalog.genreCounts(items, info: info, filter: filter),
            sectionIsEmpty: filter == .all ? items.isEmpty : !items.contains { MediaCatalog.category($0, info[$0.progressKey]) == filter })
    }

    /// The filtered and sorted library.
    lazy var filtered: [MediaItem] = MediaCatalog.select(items, info: info, progress: progress, filter: filter, genre: genre,
                                                         query: query, sort: sort, unfinished: unfinished)
    /// The featured banner and shelves of the home screen.
    lazy var catalog: (featured: MediaItem?, shelves: [MediaShelf]) = MediaCatalog.build(items: items, progress: progress, info: info, filter: filter)
    lazy var genreNames: [String] = MediaCatalog.genres(items, info: info, filter: filter)
    lazy var genreCounts: [String: Int] = MediaCatalog.genreCounts(items, info: info, filter: filter)
    lazy var sectionIsEmpty: Bool = filter == .all ? items.isEmpty : !items.contains { MediaCatalog.category($0, info[$0.progressKey]) == filter }
    lazy var visibleItems: [MediaItem] = {
        let source = collection?.items ?? filtered
        guard let artist else { return source }
        return source.filter { MediaCatalog.creator(info[$0.progressKey]) == artist }
    }()
    /// Artists with their albums, one pass over the albums (not one per artist).
    lazy var artists: [ArtistGroup] = {
        let groups = Dictionary(grouping: filtered) { MediaCatalog.creator(info[$0.progressKey]) }
        return groups.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { name in
            let albums = groups[name] ?? []
            return ArtistGroup(name: name, albums: albums, songCount: albums.reduce(0) { $0 + $1.tracks.count })
        }
    }()
    lazy var songs: [MediaSong] = MediaCatalog.songs(filtered, info: info, query: query, sort: sort)
}

/// A genre or category tile: its symbol, name and count on the poster gradient. The chosen one gets an accent edge and a check.
private struct GenreTile: View {
    let name: String
    let count: Int
    var noun = "item"
    let selected: Bool
    var width: CGFloat? = 150
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var symbol: String { GenreIcon.symbol(for: name) }
    private var countText: String { "\(count) \(noun)\(count == 1 ? "" : "s")" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button(action: action) {
            ZStack {
                // Opacity on the view, not the color: some symbols (waveform, paintpalette) ignored a faint color
                // and drew solid white.
                Image(systemName: symbol).font(.system(size: 62, weight: .semibold))
                    .symbolRenderingMode(.monochrome).foregroundStyle(.white)
                    .opacity(selected ? 0.2 : 0.12)
                    .offset(x: 16, y: 16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Image(systemName: symbol).font(.title3.weight(.semibold)).opacity(0.92)
                        Spacer()
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(MediaTheme.accent).transition(.opacity) }
                    }
                    Spacer(minLength: 4)
                    Text(name).font(.headline).lineLimit(1)
                    Text(countText).font(.caption).opacity(0.85)
                }.padding(12)
            }
            .flattenedText()
            .frame(minWidth: width, maxWidth: width ?? .infinity, minHeight: 96, maxHeight: 96)
            .foregroundStyle(.white)
            .background(LinearGradient(colors: MediaTheme.posterColors(name), startPoint: .topLeading, endPoint: .bottomTrailing), in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(selected ? MediaTheme.accent : .white.opacity(0.15), lineWidth: selected ? 2 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .hoverLift()
        .animation(Motion.gentle(reduceMotion), value: selected)
        .accessibilityLabel("\(name), \(countText)")
        .accessibilityHint(selected ? "Shows everything again" : "Shows only \(name)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One of the three ways to add to the collection.
private struct AddChoice: View {
    let symbol: String
    let title: String
    let detail: String
    var chevron: String? = nil
    var selected = false
    let action: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(MediaTheme.accent).frame(width: 36, height: 36)
                    .background(MediaTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(MediaTheme.muted).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if let chevron { Image(systemName: chevron).font(.caption.weight(.semibold)).foregroundStyle(MediaTheme.muted) }
            }
            .foregroundStyle(MediaTheme.ink)
            .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(MediaTheme.canvas.opacity(0.5), in: shape)
            .overlay(shape.strokeBorder(selected ? MediaTheme.accent : .white.opacity(0.12), lineWidth: selected ? 1.5 : 0.5))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .hoverLift(1.02)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
