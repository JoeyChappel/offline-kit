import Foundation
import Network
import Observation

/// A newer version of an installed archive, from the Kiwix catalog.
struct KitUpdate: Identifiable, Hashable, Sendable {
    let installed: URL
    let title: String
    let installedSize: Int64
    let installedDate: Date?
    let entry: CatalogEntry
    var id: String { installed.path }
    var folder: URL { installed.deletingLastPathComponent() }
}

/// Whether the Mac or phone has a working network path right now.
@MainActor @Observable
final class NetworkWatch {
    static let shared = NetworkWatch()
    private(set) var isOnline = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { path in
            let online = path.status == .satisfied
            Task { @MainActor in NetworkWatch.shared.isOnline = online }
        }
        monitor.start(queue: DispatchQueue(label: "OfflineKit.network"))
    }
}

/// Refresh everything: find newer versions of installed archives, download them through the normal queue
/// (which checks every piece and the whole file's SHA-256 before naming it), then delete the old file
/// only once the new one is in place and opens.
@MainActor @Observable
final class KitRefresh {
    static let shared = KitRefresh()

    enum Phase: Equatable {
        case idle, checking
        case checked(Date)
        case failed(String)
    }

    struct Replacement: Codable, Hashable { let newPath: String; let oldPath: String; let title: String }

    private(set) var phase: Phase = .idle
    private(set) var updates: [KitUpdate] = []
    /// Archives the check couldn't match to the catalog (renamed files, or not from Kiwix).
    private(set) var unmatched: [String] = []
    /// Replacements waiting for their download to finish.
    private(set) var pending: [Replacement] = []
    /// What happened to finished replacements, newest last.
    private(set) var log: [String] = []
    @ObservationIgnored private var watcher: Task<Void, Never>?
    /// Called after an old file is swapped out, so the library rescans.
    @ObservationIgnored var onReplaced: (() -> Void)?

    private static let pendingKey = "refreshPending"

    private init() {
        if let data = KitSettings.shared.string(forKey: Self.pendingKey)?.data(using: .utf8),
           let saved = try? JSONDecoder().decode([Replacement].self, from: data) {
            pending = saved
        }
    }

    static var catalogCache: URL {
        (KitLocation.portableRoot ?? KitLocation.testHome ?? URL.cachesDirectory.appending(path: "OfflineKit")).appending(path: ".kiwix-catalog.xml")
    }

    var totalBytes: Int64 { updates.reduce(0) { $0 + $1.entry.size } }

    // MARK: Check

    /// Fetches the live catalog (never the cached copy: an old list could miss updates) and compares.
    func check(books: [Book]) async {
        phase = .checking
        do {
            var request = URLRequest(url: Catalog.feed, timeoutInterval: 30)
            request.setValue(ProductLookup.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let catalog = try await Task.detached { try Catalog.parse(data) }.value
            try? FileManager.default.createDirectory(at: Self.catalogCache.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: Self.catalogCache, options: .atomic)
            let installed = books.map { (url: $0.url, title: $0.title, size: $0.fileSize, name: $0.archive.name,
                                         flavour: $0.archive.metadata("Flavour") ?? "", date: $0.archive.metadata("Date")) }
            let result = Self.updates(installed: installed, catalog: catalog)
            updates = result.updates.filter { update in !pending.contains { $0.oldPath == update.installed.path } }
            unmatched = result.unmatched
            phase = .checked(Date())
        } catch {
            phase = .failed(Self.describe(error))
        }
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                                             .cannotConnectToHost, .timedOut, .dnsLookupFailed].contains(error.code) {
            return "Couldn’t reach the online download list. Checking for updates needs an internet connection."
        }
        return "Couldn’t check for updates: \(error.localizedDescription)"
    }

    /// Matches each installed file to the catalog by its file name series ("wikipedia_en_medicine_maxi_2026-10.zim"
    /// → "wikipedia_en_medicine_maxi"), falling back to the archive's own name and flavour.
    nonisolated static func updates(installed: [(url: URL, title: String, size: Int64, name: String, flavour: String, date: String?)],
                                    catalog: Catalog) -> (updates: [KitUpdate], unmatched: [String]) {
        var bySeries: [String: CatalogEntry] = [:]
        for entry in catalog.entries {
            guard let key = KitCheckup.seriesKey(entry.fileName) else { continue }
            if let current = bySeries[key], current.fileName >= entry.fileName { continue }
            bySeries[key] = entry
        }
        let fm = FileManager.default
        var updates: [KitUpdate] = []
        var unmatched: [String] = []
        for file in installed {
            let fileName = file.url.lastPathComponent
            let installedDate = KitCheckup.parseDate(file.date) ?? KitCheckup.dateInFileName(fileName)
            var candidate: CatalogEntry?
            if let key = KitCheckup.seriesKey(fileName), let entry = bySeries[key] {
                if entry.fileName > fileName { candidate = entry }
            } else if !file.name.isEmpty,
                      let entry = catalog.entries.filter({ $0.name == file.name && $0.flavour == file.flavour }).max(by: { $0.issued < $1.issued }) {
                if let issued = KitCheckup.parseDate(entry.issued), let installedDate, issued > installedDate { candidate = entry }
            } else {
                unmatched.append(file.title)
                continue
            }
            guard let entry = candidate else { continue }
            // Already downloaded beside it (an earlier refresh that didn't finish replacing): the checkup offers the cleanup.
            if fm.fileExists(atPath: file.url.deletingLastPathComponent().appending(path: entry.fileName).path) { continue }
            updates.append(KitUpdate(installed: file.url, title: file.title, installedSize: file.size,
                                     installedDate: installedDate, entry: entry))
        }
        return (updates.sorted { $0.entry.size < $1.entry.size }, unmatched.sorted())
    }

    // MARK: Download and replace

    /// Queues every update into the folder its old file is in. Nothing is deleted here.
    func start(_ chosen: [KitUpdate], downloads: DownloadManager) {
        for update in chosen {
            downloads.enqueue(update.entry, to: update.folder)
            let replacement = Replacement(newPath: update.folder.appending(path: update.entry.fileName).path,
                                          oldPath: update.installed.path, title: update.title)
            if !pending.contains(replacement) { pending.append(replacement) }
        }
        updates.removeAll { chosen.contains($0) }
        savePending()
        watch(downloads: downloads)
    }

    /// Checks finished downloads every couple of seconds and swaps out the old files.
    func watch(downloads: DownloadManager) {
        guard watcher == nil, !pending.isEmpty else { return }
        watcher = Task {
            while !pending.isEmpty, !Task.isCancelled {
                await replaceFinished(downloads: downloads)
                try? await Task.sleep(for: .seconds(2))
            }
            watcher = nil
        }
    }

    private func replaceFinished(downloads: DownloadManager) async {
        for item in pending {
            let newURL = URL(fileURLWithPath: item.newPath)
            let job = downloads.jobs.last { $0.folder.appending(path: $0.fileName).path == item.newPath }
            // The queue only names the file after its checksum matched. A job still running isn't done.
            if let job, job.state != .done { continue }
            guard FileManager.default.fileExists(atPath: newURL.path) else {
                // No file and no job: the download was cancelled. Keep the old version.
                if job == nil {
                    pending.removeAll { $0 == item }
                    log.append("\(item.title): update cancelled, kept the version you had.")
                }
                continue
            }
            let opens = await Task.detached(priority: .utility) { () -> Bool in
                guard Library.looksLikeZim(newURL) else { return false }
                return (try? ZimArchive(path: newURL.path)) != nil
            }.value
            pending.removeAll { $0 == item }
            if opens && !Self.isReplaceable(old: URL(fileURLWithPath: item.oldPath), new: newURL) {
                // The saved list can come from a drive's settings file, so it's never trusted to name what to delete.
                log.append("\(item.title): updated to \(newURL.lastPathComponent). The old version was left in place.")
            } else if opens {
                let removed = await Task.detached { KitCheckup.remove([URL(fileURLWithPath: item.oldPath)]) }.value
                log.append(removed.failed.isEmpty
                           ? "\(item.title): updated to \(newURL.lastPathComponent). The old version was deleted."
                           : "\(item.title): updated, but the old file couldn’t be deleted (\(removed.failed[0].1)).")
            } else {
                log.append("\(item.title): the new file didn’t open, so the old version was kept.")
            }
            onReplaced?()
        }
        savePending()
    }

    /// Only an ordinary archive file beside the new download may be deleted: never a folder, a link or anything elsewhere.
    nonisolated static func isReplaceable(old: URL, new: URL) -> Bool {
        let old = old.standardizedFileURL, new = new.standardizedFileURL
        guard old.path != new.path,
              old.pathExtension.lowercased() == "zim",
              old.deletingLastPathComponent().path == new.deletingLastPathComponent().path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: old.path),   // doesn't follow links
              attributes[.type] as? FileAttributeType == .typeRegular else { return false }
        return true
    }

    private func savePending() {
        let json = (try? JSONEncoder().encode(pending)).flatMap { String(data: $0, encoding: .utf8) }
        KitSettings.shared.set(pending.isEmpty ? nil : json, forKey: Self.pendingKey)
    }
}
