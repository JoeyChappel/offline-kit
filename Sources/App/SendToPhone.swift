import SwiftUI

/// Something in the library that can be sent to an iPhone: its files, and where they go in the phone's library.
struct SendSource: Hashable {
    var kind: SendKind
    var title: String
    var detail: String?
    /// Files or folders on this device.
    var paths: [URL]
    /// The phone's paths are measured from here, under `prefix` ("Media", "Games", "Documents", or "" for a reference archive).
    var base: URL
    var prefix: String

    var key: String { paths.first?.standardizedFileURL.path ?? title }

    /// A movie, an album or audiobook (its whole folder), a song, or an EPUB or PDF in the Media folder. Custom covers go along.
    static func media(_ item: MediaItem, info: MediaInfo? = nil) -> SendSource {
        let kind: SendKind = switch item.kind { case .video: .video; case .audio: .audio; case .book: .book }
        let paths: [URL]
        if item.kind == .audio, MediaCover.isFolderItem(item) {
            paths = [item.tracks[0].deletingLastPathComponent()]
        } else {
            paths = item.tracks + item.tracks.compactMap(MediaCover.sidecar(for:))
        }
        let detail: String? = item.kind == .audio && item.tracks.count > 1 ? "\(item.tracks.count) tracks" : nil
        return SendSource(kind: kind, title: MediaCatalog.title(item, info), detail: detail, paths: paths, base: item.root, prefix: "Media")
    }

    /// A game file (or a ScummVM game folder) and its picture, kept under the same console subfolder. Saves stay behind.
    static func game(_ game: Game) -> SendSource {
        var paths = [game.url]
        if FileManager.default.fileExists(atPath: game.thumbnailURL.path) { paths.append(game.thumbnailURL) }
        return SendSource(kind: .game, title: game.title, detail: game.system.name, paths: paths,
                          base: GameLibrary.gamesRoot(containing: game.url), prefix: "Games")
    }

    static func archive(_ book: Book) -> SendSource {
        SendSource(kind: .archive, title: book.shortTitle, detail: book.kind.title, paths: [book.url],
                   base: book.url.deletingLastPathComponent(), prefix: "")
    }

    static func document(_ doc: SavedDocument) -> SendSource {
        SendSource(kind: .document, title: doc.title, detail: nil, paths: [doc.url], base: doc.url.deletingLastPathComponent(), prefix: "Documents")
    }
}

/// "Send to iPhone" for right-click menus and detail pages. Mac only; nothing on iPhone and iPad.
struct SendToPhoneButton: View {
    let source: SendSource

    var body: some View {
        #if os(macOS)
        let queued = SendList.shared.contains(source)
        Button(queued ? "Remove from Send to iPhone" : "Send to iPhone",
               systemImage: queued ? "iphone.slash" : "iphone.and.arrow.forward") {
            SendList.shared.toggle(source)
        }
        .help(queued ? "Take this off the list for your iPhone." : "Add this to the list your iPhone downloads over Wi-Fi. See Share on Wi-Fi.")
        #endif
    }
}

#if os(macOS)
/// A brief "Added to Send to iPhone" note at the bottom of the screen after the list changes.
struct SendNoticeBanner: View {
    @State private var shown: SendList.Notice?
    var body: some View {
        Group {
            if let shown {
                Label(shown.text, systemImage: shown.added ? "checkmark.circle.fill" : "iphone.slash")
                    .font(.callout.weight(.semibold)).lineLimit(2)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeOut(duration: 0.2), value: shown)
        .onChange(of: SendList.shared.notice) { _, notice in
            guard let notice else { return }
            shown = notice
            AccessibilityNotification.Announcement(notice.text).post()
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                if shown?.id == notice.id { shown = nil }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small iPhone badge on cards that are on the Send to iPhone list.
struct SendQueuedBadge: View {
    let item: MediaItem
    var body: some View {
        if item.unavailable == nil, SendList.shared.contains(.media(item)) {
            Image(systemName: "iphone").font(.caption.bold()).padding(6)
                .background(.black.opacity(0.8), in: Circle()).foregroundStyle(.white).padding(8)
                .help("On the Send to iPhone list")
                .accessibilityLabel("On the Send to iPhone list")
        }
    }
}
#endif

extension SendToPhoneButton {
    init(media item: MediaItem, info: MediaInfo? = nil) { self.init(source: .media(item, info: info)) }
    init(game: Game) { self.init(source: .game(game)) }
    init(archive book: Book) { self.init(source: .archive(book)) }
    init(document doc: SavedDocument) { self.init(source: .document(doc)) }
}

extension View {
    /// Right-click menu on Mac with Show in Finder and Send to iPhone.
    @ViewBuilder func sendableMenu(_ url: URL, _ source: SendSource) -> some View {
        #if os(macOS)
        contextMenu {
            ShowInFinderButton(url: url)
            SendToPhoneButton(source: source)
        }
        #else
        self
        #endif
    }
}
