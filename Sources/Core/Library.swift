import Foundation
import Observation

extension ZimArchive: @unchecked Sendable {}

/// A pointer to one article inside one archive.
struct ArticleRef: Codable, Hashable, Identifiable, Sendable {
    var bookID: String
    var path: String
    var title: String = ""
    var id: String { bookID + "/" + path }

    var url: URL {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#;")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        return URL(string: "zim://\(bookID.lowercased())/\(encoded)")!
    }
}

struct Book: Identifiable, Hashable, Sendable {
    let archive: ZimArchive
    let url: URL
    let fileSize: Int64

    var id: String { archive.uuid.lowercased() }
    var title: String { archive.title }

    var mainPage: ArticleRef? {
        archive.mainPagePath.map { ArticleRef(bookID: id, path: $0, title: title) }
    }

    /// Display title without the "Q&A" noise Stack Exchange archives carry.
    var shortTitle: String {
        title.replacingOccurrences(of: " Q&A", with: "").replacingOccurrences(of: " in English", with: "")
    }

    static func == (a: Book, b: Book) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

/// Thread-safe archive lookup for the web view scheme handler and retriever.
final class ArchiveRegistry: @unchecked Sendable {
    static let shared = ArchiveRegistry()
    private let lock = NSLock()
    private var map: [String: ZimArchive] = [:]

    func set(_ archives: [ZimArchive]) {
        lock.withLock {
            map = Dictionary(archives.map { ($0.uuid.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func archive(_ id: String) -> ZimArchive? {
        lock.withLock { map[id.lowercased()] }
    }
}

@MainActor @Observable
final class Library {
    private(set) var books: [Book] = []
    /// Files found but not opened: still downloading, or unreadable.
    private(set) var skipped: [(url: URL, reason: String)] = []
    private(set) var isLoading = false
    /// Archives opened so far and how many there are, while a scan runs (a big USB drive takes a while).
    private(set) var opened = 0
    private(set) var toOpen = 0

    /// Extra folders the user added (Mac). Defaults are always scanned too.
    var extraFolders: [String] {
        didSet { KitSettings.shared.set(extraFolders, forKey: "extraFolders") }
    }

    init() {
        extraFolders = KitSettings.shared.stringArray(forKey: "extraFolders") ?? []
    }

    func book(_ id: String) -> Book? { books.first { $0.id == id.lowercased() } }

    /// Makes sure a library folder that things are being added to is scanned, so what's added shows up.
    /// (The chosen library can be a custom folder the app doesn't scan by default.) Mac only; elsewhere a no-op.
    /// Returns true when the folder is new to the library.
    @discardableResult
    func adopt(_ folder: URL) -> Bool {
        #if os(macOS)
        let path = folder.standardizedFileURL.path
        guard !folders.contains(where: { $0.standardizedFileURL.path == path }),
              !Self.defaultCandidates.contains(where: { $0.standardizedFileURL.path == path }) else { return false }
        extraFolders.append(folder.path)
        return true
        #else
        return false
        #endif
    }

    #if os(macOS)
    /// The default library locations whether or not they exist yet: one created by an import joins on the next scan.
    private static var defaultCandidates: [URL] {
        var urls = [KitLocation.home.appending(path: "OfflineKit/Library")]
        if let portable = KitLocation.portableLibrary { urls.append(portable) }
        if KitLocation.scansVolumes, let vols = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            urls += vols.map { URL(fileURLWithPath: "/Volumes/\($0)/OfflineKit/Library") }
        }
        return urls
    }
    #endif

    /// Folders scanned on every reload.
    var folders: [URL] {
        var urls = Self.defaultFolders
        urls += extraFolders.map { URL(fileURLWithPath: $0) }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    static var defaultFolders: [URL] {
        let fm = FileManager.default
        #if os(macOS)
        var urls: [URL] = []
        // Drive mode: the library beside the app comes first.
        if let portable = KitLocation.portableLibrary {
            try? fm.createDirectory(at: portable, withIntermediateDirectories: true)
            urls.append(portable)
        }
        urls.append(KitLocation.home.appending(path: "OfflineKit/Library"))
        if KitLocation.scansVolumes, let vols = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            urls += vols.map { URL(fileURLWithPath: "/Volumes/\($0)/OfflineKit/Library") }
        }
        return urls.filter { fm.fileExists(atPath: $0.path) }
        #else
        return [URL.documentsDirectory]
        #endif
    }

    /// Archives already open, keyed by path, size and date, so a rescan reuses them instead of opening every
    /// file again. Reopening dozens of archives on each rescan used up the app's open-file limit and crashed libzim.
    @ObservationIgnored private var openArchives: [String: Book] = [:]
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var scanAgain = false

    private static let raiseFileLimit: Void = {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let wanted = min(limit.rlim_max, 8_192)
        if limit.rlim_cur < wanted {
            limit.rlim_cur = wanted
            setrlimit(RLIMIT_NOFILE, &limit)
        }
    }()

    /// Rescans the library. Calls that arrive during a scan wait for it, then one more pass runs for all of them.
    func reload() async {
        _ = Self.raiseFileLimit
        if scanning {
            scanAgain = true
            while scanning { try? await Task.sleep(for: .milliseconds(100)) }
            return
        }
        scanning = true
        repeat {
            scanAgain = false
            await scanOnce()
        } while scanAgain
        scanning = false
    }

    private func scanOnce() async {
        isLoading = true
        // Internal folders first: reading an external drive can wait on a macOS permission prompt.
        let all = self.folders
        let local = all.filter { !$0.path.hasPrefix("/Volumes/") }
        let external = all.filter { $0.path.hasPrefix("/Volumes/") }
        var books: [Book] = []
        var skipped: [(url: URL, reason: String)] = []
        var seen = Set<String>()
        var stillThere = Set<String>()
        // On first open, show each reference as soon as it opens. A rescan keeps the old list until it's done,
        // so the library doesn't flicker.
        let incremental = self.books.isEmpty
        opened = 0
        toOpen = 0
        for batch in [local, external] where !batch.isEmpty {
            let found = await Task.detached(priority: .userInitiated) { Self.candidates(in: batch) }.value
            skipped += found.skipped
            toOpen += found.files.count
            // Files unchanged since the last scan keep their open archive.
            var fresh: [ArchiveFile] = []
            for file in found.files {
                if let book = openArchives[Self.key(file)] {
                    if seen.insert(book.archive.uuid.lowercased()).inserted { books.append(book) }
                    stillThere.insert(Self.key(file))
                    opened += 1
                } else {
                    fresh.append(file)
                }
            }
            if incremental && !books.isEmpty { publish(books, skipped) }
            for chunk in stride(from: 0, to: fresh.count, by: 4).map({ Array(fresh[$0..<min($0 + 4, fresh.count)]) }) {
                let result = await Task.detached(priority: .userInitiated) { Self.open(chunk) }.value
                for (file, book) in result.books {
                    openArchives[Self.key(file)] = book
                    stillThere.insert(Self.key(file))
                    if seen.insert(book.archive.uuid.lowercased()).inserted { books.append(book) }
                }
                skipped += result.skipped
                opened += chunk.count
                if incremental { publish(books, skipped) }
            }
            publish(books, skipped)
        }
        // Let go of archives whose files are gone or changed.
        openArchives = openArchives.filter { stillThere.contains($0.key) }
        publish(books, skipped)
        isLoading = false
        // Read the text of PDF libraries in the background so Ask can search them.
        PDFIndex.shared.prepare(self.books.map(\.archive))
    }

    private func publish(_ books: [Book], _ skipped: [(url: URL, reason: String)]) {
        self.books = books.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        self.skipped = skipped
        ArchiveRegistry.shared.set(self.books.map(\.archive))
    }

    typealias ArchiveFile = (url: URL, size: Int64, modified: Double)

    nonisolated static func key(_ file: ArchiveFile) -> String { "\(file.url.path)|\(file.size)|\(file.modified)" }

    /// Finds archive files quickly, without opening them.
    nonisolated static func candidates(in folders: [URL]) -> (files: [ArchiveFile], skipped: [(url: URL, reason: String)]) {
        let fm = FileManager.default
        var files: [ArchiveFile] = []
        var skipped: [(URL, String)] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        for folder in folders {
            guard let list = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { continue }
            for url in list where url.pathExtension.lowercased() == "zim" {
                // exFAT drives get "._name" AppleDouble companions; they are not archives.
                if url.lastPathComponent.hasPrefix("._") { continue }
                // aria2 keeps a ".aria2" control file beside a file until it is complete and verified.
                if fm.fileExists(atPath: url.path + ".aria2") {
                    skipped.append((url, "Still downloading"))
                    continue
                }
                let values = try? url.resourceValues(forKeys: Set(keys))
                if let modified = values?.contentModificationDate, modified > Date().addingTimeInterval(-120) {
                    skipped.append((url, "Still downloading"))
                    continue
                }
                // libzim can crash cleaning up after a damaged file, so check the header before opening.
                guard looksLikeZim(url) else {
                    skipped.append((url, "Damaged or incomplete file"))
                    continue
                }
                files.append((url, Int64(values?.fileSize ?? 0), values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        return (files, skipped)
    }

    /// A ZIM file starts with the magic number 72173914 (little-endian) and is at least a header long.
    nonisolated static func looksLikeZim(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 80), head.count == 80 else { return false }
        return Array(head.prefix(4)) == [0x5A, 0x49, 0x4D, 0x04]
    }

    nonisolated static func open(_ files: [ArchiveFile]) -> (books: [(ArchiveFile, Book)], skipped: [(url: URL, reason: String)]) {
        var books: [(ArchiveFile, Book)] = []
        var skipped: [(URL, String)] = []
        for file in files {
            #if DEBUG
            if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil { FileHandle.standardError.write(Data("opening \(file.url.path)\n".utf8)) }
            #endif
            do {
                books.append((file, Book(archive: try ZimArchive(path: file.url.path), url: file.url, fileSize: file.size)))
            } catch {
                skipped.append((file.url, error.localizedDescription))
            }
        }
        return (books, skipped)
    }

    nonisolated static func scan(_ folders: [URL]) -> (books: [Book], skipped: [(url: URL, reason: String)]) {
        let found = candidates(in: folders)
        let result = open(found.files)
        var seen = Set<String>()
        return (result.books.map(\.1).filter { seen.insert($0.archive.uuid.lowercased()).inserted }, found.skipped + result.skipped)
    }
}
