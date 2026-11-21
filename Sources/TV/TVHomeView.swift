import SwiftUI

struct TVHomeView: View {
    @Environment(TVStore.self) private var store
    @State private var selected: TVItem?
    @State private var playing: TVPlayback?
    @State private var musicTab = "Albums"
    @State private var filter = "all"
    @State private var genre = ""
    @State private var sort = "title"
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 50) {
                    controls.padding(.horizontal, 80).padding(.top, 30)
                    if filter == "music" && musicTab == "Artists" { artists }
                    else if filter == "music" && musicTab == "Songs" { songs }
                    else if let featured = store.items.first(where: { $0.id == store.featuredID }) {
                        TVBanner(item: featured, play: { playing = $0 }, info: { selected = featured })
                    }
                    if filter == "music" && musicTab != "Albums" { EmptyView() }
                    else if store.shelves.isEmpty {
                        // An older Mac without rows: the simple layout.
                        let inProgress = store.items.filter(\.isInProgress)
                        let videos = store.items.filter { $0.kind == .video }
                        let audio = store.items.filter { $0.kind == .audio }
                        if !inProgress.isEmpty { shelf("Continue", inProgress) }
                        if !videos.isEmpty { shelf("Watch", videos) }
                        if !audio.isEmpty { shelf("Listen", audio) }
                    } else {
                        ForEach(store.shelves) { row in
                            shelf(row.title, row.items.compactMap { id in store.items.first { $0.id == id } })
                        }
                    }
                    if store.items.isEmpty { empty }
                    footer
                }
                .padding(.bottom, 40)
            }
            .background { MediaForestBackground() }
            .foregroundStyle(Color(red: 0.96, green: 0.96, blue: 0.90))
            .tint(Color(red: 0.70, green: 0.84, blue: 0.55))
            .environment(\.colorScheme, .dark)
            .navigationTitle("Watch")
        }
        .sheet(item: $selected) { item in
            TVItemDetail(item: item) { start in
                selected = nil
                playing = start
            }
        }
        .fullScreenCover(item: $playing) { playback in
            TVPlayerView(playback: playback)
        }
        .task(id: "\(filter)|\(genre)|\(sort)|\(query)") {
            store.filter = filter; store.genre = genre; store.sort = sort; store.query = query
            await store.refresh()
        }
        .onChange(of: playing) { if playing == nil { Task { await store.refresh() } } }
        #if DEBUG
        // Test hooks: -openItem <title> shows its detail; -playItem <title> starts it.
        .task {
            let defaults = UserDefaults.standard
            if let title = defaults.string(forKey: "openItem") { selected = store.items.first { $0.title == title } }
            if let title = defaults.string(forKey: "playItem"), let item = store.items.first(where: { $0.title == title }) {
                playing = TVPlayback(item: item, track: item.progress?.track ?? 0, seconds: item.progress?.seconds ?? 0)
            }
        }
        #endif
    }

    private static let sorts = [("title", "Title A–Z"), ("titleDescending", "Title Z–A"), ("added", "Recently added"),
                                ("played", "Recently played"), ("year", "Release year"), ("duration", "Duration"),
                                ("artist", "Artist, then album")]

    private var controls: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 30) {
                Picker("Category", selection: $filter) {
                    Text("All").tag("all"); Text("Video").tag("video"); Text("Audiobooks").tag("audiobooks"); Text("Music").tag("music")
                }.onChange(of: filter) { genre = "" }
                // Menus, not segmented strips: in a row, tvOS squeezes every option into an unreadable "A…".
                Menu {
                    Picker("Genre", selection: $genre) {
                        Text("All genres").tag("")
                        ForEach(store.genres, id: \.self) { Text($0).tag($0) }
                    }
                } label: {
                    Label("Genre: \(genre.isEmpty ? "All genres" : genre)", systemImage: "square.grid.2x2")
                }
                Menu {
                    Picker("Sort by", selection: $sort) {
                        ForEach(Self.sorts, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } label: {
                    Label("Sort: \(Self.sorts.first { $0.0 == sort }?.1 ?? "Title A–Z")", systemImage: "arrow.up.arrow.down")
                }
            }.focusSection()
            TextField("Search titles and artists", text: $query).frame(maxWidth: 850)
            if filter == "music" {
                Picker("Browse music", selection: $musicTab) { ForEach(["Albums", "Artists", "Songs"], id: \.self) { Text($0).tag($0) } }
            }
        }.focusSection()
    }
    private var artists: some View {
        LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(store.artists) { artist in
                shelfRow(artist.name, artist.items.compactMap { id in store.items.first { $0.id == id } })
            }
        }
    }
    private var songs: some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(store.songs) { song in
                if let item = store.items.first(where: { $0.id == song.item }), item.tracks.indices.contains(song.index) {
                    Button { playing = TVPlayback(item: item, track: song.index, seconds: 0) } label: {
                        HStack { Text(item.tracks[song.index].title); Spacer(); Text(item.artist ?? item.title).foregroundStyle(.secondary) }.padding(12)
                    }
                }
            }
        }.padding(.horizontal, 80).focusSection()
    }

    @ViewBuilder private func shelf(_ title: String, _ items: [TVItem]) -> some View {
        if !items.isEmpty { shelfRow(title, items) }
    }

    private func shelfRow(_ title: String, _ items: [TVItem]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.title2.bold()).padding(.horizontal, 80)
            ScrollView(.horizontal) {
                LazyHStack(spacing: 48) {
                    ForEach(items) { item in
                        Button { selected = item } label: { TVCard(item: item) }
                            .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Nothing to watch yet").font(.title2.bold())
            Text("On your Mac, open Offline Kit › Watch, Audiobooks or Music and add movies, home videos, audiobooks or music. They show up here.")
                .font(.title3).foregroundStyle(.secondary)
            Button("Check Again") { Task { await store.refresh() } }
        }
        .padding(.horizontal, 80)
    }

    private var footer: some View {
        HStack(spacing: 30) {
            Label("Playing from \(store.server?.name ?? "your Mac")", systemImage: "desktopcomputer")
                .foregroundStyle(.secondary)
            Button("Refresh") { Task { await store.refresh() } }
            Button("Choose Another Mac") { store.forgetServer() }
        }
        .padding(.horizontal, 80)
        .focusSection()
    }
}

struct TVCard: View {
    @Environment(TVStore.self) private var store
    let item: TVItem
    @Environment(\.isFocused) private var focused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                artwork
                    .frame(width: width, height: 270)
                if let f = item.fraction {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.3))
                        Rectangle().fill(Color(red: 0.70, green: 0.84, blue: 0.55)).frame(width: width * f)
                    }
                    .frame(width: width, height: 8)
                }
            }
            .frame(width: width, height: 270)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(focused ? .white : .white.opacity(0.12), lineWidth: focused ? 4 : 1))
            .scaleEffect(focused && !reduceMotion ? 1.035 : 1)
            .hoverEffect(.highlight)
            Text(item.title).font(.headline).lineLimit(1)
                .frame(width: width, alignment: .leading)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: width, alignment: .leading)
        }
    }

    /// Wide for videos and anything with a video still; square for album and audiobook covers.
    private var width: CGFloat { item.kind == .video ? 480 : item.category == "audiobooks" ? 180 : 270 }

    private var subtitle: String {
        if item.progress?.finished == true { return "Finished" + (item.meta.map { " · \($0)" } ?? "") }
        if let meta = item.meta, !meta.isEmpty { return meta }
        switch item.kind {
        case .video: return item.isInProgress ? "Resume" : "Video"
        case .audio: return item.tracks.count == 1 ? "Audio" : "Audiobook · \(item.tracks.count) chapters"
        }
    }

    @ViewBuilder private var artwork: some View {
        if let picture = item.thumb ?? item.cover, let url = store.url(picture) {
            AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { placeholder }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        LinearGradient(colors: tvPosterColors(item.title), startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                VStack(alignment: .leading, spacing: 20) {
                    Image(systemName: item.kind == .video ? "play.rectangle" : item.category == "music" ? "music.note" : "headphones").font(.title2)
                    Text(item.title).font(.title3.bold()).lineLimit(4)
                }.padding(24).foregroundStyle(.white)
            }
    }
}

/// Where to start: a track and a time.
struct TVPlayback: Identifiable, Hashable {
    let item: TVItem
    let track: Int
    let seconds: Double
    var id: String { "\(item.id)-\(track)-\(seconds)" }
}

struct TVItemDetail: View {
    let item: TVItem
    let play: (TVPlayback) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            HStack(alignment: .top, spacing: 40) {
                TVCard(item: item)
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.title).font(.largeTitle.bold())
                    if let artist = item.artist, item.kind == .audio { Text(artist).font(.title3).foregroundStyle(.secondary) }
                    if let meta = item.meta { Text(meta).foregroundStyle(.secondary) }
                    if let summary = item.summary { Text(summary).font(.callout).fixedSize(horizontal: false, vertical: true) }
                    let extra = [item.studio, item.series, item.ageRating.map { "Rated \($0)" }].compactMap { $0 }
                    if !extra.isEmpty { Text(extra.joined(separator: " · ") + (item.aiGuess?.isEmpty == false ? " · some details are AI guesses" : "")).font(.caption).foregroundStyle(.secondary) }
                    if let fraction = item.fraction { ProgressView(value: fraction).tint(.green); Text("\(Int(fraction * 100))% completed").font(.caption) }
                }
            }
            HStack(spacing: 30) {
                if let p = item.progress, item.isInProgress {
                    Button { play(TVPlayback(item: item, track: p.track, seconds: p.seconds)) } label: {
                        Label(resumeLabel(p), systemImage: "play.fill")
                    }
                    Button { play(TVPlayback(item: item, track: 0, seconds: 0)) } label: {
                        Label("Start Over", systemImage: "arrow.counterclockwise")
                    }
                } else {
                    Button { play(TVPlayback(item: item, track: 0, seconds: 0)) } label: {
                        Label("Play", systemImage: "play.fill")
                    }
                }
            }
            if item.tracks.count > 1 {
                Text(item.category == "music" ? "Songs" : "Chapters").font(.title3.bold()).padding(.top, 10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(item.tracks.enumerated()), id: \.offset) { index, track in
                            Button { play(TVPlayback(item: item, track: index, seconds: 0)) } label: {
                                HStack {
                                    Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                                    Text(track.title)
                                    Spacer()
                                    if let duration = track.duration { Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))).foregroundStyle(.secondary) }
                                    if item.progress?.track == index && item.isInProgress { Text("Your place").foregroundStyle(.tint) }
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(80).background { MediaForestBackground() }.environment(\.colorScheme, .dark)
    }

    private func resumeLabel(_ p: TVProgress) -> String {
        let time = Duration.seconds(p.seconds).formatted(.time(pattern: p.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
        return item.tracks.count > 1 ? "Resume Chapter \(p.track + 1) at \(time)" : "Resume at \(time)"
    }
}

/// The full-width banner at the top of the Apple TV home screen.
struct TVBanner: View {
    @Environment(TVStore.self) private var store
    let item: TVItem
    let play: (TVPlayback) -> Void
    let info: () -> Void

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let picture = item.thumb ?? item.cover, let url = store.url(picture) {
                    AsyncImage(url: url) { image in image.resizable().scaledToFill() } placeholder: { Color.black }
                } else {
                    LinearGradient(colors: tvPosterColors(item.title), startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(maxWidth: .infinity).frame(height: 760)
            .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.3), .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 18) {
                Text(eyebrow).font(.caption.bold()).tracking(2).foregroundStyle(.white.opacity(0.8))
                Text(item.title).font(.system(size: 76, weight: .bold)).foregroundStyle(.white).lineLimit(2)
                if let meta = item.meta { Text(meta).font(.title3).foregroundStyle(.white.opacity(0.85)) }
                if let summary = item.summary {
                    Text(summary + (item.aiGuess?.contains("summary") == true ? "  (AI guess)" : ""))
                        .font(.title3).foregroundStyle(.white.opacity(0.8)).lineLimit(3).frame(maxWidth: 1100, alignment: .leading)
                }
                if let f = item.fraction {
                    ProgressView(value: f).tint(.white).frame(width: 420)
                }
                HStack(spacing: 30) {
                    Button {
                        let p = item.progress
                        play(TVPlayback(item: item, track: item.isInProgress ? (p?.track ?? 0) : 0,
                                        seconds: item.isInProgress ? (p?.seconds ?? 0) : 0))
                    } label: { Label(item.isInProgress ? "Resume" : "Play", systemImage: "play.fill") }
                    if item.isInProgress {
                        Button { play(TVPlayback(item: item, track: 0, seconds: 0)) } label: {
                            Label("Start Over", systemImage: "arrow.counterclockwise")
                        }
                    }
                    if item.tracks.count > 1 {
                        Button(action: info) { Label(item.category == "music" ? "Songs" : "Chapters", systemImage: "list.bullet") }
                    }
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 80).padding(.bottom, 60)
        }
        .frame(height: 760)
        .focusSection()
    }

    private var eyebrow: String {
        item.kind == .video ? (item.isInProgress ? "KEEP WATCHING" : "WATCH NEXT") : (item.isInProgress ? "KEEP LISTENING" : "LISTEN NEXT")
    }
}

/// A stable, title-seeded fallback poster; no remote artwork is fetched.
private func tvPosterColors(_ title: String) -> [Color] {
    let seed = title.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    let hue = Double(seed % 360) / 360
    return [Color(hue: hue, saturation: 0.42, brightness: 0.32), Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.58, brightness: 0.15)]
}
