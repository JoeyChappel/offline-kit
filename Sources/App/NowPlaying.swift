import SwiftUI
#if os(macOS)
import AppKit
import PDFKit
import WebKit
#endif

/// What's playing, owned by the app so it keeps going while people move around.
@MainActor @Observable
final class NowPlaying {
    private(set) var playback: MediaPlayback?
    /// True while the full player screen is showing (the mini player hides then).
    var fullScreen = false
    /// Set by the mini player's expand button; Watch & Listen opens the full player for it.
    var expandRequest: MediaItem?
    /// Bumped when Esc is pressed in the full player; the section showing it goes back.
    private(set) var collapseRequest = 0

    #if os(macOS)
    /// The window the players are in. Keys are handled only there, so a game window keeps its Space bar.
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var keyMonitor: Any?

    init() {
        // Space plays and pauses, but never while someone is typing (Ask, search, Find my media, Edit Details)
        // or reading (a book scrolls with Space). ⌘. works anywhere in the window. In the full player,
        // ← and → skip and Esc goes back.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let key = event
            let handled = MainActor.assumeIsolated { self?.handle(key) == true }
            return handled ? nil : event
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let playback, let window, event.window === window, NSApp.keyWindow === window, window.attachedSheet == nil else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad, .capsLock])
        if modifiers == .command, event.charactersIgnoringModifiers == "." { playback.toggle(); return true }
        guard modifiers.isEmpty, !Self.isTyping(in: window) else { return false }
        let video = fullScreen && playback.item.kind == .video
        // Audiobooks skip like their Back 15 / Forward 30 buttons; songs and everything else move 10 seconds.
        let audiobook = fullScreen && playback.item.kind == .audio && !playback.isMusic
        let audio = fullScreen && playback.item.kind == .audio
        switch event.keyCode {
        case 49: playback.toggle(); return true                 // Space
        case 123 where video || audio: playback.skip(audiobook ? -15 : -10); return true   // ←
        case 124 where video || audio: playback.skip(audiobook ? 30 : 10); return true     // →
        case 53 where fullScreen: collapseRequest += 1; return true   // Esc
        default: return false
        }
    }

    /// A text field, a text view or a book page has the keyboard.
    private static func isTyping(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder, responder !== window else { return false }
        // Text fields edit through a shared NSTextView (the field editor), so NSText covers them while typing.
        if responder is NSText || responder is NSTextField { return true }
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView || current is PDFView { return true }
            view = current.superview
        }
        return false
    }
    #endif

    /// Starts (or returns to) an item. Opening something else stops the previous one and saves its place.
    func open(_ item: MediaItem, library: MediaLibrary, autoplay: Bool) {
        if playback?.item == item { if autoplay { playback?.play() }; return }
        playback?.cleanUp()
        let next = MediaPlayback(item: item, library: library)
        playback = next
        if autoplay { next.play() }
    }

    func close() {
        playback?.cleanUp()
        playback = nil
    }
}

#if os(macOS)
/// Tells NowPlaying which window the players are in.
struct PlayerWindowReader: NSViewRepresentable {
    let nowPlaying: NowPlaying
    func makeNSView(context: Context) -> Reader { Reader(nowPlaying: nowPlaying) }
    func updateNSView(_ view: Reader, context: Context) {}
    final class Reader: NSView {
        weak var nowPlaying: NowPlaying?
        init(nowPlaying: NowPlaying) { self.nowPlaying = nowPlaying; super.init(frame: .zero) }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainActor.assumeIsolated { nowPlaying?.window = window } }
        }
    }
}
#endif

/// The persistent Watch & Listen player. It never owns or tears down playback.
struct MiniPlayerBar: View {
    @Environment(NowPlaying.self) private var nowPlaying
    @Environment(MediaLibrary.self) private var media
    @Environment(KitNavigation.self) private var navigation
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        VStack(spacing: 0) {
            if let playback = nowPlaying.playback, !nowPlaying.fullScreen {
                ViewThatFits(in: .horizontal) {
                    bar(playback, compact: false)
                    bar(playback, compact: true)
                }
                .padding(12)
                .background(MediaTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(MediaTheme.muted.opacity(0.3), lineWidth: 0.5))
                .foregroundStyle(MediaTheme.ink).tint(MediaTheme.accent)
                .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
                .padding(.horizontal, 12).padding(.bottom, 8)
                .frame(maxWidth: 900).frame(maxWidth: .infinity)
            }
        }
        #if os(macOS)
        .background(PlayerWindowReader(nowPlaying: nowPlaying).frame(width: 0, height: 0).accessibilityHidden(true))
        #endif
    }
    private func bar(_ playback: MediaPlayback, compact: Bool) -> some View {
        let item = playback.item
        let info = media.info[item.progressKey]
        let music = MediaCatalog.category(item, info) == .music
        let title = MediaCatalog.title(item, info)
        // The song or chapter under the title; nothing for a single video, which would only repeat the title.
        let subtitle = music ? MediaCatalog.trackTitle(item, info, playback.track) : item.tracks.count > 1 ? playback.trackTitle : nil
        return HStack(spacing: compact ? 10 : 16) {
            Button(action: expand) {
                Group {
                    if item.kind == .video { PlatformVideoView(player: playback.player, controls: false) }
                    else { MediaArtwork(item: item, info: info) }
                }.frame(width: compact ? 42 : item.kind == .video ? 100 : 56, height: compact ? 48 : 56)
                    .clipShape(RoundedRectangle(cornerRadius: 7)).allowsHitTesting(false)
            }.accessibilityLabel("Expand \(title)")
            Button(action: expand) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.callout.bold()).lineLimit(1)
                    if !typeSize.isAccessibilitySize, let subtitle, subtitle != title {
                        Text(subtitle).font(.caption).foregroundStyle(MediaTheme.muted).lineLimit(1)
                    }
                    ProgressView(value: playback.duration > 0 ? min(1, max(0, playback.current / playback.duration)) : 0).tint(MediaTheme.accent)
                }.frame(minWidth: compact ? 70 : 150, maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.accessibilityLabel("Open full player")
            if !compact { Button(music ? "Previous song" : "Back 15 seconds", systemImage: music ? "backward.end.fill" : "gobackward.15") { if music { playback.previous() } else { playback.skip(-15) } }.labelStyle(.iconOnly) }
            Button { playback.toggle() } label: { Image(systemName: playback.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34)) }
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")
                #if os(macOS)
                .help(playback.isPlaying ? "Pause (Space or ⌘.)" : "Play (Space or ⌘.)")
                #endif
            if !compact {
                SleepTimerMenu(playback: playback, iconOnly: true).menuStyle(.button).buttonStyle(.plain).fixedSize()
                Button(music ? "Next song" : "Forward 30 seconds", systemImage: music ? "forward.end.fill" : "goforward.30") { if music { playback.next() } else { playback.skip(30) } }.labelStyle(.iconOnly)
                Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right", action: expand).labelStyle(.iconOnly)
            }
            Button("Close and save your place", systemImage: "xmark") { nowPlaying.close() }.labelStyle(.iconOnly).frame(minWidth: 32, minHeight: 44)
        }.buttonStyle(.plain)
    }
    private func expand() {
        guard let item = nowPlaying.playback?.item else { return }
        nowPlaying.expandRequest = item
        // Back to the section this item lives in.
        switch MediaCatalog.category(item, media.info[item.progressKey]) {
        case .audiobooks: navigation.selection = .audiobooks
        case .music: navigation.selection = .music
        case .books: navigation.selection = .books
        default: navigation.selection = .media
        }
    }
}
