import SwiftUI
import AVKit
import UniformTypeIdentifiers

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
    @Environment(\.dynamicTypeSize) private var typeSize
    #if os(macOS)
    /// The window's drop sheet; + sends its picks there too.
    @Environment(DropImporter.self) private var dropImporter: DropImporter?
    #endif

    init(section: MediaFilter? = nil) {
        self.section = section
        _filter = State(initialValue: section ?? .all)
    }

    private var title: String {
        switch section {
        case nil, .all?: "Watch"
        case .video?: "Watch"
        case let other?: other.label
        }
    }

    private var filtered: [MediaItem] {
        MediaCatalog.select(media.items, info: media.info, progress: media.progress, filter: filter,
                            genre: genre, query: query, sort: sort, unfinished: unfinished)
    }
    private var browsing: Bool { genre != nil || !query.isEmpty || sort != .title || unfinished || filter == .music || artist != nil || collection != nil }

    var body: some View {
        NavigationStack {
            #if os(macOS)
            if let playing {
                player(playing).toolbar { ToolbarItem(placement: .navigation) { Button(title, systemImage: "chevron.left") { self.playing = nil } } }
            } else { content }
            #else
            content.fullScreenCover(item: $playing) { item in
                NavigationStack { player(item).toolbar { ToolbarItem(placement: .topBarLeading) { Button("Minimize", systemImage: "chevron.down") { playing = nil } } } }
                    .environment(\.colorScheme, .dark).tint(MediaTheme.accent)
            }
            #endif
        }
        .onChange(of: filter) { genre = nil; artist = nil; collection = nil; selected = nil; sort = .title; query = "" }
        .onChange(of: nowPlaying.expandRequest) { openRequested() }
        .onAppear(perform: openRequested)
        .task {
            audiobooks.onFinished = { Task { await media.reload(library: library) } }
            await media.reloadIfStale(library: library)
            #if DEBUG
            let defaults = UserDefaults.standard
            if let book = LibriVoxBook.picks.first(where: { $0.id == defaults.integer(forKey: "getAudiobook") }) { audiobooks.get(book) }
            if let title = defaults.string(forKey: "playMedia"), let item = media.items.first(where: { $0.title == title }) { start(item) }
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
        .foregroundStyle(MediaTheme.ink)
        .tint(MediaTheme.accent)
        .environment(\.colorScheme, .dark)
        #if os(macOS)
        .overlay(alignment: .bottom) { SendNoticeBanner() }
        #endif
        .navigationTitle(title)
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
        filter == .all ? media.items.isEmpty : !media.items.contains { MediaCatalog.category($0, media.info[$0.progressKey]) == filter }
    }

    private var home: some View {
        ScrollViewReader { proxy in
        ScrollView {
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
                if filter == .music && musicBrowse == .artists && artist == nil {
                    artists
                } else if filter == .music && musicBrowse == .songs {
                    songList
                } else if filter == .music && musicBrowse == .genres && genre == nil {
                    genreGrid
                } else if browsing {
                    results
                } else {
                    let catalog = media.catalog(filter: filter)
                    if let featured = catalog.featured {
                        MediaFeaturedBanner(item: featured, play: { start(featured, $0, nil) }, detail: { selected = featured })
                            .padding(.horizontal, 24)
                    }
                    ForEach(catalog.shelves) { shelf in
                        MediaShelfRow(shelf: shelf, open: { selected = $0 }, seeAll: { collection = shelf })
                    }
                }
                if sectionIsEmpty && query.isEmpty && genre == nil && (media.scanning || !media.hasScanned) {
                    // Still reading the folders (a big library on a drive takes a moment): say so, not "nothing here".
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Looking through your media…").foregroundStyle(MediaTheme.ink.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else if sectionIsEmpty && query.isEmpty && genre == nil {
                    Group {
                        if filter == .all { emptyCard } else { sectionWelcome(proxy) }
                    }.padding(.horizontal, 24)
                } else if filtered.isEmpty && (!query.isEmpty || genre != nil) {
                    ContentUnavailableView.search(text: query.isEmpty ? genre ?? "" : query).padding()
                } else if filtered.isEmpty && unfinished {
                    ContentUnavailableView("Nothing unfinished", systemImage: "checkmark.circle",
                                           description: Text("Everything here is either finished or not started yet.")).padding()
                }
                DisclosureGroup("Add to your collection", isExpanded: $more) {
                    VStack(alignment: .leading, spacing: 22) {
                        if filter == .all || filter == .video || filter == .books { StarterPackCard() }
                        if filter == .all || filter == .audiobooks { librivoxCard }
                        #if os(macOS)
                        findMyMediaCard
                        #endif
                        findMore
                    }.padding(.top, 16)
                }
                .padding(20).background(MediaTheme.surface, in: RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 24)
                .id("more")
            }
            .padding(.bottom, 32)
        }
        .refreshable { await media.reload(library: library) }
        }
    }

    /// "No movies yet": what this section holds and the ways to add some.
    private func sectionWelcome(_ proxy: ScrollViewProxy) -> some View {
        let (symbol, heading, body, add, free): (String, String, String, String, String) = switch filter {
        case .audiobooks: ("headphones", "No audiobooks yet",
                           "Add your own audiobooks, or get free classics read by volunteers. They stay on this device and play without internet.",
                           "Add Audiobooks", "Get Free Audiobooks")
        case .music: ("music.note", "No music yet",
                      "Add songs and albums you already have, or find free music to keep. They stay on this device and play without internet.",
                      "Add Music", "Find Free Music")
        case .books: ("book", "No books yet",
                      "Add EPUB or PDF books, or get free classics. They stay on this device and open without internet.",
                      "Add Books", "Get Free Books")
        default: ("film", "No movies yet",
                  "Add your own movies and home videos, or get free films to keep. They stay on this device and play without internet.",
                  "Add Videos", "Get Free Films")
        }
        return VStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 48)).foregroundStyle(MediaTheme.accent).accessibilityHidden(true)
            Text(heading).font(.title2.bold())
            Text(body).foregroundStyle(MediaTheme.muted).multilineTextAlignment(.center).frame(maxWidth: 460)
            #if os(macOS)
            Text("You can also drag files onto this window.").font(.callout).foregroundStyle(MediaTheme.muted)
            #endif
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { welcomeActions(add: add, free: free, proxy: proxy) }
                VStack(spacing: 10) { welcomeActions(add: add, free: free, proxy: proxy) }
            }
        }
        .padding(28).frame(maxWidth: .infinity)
        .background(MediaTheme.surface, in: RoundedRectangle(cornerRadius: 18))
    }
    @ViewBuilder private func welcomeActions(add: String, free: String, proxy: ScrollViewProxy) -> some View {
        Button(add, systemImage: "plus") { importing = true }.buttonStyle(.borderedProminent)
        #if os(macOS)
        Button("Find My Media", systemImage: "sparkle.magnifyingglass") { finding = true }.buttonStyle(.bordered)
        #endif
        Button(free, systemImage: "arrow.down.circle") {
            more = true
            Task { try? await Task.sleep(for: .milliseconds(150)); withAnimation { proxy.scrollTo("more", anchor: .top) } }
        }.buttonStyle(.bordered)
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
                        Button { filter = option } label: { Text(option.label).font(.callout.weight(.semibold)).padding(.horizontal, 17).padding(.vertical, 10) }
                            .buttonStyle(.plain).background(filter == option ? MediaTheme.accent : MediaTheme.surface, in: Capsule())
                            .foregroundStyle(filter == option ? MediaTheme.canvas : MediaTheme.ink)
                            .accessibilityAddTraits(filter == option ? .isSelected : [])
                    }
                }
            }
            }
            if filter == .music {
                Picker("Browse music", selection: $musicBrowse) { ForEach(MusicBrowse.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).onChange(of: musicBrowse) { artist = nil; genre = nil }
            }
            if filter != .all && !MediaCatalog.genres(media.items, info: media.info, filter: filter).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(MediaCatalog.genres(media.items, info: media.info, filter: filter), id: \.self) { name in
                            let matching = media.items.filter { MediaCatalog.category($0, media.info[$0.progressKey]) == filter && media.info[$0.progressKey]?.genre == name }
                            Button { genre = genre == name ? nil : name; collection = nil } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(name).font(.headline)
                                    Text("\(matching.count) \(matching.count == 1 ? "item" : "items")").font(.caption)
                                }.frame(width: 130, height: 48, alignment: .bottomLeading).padding(12)
                                    .foregroundStyle(.white)
                                    .background(LinearGradient(colors: MediaTheme.posterColors(name), startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(genre == name ? MediaTheme.accent : .white.opacity(0.15), lineWidth: genre == name ? 2 : 0.5))
                            }.buttonStyle(.plain).accessibilityAddTraits(genre == name ? .isSelected : [])
                        }
                    }
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
    private var genrePicker: some View {
        Menu {
            Button("All genres") { genre = nil; collection = nil }
            ForEach(MediaCatalog.genres(media.items, info: media.info, filter: filter), id: \.self) { name in Button(name) { genre = name; collection = nil } }
        } label: { Label(genre ?? "Browse genres", systemImage: "square.grid.2x2").font(.callout) }
        .accessibilityLabel("Genre: \(genre ?? "All genres")")
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
    private var visibleItems: [MediaItem] {
        let source = collection?.items ?? filtered
        return artist.map { name in source.filter { MediaCatalog.creator(media.info[$0.progressKey]) == name } } ?? source
    }
    private var results: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(genre ?? (filter == .music ? (artist == nil ? "Albums" : "Albums by \(artist!)") : "Your collection")).font(.title2.bold())
                Spacer(); Text("\(visibleItems.count) \(visibleItems.count == 1 ? "item" : "items")").font(.callout).foregroundStyle(MediaTheme.muted)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 260 : (filter == .music || filter == .audiobooks ? 140 : 240)), spacing: 18)], alignment: .leading, spacing: 24) {
                ForEach(visibleItems) { item in
                    Button { selected = item } label: { MediaCard(item: item, info: media.info[item.progressKey], progress: media.progress[item.progressKey]) }
                        .buttonStyle(.plain).mediaCardMenu(item)
                }
            }
        }.padding(.horizontal, 24)
    }
    private var artists: some View {
        let names = Set(filtered.map { MediaCatalog.creator(media.info[$0.progressKey]) }).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return LazyVStack(spacing: 10) {
            ForEach(names, id: \.self) { name in
                let albums = filtered.filter { MediaCatalog.creator(media.info[$0.progressKey]) == name }
                Button { artist = name } label: {
                    HStack(spacing: 16) {
                        if let item = albums.first { MediaArtwork(item: item, info: media.info[item.progressKey]).frame(width: 64, height: 64).clipShape(Circle()) }
                        VStack(alignment: .leading) { Text(name).font(.headline); Text("\(albums.count) albums · \(albums.reduce(0) { $0 + $1.tracks.count }) songs").font(.caption).foregroundStyle(MediaTheme.muted) }
                        Spacer(); Image(systemName: "chevron.right")
                    }.padding(14).background(MediaTheme.surface, in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 24)
    }
    private var songList: some View {
        LazyVStack(spacing: 0) {
            ForEach(MediaCatalog.songs(filtered, info: media.info, query: query, sort: sort)) { song in
                let item = song.item
                let index = song.index
                Button { start(item, false, index) } label: {
                    HStack(spacing: 14) {
                        MediaArtwork(item: item, info: media.info[item.progressKey]).frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 7))
                        VStack(alignment: .leading, spacing: 4) { Text(MediaCatalog.trackTitle(item, media.info[item.progressKey], index)); Text("\(MediaCatalog.creator(media.info[item.progressKey])) · \(MediaCatalog.title(item, media.info[item.progressKey]))").font(.caption).foregroundStyle(MediaTheme.muted) }
                        Spacer()
                        if let details = media.info[item.progressKey]?.tracks, details.indices.contains(index), let duration = details[index].duration { Text(MediaTheme.time(duration)).font(.caption).foregroundStyle(MediaTheme.muted) }
                        Image(systemName: "play.fill").foregroundStyle(MediaTheme.accent)
                    }.padding(.vertical, 10).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
            }
        }.padding(.horizontal, 24)
    }
    private var genreGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 16) {
            ForEach(MediaCatalog.genres(media.items, info: media.info, filter: filter), id: \.self) { name in
                Button { genre = name } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "music.note.list").font(.title)
                        Text(name).font(.headline)
                        Text("\(filtered.filter { media.info[$0.progressKey]?.genre == name }.count) albums").font(.caption)
                    }.frame(maxWidth: .infinity, minHeight: 100, alignment: .leading).padding(20)
                        .background(MediaTheme.posterColors(name)[0], in: RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 24)
    }
    private var emptyCard: some View {
        VStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 22).fill(MediaTheme.accent.opacity(0.12)).frame(width: 170, height: 110).rotationEffect(.degrees(-6))
                Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 54)).foregroundStyle(MediaTheme.accent)
            }.accessibilityHidden(true)
            Text("Make room for a good story.").font(.title2.bold())
            Text("Add home videos, audiobooks or music with +. On Mac you can also drag files here. They stay on your device and play without internet.").foregroundStyle(MediaTheme.muted).multilineTextAlignment(.center)
            Button("Add Files", systemImage: "plus") { importing = true }.buttonStyle(.borderedProminent)
            #if os(macOS)
            Button("Find media already on this Mac", systemImage: "sparkle.magnifyingglass") { finding = true }
            #endif
            Button("Find free films and audiobooks") { more = true }
        }.padding(28).frame(maxWidth: .infinity).background(MediaTheme.surface, in: RoundedRectangle(cornerRadius: 18))
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
            if fromStart { media.saveProgress(MediaProgress(track: 0, seconds: 0), for: item) }
        } else {
            if fromStart { nowPlaying.close(); media.saveProgress(MediaProgress(track: 0, seconds: 0), for: item) }
            nowPlaying.open(item, library: media, autoplay: true)
            if let track { if track == -1 { nowPlaying.playback?.shuffle() } else { nowPlaying.playback?.load(track: track, play: true) } }
        }
        playing = item
    }
    private func openRequested() {
        guard let item = nowPlaying.expandRequest else { return }
        nowPlaying.expandRequest = nil; playing = item
    }
    #if os(macOS)
    private var findMyMediaCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkle.magnifyingglass").font(.title3).foregroundStyle(.tint).frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("Already have it somewhere?").font(.headline)
                Text("Find my media looks through this Mac’s Music, Movies, Downloads, Documents and Desktop folders, and drives you choose. Ask for what you want, like “my Beatles albums”, then keep it where it is, copy it or move it into the kit.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Find My Media", systemImage: "sparkle.magnifyingglass") { finding = true }.buttonStyle(.bordered)
            }
        }
        .card(padding: 18)
    }
    #endif

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
                    }
                    Spacer(minLength: 12)
                    trailing(book)
                }
                .padding(.vertical, 2)
            }
        }
        .card(padding: 18)
    }

    @ViewBuilder private func trailing(_ book: LibriVoxBook) -> some View {
        if audiobooks.isInstalled(book) {
            Pill(text: "Saved", symbol: "checkmark", tint: .accentColor)
        } else {
            switch audiobooks.states[book.id] {
            case .queued: Pill(text: "Waiting", symbol: "clock")
            case .downloading(let f): Pill(text: "\(Int(f * 100))%", symbol: "arrow.down", tint: .accentColor)
            case .failed: Button("Retry") { audiobooks.get(book) }.buttonStyle(.bordered)
            default:
                Button("Get · \(ByteCountFormatter.string(fromByteCount: book.estimatedBytes, countStyle: .file))") { audiobooks.get(book) }
                    .buttonStyle(.bordered)
            }
        }
    }
}
