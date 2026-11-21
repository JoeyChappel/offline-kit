import Foundation
import CryptoKit
#if os(macOS)
import Darwin
#endif

// MARK: - Metalink

/// A Kiwix .meta4 file: the archive's size, checksums and mirror list.
struct Metalink: Codable, Sendable {
    var fileName: String
    var size: Int64
    var sha256: String?
    var pieceLength: Int64?
    var pieceSHA1: [String]
    var mirrors: [URL]

    static func fetch(_ url: URL) async throws -> Metalink {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(ProductLookup.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw DownloadError.server("Couldn't get the mirror list.") }
        var meta = try parse(data)
        if meta.mirrors.isEmpty, let direct = URL(string: url.absoluteString.replacingOccurrences(of: ".meta4", with: "")) {
            meta.mirrors = [direct]  // download.kiwix.org redirects to a mirror
        }
        if meta.fileName.isEmpty { meta.fileName = url.lastPathComponent.replacingOccurrences(of: ".meta4", with: "") }
        return meta
    }

    /// A download may only ever name one plain file in its folder: a mirror list or saved progress file
    /// (which can come from any drive) must not be able to write somewhere else with "../" or "/".
    nonisolated static func isSafeFileName(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !name.isEmpty && name.count < 256 && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
            && (name as NSString).lastPathComponent == name
            && (ext == "zim" || ext == "gguf")
    }

    static func parse(_ data: Data) throws -> Metalink {
        let delegate = MetalinkParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), delegate.size > 0 else { throw DownloadError.server("The mirror list was unreadable.") }
        return Metalink(fileName: delegate.name, size: delegate.size, sha256: delegate.sha256,
                        pieceLength: delegate.pieceLength, pieceSHA1: delegate.pieces, mirrors: delegate.urls)
    }
}

private final class MetalinkParser: NSObject, XMLParserDelegate {
    var name = "", size: Int64 = 0, sha256: String?, pieceLength: Int64?, pieces: [String] = [], urls: [URL] = []
    private var stack: [String] = []
    private var hashType = ""
    private var text = ""

    func parser(_ p: XMLParser, didStartElement el: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        stack.append(el)
        text = ""
        switch el {
        case "file": name = attributes["name"] ?? ""
        case "hash": hashType = attributes["type"] ?? ""
        case "pieces":
            if attributes["type"] == "sha-1" { pieceLength = Int64(attributes["length"] ?? "") }
        default: break
        }
    }

    func parser(_ p: XMLParser, foundCharacters s: String) { text += s }

    func parser(_ p: XMLParser, didEndElement el: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.dropLast().last ?? ""
        // Only <url> inside <file> is a mirror; the publisher's <url> is a home page.
        switch (el, parent) {
        case ("size", "file"): size = Int64(value) ?? 0
        case ("hash", "file") where hashType == "sha-256": sha256 = value.lowercased()
        case ("hash", "pieces") where pieceLength != nil: pieces.append(value.lowercased())
        case ("url", "file"): if let u = URL(string: value), u.pathExtension == "zim" { urls.append(u) }
        default: break
        }
        stack.removeLast()
        text = ""
    }
}

enum DownloadError: LocalizedError {
    case server(String), noSpace(needed: Int64, free: Int64), fat32, checksum, allMirrorsFailed

    var errorDescription: String? {
        switch self {
        case .server(let m): m
        case .noSpace(let needed, let free):
            "Not enough space: needs \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)), " +
            "\(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free."
        case .fat32: "This drive is formatted FAT32, which can't hold files over 4 GB. Reformat it as exFAT or APFS."
        case .checksum: "The file didn't match its checksum after two repair attempts. Delete it and try again."
        case .allMirrorsFailed: "No download mirror is responding. Check the internet connection."
        }
    }
}

// MARK: - Saved progress

/// Saved beside the partial file (`name.zim.okdl`) so a download resumes after quitting, sleeping or unplugging.
struct DownloadState: Codable {
    var metalinkURL: URL
    var title: String
    var meta: Metalink
    var chunkSize: Int64
    var done: [Bool]

    var chunkCount: Int { Int((meta.size + chunkSize - 1) / chunkSize) }
    var bytesDone: Int64 {
        done.indices.reduce(0) { $0 + (done[$1] ? DownloadState.length(of: $1, chunk: chunkSize, size: meta.size) : 0) }
    }
    static func length(of chunk: Int, chunk size: Int64, size total: Int64) -> Int64 {
        min(size, total - Int64(chunk) * size)
    }
}

struct DownloadProgress: Sendable {
    enum Phase: Sendable { case preparing, downloading, verifying, finishing }
    var phase: Phase
    var done: Int64
    var total: Int64
    var bytesPerSecond: Double
    var mirrorsActive: Int
}

// MARK: - Chunked downloader

/// Downloads one archive from several mirrors at once in 8 MB chunks, checking each chunk against the
/// metalink's SHA-1 piece hashes, then verifies the whole file's SHA-256 before renaming it into place.
/// Slow mirrors near the end get their chunks re-requested elsewhere, so the last 1% doesn't drag.
actor ChunkedDownload {
    static let partExtension = "part"
    static let stateExtension = "okdl"

    let folder: URL
    let finalURL: URL
    let partURL: URL
    let stateURL: URL
    private var state: DownloadState
    private var handle: FileHandle?

    private struct Attempt { let id: UUID; let mirror: Int; let started: Date; let task: Task<Data, Error> }
    private var pending: [Int] = []
    private var inFlight: [Int: [Attempt]] = [:]
    private var mirrors: [MirrorStats]
    private var samples: [(Date, Int64)] = []
    private var lastSave = Date()
    private var bytesDone: Int64 = 0
    private var progress: (@Sendable (DownloadProgress) -> Void)?

    private struct MirrorStats {
        var url: URL
        var active = 0
        var bytes: Int64 = 0
        var seconds: Double = 0
        var failures = 0
        var disabledUntil = Date.distantPast
        var speed: Double { seconds > 0 ? Double(bytes) / seconds : 0 }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config)
    }()

    static let connections = 10

    /// Starts fresh or picks up a saved partial download in `folder`.
    init(metalinkURL: URL, title: String, meta: Metalink, folder: URL) {
        self.folder = folder
        finalURL = folder.appending(path: meta.fileName)
        partURL = finalURL.appendingPathExtension(Self.partExtension)
        stateURL = finalURL.appendingPathExtension(Self.stateExtension)

        let chunk: Int64 = {
            guard let piece = meta.pieceLength, piece > 0 else { return 8 << 20 }
            return piece * max(1, (8 << 20) / piece)
        }()
        if let data = try? Data(contentsOf: stateURL),
           var saved = try? JSONDecoder().decode(DownloadState.self, from: data),
           saved.meta.size == meta.size, saved.meta.sha256 == meta.sha256,
           FileManager.default.fileExists(atPath: partURL.path) {
            saved.meta.mirrors = meta.mirrors   // mirror lists change; hashes don't
            state = saved
        } else {
            let count = Int((meta.size + chunk - 1) / chunk)
            state = DownloadState(metalinkURL: metalinkURL, title: title, meta: meta, chunkSize: chunk,
                                  done: Array(repeating: false, count: count))
        }
        mirrors = meta.mirrors.map { MirrorStats(url: $0) }
    }

    /// Partial downloads saved in a folder, for resuming at launch.
    nonisolated static func saved(in folder: URL) -> [DownloadState] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == stateExtension && !$0.lastPathComponent.hasPrefix("._") }
            .compactMap { try? JSONDecoder().decode(DownloadState.self, from: Data(contentsOf: $0)) }
            // Saved progress is only trusted when it's self-consistent; a damaged or made-up file is ignored.
            .filter { state in
                Metalink.isSafeFileName(state.meta.fileName) && state.meta.size > 0 && state.chunkSize > 0
                    && state.done.count == state.chunkCount
            }
    }

    /// Deletes a partial download and its saved progress.
    nonisolated static func discard(fileName: String, in folder: URL) {
        let final = folder.appending(path: fileName)
        for ext in [partExtension, stateExtension] {
            let url = final.appendingPathExtension(ext)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent().appending(path: "._" + url.lastPathComponent))
        }
    }

    // MARK: Run

    func run(progress: @escaping @Sendable (DownloadProgress) -> Void) async throws -> URL {
        self.progress = progress
        if FileManager.default.fileExists(atPath: finalURL.path) { return finalURL }
        try checkDestination()
        try openPart()
        defer { try? handle?.close(); handle = nil }

        for round in 0..<3 {
            pending = state.done.indices.filter { !state.done[$0] }
            bytesDone = state.bytesDone
            report(.downloading)
            if !pending.isEmpty { try await downloadAll() }
            try saveState()

            report(.verifying)
            let bad = try await verify()
            if bad.isEmpty { break }
            // Rare: a chunk got damaged on disk (power loss, yanked drive). Fetch just those again.
            for chunk in bad { state.done[chunk] = false }
            try saveState()
            if round == 2 { throw DownloadError.checksum }
        }

        report(.finishing)
        try handle?.truncate(atOffset: UInt64(state.meta.size))
        try handle?.close()
        handle = nil
        try FileManager.default.moveItem(at: partURL, to: finalURL)
        // The library skips files modified in the last two minutes (to avoid half-copied files from other tools).
        // This one is complete and verified, so date it back so it shows up right away.
        try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)], ofItemAtPath: finalURL.path)
        Self.discard(fileName: state.meta.fileName, in: folder)
        return finalURL
    }

    private func checkDestination() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let remaining = state.meta.size - state.bytesDone
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        let free = max(values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeAvailableCapacity ?? 0))
        // The part file already holds its size on exFAT; only count what's still missing, plus headroom.
        if free < remaining + (256 << 20) { throw DownloadError.noSpace(needed: remaining, free: free) }
        #if os(macOS)
        var fs = statfs()
        if statfs(folder.path, &fs) == 0 {
            let type = withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if type == "msdos" && state.meta.size >= 4 << 30 { throw DownloadError.fat32 }
        }
        #endif
    }

    private func openPart() throws {
        if !FileManager.default.fileExists(atPath: partURL.path) {
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            state.done = Array(repeating: false, count: state.chunkCount)
        }
        handle = try FileHandle(forUpdating: partURL)
        try saveState()
    }

    private func saveState() throws {
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        lastSave = Date()
    }

    // MARK: Workers

    private func downloadAll() async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.connections { group.addTask { try await self.worker() } }
            try await group.waitForAll()
        }
    }

    private func worker() async throws {
        while true {
            try Task.checkCancellation()
            if state.done.allSatisfy({ $0 }) { return }
            guard let (chunk, mirror) = nextAssignment() else {
                if mirrors.allSatisfy({ $0.failures >= 8 }) { throw DownloadError.allMirrorsFailed }
                try await Task.sleep(for: .milliseconds(500))
                continue
            }
            let id = UUID()
            let range = byteRange(chunk)
            let url = mirrors[mirror].url
            let task = Task { try await Self.fetch(url, range: range) }
            inFlight[chunk, default: []].append(Attempt(id: id, mirror: mirror, started: Date(), task: task))
            mirrors[mirror].active += 1
            let started = Date()
            do {
                let data = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                mirrors[mirror].active -= 1
                finish(attempt: id, chunk: chunk)
                try accept(data, chunk: chunk, mirror: mirror, seconds: Date().timeIntervalSince(started))
            } catch {
                mirrors[mirror].active -= 1
                finish(attempt: id, chunk: chunk)
                if Task.isCancelled { throw CancellationError() }
                if state.done[chunk] { continue }            // another mirror won the race
                if error is DownloadError { throw error }      // disk problems stop the job
                fail(mirror: mirror)
                if inFlight[chunk, default: []].isEmpty && !pending.contains(chunk) { pending.insert(chunk, at: 0) }
            }
        }
    }

    private func nextAssignment() -> (Int, Int)? {
        if !pending.isEmpty {
            guard let mirror = pickMirror(excluding: []) else { return nil }
            return (pending.removeFirst(), mirror)
        }
        // Nothing left to start: race the slowest in-flight chunk on a different mirror.
        let now = Date()
        let stragglers = inFlight
            .filter { !state.done[$0.key] && $0.value.count == 1 && now.timeIntervalSince($0.value[0].started) > 12 }
            .sorted { $0.value[0].started < $1.value[0].started }
        for (chunk, attempts) in stragglers {
            if let mirror = pickMirror(excluding: Set(attempts.map(\.mirror))) { return (chunk, mirror) }
        }
        return nil
    }

    private func pickMirror(excluding: Set<Int>) -> Int? {
        let now = Date()
        let usable = mirrors.indices.filter { !excluding.contains($0) && mirrors[$0].disabledUntil < now && mirrors[$0].active < 3 }
        if let untried = usable.first(where: { mirrors[$0].seconds == 0 && mirrors[$0].active == 0 }) { return untried }
        return usable.max { a, b in
            mirrors[a].speed / Double(mirrors[a].active + 1) < mirrors[b].speed / Double(mirrors[b].active + 1)
        }
    }

    private func fail(mirror: Int) {
        mirrors[mirror].failures += 1
        let backoff = min(300.0, 10 * pow(2, Double(min(mirrors[mirror].failures, 5))))
        mirrors[mirror].disabledUntil = Date().addingTimeInterval(backoff)
    }

    private func finish(attempt id: UUID, chunk: Int) {
        inFlight[chunk]?.removeAll { $0.id == id }
        if inFlight[chunk]?.isEmpty == true { inFlight[chunk] = nil }
    }

    private func byteRange(_ chunk: Int) -> ClosedRange<Int64> {
        let start = Int64(chunk) * state.chunkSize
        let length = DownloadState.length(of: chunk, chunk: state.chunkSize, size: state.meta.size)
        return start...(start + length - 1)
    }

    private static func fetch(_ url: URL, range: ClosedRange<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        request.setValue(ProductLookup.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let expected = Int(range.upperBound - range.lowerBound + 1)
        guard http.statusCode == 206 || (http.statusCode == 200 && range.lowerBound == 0), data.count >= expected else {
            throw URLError(.badServerResponse)
        }
        return data.count == expected ? data : data.prefix(expected)
    }

    /// Checks a chunk against its piece hashes, then writes it.
    private func accept(_ data: Data, chunk: Int, mirror: Int, seconds: Double) throws {
        guard !state.done[chunk] else { return }
        if let piece = state.meta.pieceLength, !state.meta.pieceSHA1.isEmpty {
            let first = Int(Int64(chunk) * state.chunkSize / piece)
            var offset = 0
            var index = first
            while offset < data.count {
                let end = min(data.count, offset + Int(piece))
                if index < state.meta.pieceSHA1.count {
                    let digest = Insecure.SHA1.hash(data: data[offset..<end]).hex
                    if digest != state.meta.pieceSHA1[index] {
                        fail(mirror: mirror)
                        if !pending.contains(chunk) && inFlight[chunk] == nil { pending.insert(chunk, at: 0) }
                        return
                    }
                }
                offset = end
                index += 1
            }
        }
        guard let handle else { throw CancellationError() }
        do {
            try handle.seek(toOffset: UInt64(byteRange(chunk).lowerBound))
            try handle.write(contentsOf: data)
        } catch {
            throw DownloadError.server("Couldn't write to the drive: \(error.localizedDescription)")
        }
        state.done[chunk] = true
        bytesDone += Int64(data.count)
        mirrors[mirror].bytes += Int64(data.count)
        mirrors[mirror].seconds += max(seconds, 0.01)
        mirrors[mirror].failures = 0
        // Cancel any slower duplicate of this chunk.
        for attempt in inFlight[chunk] ?? [] { attempt.task.cancel() }
        samples.append((Date(), bytesDone))
        if Date().timeIntervalSince(lastSave) > 3 { try? saveState() }
        report(.downloading)
    }

    private func report(_ phase: DownloadProgress.Phase) {
        let cutoff = Date().addingTimeInterval(-10)
        samples.removeAll { $0.0 < cutoff }
        var speed = 0.0
        if let first = samples.first, let last = samples.last, last.0 > first.0 {
            speed = Double(last.1 - first.1) / last.0.timeIntervalSince(first.0)
        }
        let active = Set(inFlight.values.flatMap { $0.map(\.mirror) }).count
        progress?(DownloadProgress(phase: phase, done: bytesDone, total: state.meta.size,
                                   bytesPerSecond: speed, mirrorsActive: active))
    }

    // MARK: Verify

    /// Reads the whole file once, checking SHA-256 and the piece hashes together.
    /// Returns the chunks that need re-downloading (empty means the file is good).
    private func verify() async throws -> [Int] {
        guard let handle else { return [] }
        let meta = state.meta
        let chunkSize = state.chunkSize
        let progress = self.progress
        let total = meta.size
        return try await Task.detached(priority: .utility) {
            var sha = SHA256()
            var bad = Set<Int>()
            let piece = Int(meta.pieceLength ?? 0)
            let block = piece > 0 ? max(piece, 8 << 20) / piece * piece : 8 << 20
            try handle.seek(toOffset: 0)
            var offset: Int64 = 0
            var lastReport = Date()
            while offset < total {
                try Task.checkCancellation()
                let want = Int(min(Int64(block), total - offset))
                guard let data = try handle.read(upToCount: want), data.count == want else {
                    bad.insert(Int(offset / chunkSize)); break
                }
                sha.update(data: data)
                if piece > 0 && !meta.pieceSHA1.isEmpty {
                    var p = 0
                    while p < data.count {
                        let index = Int((offset + Int64(p)) / Int64(piece))
                        let end = min(data.count, p + piece)
                        if index < meta.pieceSHA1.count, Insecure.SHA1.hash(data: data[p..<end]).hex != meta.pieceSHA1[index] {
                            bad.insert(Int((offset + Int64(p)) / chunkSize))
                        }
                        p = end
                    }
                }
                offset += Int64(data.count)
                if Date().timeIntervalSince(lastReport) > 0.5 {
                    lastReport = Date()
                    progress?(DownloadProgress(phase: .verifying, done: offset, total: total, bytesPerSecond: 0, mirrorsActive: 0))
                }
            }
            if let expected = meta.sha256, sha.finalize().hex != expected, bad.isEmpty {
                // Whole-file mismatch with no piece hashes to localize it: start over.
                return Array(0..<Int((total + chunkSize - 1) / chunkSize))
            }
            return bad.sorted()
        }.value
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
