import SwiftUI
import AVKit
import ImageIO

/// Local to Watch & Listen. The rest of the app keeps its existing appearance.
enum MediaTheme {
    static let canvas = Color(red: 0.045, green: 0.105, blue: 0.085)
    static let surface = Color(red: 0.085, green: 0.16, blue: 0.13)
    static let ink = Color(red: 0.96, green: 0.96, blue: 0.90)
    static let muted = Color(red: 0.72, green: 0.78, blue: 0.72)
    static let accent = Color(red: 0.70, green: 0.84, blue: 0.55)
    static func posterColors(_ title: String) -> [Color] {
        let seed = title.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let hue = Double(seed % 360) / 360
        return [Color(hue: hue, saturation: 0.42, brightness: 0.32), Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.58, brightness: 0.15)]
    }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Decode and downsample local artwork off the main thread, with cancellation and a title-seeded poster fallback.
struct MediaArtwork: View {
    let item: MediaItem
    let info: MediaInfo?
    @State private var image: CGImage?
    /// True while the picture is being read, so the poster gradient shimmers until it fades in.
    @State private var decoding = false
    @State private var shownPath: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A chosen or folder cover wins over the automatic video still or embedded art.
    private var path: String? { item.cover?.path ?? info?.thumb }
    /// Changes when a cover file is replaced in place, so the new picture loads.
    private var reloadKey: String {
        guard let path else { return "" }
        return "\(path)|\(ImageCache.shared.stamp(path))|\(CoverStamp.shared.value)"
    }
    var body: some View {
        GeometryReader { geo in
            ZStack {
                let poster = LinearGradient(colors: MediaTheme.posterColors(item.title), startPoint: .topLeading, endPoint: .bottomTrailing)
                if decoding { poster.shimmer() } else { poster }
                if let image {
                    Image(decorative: image, scale: 1).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                        .contentShape(Rectangle())
                        .transition(.opacity)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: item.kind == .video ? "play.rectangle" : item.kind == .book ? "book.closed" : MediaCatalog.category(item, info) == .music ? "music.note" : "headphones")
                            .font(.title3)
                        Spacer(minLength: 0)
                        Text(MediaCatalog.title(item, info)).font(.system(.title3, design: .serif, weight: .semibold)).lineLimit(4)
                        if let artist = info?.artist { Text(artist).font(.caption).lineLimit(1) }
                    }.padding(max(8, min(20, geo.size.width * 0.1))).foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }.frame(width: geo.size.width, height: geo.size.height).clipped()
            // clipped() only trims what's drawn. A cover scaled to fill (a tall book cover across a wide banner) still
            // takes clicks far outside its frame, which made the Books genre tiles above the banner unclickable.
            .contentShape(Rectangle())
            // Reloads when the file or the size bucket changes; the shared cache makes a repeat a lookup, not a decode.
            .task(id: "\(reloadKey)|\(ImageCache.pixels(forPoints: max(geo.size.width, geo.size.height)))|\(geo.size.width > 0)") {
                await load(pixels: ImageCache.pixels(forPoints: max(geo.size.width, geo.size.height)), laidOut: geo.size.width > 0)
            }
        }
        .accessibilityHidden(true)
    }

    private func load(pixels: Int, laidOut: Bool) async {
        guard let path else { image = nil; decoding = false; return }
        // Not measured yet: wait for the real size rather than decode twice.
        guard laidOut else { return }
        if let hit = ImageCache.shared.cached(path, pixels: pixels) { image = hit; decoding = false; return }
        // Keep what's showing while a different size loads; a different picture starts from the poster.
        if shownPath != path { image = nil }
        decoding = true
        let result = await ImageCache.shared.image(path, pixels: pixels)
        guard !Task.isCancelled else { return }
        shownPath = path
        withAnimation(Motion.gentle(reduceMotion)) { image = result; decoding = false }
    }
}

struct MediaCard: View {
    let item: MediaItem
    let info: MediaInfo?
    let progress: MediaProgress?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var category: MediaFilter { MediaCatalog.category(item, info) }
    var ratio: CGFloat { category == .video ? 16 / 9 : category == .audiobooks || category == .books ? 2 / 3 : 1 }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaArtwork(item: item, info: info)
                .aspectRatio(ratio, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    if let f = MediaCatalog.fraction(item, progress, info) {
                        ProgressView(value: f).tint(MediaTheme.accent).padding(9).background(.black.opacity(0.65))
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if progress?.finished == true { Label("Finished", systemImage: "checkmark.circle.fill").font(.caption2.bold()).padding(6).background(.black.opacity(0.8), in: Capsule()).padding(8) }
                    else if let d = info?.duration, d > 0, category == .video { Text(MediaTheme.time(d)).font(.caption2.bold()).padding(5).background(.black.opacity(0.8), in: Capsule()).padding(8) }
                }
                #if os(macOS)
                .overlay(alignment: .topLeading) { SendQueuedBadge(item: item) }
                #endif
                .overlay {
                    if let badge = item.unavailableBadge {
                        ZStack { Color.black.opacity(0.6); Label(badge, systemImage: "externaldrive.badge.xmark").font(.caption.bold()).padding(8) }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hovering ? MediaTheme.accent : .white.opacity(0.12), lineWidth: hovering ? 2 : 0.5))
            Text(MediaCatalog.title(item, info)).font(.callout.weight(.semibold)).lineLimit(2)
            if category == .music || category == .audiobooks {
                Text(MediaCatalog.creator(info)).font(.caption).foregroundStyle(MediaTheme.muted).lineLimit(1)
            }
            Text(MediaCatalog.meta(item, info)).font(.caption).foregroundStyle(MediaTheme.muted).lineLimit(2)
        }
        .foregroundStyle(MediaTheme.ink)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .hoverLift()
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : Motion.quick, value: hovering)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Open details and playback options")
    }
    private var accessibilityText: String {
        var text = "\(MediaCatalog.title(item, info)), \(MediaCatalog.meta(item, info))"
        if let place = item.unavailable { text += ", unavailable until \(place == "its folder" ? "its folder is back" : place == "its file" ? "its file is back" : place + " is connected")" }
        if progress?.finished == true { text += ", Finished" }
        else if let fraction = MediaCatalog.fraction(item, progress, info) { text += ", \(Int(fraction * 100)) percent \(category == .video ? "watched" : "completed")" }
        #if os(macOS)
        if item.unavailable == nil, SendList.shared.contains(.media(item)) { text += ", on the Send to iPhone list" }
        #endif
        return text
    }
}

struct MediaShelfRow: View {
    let shelf: MediaShelf
    let open: (MediaItem) -> Void
    var seeAll: (() -> Void)? = nil
    @Environment(MediaLibrary.self) private var media
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(shelf.title).font(.title2.bold())
                Text("\(shelf.items.count)").font(.callout).foregroundStyle(MediaTheme.muted)
                Spacer()
                if let seeAll { Button("See all", action: seeAll).font(.callout).accessibilityLabel("See all \(shelf.title)") }
            }.padding(.horizontal, 24)
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 18) {
                    ForEach(Array(shelf.items.enumerated()), id: \.element.id) { index, item in
                        Button { open(item) } label: {
                            MediaCard(item: item, info: media.info[item.progressKey], progress: media.progress[item.progressKey])
                                .frame(width: item.kind == .video ? 272 : MediaCatalog.category(item, media.info[item.progressKey]) == .music ? 180 : 152)
                        }.buttonStyle(.plain).mediaCardMenu(item)
                            .appearFade(delay: min(Double(index), 6) * 0.04)
                    }
                }.scrollTargetLayout().padding(.horizontal, 24).padding(.vertical, 4)
            }.scrollTargetBehavior(.viewAligned)
        }
    }
}

struct MediaFeaturedBanner: View {
    let item: MediaItem
    let play: (Bool) -> Void
    let detail: () -> Void
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        let info = media.info[item.progressKey]
        let progress = media.progress[item.progressKey]
        let resuming = MediaCatalog.isInProgress(progress, kind: item.kind)
        VStack(alignment: .leading, spacing: 14) {
            Text(resuming ? "PICK UP WHERE YOU LEFT OFF" : "READY WHEN YOU ARE").font(.caption.bold()).tracking(1.5)
            Text(MediaCatalog.title(item, info)).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            Text(MediaCatalog.meta(item, info)).font(.callout)
            if let f = MediaCatalog.fraction(item, progress, info) {
                ProgressView(value: f).tint(MediaTheme.accent).frame(maxWidth: 280)
                Text("\(Int(f * 100))% completed").font(.caption)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { actions(resuming) }
                VStack(alignment: .leading, spacing: 12) { actions(resuming) }
            }
        }
        .padding(26).padding(.top, 36).frame(maxWidth: .infinity, minHeight: typeSize.isAccessibilitySize ? 320 : 260, alignment: .bottomLeading)
        .foregroundStyle(.white)
        .background {
            GeometryReader { geo in
                MediaArtwork(item: item, info: info).frame(width: geo.size.width, height: geo.size.height)
                    .overlay(LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    .overlay(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .contentShape(RoundedRectangle(cornerRadius: 18))   // clicks stop at the banner's edge, like its picture
    }
    @ViewBuilder private func actions(_ resuming: Bool) -> some View {
        Button { play(false) } label: { Label(item.kind == .book ? "Read" : resuming ? "Resume" : "Play", systemImage: item.kind == .book ? "book.fill" : "play.fill") }.buttonStyle(.borderedProminent)
        if resuming { Button("Start Over", systemImage: "arrow.counterclockwise") { play(true) }.buttonStyle(.bordered) }
        Button(item.tracks.count > 1 ? "Chapters & details" : "Details", systemImage: "info.circle", action: detail).buttonStyle(.bordered)
    }
}

struct MediaItemDetail: View {
    let item: MediaItem
    let open: (MediaItem) -> Void
    let play: (MediaItem, Bool, Int?) -> Void
    /// Leaves the page (after Remove from Kit).
    var close: () -> Void = {}
    @Environment(MediaLibrary.self) private var media
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The latest scan of this item, so a new cover, new details or a located file show without leaving the page.
    /// A linked item is matched by its link too, since Locate… changes where its files are.
    private var current: MediaItem {
        media.items.first { $0.id == item.id } ?? item.linkID.flatMap { id in media.items.first { $0.linkID == id } } ?? item
    }
    private var info: MediaInfo? { media.info[current.progressKey] }
    private var progress: MediaProgress? { media.progress[current.progressKey] }
    private var category: MediaFilter { MediaCatalog.category(current, info) }
    var body: some View {
        let current = current
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) { art.frame(width: 220); heading.frame(minWidth: 270) }
                    VStack(alignment: .leading, spacing: 22) { art.frame(maxWidth: 260).frame(maxWidth: .infinity); heading }
                }
                HStack(spacing: 12) {
                    CoverArtButtons(item: current)
                    SendToPhoneButton(media: current, info: info).disabled(current.unavailable != nil)
                }
                .buttonStyle(.bordered)
                MediaCatalogDetails(item: current, removed: close)
                if current.kind == .video {
                    Label(current.tracks[0].lastPathComponent, systemImage: "externaldrive").font(.callout).foregroundStyle(MediaTheme.muted)
                    #if os(macOS)
                    Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting(current.tracks) }.disabled(current.unavailable != nil)
                    #endif
                } else if current.kind == .audio {
                    MediaTrackList(item: current, info: info, progress: progress, play: { play(current, false, $0) })
                }
                if let studio = info?.studio {
                    let others = media.items.filter { $0.id != current.id && media.info[$0.progressKey]?.studio == studio }
                    if !others.isEmpty { MediaShelfRow(shelf: MediaShelf(title: "More from \(studio)", items: others), open: open) }
                }
                let related = MediaCatalog.related(to: current, items: media.items, info: media.info)
                if !related.isEmpty { MediaShelfRow(shelf: MediaShelf(title: "More like this", items: Array(related.prefix(12))), open: open) }
            }.padding(24)
        }.background { MediaForestBackground() }
    }
    private var art: some View { MediaArtwork(item: current, info: info).aspectRatio(category == .video ? 16 / 9 : category == .music ? 1 : 2 / 3, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 14)) }
    private var heading: some View {
        let current = current
        return VStack(alignment: .leading, spacing: 16) {
            Text(category.label.uppercased()).font(.caption.bold()).tracking(1.5).foregroundStyle(MediaTheme.accent)
            Text(MediaCatalog.title(current, info)).font(.largeTitle.bold()).fixedSize(horizontal: false, vertical: true)
            if current.kind == .audio { Text(MediaCatalog.creator(info)).font(.title3).foregroundStyle(MediaTheme.muted) }
            Text(MediaCatalog.meta(current, info)).foregroundStyle(MediaTheme.muted)
            if let f = MediaCatalog.fraction(current, progress, info) {
                ProgressView(value: f).tint(MediaTheme.accent)
                Text("\(Int(f * 100))% completed").font(.callout).foregroundStyle(MediaTheme.muted)
            }
            ViewThatFits(in: .horizontal) {
                HStack { actions }
                VStack(alignment: .leading) { actions }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private var actions: some View {
        let current = current
        let book = current.kind == .book
        Button(MediaCatalog.isInProgress(progress, kind: current.kind) ? "Resume" : book ? "Read" : "Play", systemImage: book ? "book.fill" : "play.fill") { play(current, false, nil) }
            .buttonStyle(.borderedProminent)
            .disabled(current.unavailable != nil)
        Button("Start Over", systemImage: "arrow.counterclockwise") { play(current, true, nil) }.buttonStyle(.bordered).disabled(current.unavailable != nil)
        if category == .music, current.tracks.count > 1 { Button("Shuffle", systemImage: "shuffle") { play(current, false, -1) }.buttonStyle(.bordered).disabled(current.unavailable != nil) }
    }
}

struct MediaTrackList: View {
    let item: MediaItem
    let info: MediaInfo?
    let progress: MediaProgress?
    let play: (Int) -> Void
    var body: some View {
        let music = MediaCatalog.category(item, info) == .music
        LazyVStack(alignment: .leading, spacing: 0) {
            Text(music ? "Songs" : "Chapters").font(.title2.bold()).padding(.bottom, 12)
            ForEach(Array(item.tracks.indices), id: \.self) { index in
                Button { play(index) } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(MediaTheme.muted).frame(minWidth: 24)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(MediaCatalog.trackTitle(item, info, index)).frame(maxWidth: .infinity, alignment: .leading)
                            if !music, let progress, !progress.finished, progress.track == index {
                                Text("Your current chapter").font(.caption).foregroundStyle(MediaTheme.accent)
                                if let tracks = info?.tracks, tracks.indices.contains(index), let d = tracks[index].duration, d > 0 { ProgressView(value: min(1, progress.seconds / d)).tint(MediaTheme.accent) }
                            }
                        }
                        if !music, progress?.finished == true || index < (progress?.track ?? 0) { Image(systemName: "checkmark.circle.fill").foregroundStyle(MediaTheme.accent).accessibilityLabel("Finished") }
                        if let tracks = info?.tracks, tracks.indices.contains(index), let d = tracks[index].duration { Text(MediaTheme.time(d)).font(.caption).monospacedDigit().foregroundStyle(MediaTheme.muted) }
                    }.padding(.vertical, 14).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityHint("Play \(music ? "song" : "chapter") \(index + 1)")
                Divider()
            }
        }
    }
}

struct MediaPlayerView: View {
    let item: MediaItem
    var advance: (MediaItem) -> Void = { _ in }
    @State private var cancelledNext = false
    @Environment(MediaLibrary.self) private var media
    @Environment(NowPlaying.self) private var nowPlaying
    var body: some View {
        Group {
            if let playback = nowPlaying.playback, playback.item == item {
                if item.kind == .video {
                    PlatformVideoView(player: playback.player).background(.black)
                        .overlay(alignment: .topLeading) { Text(MediaCatalog.displayTitle(item.title)).font(.headline).padding(12).background(.black.opacity(0.85), in: Capsule()).padding().allowsHitTesting(false) }
                        .overlay(alignment: .bottomTrailing) {
                            if !cancelledNext, playback.duration > 0, playback.duration - playback.current <= 20,
                               MediaCatalog.chainsToNext(item, duration: playback.duration, info: media.info),
                               let next = MediaCatalog.nextVideo(after: item, items: media.items, info: media.info, progress: media.progress) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Up next in \(max(0, Int(ceil(playback.duration - playback.current))))s").font(.caption).monospacedDigit()
                                    Text(next.title).font(.headline)
                                    HStack { Button("Play now") { advance(next) }; Button("Cancel") { cancelledNext = true } }
                                }.padding(18).background(MediaTheme.surface, in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(MediaTheme.ink).padding(24).padding(.bottom, 48)
                            }
                        }
                        .onChange(of: playback.finished) {
                            if playback.finished, !cancelledNext, MediaCatalog.chainsToNext(item, duration: playback.duration, info: media.info), let next = MediaCatalog.nextVideo(after: item, items: media.items, info: media.info, progress: media.progress) { advance(next) }
                        }
                } else { AudioPlayerView(playback: playback) }
            } else { ProgressView() }
        }
        .navigationTitle(MediaCatalog.title(item, media.info[item.progressKey]))
        #if os(macOS)
        .background(PlayerWindowReader(nowPlaying: nowPlaying).frame(width: 0, height: 0).accessibilityHidden(true))
        #endif
        .onChange(of: item.id) { cancelledNext = false }
        .onAppear { nowPlaying.open(item, library: media, autoplay: nowPlaying.playback?.item != item); nowPlaying.fullScreen = true }
        .onDisappear { nowPlaying.fullScreen = false }
    }
}

struct AudioPlayerView: View {
    let playback: MediaPlayback
    @Environment(MediaLibrary.self) private var media
    @State private var scrubbing: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    private var info: MediaInfo? { media.info[playback.item.progressKey] }
    private var music: Bool { MediaCatalog.category(playback.item, info) == .music }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 24) {
                    Text(music ? "NOW PLAYING" : "NOW LISTENING").font(.caption.bold()).tracking(2).foregroundStyle(MediaTheme.muted)
                    MediaArtwork(item: playback.item, info: info).aspectRatio(music ? 1 : 2 / 3, contentMode: .fit)
                        .frame(maxWidth: music ? 280 : 220).clipShape(RoundedRectangle(cornerRadius: 16)).shadow(color: .black.opacity(0.4), radius: 20, y: 10)
                    VStack(spacing: 8) {
                        Text(MediaCatalog.title(playback.item, info)).font(.title2.bold()).multilineTextAlignment(.center)
                        Text(MediaCatalog.creator(info)).foregroundStyle(MediaTheme.muted)
                        Text(MediaCatalog.trackTitle(playback.item, info, playback.track)).font(.headline).multilineTextAlignment(.center)
                        if !music { Text("Chapter \(playback.track + 1) of \(playback.item.tracks.count)").font(.caption).foregroundStyle(MediaTheme.muted) }
                    }
                    VStack {
                        Slider(value: Binding(get: { scrubbing ?? (playback.duration > 0 ? min(1, max(0, playback.current / playback.duration)) : 0) }, set: { scrubbing = $0 }), onEditingChanged: { editing in if !editing, let value = scrubbing { playback.seek(to: value); scrubbing = nil } })
                            .accessibilityLabel("Playback position")
                        HStack { Text(MediaTheme.time(playback.current)); Spacer(); Text("−" + MediaTheme.time(max(0, playback.duration - playback.current))) }.font(.caption).monospacedDigit().foregroundStyle(MediaTheme.muted)
                    }
                    HStack(spacing: 20) {
                        Button("Previous", systemImage: "backward.end.fill") { playback.previous() }.labelStyle(.iconOnly).disabled(playback.track == 0 && playback.current < 5)
                        if !music { Button("Back 15 seconds", systemImage: "gobackward.15") { playback.skip(-15) }.labelStyle(.iconOnly) }
                        Button { playback.toggle() } label: { Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 62)) }.accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                            #if os(macOS)
                            .help(playback.isPlaying ? "Pause (Space or ⌘.)" : "Play (Space or ⌘.)")
                            #endif
                        if !music { Button("Forward 30 seconds", systemImage: "goforward.30") { playback.skip(30) }.labelStyle(.iconOnly) }
                        Button("Next", systemImage: "forward.end.fill") { playback.next() }.labelStyle(.iconOnly).disabled(playback.nextTrack == nil)
                    }.font(.title2).buttonStyle(.plain).foregroundStyle(MediaTheme.accent).controlSize(.large)
                    if !music {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { listeningTools(proxy) }
                            VStack(spacing: 16) { listeningTools(proxy) }
                        }
                    }
                    MediaTrackList(item: playback.item, info: info, progress: MediaProgress(track: playback.track, seconds: playback.current, finished: playback.finished), play: { playback.load(track: $0, play: true) }).id("tracks")
                }.frame(maxWidth: 600).padding(24).frame(maxWidth: .infinity)
            }
        }.foregroundStyle(MediaTheme.ink)
            .background {
                MediaForestBackground()
                if music && !reduceTransparency { MediaArtwork(item: playback.item, info: info).blur(radius: 70).opacity(0.13).allowsHitTesting(false) }
            }.tint(MediaTheme.accent).environment(\.colorScheme, .dark)
    }
    @ViewBuilder private func listeningTools(_ proxy: ScrollViewProxy) -> some View {
        Menu {
            ForEach([0.75, 1, 1.25, 1.5, 1.75, 2] as [Float], id: \.self) { rate in Button("\(rate.formatted())×") { playback.rate = rate } }
        } label: { Label("\(playback.rate.formatted())× Speed", systemImage: "speedometer") }
        Menu {
            Button("Off") { playback.setSleep() }
            ForEach([15, 30, 60], id: \.self) { value in Button("\(value) minutes") { playback.setSleep(minutes: value) } }
            Button("End of chapter") { playback.setSleep(endOfChapter: true) }
        } label: { Label(sleepLabel, systemImage: "moon") }
        Button("Chapters", systemImage: "list.bullet") { proxy.scrollTo("tracks", anchor: .top) }
    }
    /// "Sleep · 12 min left". Redrawn as playback ticks, so it counts down.
    private var sleepLabel: String {
        if playback.sleepAtChapterEnd { return "Sleep · End of chapter" }
        guard let deadline = playback.sleepDeadline else { return "Sleep timer" }
        _ = playback.current   // re-read on every tick
        let minutes = max(1, Int((deadline.timeIntervalSinceNow / 60).rounded(.up)))
        return "Sleep · \(minutes) min left"
    }
}

/// The description and organized details (studio, series, age rating) with where each came from.
/// AI guesses say so. On Mac, details can be edited; an edit always wins over later runs.
struct MediaCatalogDetails: View {
    let item: MediaItem
    /// Called after Remove from Kit, so the page can close.
    var removed: () -> Void = {}
    @Environment(MediaLibrary.self) private var media
    @Environment(Library.self) private var library
    @State private var editing = false
    @State private var removing = false
    @State private var problem: String?
    private var key: String { KitCatalog.mediaKey(item) }
    var body: some View {
        let details = KitCatalog.shared.details[key]
        VStack(alignment: .leading, spacing: 10) {
            if let sentence = item.unavailableSentence {
                Label(sentence, systemImage: "externaldrive.badge.xmark").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let summary = details?.summary, !summary.value.isEmpty {
                Text(summary.value).font(.title3).fixedSize(horizontal: false, vertical: true)
                if summary.source == .aiGuess { SourceTag(field: summary) }
            }
            let rows = [CatalogDetails.Key.creator, .series, .genre, .subgenre, .year, .ageRating].compactMap { field in
                details?[field].flatMap { $0.value.isEmpty ? nil : (field, $0) }
            }
            if !rows.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(rows, id: \.0) { field, value in
                        let text = field == .series ? value.value + (details?.seriesOrder.map { " #\($0.value)" } ?? "") : value.value
                        HStack(spacing: 4) {
                            Text("\(field.label(for: kind)): \(text)")
                            if value.source == .aiGuess { Text("AI guess").font(.caption2.bold()).foregroundStyle(.orange) }
                        }
                        .font(.caption).padding(.horizontal, 9).padding(.vertical, 5)
                        .background(MediaTheme.surface, in: Capsule())
                        .help(value.label)
                    }
                }
            }
            #if os(macOS)
            HStack(spacing: 12) {
                Button(details == nil ? "Add Details" : "Edit Details", systemImage: "pencil") { editing = true }
                if let linkID = item.linkID {
                    if item.unavailable != nil {
                        Button("Locate…", systemImage: "magnifyingglass") { locate(linkID) }
                            .help("Moved it? Show the kit where it is now.")
                    }
                    Button("Remove from Kit", systemImage: "minus.circle") { removing = true }
                        .confirmationDialog("Remove “\(item.title)” from the kit?", isPresented: $removing) {
                            Button("Remove Link", role: .destructive) {
                                do {
                                    try LinkedMedia.remove(id: linkID, from: KitCatalog.folders(library))
                                    removed()
                                    Task { await media.reload(library: library) }
                                } catch {
                                    problem = "Couldn’t remove it from the kit: \(error.localizedDescription)"
                                }
                            }
                        } message: { Text("The kit forgets this linked item. The files stay where they are.") }
                }
            }
            .buttonStyle(.bordered)
            .alert("Something went wrong", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
                Button("OK") { problem = nil }
            } message: { Text(problem ?? "") }
            .sheet(isPresented: $editing) { CatalogEditSheet(key: key, title: item.title, kind: kind, owner: MediaOrganizer.owner(of: item)) { media.applyCatalog(library: library) } }
            #endif
        }
    }
    #if os(macOS)
    /// "Locate…": point a linked item whose file or folder moved at where it is now.
    private func locate(_ linkID: String) {
        let folder = item.kind == .audio && item.tracks.count > 1 || item.unavailable == "its folder"
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folder
        panel.canChooseFiles = !folder
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This"
        panel.message = folder ? "Choose the folder “\(item.title)” is in now." : "Choose the file for “\(item.title)”."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LinkedMedia.relocate(id: linkID, to: url, in: KitCatalog.folders(library))
            Task { await media.reload(library: library) }
        } catch {
            problem = error.localizedDescription
        }
    }
    #endif

    private var kind: CatalogKind {
        switch MediaCatalog.category(item, media.info[item.progressKey]) {
        case .video: .video
        case .music: .music
        case .audiobooks: .audiobook
        default: .book
        }
    }
}

private struct SourceTag: View {
    let field: CatalogField
    var body: some View {
        Label(field.label, systemImage: "sparkles").font(.caption).foregroundStyle(.orange)
    }
}

#if os(macOS)
/// A person's own details for one item. Saved as theirs, so Organize with AI never changes them.
struct CatalogEditSheet: View {
    let key: String
    let title: String
    let kind: CatalogKind
    let owner: URL
    var saved: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var values: [CatalogDetails.Key: String] = [:]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Details for \(title)").font(.title2.bold())
            Form {
                ForEach(CatalogDetails.Key.allCases) { field in
                    if field == .ageRating {
                        Picker(field.label(for: kind), selection: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 })) {
                            Text("Not set").tag("")
                            ForEach(CatalogDetails.ageRatings, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        TextField(field.label(for: kind), text: Binding(get: { values[field] ?? "" }, set: { values[field] = $0 }),
                                  axis: field == .summary ? .vertical : .horizontal)
                    }
                }
            }
            Text("Your details are kept even when Organize with AI runs again.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Save") { save(); dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(24).frame(width: 520)
        .onAppear {
            for field in CatalogDetails.Key.allCases { values[field] = KitCatalog.shared.details[key]?[field]?.value ?? "" }
        }
    }
    private func save() {
        let current = KitCatalog.shared.details[key]
        for field in CatalogDetails.Key.allCases {
            let value = (values[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value != (current?[field]?.value ?? "") { KitCatalog.shared.setByUser(key, field: field, value: value, owner: owner) }
        }
        saved()
    }
}
#endif
