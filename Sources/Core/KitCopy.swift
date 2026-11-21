import Foundation
import CryptoKit
import Observation

/// Copy my kit: copies library folders (and optionally the app) to another drive or folder so it works there
/// as a kit, checking every copied file against a SHA-256 of the original.
///
/// Rules it keeps:
/// - Nothing at the source is ever changed or deleted.
/// - At the destination it only replaces files the person confirmed (listed before the copy starts),
///   and its own unfinished ".okcopy" temp files.
/// - Private household data never goes: it's sealed with a Keychain key that stays on this device.
enum KitCopy {
    static let tempExtension = "okcopy"

    /// One folder to copy and where it goes.
    struct Root: Hashable, Sendable {
        let source: URL
        let destination: URL
        /// App bundles keep their internal symlinks as links; library links are copied as the files they point to.
        let keepsLinks: Bool
    }

    struct Item: Hashable, Sendable {
        let source: URL            // a real file (links already resolved), or the link itself when linkTarget is set
        let destination: URL
        let relative: String       // shown in reports, e.g. "Library/Media/Films/Sintel.mp4"
        let size: Int64
        let modified: Date
        let permissions: Int
        var linkTarget: String? = nil
    }

    struct Skipped: Hashable, Sendable {
        let relative: String
        let reason: String
    }

    struct Plan: Sendable {
        var roots: [Root] = []
        var toCopy: [Item] = []
        var identical: [Item] = []
        /// Files already at the destination with different contents. Copying replaces them, so they need a yes first.
        var replacing: [Item] = []
        var skipped: [Skipped] = []
        var freeAtDestination: Int64 = 0
        var isFAT32 = false

        var copyBytes: Int64 { (toCopy + replacing).reduce(0) { $0 + $1.size } }
        /// Room needed: new files, plus replacements that are bigger than what they replace.
        var neededBytes: Int64 { copyBytes }
        var fileCount: Int { toCopy.count + replacing.count + identical.count }
        var tooBigForFAT32: [Item] { isFAT32 ? (toCopy + replacing).filter { $0.size >= 4 << 30 } : [] }
        var fits: Bool { freeAtDestination > neededBytes + (256 << 20) }
    }

    /// Where the kit goes inside what the person picked: an "OfflineKit" folder, so another Mac finds
    /// `/Volumes/<drive>/OfflineKit/Library` and the app beside it runs in drive mode.
    static func kitFolder(in picked: URL) -> URL {
        picked.lastPathComponent == "OfflineKit" ? picked : picked.appending(path: "OfflineKit", directoryHint: .isDirectory)
    }

    static let junk: Set<String> = [".DS_Store", ".Trashes", ".Spotlight-V100", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100"]

    /// Personal data that must never travel: the sealed household store, wherever it might be.
    static func isPrivate(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return url.pathExtension == "sealed" || name == ".private"
            || url.standardizedFileURL.path.hasPrefix(PrivateStore.folder.standardizedFileURL.path)
    }

    // MARK: Plan

    nonisolated static func plan(_ roots: [Root]) -> Plan {
        let fm = FileManager.default
        var plan = Plan(roots: roots)
        var claimed = Set<String>()
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]

        func add(_ file: URL, to destination: URL, relative: String, link: String?) {
            guard claimed.insert(destination.standardizedFileURL.path).inserted else {
                plan.skipped.append(Skipped(relative: relative, reason: "Same name in two library folders; the first one is copied"))
                return
            }
            let attributes = (try? fm.attributesOfItem(atPath: file.path)) ?? [:]
            let size = link == nil ? (attributes[.size] as? NSNumber)?.int64Value ?? 0 : 0
            let modified = attributes[.modificationDate] as? Date ?? .distantPast
            let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
            let item = Item(source: file, destination: destination, relative: relative, size: size, modified: modified,
                            permissions: permissions, linkTarget: link)
            switch compare(item) {
            case .missing: plan.toCopy.append(item)
            case .same: plan.identical.append(item)
            case .different: plan.replacing.append(item)
            }
        }

        func walk(_ folder: URL, into destination: URL, prefix: String, keepsLinks: Bool, visited: inout Set<String>) {
            guard visited.insert(folder.resolvingSymlinksInPath().path).inserted,
                  let children = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
            for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = child.lastPathComponent
                let relative = prefix + "/" + name
                let target = destination.appending(path: name)
                if junk.contains(name) || name.hasPrefix("._") { continue }
                if isPrivate(child) { plan.skipped.append(Skipped(relative: relative, reason: "Private household data stays on this device")); continue }
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true {
                    if keepsLinks, let link = try? fm.destinationOfSymbolicLink(atPath: child.path) {
                        add(child, to: target, relative: relative, link: link)
                        continue
                    }
                    let resolved = child.resolvingSymlinksInPath()
                    // A link is copied as what it points to, so check that, not the link.
                    if isPrivate(resolved) || SharePolicy.isOffLimits(resolved) {
                        plan.skipped.append(Skipped(relative: relative, reason: "Private household data stays on this device")); continue
                    }
                    var isDirectory: ObjCBool = false
                    guard fm.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
                        plan.skipped.append(Skipped(relative: relative, reason: "Broken link: what it pointed to is gone"))
                        continue
                    }
                    if isDirectory.boolValue {
                        walk(resolved, into: target, prefix: relative, keepsLinks: keepsLinks, visited: &visited)
                    } else {
                        add(resolved, to: target, relative: relative, link: nil)
                    }
                    continue
                }
                if values?.isDirectory == true {
                    walk(child, into: target, prefix: relative, keepsLinks: keepsLinks, visited: &visited)
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                if KitCheckup.partialExtensions.contains(child.pathExtension.lowercased()) {
                    plan.skipped.append(Skipped(relative: relative, reason: "Unfinished download"))
                    continue
                }
                if child.pathExtension.lowercased() == "zim", !Library.looksLikeZim(child) {
                    plan.skipped.append(Skipped(relative: relative, reason: "Damaged archive that won’t open"))
                    continue
                }
                add(child, to: target, relative: relative, link: nil)
            }
        }

        for root in roots {
            var visited = Set<String>()
            let prefix = root.destination.lastPathComponent
            walk(root.source, into: root.destination, prefix: prefix, keepsLinks: root.keepsLinks, visited: &visited)
        }
        if let first = roots.first {
            plan.freeAtDestination = freeSpace(near: first.destination)
            plan.isFAT32 = fileSystem(near: first.destination) == "msdos"
        }
        return plan
    }

    enum Comparison { case missing, same, different }

    /// Same size and modification time (within 2 seconds, for FAT and exFAT clocks) counts as already copied.
    nonisolated static func compare(_ item: Item) -> Comparison {
        let fm = FileManager.default
        if let link = item.linkTarget {
            guard let existing = try? fm.destinationOfSymbolicLink(atPath: item.destination.path) else {
                return (try? fm.attributesOfItem(atPath: item.destination.path)) == nil ? .missing : .different
            }
            return existing == link ? .same : .different
        }
        guard let attributes = try? fm.attributesOfItem(atPath: item.destination.path) else { return .missing }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let modified = attributes[.modificationDate] as? Date ?? .distantPast
        return size == item.size && abs(modified.timeIntervalSince(item.modified)) <= 2 ? .same : .different
    }

    nonisolated static func nearestExisting(_ url: URL) -> URL {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" { probe.deleteLastPathComponent() }
        return probe
    }

    nonisolated static func freeSpace(near url: URL) -> Int64 {
        let values = try? nearestExisting(url).resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return max(values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeAvailableCapacity ?? 0))
    }

    nonisolated static func fileSystem(near url: URL) -> String {
        #if os(macOS)
        var fs = statfs()
        guard statfs(nearestExisting(url).path, &fs) == 0 else { return "" }
        return withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #else
        return ""
        #endif
    }

    // MARK: Hashing

    /// SHA-256 of a file, read around the system cache so a just-written copy is read back from the drive itself.
    nonisolated static func sha256(of url: URL, control: Control? = nil, progress: (Int64) -> Void = { _ in }) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        #if os(macOS) || os(iOS)
        _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1)
        #endif
        var hasher = SHA256()
        while true {
            try control?.waitIfPaused()
            guard let data = try handle.read(upToCount: 8 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
            progress(Int64(data.count))
        }
        return hasher.finalize().hex
    }

    // MARK: Control

    /// Pause and stop for a running copy, shared with the worker thread.
    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var paused = false
        private var stopped = false

        var isPaused: Bool { lock.withLock { paused } }
        func pause() { lock.withLock { paused = true } }
        func resume() { lock.withLock { paused = false } }
        func stop() { lock.withLock { stopped = true; paused = false } }

        func waitIfPaused() throws {
            while true {
                let (p, s) = lock.withLock { (paused, stopped) }
                if s { throw CancellationError() }
                if !p { return }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
    }

    // MARK: Copy one file

    struct Outcome: Sendable {
        var copied = 0
        var verified = 0
        var failures: [Skipped] = []
    }

    /// Copies one file through a temp file, hashing as it goes, then reads the copy back and compares.
    nonisolated static func copy(_ item: Item, control: Control, progress: (Int64) -> Void) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let link = item.linkTarget {
            if (try? fm.attributesOfItem(atPath: item.destination.path)) != nil { try fm.removeItem(at: item.destination) }
            try fm.createSymbolicLink(atPath: item.destination.path, withDestinationPath: link)
            return (try? fm.destinationOfSymbolicLink(atPath: item.destination.path)) == link
        }
        let temp = item.destination.appendingPathExtension(tempExtension)
        if fm.fileExists(atPath: temp.path) { try fm.removeItem(at: temp) }
        guard fm.createFile(atPath: temp.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        let source = try FileHandle(forReadingFrom: item.source)
        defer { try? source.close() }
        _ = fcntl(source.fileDescriptor, F_NOCACHE, 1)
        var hasher = SHA256()
        do {
            let out = try FileHandle(forWritingTo: temp)
            defer { try? out.close() }
            while true {
                try control.waitIfPaused()
                guard let data = try source.read(upToCount: 8 << 20), !data.isEmpty else { break }
                hasher.update(data: data)
                try out.write(contentsOf: data)
                progress(Int64(data.count))
            }
            try out.synchronize()
        } catch {
            try? fm.removeItem(at: temp)
            throw error
        }
        let expected = hasher.finalize().hex
        // Read back the copy, not the cache, and compare before it takes the real name.
        let actual = try sha256(of: temp, control: control, progress: progress)
        guard actual == expected else {
            try? fm.removeItem(at: temp)
            return false
        }
        try? fm.setAttributes([.modificationDate: item.modified, .posixPermissions: item.permissions], ofItemAtPath: temp.path)
        if (try? fm.attributesOfItem(atPath: item.destination.path)) != nil { try fm.removeItem(at: item.destination) }
        try fm.moveItem(at: temp, to: item.destination)
        return true
    }

    /// A note left beside the copy so whoever plugs it in knows what it is.
    static func aboutText(includesApp: Bool) -> String {
        """
        Offline Kit

        This folder is a copy of an Offline Kit library: references, maps, books, films, music, games and answer models \
        that work with no internet.

        \(includesApp ? "To use it on a Mac, open \"Offline Kit\" in this folder. It finds the Library folder beside it." : "Open Offline Kit on a Mac with this drive plugged in. It finds OfflineKit/Library on the drive by itself.")

        Private household information (people, health notes, contacts, saved answers) is not part of this copy. \
        It stays encrypted on the Mac it was made on.
        """
    }
}

/// Runs a copy in the background and publishes progress for the screen.
@MainActor @Observable
final class KitCopier {
    static let shared = KitCopier()

    enum Phase: Equatable { case idle, planning, ready, copying, paused, verifying, finished, stopped }

    private(set) var phase: Phase = .idle
    private(set) var plan: KitCopy.Plan?
    private(set) var bytesDone: Int64 = 0
    private(set) var bytesTotal: Int64 = 0
    private(set) var current = ""
    private(set) var outcome = KitCopy.Outcome()
    private(set) var bytesPerSecond: Double = 0
    private(set) var finishedAt: Date?
    /// Set by "Check the copy again": how many files matched and which didn't.
    private(set) var recheck: (checked: Int, mismatched: [KitCopy.Skipped])?
    private(set) var destinationKit: URL?
    /// Files the person chose not to replace.
    private(set) var leftAlone: [KitCopy.Item] = []
    /// Everything the last plan covered (copied, replaced or already there), for "Check the copy again".
    @ObservationIgnored private var allItems: [KitCopy.Item] = []
    @ObservationIgnored private var control = KitCopy.Control()
    @ObservationIgnored private var samples: [(Date, Int64)] = []

    var fraction: Double { bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0 }
    var isBusy: Bool { [.planning, .copying, .paused, .verifying].contains(phase) }

    var secondsLeft: Double? {
        guard bytesPerSecond > 0, bytesTotal > bytesDone else { return nil }
        return Double(bytesTotal - bytesDone) / bytesPerSecond
    }

    func reset() {
        guard !isBusy else { return }
        phase = .idle; plan = nil; outcome = KitCopy.Outcome(); recheck = nil; destinationKit = nil; finishedAt = nil
        leftAlone = []; allItems = []
    }

    /// Looks at what's there and works out what to copy. Copies nothing.
    func prepare(libraries: [URL], picked: URL, includeApp: Bool, appBundle: URL = Bundle.main.bundleURL) async {
        guard !isBusy else { return }
        let kit = KitCopy.kitFolder(in: picked)
        destinationKit = kit
        var roots = libraries.map { KitCopy.Root(source: $0, destination: kit.appending(path: "Library", directoryHint: .isDirectory), keepsLinks: false) }
        if includeApp, appBundle.pathExtension == "app" {
            roots.append(KitCopy.Root(source: appBundle, destination: kit.appending(path: appBundle.lastPathComponent, directoryHint: .isDirectory), keepsLinks: true))
        }
        phase = .planning
        outcome = KitCopy.Outcome()
        recheck = nil
        let made = await Task.detached(priority: .userInitiated) { KitCopy.plan(roots) }.value
        plan = made
        allItems = made.toCopy + made.replacing + made.identical
        phase = .ready
    }

    /// Copies everything in the plan. `replace` is true only after the person confirmed the listed replacements.
    func start(replace: Bool) {
        guard let plan, phase == .ready || phase == .stopped else { return }
        let items = plan.toCopy + (replace ? plan.replacing : [])
        let includesApp = plan.roots.contains { $0.keepsLinks }
        let kit = destinationKit
        control = KitCopy.Control()
        let control = self.control
        bytesTotal = items.reduce(0) { $0 + $1.size } * 2     // written once, read back once
        bytesDone = 0
        samples = []
        outcome = KitCopy.Outcome()
        phase = .copying
        leftAlone = replace ? [] : plan.replacing
        Task.detached(priority: .utility) {
            var result = KitCopy.Outcome()
            var stopped = false
            for item in items {
                do {
                    await MainActor.run { KitCopier.shared.current = item.relative }
                    let ok = try KitCopy.copy(item, control: control) { bytes in
                        Task { @MainActor in KitCopier.shared.advance(bytes) }
                    }
                    result.copied += 1
                    if ok { result.verified += 1 } else {
                        result.failures.append(KitCopy.Skipped(relative: item.relative, reason: "The copy didn’t match the original. It was removed; copy again to retry."))
                    }
                } catch is CancellationError {
                    stopped = true
                    break
                } catch {
                    result.failures.append(KitCopy.Skipped(relative: item.relative, reason: error.localizedDescription))
                }
            }
            if !stopped, let kit {
                let about = kit.appending(path: "About this kit.txt")
                if !FileManager.default.fileExists(atPath: about.path) {
                    try? KitCopy.aboutText(includesApp: includesApp).write(to: about, atomically: true, encoding: .utf8)
                }
            }
            let final = result, wasStopped = stopped
            await MainActor.run { KitCopier.shared.finish(final, stopped: wasStopped) }
        }
    }

    private func advance(_ bytes: Int64) {
        bytesDone += bytes
        let now = Date()
        samples.append((now, bytesDone))
        samples.removeAll { $0.0 < now.addingTimeInterval(-8) }
        if let first = samples.first, let last = samples.last, last.0.timeIntervalSince(first.0) > 0.5 {
            bytesPerSecond = Double(last.1 - first.1) / last.0.timeIntervalSince(first.0)
        }
    }

    private func finish(_ result: KitCopy.Outcome, stopped: Bool) {
        outcome = result
        current = ""
        phase = stopped ? .stopped : .finished
        finishedAt = Date()
    }

    func pause() {
        guard phase == .copying || phase == .verifying else { return }
        resumePhase = phase
        control.pause()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        control.resume()
        phase = resumePhase
    }

    func stop() { control.stop() }
    @ObservationIgnored private var resumePhase = Phase.copying

    /// Reads every file on both sides again and compares checksums. Changes nothing.
    func verifyAgain() {
        guard !allItems.isEmpty, !isBusy else { return }
        let items = allItems.filter { $0.linkTarget == nil }
        control = KitCopy.Control()
        let control = self.control
        bytesTotal = items.reduce(0) { $0 + $1.size } * 2
        bytesDone = 0
        samples = []
        phase = .verifying
        Task.detached(priority: .utility) {
            var mismatched: [KitCopy.Skipped] = []
            var checked = 0
            for item in items {
                await MainActor.run { KitCopier.shared.current = item.relative }
                let report: (Int64) -> Void = { bytes in Task { @MainActor in KitCopier.shared.advance(bytes) } }
                do {
                    let original = try KitCopy.sha256(of: item.source, control: control, progress: report)
                    guard FileManager.default.fileExists(atPath: item.destination.path) else {
                        mismatched.append(KitCopy.Skipped(relative: item.relative, reason: "Missing from the copy"))
                        continue
                    }
                    let copy = try KitCopy.sha256(of: item.destination, control: control, progress: report)
                    checked += 1
                    if original != copy { mismatched.append(KitCopy.Skipped(relative: item.relative, reason: "Doesn’t match the original")) }
                } catch is CancellationError {
                    break
                } catch {
                    mismatched.append(KitCopy.Skipped(relative: item.relative, reason: error.localizedDescription))
                }
            }
            let done = checked, bad = mismatched
            await MainActor.run {
                let copier = KitCopier.shared
                copier.recheck = (done, bad)
                copier.current = ""
                copier.phase = .finished
                copier.finishedAt = Date()
            }
        }
    }

    /// After a check found mismatches: copy those files again (they're the person's copy, made by this app).
    func recopyMismatched() async {
        guard let plan, let recheck, !recheck.mismatched.isEmpty, !isBusy else { return }
        let bad = Set(recheck.mismatched.map(\.relative))
        var redo = plan
        redo.toCopy = allItems.filter { bad.contains($0.relative) }
        redo.replacing = []
        redo.identical = []
        self.plan = redo
        self.recheck = nil
        phase = .ready
        start(replace: false)
    }
}
