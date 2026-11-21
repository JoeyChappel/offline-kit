import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
// Drag files from Finder onto the window to add them to the kit. Mac only for now.

/// What a dropped file is, and where in the kit it belongs.
enum ImportKind: String, CaseIterable, Identifiable, Sendable {
    case reference, video, audio, album, audiobook, book, game, document, unsupported
    var id: String { rawValue }

    var label: String {
        switch self {
        case .reference: "Reference archive"
        case .video: "Video"
        case .audio: "Song"
        case .album: "Album"
        case .audiobook: "Audiobook"
        case .book: "Book (EPUB or PDF)"
        case .game: "Game"
        case .document: "PDF document"
        case .unsupported: "Can’t add this"
        }
    }

    var symbol: String {
        switch self {
        case .reference: "books.vertical"
        case .video: "film"
        case .audio: "music.note"
        case .album: "square.stack"
        case .audiobook: "headphones"
        case .book: "book.closed"
        case .game: "gamecontroller"
        case .document: "doc.richtext"
        case .unsupported: "questionmark.square.dashed"
        }
    }

    /// Where it shows up in the app.
    var shelf: String {
        switch self {
        case .reference: "Library"
        case .video: "Watch"
        case .audio, .album: "Music"
        case .audiobook: "Audiobooks"
        case .book: "Books"
        case .game: "Play"
        case .document: "Everything saved › Your documents"
        case .unsupported: ""
        }
    }

    var isMedia: Bool { [.video, .audio, .album, .audiobook, .book].contains(self) }

    /// The folder inside the library. Songs and albums go in Media/Music and audiobooks in Media/Audiobooks,
    /// so each shows in its own section (see MediaCatalog.category and MediaLibrary.holdsLooseTracks).
    func folder(in library: URL) -> URL {
        switch self {
        case .reference, .unsupported: library
        case .video: library.appending(path: "Media", directoryHint: .isDirectory)
        case .audio, .album: library.appending(path: "Media/Music", directoryHint: .isDirectory)
        case .audiobook: library.appending(path: "Media/Audiobooks", directoryHint: .isDirectory)
        case .game: library.appending(path: "Games", directoryHint: .isDirectory)
        case .book: library.appending(path: "Media/Books", directoryHint: .isDirectory)
        case .document: library.appending(path: "Documents", directoryHint: .isDirectory)
        }
    }

    static func classify(_ url: URL) -> ImportKind {
        if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let files = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
            let audio = files.filter { MediaLibrary.audioExtensions.contains($0.pathExtension.lowercased()) }
            guard !audio.isEmpty else { return .unsupported }
            // The same signs the library uses: .m4b files, an audiobook folder name, chapter-named tracks.
            let name = url.lastPathComponent.lowercased()
            if audio.contains(where: { $0.pathExtension.lowercased() == "m4b" }) || name.contains("audiobook") || name.contains("librivox") { return .audiobook }
            let chapterish = audio.filter {
                $0.deletingPathExtension().lastPathComponent.lowercased().range(of: #"chapter|chap\.|\bch\s?\d|\bpart\s?\d|\bbook\s?\d"#, options: .regularExpression) != nil
            }
            return chapterish.count * 2 >= audio.count && audio.count > 1 ? .audiobook : .album
        }
        let ext = url.pathExtension.lowercased()
        if ext == "zim" { return .reference }
        if ext == "pdf" { return .document }   // manuals and guides; switch to Book in the sheet for a novel
        if ext == "epub" { return .book }
        if MediaLibrary.videoExtensions.contains(ext) { return .video }
        if ext == "m4b" { return .audiobook }
        if MediaLibrary.audioExtensions.contains(ext) { return .audio }
        if GameSystem(file: url) != nil { return .game }
        return .unsupported
    }

    /// What a file becomes when it was added from a section's + button: a PDF picked in Books is a book,
    /// audio picked in Audiobooks is an audiobook, a folder picked in Music is an album.
    func preferring(_ section: ImportKind?, isFolder: Bool) -> ImportKind {
        switch (section, self) {
        case (.book?, .document): .book
        case (.audiobook?, .audio), (.audiobook?, .album): .audiobook
        case (.audio?, .audiobook) where isFolder: .album
        case (.album?, .audiobook) where isFolder: .album
        default: self
        }
    }
}

struct ImportItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    var kind: ImportKind
    let size: Int64
    /// A different file with the same name is already there: replace it (off: keep both, as "Name 2").
    var replace = false
    /// The same file (size and checksum) is already somewhere in the kit's Media folder: where, for the row.
    var duplicateOf: String?
    /// Add it again even though it's already in the kit.
    var addAnyway = false
    var name: String { url.lastPathComponent }
    var skipped: Bool { kind.isMedia && duplicateOf != nil && !addAnyway }
}

@MainActor @Observable
final class DropImporter {
    var items: [ImportItem] = []
    /// Move instead of copy: originals go to the Trash once their copy is complete. Off again for every new drop.
    var moveOriginals = false
    var isPresented = false
    var destination: SaveLocation? { didSet { if oldValue != destination { checkDuplicates() } } }
    var locations: [SaveLocation] = []
    private(set) var copying = false
    private(set) var finished = 0
    private(set) var current = ""
    private(set) var failures: [String] = []
    private(set) var done = false
    /// True while the kit is being checked for files it already has.
    private(set) var checking = false
    @ObservationIgnored private var checkTask: Task<Void, Never>?

    /// Folders of loose files are opened up; folders of audio stay together as an audiobook or album.
    /// `section` is set when files come from a section's + button, so they land in that section.
    func receive(_ urls: [URL], section: ImportKind? = nil) {
        guard !copying else { return }
        var list: [ImportItem] = []
        func item(_ url: URL) -> ImportItem {
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            return ImportItem(url: url, kind: ImportKind.classify(url).preferring(section, isFolder: isFolder), size: KitTransfer.size(of: url))
        }
        for url in urls {
            let kind = ImportKind.classify(url)
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            if isFolder && kind == .unsupported {
                let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                list += inside.map(item)
            } else {
                list.append(item(url))
            }
        }
        guard !list.isEmpty else { return }
        items = list
        moveOriginals = false
        locations = SaveLocation.available()
        // Always offer, and pre-select, the library location they chose, even a custom folder.
        let primary = KitStorage.primaryLibrary
        if !locations.contains(where: { $0.folder.standardizedFileURL.path == primary.standardizedFileURL.path }) {
            let parts = primary.pathComponents
            let onDrive = parts.count > 2 && parts[1] == "Volumes"
            locations.insert(SaveLocation(folder: primary, name: onDrive ? parts[2] : primary.lastPathComponent,
                                          symbol: onDrive ? "externaldrive" : "folder"), at: 0)
        }
        copying = false; finished = 0; failures = []; done = false
        destination = locations.first { $0.folder.standardizedFileURL.path == primary.standardizedFileURL.path }
        checkDuplicates()
        isPresented = true
    }

    var addable: [ImportItem] { items.filter { $0.kind != .unsupported } }
    /// What "Add to Kit" copies: everything addable except what's already in the kit (unless asked to add it again).
    var toCopy: [ImportItem] { addable.filter { !$0.skipped } }
    var totalBytes: Int64 { toCopy.reduce(0) { $0 + $1.size } }

    func target(_ item: ImportItem) -> URL? {
        guard let library = destination?.folder, item.kind != .unsupported else { return nil }
        return item.kind.folder(in: library).appending(path: item.name)
    }

    func exists(_ item: ImportItem) -> Bool {
        target(item).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Looks through the destination's Media folder for files that are already there under any name
    /// (same size, then the same checksum, as Find my media does). Those are skipped unless asked for again.
    func checkDuplicates() {
        checkTask?.cancel()
        guard let library = destination?.folder, !items.isEmpty else { return }
        let media = library.appending(path: "Media", directoryHint: .isDirectory)
        let list = items.filter { $0.kind.isMedia }
        checking = true
        checkTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { Self.duplicates(list, in: media) }.value
            guard let self, !Task.isCancelled else { return }
            for index in self.items.indices { self.items[index].duplicateOf = found[self.items[index].id] }
            self.checking = false
        }
    }

    /// Each item whose every file is already in `media`, with where the copy is (relative to Media).
    nonisolated static func duplicates(_ items: [ImportItem], in media: URL) -> [UUID: String] {
        guard !items.isEmpty else { return [:] }
        let fm = FileManager.default
        var bySize: [Int64: [URL]] = [:]
        if let walker = fm.enumerator(at: media, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true,
                      let size = values.fileSize, size > 0 else { continue }
                bySize[Int64(size), default: []].append(url)
            }
        }
        func copy(of file: URL) -> URL? {
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0,
                  let candidates = bySize[Int64(size)]?.filter({ $0.standardizedFileURL.path != file.standardizedFileURL.path }), !candidates.isEmpty,
                  let mine = FileChecksum.fingerprint(file, size: Int64(size)) else { return nil }
            return candidates.first { FileChecksum.fingerprint($0, size: Int64(size)) == mine }
        }
        var out: [UUID: String] = [:]
        for item in items {
            if Task.isCancelled { break }
            let isFolder = (try? item.url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            let files = isFolder
                ? ((try? fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                    .filter { MediaLibrary.audioExtensions.contains($0.pathExtension.lowercased()) }
                : [item.url]
            guard !files.isEmpty else { continue }
            var first: URL?
            var all = true
            for file in files {
                guard let match = copy(of: file) else { all = false; break }
                first = first ?? match
            }
            guard all, let first else { continue }
            let shown = isFolder ? first.deletingLastPathComponent() : first
            let base = media.standardizedFileURL.path
            let path = shown.standardizedFileURL.path
            out[item.id] = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : shown.lastPathComponent
        }
        return out
    }

    /// Copies everything new. A different file with the same name is replaced only when asked; otherwise both are kept.
    /// Large movies take a while; the sheet shows which file is copying.
    func run(library: Library, media: MediaLibrary, games: GameLibrary) async {
        guard let destination else { return }
        copying = true
        let jobs = toCopy.compactMap { item -> (ImportItem, URL)? in
            guard var target = target(item) else { return nil }
            if FileManager.default.fileExists(atPath: target.path) && !item.replace { target = Self.freeName(target) }
            return (item, target)
        }
        let move = moveOriginals
        for (item, target) in jobs {
            current = item.name
            let result: String? = await Task.detached(priority: .userInitiated) {
                let scoped = item.url.startAccessingSecurityScopedResource()
                defer { if scoped { item.url.stopAccessingSecurityScopedResource() } }
                return KitTransfer.transfer(item.url, to: target, move: move, replace: true)
            }.value
            if let result { failures.append(result) }
            finished += 1
        }
        current = ""
        // A library folder the app doesn't scan yet becomes part of the kit.
        let newFolder = library.adopt(destination.folder)
        // Rescan only what was added to (everything for a newly added folder), and say "done" once it's on screen.
        let kinds = newFolder ? Set(ImportKind.allCases) : Set(jobs.map(\.0.kind))
        if kinds.contains(.reference) { await library.reload() }
        if kinds.contains(where: \.isMedia) { await media.reload(library: library) }
        if kinds.contains(.game) { await games.reload(library: library) }
        if kinds.contains(.document) { KitChanges.shared.documentsChanged() }
        copying = false
        done = true
    }

    /// "Name 2.mp4" (or "Name 2" for a folder) beside a different file that already has the name.
    nonisolated static func freeName(_ target: URL) -> URL {
        let fm = FileManager.default
        let base = target.deletingPathExtension().lastPathComponent, ext = target.pathExtension
        for n in 2...999 {
            let candidate = target.deletingLastPathComponent().appending(path: ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return target
    }

    /// Where the things added can be found, for the "done" line: "Watch and Music".
    var shelves: String {
        var names: [String] = []
        for item in toCopy where !names.contains(item.kind.shelf) && !item.kind.shelf.isEmpty { names.append(item.kind.shelf) }
        return ListFormatter.localizedString(byJoining: names)
    }
}

/// Copies or moves one file or folder into the kit. Shared by dropped files and Find my media.
/// A move on the same disk is a rename. Across disks it's copy, verify (size, then checksum for files), and only
/// then the original goes to the Trash. Returns a message for the person when something went wrong.
enum KitTransfer {
    nonisolated static func transfer(_ source: URL, to target: URL, move: Bool, replace: Bool) -> String? {
        let fm = FileManager.default
        let name = source.lastPathComponent
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if source.standardizedFileURL == target.standardizedFileURL { return nil }   // already in place
            if fm.fileExists(atPath: target.path) {
                guard replace else { return nil }
                try fm.removeItem(at: target)
            }
            let sameDisk = volume(of: source) == volume(of: target.deletingLastPathComponent())
            if move && sameDisk {
                try fm.moveItem(at: source, to: target)        // instant on the same disk
            } else {
                try fm.copyItem(at: source, to: target)
                // Moving across disks: the original goes to the Trash only once the copy is complete and checks out.
                if move {
                    guard verify(target, matches: source) else {
                        return "\(name): the copy didn’t match the original, so the original was kept."
                    }
                    try fm.trashItem(at: source, resultingItemURL: nil)
                }
            }
            return nil
        } catch {
            return "\(name): \(explain(error))"
        }
    }

    /// Same size, and for a single file the same SHA-256 of its contents.
    nonisolated static func verify(_ copy: URL, matches original: URL) -> Bool {
        guard size(of: copy) == size(of: original) else { return false }
        guard (try? original.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { return true }
        guard let a = FileChecksum.sha256(copy), let b = FileChecksum.sha256(original) else { return false }
        return a == b
    }

    nonisolated static func explain(_ error: Error) -> String {
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError): return "the drive is full."
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError), (NSCocoaErrorDomain, NSFileReadNoPermissionError):
            return "Offline Kit isn’t allowed to use that drive. Check System Settings › Privacy & Security › Files and Folders."
        case (NSCocoaErrorDomain, NSFileWriteVolumeReadOnlyError): return "the drive is read-only."
        case (NSCocoaErrorDomain, NSFileReadNoSuchFileError): return "the original file was moved or its drive was unplugged."
        default:
            let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            if (ns.domain == NSPOSIXErrorDomain && ns.code == Int(EFBIG))
                || (underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(EFBIG)) {
                return "it’s over 4 GB and the drive is formatted as FAT32, which can’t hold files that big."
            }
            return ns.localizedDescription
        }
    }

    nonisolated static func volume(of url: URL) -> URL? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" { probe.deleteLastPathComponent() }
        return (try? probe.resourceValues(forKeys: [.volumeURLKey]))?.volume
    }

    nonisolated static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isDirectory != true { return Int64(values.fileSize ?? 0) }
        var total: Int64 = 0
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let file = walker?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - Drop target

extension View {
    /// Accepts files dropped anywhere on the window and asks where they should go.
    func acceptsKitDrops(_ importer: DropImporter) -> some View { modifier(KitDropModifier(importer: importer)) }
}

private struct KitDropModifier: ViewModifier {
    let importer: DropImporter
    @State private var targeted = false

    func body(content: Content) -> some View {
        content
            // Sections' + buttons send their picks through the same sheet.
            .environment(importer)
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                Task { @MainActor in
                    var urls: [URL] = []
                    for provider in providers {
                        if let url = try? await provider.loadFileURL() { urls.append(url) }
                    }
                    importer.receive(urls)
                }
                return true
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            Label("Drop to add to your kit", systemImage: "square.and.arrow.down")
                                .font(.title2.bold()).padding(18)
                                .background(.regularMaterial, in: Capsule())
                        }
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .sheet(isPresented: Binding(get: { importer.isPresented }, set: { importer.isPresented = $0 })) {
                DropImportSheet(importer: importer)
            }
    }
}

private extension NSItemProvider {
    func loadFileURL() async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: url) }
            }
        }
    }
}

// MARK: - Confirm sheet

private struct DropImportSheet: View {
    @Bindable var importer: DropImporter
    @Environment(Library.self) private var library
    @Environment(MediaLibrary.self) private var media
    @Environment(GameLibrary.self) private var games
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach($importer.items) { $item in row($item) }
                }
            }
            .frame(minHeight: 120, maxHeight: 360)
            footer
        }
        .padding(24)
        .frame(minWidth: 560)
        .interactiveDismissDisabled(importer.copying)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(importer.done ? "Added to your kit" : "Add \(importer.toCopy.count) \(importer.toCopy.count == 1 ? "item" : "items") to your kit?")
                .font(.title2.bold())
            if !importer.done {
                Text("Each file goes where it belongs. Change anything that looks wrong.")
                    .foregroundStyle(.secondary)
                Picker("Save to", selection: $importer.destination) {
                    ForEach(importer.locations) { location in
                        Label("\(location.name) · \(ByteCountFormatter.string(fromByteCount: location.freeSpace, countStyle: .file)) free",
                              systemImage: location.symbol).tag(Optional(location))
                    }
                }
                .disabled(importer.copying)
                Toggle(isOn: $importer.moveOriginals) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Move instead of copy")
                        Text("The originals go to the Trash once each copy is complete.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(importer.copying)
            }
        }
    }

    private func row(_ item: Binding<ImportItem>) -> some View {
        let value = item.wrappedValue
        let exists = importer.exists(value)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: value.kind.symbol).font(.title3)
                .foregroundStyle(value.kind == .unsupported || value.skipped ? Color.secondary : Color.accentColor).frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(value.name).font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if value.kind == .unsupported {
                    Text("Offline Kit can’t use this kind of file.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Goes to \(value.kind.shelf) · \(ByteCountFormatter.string(fromByteCount: value.size, countStyle: .file))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let copy = value.duplicateOf, value.kind.isMedia, !importer.done {
                    Label("Already in your kit (Media › \(copy.replacingOccurrences(of: "/", with: " › "))), so it’s skipped.", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    Toggle(isOn: item.addAnyway) { Text("Add another copy anyway").font(.caption) }
                        .toggleStyle(.checkbox).disabled(importer.copying)
                } else if exists && value.kind != .unsupported && !importer.done {
                    Toggle(isOn: item.replace) {
                        Text("Something with this name is already there. Replace it (otherwise both are kept)").font(.caption)
                    }
                    .toggleStyle(.checkbox).disabled(importer.copying)
                }
            }
            Spacer()
            if value.kind != .unsupported && !importer.done {
                Picker("Type", selection: item.kind) {
                    ForEach(ImportKind.allCases.filter { $0 != .unsupported }) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize()
                .disabled(importer.copying)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder private var footer: some View {
        let free = importer.destination?.freeSpace ?? 0
        let fits = importer.totalBytes < free - 200_000_000
        let tooBigForFAT = importer.destination?.isFAT32 == true && importer.toCopy.contains { $0.size >= 4_294_967_295 }
        VStack(alignment: .leading, spacing: 10) {
            if importer.copying {
                ProgressView(value: Double(importer.finished), total: Double(max(importer.toCopy.count, 1))) {
                    Text(importer.current.isEmpty ? "Updating your kit…" : "Copying \(importer.current)…").lineLimit(1).truncationMode(.middle)
                }
                Text("Big movies can take a few minutes. Keep the drive plugged in.").font(.caption).foregroundStyle(.secondary)
            } else if importer.done {
                if importer.failures.isEmpty {
                    Label(importer.toCopy.isEmpty ? "Nothing new to add: it’s all in your kit already."
                          : "Everything was \(importer.moveOriginals ? "moved" : "added"). Find it in \(importer.shelves).", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Label("Some files couldn’t be added:", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    ForEach(importer.failures, id: \.self) { Text($0).font(.callout) }
                }
            } else {
                if !fits {
                    Label("Not enough room on \(importer.destination?.name ?? "that drive"). Choose another place or fewer files.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if tooBigForFAT {
                    Label("A file is over 4 GB and \(importer.destination?.name ?? "this drive") uses FAT32, which can’t hold it. Choose another place.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            HStack {
                Text(importer.done ? "" : importer.checking ? "Checking what’s already in your kit…" : "\(ByteCountFormatter.string(fromByteCount: importer.totalBytes, countStyle: .file)) to copy")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                if importer.done {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                } else {
                    Button("Cancel", role: .cancel) { dismiss() }.disabled(importer.copying)
                    Button(importer.moveOriginals ? "Move to Kit" : "Add to Kit") {
                        // A one-off choice here never changes where the kit lives; only Get Resources and setup do.
                        Task { await importer.run(library: library, media: media, games: games) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(importer.copying || importer.checking || importer.toCopy.isEmpty || !fits || tooBigForFAT || importer.destination == nil)
                }
            }
        }
    }
}
#endif
