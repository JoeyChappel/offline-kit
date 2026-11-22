import Foundation
import Observation

/// "Send to iPhone" on the Mac: the movies, audiobooks, music, books, games and references picked for phones.
///
/// One shared list for the whole household, not one per phone. Each phone downloads whatever is on it that it
/// doesn't already have, and reports back; the list shows which phones have each item. Per-phone lists would mean
/// naming and picking phones on the Mac first, and phones on iOS only report a generic "iPhone" name anyway.
///
/// Only files inside the library (Media, Games, Documents and reference archives) can be added. Private household
/// data lives outside the library, and anything under its folder is refused.
@MainActor @Observable
final class SendList {
    static let shared = SendList()

    struct Entry: Codable, Identifiable, Hashable, Sendable {
        var id: String
        var kind: SendKind
        var title: String
        var detail: String?
        /// Files or folders on this Mac.
        var sources: [String]
        /// Folder the phone's paths are measured from, and the library subfolder they go under ("Media", "Games", "Documents" or "").
        var base: String
        var prefix: String
        var added: Date
        var size: Int64
        /// Phone name → when it reported the item downloaded.
        var receivedBy: [String: Date] = [:]
    }

    private(set) var entries: [Entry] = []
    private static let key = "sendToPhone"

    init() {
        if let text = KitSettings.shared.string(forKey: Self.key), let data = text.data(using: .utf8),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }
    var waitingCount: Int { entries.filter { $0.receivedBy.isEmpty }.count }

    func contains(_ source: SendSource) -> Bool { contains(key: source.key) }
    func contains(key: String) -> Bool { entries.contains { $0.sources.first == key } }

    /// A short confirmation after something is added or taken off ("Added to Send to iPhone").
    struct Notice: Equatable, Identifiable {
        let id = UUID()
        let text: String
        let added: Bool
    }
    private(set) var notice: Notice?

    func toggle(_ source: SendSource) {
        if let entry = entries.first(where: { $0.sources.first == source.key }) {
            remove(entry.id)
            notice = Notice(text: "Removed “\(source.title)” from Send to iPhone", added: false)
        } else if add(source) {
            notice = Notice(text: "Added “\(source.title)” to Send to iPhone", added: true)
        } else {
            notice = Notice(text: "“\(source.title)” can’t be sent right now: its files aren’t here.", added: false)
        }
    }

    @discardableResult
    func add(_ source: SendSource) -> Bool {
        guard !contains(source), !source.paths.isEmpty else { return false }
        // Nothing to send while the files are missing (a linked item whose drive or folder is gone).
        guard source.paths.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return false }
        // Never private household data: refuse anything inside its folder.
        let privateFolder = PrivateStore.folder.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        guard !source.paths.contains(where: { ($0.standardizedFileURL.resolvingSymlinksInPath().path + "/").hasPrefix(privateFolder) }) else { return false }
        var entry = Entry(id: UUID().uuidString.lowercased(), kind: source.kind, title: source.title, detail: source.detail,
                          sources: source.paths.map { $0.standardizedFileURL.path }, base: source.base.standardizedFileURL.path,
                          prefix: source.prefix, added: Date(), size: 0)
        entry.size = Self.files(for: entry).reduce(0) { $0 + $1.size }
        entries.append(entry)
        save()
        return true
    }

    func remove(_ id: String) {
        entries.removeAll { $0.id == id }
        save()
    }

    /// Drops everything at least one phone has downloaded.
    func clearReceived() {
        entries.removeAll { !$0.receivedBy.isEmpty }
        save()
    }

    func markReceived(_ id: String, by device: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let name = String(device.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        entries[index].receivedBy[name.isEmpty ? "iPhone" : name] = Date()
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { KitSettings.shared.set(String(decoding: data, as: UTF8.self), forKey: Self.key) }
    }

    // MARK: Files

    struct SendFile: Sendable {
        let url: URL
        let path: String
        let size: Int64
        let modified: Date
    }

    /// Every file an entry sends, with where each goes on the phone. Folders are walked; hidden files, macOS "._"
    /// companions and game "Saves" folders are left out. Files that are missing right now (a drive unplugged) are skipped.
    /// `scope` limits what leaves this Mac (see SharePolicy.Scope); without one, as when sizing a pick, it isn't applied.
    nonisolated static func files(for entry: Entry, scope: SharePolicy.Scope? = nil) -> [SendFile] {
        let fm = FileManager.default
        let base = URL(fileURLWithPath: entry.base).resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        var out: [SendFile] = []
        var seen = Set<String>()

        func add(_ link: URL) {
            let url = link.resolvingSymlinksInPath().standardizedFileURL
            // Checked again here, not only when added: the list can come from a drive's settings file.
            guard !SharePolicy.isOffLimits(url), scope?.allows(url) ?? true, !url.lastPathComponent.hasPrefix("."), seen.insert(url.path).inserted,
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return }
            let full = url.path
            let relative = full.hasPrefix(base + "/") ? String(full.dropFirst(base.count + 1)) : url.lastPathComponent
            let path = entry.prefix.isEmpty ? relative : entry.prefix + "/" + relative
            guard SendManifest.isSafe(path) else { return }
            out.append(SendFile(url: url, path: path, size: Int64(values.fileSize ?? 0),
                                modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0)))
        }

        for source in entry.sources {
            let url = URL(fileURLWithPath: source).resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            if isDirectory.boolValue {
                guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { continue }
                var found: [URL] = []
                for case let file as URL in walker {
                    if file.lastPathComponent == "Saves" { walker.skipDescendants(); continue }
                    if file.lastPathComponent.hasPrefix("._") { continue }
                    found.append(file)
                }
                found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }.forEach(add)
            } else {
                add(url)
            }
        }
        return out
    }

    // MARK: Share on Wi-Fi routes

    /// GET /api/send (manifest), GET /api/send/file/<item>/<index> (a file, resumable), POST /api/send/received.
    func handle(_ req: WebServer.Request, _ res: WebServer.Responder, macName: String, libraries: [URL]) async {
        switch (req.method, req.path) {
        case ("GET", "/api/send"):
            await res.send(json: await manifestJSON(macName: macName, libraries: libraries))
        case ("POST", "/api/send/received"):
            let body = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
            guard let id = body["item"] as? String, entries.contains(where: { $0.id == id }) else {
                await res.send(status: 404, json: ["error": "Unknown item"]); return
            }
            markReceived(id, by: body["device"] as? String ?? "iPhone")
            await res.send(json: ["ok": true])
        case ("GET", let path) where path.hasPrefix("/api/send/file/"):
            let parts = path.dropFirst("/api/send/file/".count).split(separator: "/").map(String.init)
            guard parts.count == 2, let entry = entries.first(where: { $0.id == parts[0] }), let index = Int(parts[1]) else {
                await res.send(status: 404, text: "Not found"); return
            }
            let files = await Task.detached(priority: .userInitiated) { Self.files(for: entry, scope: SharePolicy.Scope(libraries: libraries)) }.value
            guard files.indices.contains(index) else { await res.send(status: 404, text: "Not found"); return }
            var throttle = 0
            #if DEBUG
            throttle = UserDefaults.standard.integer(forKey: "sendThrottleKBps")   // test hook: slow downloads to test pause and resume
            #endif
            await res.sendDownload(files[index].url, rangeHeader: req.headers["range"], ifRange: req.headers["if-range"], throttleKBps: throttle)
        default:
            await res.send(status: 404, text: "Not found")
        }
    }

    private func manifestJSON(macName: String, libraries: [URL]) async -> [String: Any] {
        let entries = self.entries
        let lists = await Task.detached(priority: .userInitiated) { () -> [[SendFile]] in
            let scope = SharePolicy.Scope(libraries: libraries)
            return entries.map { Self.files(for: $0, scope: scope) }
        }.value
        var items: [[String: Any]] = []
        for (entry, files) in zip(entries, lists) where !files.isEmpty {
            var item: [String: Any] = [
                "id": entry.id, "kind": entry.kind.rawValue, "title": entry.title, "added": entry.added.timeIntervalSince1970,
                "receivedBy": entry.receivedBy.keys.sorted(),
                "files": files.enumerated().map { index, file in
                    ["path": file.path, "size": file.size, "modified": file.modified.timeIntervalSince1970,
                     "url": "/api/send/file/\(entry.id)/\(index)"] as [String: Any]
                },
            ]
            if let detail = entry.detail { item["detail"] = detail }
            items.append(item)
        }
        return ["name": macName, "items": items]
    }
}

extension WebServer.Responder {
    /// Sends a whole file for download, or the byte range asked for, with no cap on open-ended ranges (unlike `sendFile`,
    /// which is tuned for video seeking). ETag and Last-Modified let URLSession resume an interrupted download;
    /// If-Range falls back to the whole file when the file has changed since.
    func sendDownload(_ link: URL, rangeHeader: String?, ifRange: String?, throttleKBps: Int = 0) async {
        let url = link.resolvingSymlinksInPath()   // a symlink's own size is a few bytes
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let total = (attributes[.size] as? NSNumber)?.int64Value,
              let handle = try? FileHandle(forReadingFrom: url) else {
            await send(status: 404, text: "Not found"); return
        }
        defer { try? handle.close() }
        let modified = attributes[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        let etag = "\"\(total)-\(Int64(modified.timeIntervalSince1970))\""
        let lastModified = Self.httpDate(modified)
        var range = rangeHeader
        if let ifRange, ifRange != etag, ifRange != lastModified { range = nil }

        var lower: Int64 = 0, upper = total - 1, status = 200
        if let range, total > 0 {
            if let parsed = ByteRange(header: range, total: Int(total)) {
                lower = Int64(parsed.lower); upper = Int64(parsed.upper); status = 206
            } else if let start = Int64(range.dropFirst("bytes=".count).split(separator: "-").first ?? ""), start >= total {
                await send(status: 416, contentType: "text/plain", body: Data(), headers: ["Content-Range": "bytes */\(total)"])
                return
            }
        }
        let length = total == 0 ? 0 : upper - lower + 1
        var head = "HTTP/1.1 \(status) \(status == 206 ? "Partial Content" : "OK")\r\nContent-Type: application/octet-stream\r\n"
        head += "Content-Length: \(length)\r\nAccept-Ranges: bytes\r\nETag: \(etag)\r\nLast-Modified: \(lastModified)\r\n"
        head += connectionHeaders() + "Cache-Control: no-store\r\n"
        if status == 206 { head += "Content-Range: bytes \(lower)-\(upper)/\(total)\r\n" }
        head += "\r\n"
        guard await write(Data(head.utf8)) else { finish(complete: false); return }
        let chunkSize = throttleKBps > 0 ? 64 * 1024 : 1 << 20
        var remaining = length
        do {
            try handle.seek(toOffset: UInt64(lower))
            while remaining > 0 {
                let chunk = try handle.read(upToCount: Int(min(remaining, Int64(chunkSize)))) ?? Data()
                if chunk.isEmpty { break }
                // Stop reading as soon as the phone goes away (paused, out of range), instead of reading the rest of a big file.
                guard await write(chunk) else { break }
                remaining -= Int64(chunk.count)
                if throttleKBps > 0 { try? await Task.sleep(for: .seconds(Double(chunk.count) / Double(throttleKBps * 1024))) }
            }
        } catch {}
        // Short of the Content-Length (the phone went away, or the file changed): the connection has to close.
        finish(complete: remaining == 0)
    }

    nonisolated static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}
