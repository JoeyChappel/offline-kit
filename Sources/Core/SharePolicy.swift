import Foundation

/// Where a file may come from when it leaves this Mac: over Share on Wi-Fi, Send to iPhone or a kit copy to a drive.
/// Library folders can hold links (symlinks, aliases, "Keep where it is" media), and a drive or a dropped folder
/// can be made by someone else, so every file is checked where it really lives, after following links.
enum SharePolicy {
    /// True for places nothing should ever be shared from, whatever a link says: private household data,
    /// the home folder's Library and hidden folders (.ssh, .config and so on), and system folders.
    /// The app's own caches (cover art, video stills) are allowed.
    nonisolated static func isOffLimits(_ url: URL) -> Bool {
        let path = real(url)
        if path.hasPrefix(real(appCaches) + "/") { return false }
        let privateFolder = real(PrivateStore.folder)
        if path == privateFolder || path.hasPrefix(privateFolder + "/") { return true }
        let home = real(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        if path.hasPrefix(home + "/Library/") || path.hasPrefix(home + "/.") { return true }
        for system in ["/etc/", "/private/etc/", "/var/", "/private/var/", "/System/", "/Library/", "/usr/", "/bin/", "/sbin/", "/cores/"]
        where path.hasPrefix(system) { return true }
        return false
    }

    /// For a file found in a library on an external drive: true only if, after following links, it's on that same
    /// drive. A drive can't point into this Mac.
    nonisolated static func staysOnDrive(_ file: URL, libraryRoot root: URL) -> Bool {
        let rootPath = real(root)
        guard rootPath.hasPrefix("/Volumes/") else { return true }   // this Mac's own library: links are the owner's
        let parts = rootPath.split(separator: "/", maxSplits: 2)
        guard parts.count >= 2 else { return false }
        return real(file).hasPrefix("/Volumes/\(parts[1])/")
    }

    /// Where files may come from when they leave this Mac, worked out once per request from the library folders.
    /// A file counts only where it really lives (links followed): inside a library folder or the app's caches,
    /// or covered by a "Keep where it is" link. Links listed in a library on this Mac are the owner's; links listed
    /// in a library on a drive count only when they stay on that drive, so a drive someone hands you can't point
    /// Share or Send at the rest of this Mac, and neither can a symlink inside a folder someone gave you.
    struct Scope: Sendable {
        private var folders: [String] = []
        private var files: Set<String> = []

        nonisolated init(libraries: [URL]) {
            folders = [SharePolicy.real(SharePolicy.appCaches)]
            for library in libraries {
                let root = SharePolicy.real(library)
                folders.append(root)
                let onDrive = root.hasPrefix("/Volumes/")
                for entry in LinkedMedia.load([library]) {
                    let paths = (entry.folder.map { [$0] } ?? []) + entry.tracks
                    for path in paths {
                        let url = URL(fileURLWithPath: path)
                        guard !onDrive || SharePolicy.staysOnDrive(url, libraryRoot: library) else { continue }
                        if path == entry.folder { folders.append(SharePolicy.real(url)) } else { files.insert(SharePolicy.real(url)) }
                    }
                }
            }
        }

        nonisolated func allows(_ url: URL) -> Bool {
            let path = SharePolicy.real(url)
            if SharePolicy.isOffLimits(url) { return false }
            return files.contains(path) || folders.contains { path.hasPrefix($0 + "/") }
        }
    }

    /// Offline Kit's own caches (cover art, video stills, phone-sized artwork). Not the whole caches folder: outside a
    /// sandbox that is ~/Library/Caches, every app's.
    nonisolated static var appCaches: URL { KitLocation.caches.appending(path: "OfflineKit", directoryHint: .isDirectory) }

    /// The full path with links followed and "..", "." removed.
    nonisolated static func real(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
