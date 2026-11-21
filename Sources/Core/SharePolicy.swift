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
        if path.hasPrefix(real(KitLocation.caches) + "/") { return false }
        let privateFolder = real(PrivateStore.folder)
        if path == privateFolder || path.hasPrefix(privateFolder + "/") { return true }
        let home = real(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
        if path.hasPrefix(home + "/Library/") || path.hasPrefix(home + "/.") { return true }
        for system in ["/etc/", "/private/etc/", "/private/var/", "/System/", "/Library/", "/usr/", "/bin/", "/sbin/", "/cores/"]
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

    /// The full path with links followed and "..", "." removed.
    nonisolated static func real(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
