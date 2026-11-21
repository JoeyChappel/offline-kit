import SwiftUI

/// The "Send to iPhone" card on the Share on Wi-Fi page: what's waiting for phones, with the total size.
struct SendListSection: View {
    @Environment(ShareController.self) private var share
    @Environment(MediaLibrary.self) private var media
    @Environment(GameLibrary.self) private var games
    @Environment(Library.self) private var library
    private var list: SendList { SendList.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label("Send to iPhone", systemImage: "iphone.and.arrow.forward").font(.headline)
                Spacer()
                if !list.entries.isEmpty {
                    Text("\(list.entries.count) item\(list.entries.count == 1 ? "" : "s") · \(bytes(list.totalSize))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Text("Take movies, audiobooks, music, books, games and references on a trip. Right-click something in Watch, Audiobooks, Music, Books, Play or Library and choose Send to iPhone. Then, on the iPhone, open Offline Kit › Get › From your Mac while it's on this Wi-Fi.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !share.isRunning && !list.entries.isEmpty {
                Label("Turn on Share on Wi-Fi above so the iPhone can find this Mac.", systemImage: "wifi.exclamationmark")
                    .font(.callout).foregroundStyle(.orange)
            }
            if list.entries.isEmpty {
                Text("Nothing picked yet.").font(.callout).foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(list.entries) { entry in
                        row(entry)
                        if entry.id != list.entries.last?.id { Divider() }
                    }
                }
                HStack {
                    if list.entries.contains(where: { !$0.receivedBy.isEmpty }) {
                        Button("Clear Downloaded", systemImage: "checkmark.circle") { list.clearReceived() }
                            .help("Remove items a phone has already downloaded.")
                    }
                    Spacer()
                    Text("Phones download over your home Wi-Fi only. Nothing goes to the internet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .card(padding: 18)
        #if DEBUG
        .task { await addTestPicks() }
        #endif
    }

    #if DEBUG
    /// Test hook: -sendTestPicks "Title|Title|…" adds those media items, games, references and PDFs, as Send to iPhone would.
    private func addTestPicks() async {
        guard let names = UserDefaults.standard.string(forKey: "sendTestPicks")?.split(separator: "|").map(String.init) else { return }
        await library.reload()
        await StarterBooks.installIfNeeded()
        await media.reload(library: library)
        await games.reload(library: library)
        let documents = DocumentShelf.scan(DocumentShelf.folders(library: library))
        for name in names {
            if let item = media.items.first(where: { $0.title == name }) { list.add(.media(item, info: media.info[item.progressKey])) }
            else if let game = games.games.first(where: { $0.title == name }) { list.add(.game(game)) }
            else if let book = library.books.first(where: { $0.shortTitle == name }) { list.add(.archive(book)) }
            else if let doc = documents.first(where: { $0.title == name }) { list.add(.document(doc)) }
        }
        // -sendSnapshot <path.png>: draws this window to a picture, for checking the layout without screen recording.
        if let path = UserDefaults.standard.string(forKey: "sendSnapshot") {
            try? await Task.sleep(for: .seconds(2))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }), let view = window.contentView else { return }
            window.setFrame(NSRect(x: window.frame.minX, y: 40, width: 1100, height: 1500), display: true)
            try? await Task.sleep(for: .seconds(1))
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif

    private func row(_ entry: SendList.Entry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: entry.kind.symbol).frame(width: 22).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(1)
                Text([entry.detail ?? entry.kind.label, bytes(entry.size)].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if entry.receivedBy.isEmpty {
                Text("Waiting").font(.caption).foregroundStyle(.secondary)
            } else {
                Label("On \(entry.receivedBy.keys.sorted().joined(separator: ", "))", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).lineLimit(1)
            }
            Button { list.remove(entry.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Remove from Send to iPhone")
                .accessibilityLabel("Remove \(entry.title)")
        }
        .padding(.vertical, 8)
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}
