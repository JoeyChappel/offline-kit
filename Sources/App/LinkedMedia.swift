import Foundation
import CryptoKit

/// Media kept where it already is (an album in ~/Music, movies on another drive), remembered by the kit.
/// The list lives in the library folder ("Media/Linked Media.json") so it travels with the kit. When a drive
/// holding linked media isn't connected, those items show as unavailable instead of disappearing.
struct LinkedMediaEntry: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case video, audio, book }
    var id = UUID().uuidString
    var kind: Kind
    var title: String
    /// Artist or author, shown while the drive is away.
    var creator: String? = nil
    /// The album or audiobook folder, so tracks added there later show up. Nil for a single file.
    var folder: String?
    /// The files when linked, in play order.
    var tracks: [String]
    /// The drive's name when it isn't this Mac's own disk ("My Drive"), for "Connect My Drive".
    var volume: String?
    var added = Date()

    var catalogKey: String { "/@linked/\(id)" }
}

enum LinkedMedia {
    nonisolated static let fileName = "Linked Media.json"

    nonisolated static func file(in library: URL) -> URL {
        library.appending(path: "Media", directoryHint: .isDirectory).appending(path: fileName)
    }

    /// Every library folder's links, de-duplicated by id.
    nonisolated static func load(_ libraries: [URL]) -> [LinkedMediaEntry] {
        var seen = Set<String>(), out: [LinkedMediaEntry] = []
        for library in libraries {
            guard let data = try? Data(contentsOf: file(in: library)),
                  let list = try? JSONDecoder.catalog.decode([LinkedMediaEntry].self, from: data) else { continue }
            for entry in list where seen.insert(entry.id).inserted { out.append(entry) }
        }
        return out
    }

    /// Adds links to the library's list, skipping anything already linked (same first file).
    @discardableResult
    nonisolated static func add(_ entries: [LinkedMediaEntry], to library: URL) throws -> Int {
        let url = file(in: library)
        var list = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.catalog.decode([LinkedMediaEntry].self, from: $0) } ?? []
        let existing = Set(list.compactMap(\.tracks.first))
        let fresh = entries.filter { !($0.tracks.first.map(existing.contains) ?? true) }
        list += fresh
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.catalog.encode(list).write(to: url, options: .atomic)
        return fresh.count
    }

    /// Forgets a link. The files themselves are never touched.
    nonisolated static func remove(id: String, from libraries: [URL]) throws {
        for library in libraries {
            let url = file(in: library)
            guard let data = try? Data(contentsOf: url),
                  var list = try? JSONDecoder.catalog.decode([LinkedMediaEntry].self, from: data),
                  list.contains(where: { $0.id == id }) else { continue }
            list.removeAll { $0.id == id }
            try JSONEncoder.catalog.encode(list).write(to: url, options: .atomic)
        }
    }

    /// The drive a path is on, when it's an external one ("/Volumes/My Drive/…" → "My Drive").
    nonisolated static func volumeName(_ path: String) -> String? {
        let parts = URL(fileURLWithPath: path).pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? parts[2] : nil
    }

    /// Library items for the links: playable ones when their files are there, unavailable ones otherwise.
    /// A missing drive is never an error: its items just wait until it's plugged in again.
    nonisolated static func items(_ entries: [LinkedMediaEntry]) -> [MediaItem] {
        let fm = FileManager.default
        return entries.compactMap { entry in
            let kind: MediaItem.Kind = switch entry.kind { case .video: .video; case .audio: .audio; case .book: .book }
            var tracks = entry.tracks.map { URL(fileURLWithPath: $0) }
            let driveConnected = entry.volume.map { fm.fileExists(atPath: "/Volumes/\($0)") } ?? true
            if driveConnected, let folder = entry.folder, fm.fileExists(atPath: folder) {
                // Tracks added to the folder later are picked up; removed ones drop out.
                let files = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                let audio = files.filter { MediaLibrary.audioExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                if !audio.isEmpty { tracks = audio }
            }
            guard let first = tracks.first else { return nil }
            let present = driveConnected && tracks.allSatisfy { fm.fileExists(atPath: $0.path) }
            let root = (entry.folder.map { URL(fileURLWithPath: $0) } ?? first).deletingLastPathComponent()
            var cover: URL?
            if present {
                if let folder = entry.folder {
                    cover = ["cover-custom.jpg", "cover.jpg", "cover.png", "folder.jpg"].map { URL(fileURLWithPath: folder).appending(path: $0) }
                        .first { fm.fileExists(atPath: $0.path) }
                } else {
                    cover = MediaCover.sidecar(for: first)
                }
            }
            return MediaItem(kind: kind, title: entry.title, tracks: tracks, root: root, cover: cover,
                             catalogKey: entry.catalogKey,
                             unavailable: present ? nil : (entry.volume.flatMap { driveConnected ? nil : $0 } ?? (entry.folder == nil ? "its file" : "its folder")),
                             linkID: entry.id)
        }
    }

    /// Points a link at where its file or folder is now ("Locate…"). Its details and saved place stay with it.
    /// A folder link takes a folder; a single-file link takes a file.
    nonisolated static func relocate(id: String, to url: URL, in libraries: [URL]) throws {
        let fm = FileManager.default
        for library in libraries {
            let file = file(in: library)
            guard let data = try? Data(contentsOf: file),
                  var list = try? JSONDecoder.catalog.decode([LinkedMediaEntry].self, from: data),
                  let index = list.firstIndex(where: { $0.id == id }) else { continue }
            var entry = list[index]
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw LocateError.notFound }
            if entry.folder != nil {
                guard isDirectory.boolValue else { throw LocateError.wantFolder }
                let audio = ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                    .filter { MediaLibrary.audioExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                guard !audio.isEmpty else { throw LocateError.noAudio }
                entry.folder = url.path
                entry.tracks = audio.map(\.path)
            } else {
                guard !isDirectory.boolValue else { throw LocateError.wantFile }
                entry.tracks = [url.path]
            }
            entry.volume = volumeName(url.path)
            list[index] = entry
            try JSONEncoder.catalog.encode(list).write(to: file, options: .atomic)
            return
        }
        throw LocateError.notFound
    }

    enum LocateError: LocalizedError {
        case notFound, wantFolder, wantFile, noAudio
        var errorDescription: String? {
            switch self {
            case .notFound: "The kit couldn’t find that link any more. Try Find my media to add it again."
            case .wantFolder: "This was linked to a folder. Choose the folder it’s in now."
            case .wantFile: "This was linked to a single file. Choose that file."
            case .noAudio: "That folder has no audio files in it. Choose the folder with the tracks."
            }
        }
    }
}

/// Checksums for "is this the same file?" (already in the kit, and verifying a copy before a move).
enum FileChecksum {
    /// SHA-256 of the whole file, read in 4 MB pieces.
    nonisolated static func sha256(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            // nil (or empty) means the end of the file; a thrown error means it couldn't be read.
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 4 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whole-file SHA-256 up to 256 MB. Bigger files (movies) hash their size plus three 4 MB samples
    /// (start, middle, end), which tells copies apart from different files without reading gigabytes.
    nonisolated static func fingerprint(_ url: URL, size: Int64) -> String? {
        guard size > 256 << 20 else { return sha256(url) }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        hasher.update(data: Data(String(size).utf8))
        for offset in [Int64(0), size / 2, size - (4 << 20)] {
            guard (try? handle.seek(toOffset: UInt64(max(0, offset)))) != nil, let chunk = try? handle.read(upToCount: 4 << 20) else { return nil }
            hasher.update(data: chunk)
        }
        return "s:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
