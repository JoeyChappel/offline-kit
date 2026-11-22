import Foundation

/// Where the kit lives. When the app runs from an external drive, the folder holding the app is the kit:
/// `Library/` and the settings file sit beside it, so the drive works on any Mac it's plugged into.
enum KitLocation {
    /// The folder containing the app when it runs from an external drive, else nil.
    static let portableRoot: URL? = {
        #if os(macOS)
        #if DEBUG
        // Test hook: OFFLINEKIT_ROOT=/path forces drive mode.
        if let forced = ProcessInfo.processInfo.environment["OFFLINEKIT_ROOT"], !forced.isEmpty {
            return URL(fileURLWithPath: forced, isDirectory: true)
        }
        #endif
        let app = Bundle.main.bundleURL
        guard app.pathExtension == "app", app.path.hasPrefix("/Volumes/") else { return nil }
        let values = try? app.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsReadOnlyKey])
        guard values?.volumeIsInternal != true else { return nil }
        // A read-only volume (the mounted disk image) can't hold a kit; the app offers to move to Applications.
        guard values?.volumeIsReadOnly != true else { return nil }
        return app.deletingLastPathComponent()
        #else
        return nil
        #endif
    }()

    static var isPortable: Bool { portableRoot != nil }

    /// Debug builds can run as a brand-new user: OFFLINEKIT_HOME=<empty folder> stands in for the home folder,
    /// settings live in a plist there, and connected drives are ignored.
    static let testHome: URL? = {
        #if DEBUG
        if let path = ProcessInfo.processInfo.environment["OFFLINEKIT_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return nil
    }()

    /// The caches folder; a test run keeps its caches inside its stand-in home, away from the real ones.
    nonisolated static var caches: URL {
        testHome?.appending(path: "Library/Caches", directoryHint: .isDirectory) ?? URL.cachesDirectory
    }

    /// The user's home folder (or the test stand-in).
    static var home: URL {
        #if os(macOS)
        testHome ?? FileManager.default.homeDirectoryForCurrentUser
        #else
        testHome ?? URL.documentsDirectory
        #endif
    }

    /// False in the isolated test mode, so a fresh-user run never sees real drives.
    static var scansVolumes: Bool { testHome == nil }

    /// The library folder beside the app in drive mode.
    static var portableLibrary: URL? { portableRoot?.appending(path: "Library", directoryHint: .isDirectory) }

    /// The drive's display name in drive mode.
    static var portableVolumeName: String? {
        guard let root = portableRoot else { return nil }
        return (try? root.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
    }
}

/// Settings store. In drive mode it's a plist beside the app, so settings travel with the drive.
/// Otherwise it's the normal per-Mac UserDefaults.
final class KitSettings: @unchecked Sendable {
    static let shared = KitSettings()

    private let lock = NSLock()
    private let fileURL: URL?
    private var values: [String: Any] = [:]

    init(fileURL: URL? = (KitLocation.portableRoot ?? KitLocation.testHome)?.appending(path: "Offline Kit Settings.plist")) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            values = dict
        }
    }

    func string(forKey key: String) -> String? { get(key) as? String }
    func stringArray(forKey key: String) -> [String]? { get(key) as? [String] }
    func bool(forKey key: String) -> Bool? { get(key) as? Bool }

    /// Drive mode keeps the whole plist in one file, so a setting changed on every keystroke (calculator inputs, the
    /// power-out checklist) would rewrite it each time. Changes are held in memory and written together once they
    /// stop for this long. `flush()` writes at once: the app calls it when quitting, going to the background and
    /// before a drive is ejected.
    static let writeDelay: TimeInterval = 0.5
    private let writeLock = NSLock()
    private var dirty = false
    private var pendingWrite: DispatchWorkItem?

    func set(_ value: Any?, forKey key: String) {
        guard fileURL != nil else {
            UserDefaults.standard.set(value, forKey: key)
            return
        }
        lock.withLock {
            values[key] = value
            dirty = true
            pendingWrite?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.flush() }
            pendingWrite = item
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.writeDelay, execute: item)
        }
    }

    /// Writes any change still waiting for its debounce, now. Cheap when nothing is waiting.
    func flush() {
        guard let fileURL else { return }
        // One write at a time, and the snapshot is taken inside the write lock, so an older snapshot never lands last.
        writeLock.withLock {
            let snapshot: [String: Any]? = lock.withLock {
                pendingWrite?.cancel()
                pendingWrite = nil
                guard dirty else { return nil }
                dirty = false
                return values
            }
            guard let snapshot,
                  let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .xml, options: 0) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    private func get(_ key: String) -> Any? {
        guard fileURL != nil else { return UserDefaults.standard.object(forKey: key) }
        return lock.withLock { values[key] }
    }
}

/// The one place new things go: downloads, and the games, movies, audio and PDFs people add.
/// It's the location they chose for their library (often a USB drive), so everything stays together.
enum KitStorage {
    private static let key = "saveFolder"

    /// Drive mode: beside the app. Otherwise the library folder they chose, if its drive is connected; else this device.
    static var primaryLibrary: URL {
        #if os(macOS)
        if let portable = KitLocation.portableLibrary { return portable }
        if let chosen { return chosen }
        // Nothing chosen yet: a connected drive that already holds a kit, so new things join the existing library.
        if KitLocation.scansVolumes, let volumes = try? FileManager.default.contentsOfDirectory(atPath: "/Volumes") {
            for volume in volumes.sorted() {
                let library = URL(fileURLWithPath: "/Volumes/\(volume)/OfflineKit/Library", isDirectory: true)
                if FileManager.default.fileExists(atPath: library.path), FileManager.default.isWritableFile(atPath: library.path) {
                    return library
                }
            }
        }
        return KitLocation.home.appending(path: "OfflineKit/Library", directoryHint: .isDirectory)
        #else
        return URL.documentsDirectory
        #endif
    }

    /// The chosen library folder, when it's reachable right now.
    static var chosen: URL? {
        guard let path = KitSettings.shared.string(forKey: key), !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        // A folder on a drive counts only while that drive is plugged in.
        let parts = url.pathComponents
        if parts.count > 2, parts[1] == "Volumes" {
            guard FileManager.default.fileExists(atPath: "/Volumes/\(parts[2])") else { return nil }
        }
        return url
    }

    /// Saved path even when its drive is away, for messages like "Connect My Drive".
    static var chosenPath: String? { KitSettings.shared.string(forKey: key) }

    static func remember(_ folder: URL) {
        KitSettings.shared.set(folder.standardizedFileURL.path, forKey: key)
    }

    /// Where each kind of thing goes inside the library.
    static var games: URL { primaryLibrary.appending(path: "Games", directoryHint: .isDirectory) }
    static var media: URL { primaryLibrary.appending(path: "Media", directoryHint: .isDirectory) }
    static var documents: URL { primaryLibrary.appending(path: "Documents", directoryHint: .isDirectory) }
}
