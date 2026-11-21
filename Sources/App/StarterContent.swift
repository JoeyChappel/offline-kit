import SwiftUI

/// Classic public-domain books shipped inside the app, copied into the kit once so they're there
/// on day one, travel with the drive and can be deleted like anything else.
enum StarterBooks {
    static var bundled: [URL] {
        guard let folder = Bundle.main.url(forResource: "StarterBooks", withExtension: nil),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == "epub" }
    }

    static var folder: URL { KitStorage.media.appending(path: "Books/Classics", directoryHint: .isDirectory) }

    private static let doneKey = "starterBooksInstalled"

    /// First launch: copy the books in. Later launches do nothing, so deleted books stay deleted.
    /// Returns true when it copied the books, so the caller rescans Media.
    @discardableResult
    static func installIfNeeded() async -> Bool {
        guard KitSettings.shared.bool(forKey: doneKey) != true, !bundled.isEmpty else { return false }
        guard await copyMissing() else { return false }
        KitSettings.shared.set(true, forKey: doneKey)
        return true
    }

    /// Puts back any of the starter books that are missing. Returns false if the folder can't be written.
    @discardableResult
    static func copyMissing() async -> Bool {
        let sources = bundled, destination = folder
        return await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard (try? fm.createDirectory(at: destination, withIntermediateDirectories: true)) != nil else { return false }
            for source in sources {
                let target = destination.appending(path: source.lastPathComponent)
                if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: source, to: target) }
            }
            return true
        }.value
    }

    static var missingCount: Int {
        bundled.filter { !FileManager.default.fileExists(atPath: folder.appending(path: $0.lastPathComponent).path) }.count
    }
}

/// Free short films from Blender Studio (CC-BY), downloaded with one tap from Watch & Listen.
@MainActor @Observable
final class StarterFilms {
    struct Film: Identifiable { let title: String; let url: URL; let bytes: Int64; var id: String { title } }

    /// Checked November 2026. studio.blender.org redirects each link to a short-lived signed file URL.
    static let films: [Film] = {
        let base = "https://studio.blender.org/download-source/files/"
        return [
            ("Tears of Steel (2012)", "0d/0d4beb382f57cec10fa3e54c13c5c02e24e53f02/0d4beb382f57cec10fa3e54c13c5c02e24e53f02.mp4", 505_533_124),
            ("Elephants Dream (2006)", "72/729ec3647df164d468c53e4798e13f4fabf75ce3/729ec3647df164d468c53e4798e13f4fabf75ce3.mp4", 545_538_641),
            ("Cosmos Laundromat (2015)", "9e/9e18c8684db6ae04cc458477554f2976062f4d9d/9e18c8684db6ae04cc458477554f2976062f4d9d.mp4", 525_038_123),
            ("Sintel (2010)", "47/47a954682dbd4f064da7e78ad6c2d32f044a3e85/47a954682dbd4f064da7e78ad6c2d32f044a3e85.mp4", 224_702_298),
            ("Caminandes - Llamigos (2016)", "26/263f328078fbebd508a0d3262f4fb4da5f16439f/263f328078fbebd508a0d3262f4fb4da5f16439f-1080p.mp4", 138_945_811),
            ("Caminandes - Gran Dillama (2013)", "ff/ff0cd0946c500c32da78c8f3101b02eb670df72c/ff0cd0946c500c32da78c8f3101b02eb670df72c.mp4", 116_672_105),
            ("Glass Half (2015)", "c6/c63ddc47dd56cf369557e969f15e2cb644aa421a/c63ddc47dd56cf369557e969f15e2cb644aa421a-1080p.mp4", 65_761_189),
            ("Caminandes - Llama Drama (2013)", "fe/fe8c9ad1bc842403f24f46375709ead8b5fb154c/fe8c9ad1bc842403f24f46375709ead8b5fb154c.mp4", 34_169_004),
        ].map { Film(title: $0.0, url: URL(string: base + $0.1)!, bytes: $0.2) }
    }()

    static var totalBytes: Int64 { films.reduce(0) { $0 + $1.bytes } }
    static var folder: URL { KitStorage.media.appending(path: "Blender Films", directoryHint: .isDirectory) }

    enum State: Equatable { case idle, downloading(index: Int, title: String), done, failed(String) }
    private(set) var state: State = .idle
    private var task: Task<Void, Never>?

    func target(_ film: Film) -> URL { Self.folder.appending(path: film.title + ".mp4") }
    var missing: [Film] { Self.films.filter { !FileManager.default.fileExists(atPath: target($0).path) } }
    var missingBytes: Int64 { missing.reduce(0) { $0 + $1.bytes } }

    func getAll(onFinished: @escaping () -> Void) {
        guard task == nil else { return }
        let todo = missing
        task = Task {
            defer { task = nil }
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            for (index, film) in todo.enumerated() {
                state = .downloading(index: index + 1, title: film.title)
                do {
                    let (temp, response) = try await URLSession.shared.download(from: film.url)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    let destination = target(film)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: temp, to: destination)
                    onFinished()
                } catch {
                    if Task.isCancelled { state = .idle; return }
                    state = .failed("Couldn’t download \(MediaCatalog.displayTitle(film.title)). Check the internet connection and try again.")
                    return
                }
            }
            state = .done
            onFinished()
        }
    }

    func cancel() { task?.cancel(); task = nil; state = .idle }
}

/// The "free to keep" starter card in Watch & Listen.
struct StarterPackCard: View {
    @Environment(StarterFilms.self) private var films
    @Environment(MediaLibrary.self) private var media
    @Environment(Library.self) private var library
    @State private var booksMissing = StarterBooks.missingCount

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                KitSymbol("gift")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Free to keep").font(.headline)
                    Text("Films and books that are free to download and share. Get them once and they work offline for good.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("8 short films from Blender Studio")
                    Text("Animated and live-action shorts, 2 to 15 minutes each. Creative Commons (CC-BY): credit Blender Studio if you share them.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                filmsControl
            }
            if !StarterBooks.bundled.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(StarterBooks.bundled.count) classic books")
                        Text("The Secret Garden, Treasure Island, Robinson Crusoe, Walden and more, from Standard Ebooks. Public domain.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    if booksMissing == 0 {
                        Pill(text: "In Books", symbol: "checkmark", tint: .accentColor)
                    } else {
                        Button("Add \(booksMissing) Books") {
                            Task {
                                await StarterBooks.copyMissing()
                                booksMissing = StarterBooks.missingCount
                                await media.reload(library: library)
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
        .card(padding: 18)
    }

    @ViewBuilder private var filmsControl: some View {
        switch films.state {
        case .downloading(let index, let title):
            VStack(alignment: .trailing, spacing: 4) {
                ProgressView().controlSize(.small)
                Text("\(index) of \(films.missing.count + index - 1): \(MediaCatalog.displayTitle(title))").font(.caption).foregroundStyle(.secondary)
                Button("Stop") { films.cancel() }.buttonStyle(.borderless).font(.caption)
            }
        case .failed(let message):
            VStack(alignment: .trailing, spacing: 4) {
                Text(message).font(.caption).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                getButton
            }
        default:
            if films.missing.isEmpty {
                Pill(text: "In Watch", symbol: "checkmark", tint: .accentColor)
            } else {
                getButton
            }
        }
    }

    private var getButton: some View {
        Button("Get · \(ByteCountFormatter.string(fromByteCount: films.missingBytes, countStyle: .file))") {
            films.getAll { Task { await media.reload(library: library) } }
        }
        .buttonStyle(.borderedProminent)
        .help("Downloads to the Media folder in your kit. Needs internet; takes a while on slow connections.")
    }
}
