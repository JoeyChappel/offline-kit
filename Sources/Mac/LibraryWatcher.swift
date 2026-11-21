import Foundation
import CoreServices

/// Notices files added, removed or renamed in the kit's folders (someone dragging movies in with Finder, `cp`,
/// another app) and rescans just the shelf that changed, once things have been quiet for about a second.
///
/// Kept cheap on purpose: one FSEvents stream for every library folder, no rescans for the app's own writes
/// (game saves, catalog and linked-media lists, temp files of copies and downloads still in progress),
/// and a busy folder (a long copy) waits until it settles instead of rescanning over and over.
@MainActor
final class LibraryWatcher {
    enum Shelf: Hashable { case references, media, games, documents, models }

    static let shared = LibraryWatcher()

    /// Called on the main thread with the shelves whose folders changed.
    var onChange: ((Set<Shelf>) -> Void)?

    private enum Root { case library, media, documents }
    private var stream: FSEventStreamRef?
    private var roots: [(path: String, kind: Root)] = []
    private var pending: Set<Shelf> = []
    private var debounce: Task<Void, Never>?

    /// Files that are still being written by a copy or download, or that the app writes for itself.
    nonisolated private static let ignoredExtensions: Set<String> = ["part", "okdl", "okcopy", "aria2", "download", "crdownload", "tmp", "json", "ini", "plist"]

    /// Watches these library folders plus the extra Media and Documents folders. Restarts only if the list changed.
    /// Folders that don't exist aren't watched; call again after one is created or a drive comes and goes.
    func watch(libraries: [URL], media: [URL], documents: [URL]) {
        let fm = FileManager.default
        // FSEvents reports real paths ("/private/tmp", not "/tmp"), so match against those.
        func existing(_ urls: [URL], _ kind: Root) -> [(String, Root)] {
            urls.map(\.path).filter { fm.fileExists(atPath: $0) }
                .compactMap { path in realpath(path, nil).map { pointer in defer { free(pointer) }; return (String(cString: pointer), kind) } }
        }
        var list = existing(libraries, .library) + existing(media, .media) + existing(documents, .documents)
        var seen = Set<String>()
        list = list.filter { seen.insert($0.0).inserted }
        guard list.map(\.0) != roots.map(\.path) || stream == nil && !list.isEmpty else { return }
        stop()
        roots = list.map { (path: $0.0, kind: $0.1) }
        guard !roots.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(nil, Self.callback, &context, roots.map(\.path) as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    /// Stops watching folders on a drive that's about to go away (so nothing holds on to it), or everything.
    func stop(volume: URL? = nil) {
        if let volume {
            let prefix = volume.standardizedFileURL.path + "/"
            guard roots.contains(where: { ($0.path + "/").hasPrefix(prefix) }) else { return }
            let keep = roots.filter { !($0.path + "/").hasPrefix(prefix) }
            stop()
            watch(libraries: keep.filter { $0.kind == .library }.map { URL(fileURLWithPath: $0.path) },
                  media: keep.filter { $0.kind == .media }.map { URL(fileURLWithPath: $0.path) },
                  documents: keep.filter { $0.kind == .documents }.map { URL(fileURLWithPath: $0.path) })
            return
        }
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        roots = []
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray as? [String]) ?? []
        let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
        MainActor.assumeIsolated {
            Unmanaged<LibraryWatcher>.fromOpaque(info).takeUnretainedValue().received(list, flagList)
        }
    }

    private func received(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        var shelves: Set<Shelf> = []
        for (index, path) in paths.enumerated() {
            let flag = index < flags.count ? Int(flags[index]) : 0
            // Events were dropped or a watched folder itself moved: rescan everything under it.
            let everything = flag & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged
                                     | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0
            shelves.formUnion(Self.shelves(for: path, isFolder: flag & kFSEventStreamEventFlagItemIsDir != 0,
                                           everything: everything, roots: roots))
        }
        guard !shelves.isEmpty else { return }
        pending.formUnion(shelves)
        // Trailing debounce: a copy that keeps writing keeps pushing the rescan back until it's finished.
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            let changed = self.pending
            self.pending = []
            #if DEBUG
            if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
                FileHandle.standardError.write(Data("watcher: rescanning \(changed.map { "\($0)" }.sorted().joined(separator: ", "))\n".utf8))
            }
            #endif
            self.onChange?(changed)
        }
    }

    /// Which shelves a changed path belongs to, or none for files the app doesn't show or writes itself.
    nonisolated private static func shelves(for path: String, isFolder: Bool, everything: Bool,
                                            roots: [(path: String, kind: Root)]) -> Set<Shelf> {
        // The deepest watched folder holding it (a Media folder inside a library is listed on its own).
        guard let root = roots.filter({ path == $0.path || path.hasPrefix($0.path + "/") }).max(by: { $0.path.count < $1.path.count })
        else { return [] }
        let relative = path == root.path ? [] : path.dropFirst(root.path.count + 1).split(separator: "/").map(String.init)
        if everything || relative.isEmpty {
            switch root.kind {
            case .library: return [.references, .media, .games, .documents, .models]
            case .media: return [.media]
            case .documents: return [.documents]
            }
        }
        let name = relative.last ?? ""
        // Hidden files (.DS_Store, "._" companions, ".complete" markers) and files still being written.
        if name.hasPrefix(".") || ignoredExtensions.contains((name as NSString).pathExtension.lowercased()) { return [] }
        let ext = (name as NSString).pathExtension.lowercased()
        switch root.kind {
        case .media:
            return isFolder || isMedia(ext) ? [.media] : []
        case .documents:
            return isFolder || ext == "pdf" ? [.documents] : []
        case .library:
            switch relative[0] {
            case "Media": return relative.count == 1 || isFolder || isMedia(ext) ? [.media] : []
            // Saves, save pictures, settings and play history are the app's own writes.
            case "Games": return relative.contains("Saves") ? [] : [.games]
            case "Documents": return relative.count == 1 || isFolder || ext == "pdf" ? [.documents] : []
            case "Models": return [.models]
            default:
                // Reference archives sit directly in the library folder. Catalog and linked-media lists are the app's.
                return relative.count == 1 && ext == "zim" ? [.references] : []
            }
        }
    }

    nonisolated private static func isMedia(_ ext: String) -> Bool {
        MediaLibrary.videoExtensions.contains(ext) || MediaLibrary.audioExtensions.contains(ext)
            || MediaLibrary.bookExtensions.contains(ext) || ["jpg", "jpeg", "png"].contains(ext)
    }
}
