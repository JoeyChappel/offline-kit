import Foundation
import Testing

// MARK: - SharePolicy

@Suite("SharePolicy.Scope")
struct SharePolicyScopeTests {
    @Test("Files inside a library folder are allowed; files outside are not")
    func insideAndOutside() throws {
        let tmp = try TempDir()
        let library = try tmp.folder("Library")
        let movie = try tmp.file("Library/Media/Film.mp4")
        let outside = try tmp.file("Elsewhere/secret.txt")
        let scope = SharePolicy.Scope(libraries: [library])
        #expect(scope.allows(movie))
        #expect(!scope.allows(outside))
        #expect(!scope.allows(library), "the library folder itself isn't a file inside it")
    }

    @Test("A path that climbs out with .. is judged where it lands")
    func dotDotEscape() throws {
        let tmp = try TempDir()
        let library = try tmp.folder("Library")
        try tmp.file("Elsewhere/secret.txt")
        let sneaky = URL(fileURLWithPath: library.path + "/Media/../../Elsewhere/secret.txt")
        #expect(!SharePolicy.Scope(libraries: [library]).allows(sneaky))
    }

    @Test("A folder whose name starts like the library's isn't inside it")
    func siblingPrefix() throws {
        let tmp = try TempDir()
        let library = try tmp.folder("Library")
        let sibling = try tmp.file("Library2/file.mp4")
        #expect(!SharePolicy.Scope(libraries: [library]).allows(sibling))
    }

    @Test("A symlink inside the library that points outside is refused")
    func symlinkEscaping() throws {
        let tmp = try TempDir()
        let library = try tmp.folder("Library")
        let secret = try tmp.file("Elsewhere/secret.txt")
        let link = try tmp.link("Library/Media/innocent.mp4", to: secret)
        let folderLink = try tmp.link("Library/Media/Folder", to: tmp.url.appending(path: "Elsewhere"))
        let scope = SharePolicy.Scope(libraries: [library])
        #expect(!scope.allows(link))
        #expect(!scope.allows(folderLink.appending(path: "secret.txt")))
    }

    @Test("A symlink to a system file is refused")
    func symlinkToSystem() throws {
        let tmp = try TempDir()
        let library = try tmp.folder("Library")
        let link = try tmp.link("Library/hosts.txt", to: URL(fileURLWithPath: "/etc/hosts"))
        #expect(!SharePolicy.Scope(libraries: [library]).allows(link))
    }

    @Test("A symlink that stays inside the library is allowed")
    func symlinkInside() throws {
        let tmp = try TempDir()
        let library = try tmp.folder("Library")
        let real = try tmp.file("Library/Media/Real.mp4")
        let link = try tmp.link("Library/Media/Alias.mp4", to: real)
        #expect(SharePolicy.Scope(libraries: [library]).allows(link))
    }

    @Test("The app's own caches are allowed")
    func caches() throws {
        _ = try TestSupport.testHome()
        let art = KitLocation.caches.appending(path: "OfflineKit/test-art-\(UUID().uuidString).jpg")
        try FileManager.default.createDirectory(at: art.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("jpg".utf8).write(to: art)
        defer { try? FileManager.default.removeItem(at: art) }
        #expect(SharePolicy.Scope(libraries: []).allows(art))
    }

    @Test("Linked Media in a library on this Mac counts: its files and folders, nothing else")
    func linkedMediaOnMac() throws {
        let tmp = try TempDir()
        let library = try tmp.folder("Library")
        let song = try tmp.file("Music/Album/01 Song.mp3")
        let other = try tmp.file("Music/Album/notes.txt")
        let film = try tmp.file("Movies/Film.mp4")
        let unrelated = try tmp.file("Movies/Other.mp4")
        try LinkedMedia.add([
            LinkedMediaEntry(kind: .audio, title: "Album", folder: song.deletingLastPathComponent().path, tracks: [song.path]),
            LinkedMediaEntry(kind: .video, title: "Film", folder: nil, tracks: [film.path]),
        ], to: library)
        let scope = SharePolicy.Scope(libraries: [library])
        #expect(scope.allows(song))
        #expect(scope.allows(other), "a linked folder covers everything in it")
        #expect(scope.allows(film))
        #expect(!scope.allows(unrelated), "a single linked file covers only itself")
    }

    @Test("Linked Media can't open the private details folder")
    func linkedMediaIntoPrivate() throws {
        _ = try TestSupport.testHome()
        let tmp = try TempDir()
        let library = try tmp.folder("Library")
        let privateFile = PrivateStore.localFolder.appending(path: "probe-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: PrivateStore.localFolder, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: privateFile)
        defer { try? FileManager.default.removeItem(at: privateFile) }
        try LinkedMedia.add([LinkedMediaEntry(kind: .audio, title: "Sneaky", folder: PrivateStore.localFolder.path,
                                              tracks: [privateFile.path])], to: library)
        #expect(!SharePolicy.Scope(libraries: [library]).allows(privateFile))
    }

    @Test("Links from a drive library count only when they stay on that drive")
    func staysOnDrive() {
        // Path logic only: nothing under /Volumes is created or read (the names don't exist).
        let drive = "OKTestNoSuchDrive-\(UUID().uuidString.prefix(6))"
        let root = URL(fileURLWithPath: "/Volumes/\(drive)/OfflineKit/Library")
        #expect(SharePolicy.staysOnDrive(URL(fileURLWithPath: "/Volumes/\(drive)/Movies/Film.mp4"), libraryRoot: root))
        #expect(!SharePolicy.staysOnDrive(URL(fileURLWithPath: "/Users/someone/Movies/Film.mp4"), libraryRoot: root))
        #expect(!SharePolicy.staysOnDrive(URL(fileURLWithPath: "/Volumes/\(drive)-other/Film.mp4"), libraryRoot: root))
        #expect(!SharePolicy.staysOnDrive(URL(fileURLWithPath: "/Volumes/\(drive)/../Macintosh HD/Users/x"), libraryRoot: root))
        // A library on this Mac: links are the owner's.
        #expect(SharePolicy.staysOnDrive(URL(fileURLWithPath: "/Users/someone/Movies/Film.mp4"), libraryRoot: URL(fileURLWithPath: "/tmp/Library")))
    }
}

@Suite("SharePolicy.isOffLimits")
struct OffLimitsTests {
    @Test("System folders are off limits", arguments: ["/etc/hosts", "/System/Library/CoreServices", "/usr/bin/true", "/bin/ls",
                                                       "/sbin/mount", "/Library/Preferences", "/private/etc/hosts"])
    func systemFolders(_ path: String) {
        #expect(SharePolicy.isOffLimits(URL(fileURLWithPath: path)))
    }

    @Test("/private/var (and /var) is off limits")
    func privateVar() {
        // SharePolicy.real strips the "/private" prefix ("/private/var/log" becomes "/var/log"), so /var/ is listed too.
        #expect(SharePolicy.isOffLimits(URL(fileURLWithPath: "/private/var/log/system.log")))
        #expect(SharePolicy.isOffLimits(URL(fileURLWithPath: "/var/db")))
    }

    @Test("The home folder's Library and hidden folders are off limits")
    func homeLibraryAndDotFolders() {
        // Names that don't exist, so nothing in the real home is read.
        let home = NSHomeDirectory()
        #expect(SharePolicy.isOffLimits(URL(fileURLWithPath: home + "/.okit-test-nonexistent/id_rsa")))
        #expect(SharePolicy.isOffLimits(URL(fileURLWithPath: home + "/Library/okit-test-nonexistent/Cookies")))
        #expect(!SharePolicy.isOffLimits(URL(fileURLWithPath: home + "/okit-test-nonexistent/Movies/Film.mp4")))
    }

    @Test("The private details folder is off limits, the caches aren't")
    func privateAndCaches() throws {
        _ = try TestSupport.testHome()
        #expect(SharePolicy.isOffLimits(PrivateStore.localFolder))
        #expect(SharePolicy.isOffLimits(PrivateStore.localFolder.appending(path: "household.sealed")))
        #expect(!SharePolicy.isOffLimits(KitLocation.caches.appending(path: "OfflineKit/art.jpg")))
    }

    @Test("Ordinary temp files aren't off limits")
    func ordinary() throws {
        let tmp = try TempDir()
        #expect(!SharePolicy.isOffLimits(try tmp.file("Library/Film.mp4")))
    }

    @Test("real() follows links and removes .. and .")
    func real() throws {
        let tmp = try TempDir()
        let target = try tmp.file("a/b/file.txt")
        let link = try tmp.link("link.txt", to: target)
        #expect(SharePolicy.real(link) == SharePolicy.real(target))
        #expect(SharePolicy.real(URL(fileURLWithPath: tmp.url.path + "/a/./b/../b/file.txt")) == SharePolicy.real(target))
    }
}

// MARK: - KitRefresh

@Suite("KitRefresh.isReplaceable")
struct KitRefreshTests {
    @Test("An ordinary .zim beside the new download may be replaced")
    func ordinary() throws {
        let tmp = try TempDir()
        let old = try tmp.file("Library/wikipedia_2025.zim")
        let new = tmp.url.appending(path: "Library/wikipedia_2026.zim")
        #expect(KitRefresh.isReplaceable(old: old, new: new))
        let upper = try tmp.file("Library/OLD.ZIM")
        #expect(KitRefresh.isReplaceable(old: upper, new: new), "the extension is matched in any case")
    }

    @Test("The new file itself is never the old one")
    func samePath() throws {
        let tmp = try TempDir()
        let file = try tmp.file("Library/a.zim")
        #expect(!KitRefresh.isReplaceable(old: file, new: file))
        #expect(!KitRefresh.isReplaceable(old: URL(fileURLWithPath: tmp.url.path + "/Library/./a.zim"), new: file))
    }

    @Test("A folder named .zim is refused")
    func folder() throws {
        let tmp = try TempDir()
        let old = try tmp.folder("Library/old.zim")
        #expect(!KitRefresh.isReplaceable(old: old, new: tmp.url.appending(path: "Library/new.zim")))
    }

    @Test("A symlink is refused, even to a real archive beside it")
    func symlink() throws {
        let tmp = try TempDir()
        let target = try tmp.file("Library/real.zim")
        let link = try tmp.link("Library/old.zim", to: target)
        #expect(!KitRefresh.isReplaceable(old: link, new: tmp.url.appending(path: "Library/new.zim")))
        let outside = try tmp.file("Elsewhere/important.zim")
        let link2 = try tmp.link("Library/old2.zim", to: outside)
        #expect(!KitRefresh.isReplaceable(old: link2, new: tmp.url.appending(path: "Library/new.zim")))
    }

    @Test("An archive in another folder is refused")
    func otherFolder() throws {
        let tmp = try TempDir()
        let old = try tmp.file("Other/old.zim")
        #expect(!KitRefresh.isReplaceable(old: old, new: tmp.url.appending(path: "Library/new.zim")))
        let climbing = URL(fileURLWithPath: tmp.url.path + "/Library/../Other/old.zim")
        #expect(!KitRefresh.isReplaceable(old: climbing, new: tmp.url.appending(path: "Library/new.zim")))
    }

    @Test("Anything that isn't a .zim is refused")
    func notZim() throws {
        let tmp = try TempDir()
        let new = tmp.url.appending(path: "Library/new.zim")
        for name in ["notes.txt", "photo.zim.jpg", "archive.zimaa", "zim"] {
            #expect(!KitRefresh.isReplaceable(old: try tmp.file("Library/\(name)"), new: new), "\(name)")
        }
    }

    @Test("A file that isn't there is refused")
    func missing() throws {
        let tmp = try TempDir()
        #expect(!KitRefresh.isReplaceable(old: tmp.url.appending(path: "Library/gone.zim"), new: tmp.url.appending(path: "Library/new.zim")))
    }
}

// MARK: - Addresses

@Suite("Device keys and addresses")
struct AddressTests {
    @Test("ShareDeviceKey groups one device's address forms", arguments: [
        ("192.168.1.20", "192.168.1.20"),
        ("::ffff:192.168.1.20", "192.168.1.20"),
        ("::FFFF:192.168.1.20", "192.168.1.20"),
        ("fe80::1c2b:3a4d%en0", "fe80::1c2b:3a4d"),
        ("FE80::1C2B:3A4D%en0", "fe80::1c2b:3a4d"),
        ("2001:db8::1", "2001:db8::1"),
        ("::ffff:abcd", "::ffff:abcd"),
    ])
    func deviceKey(_ host: String, _ expected: String) {
        #expect(ShareDeviceKey.key(host) == expected)
    }

    @Test("Two addresses of the same /64 stay separate devices")
    func noIPv6Grouping() {
        #expect(ShareDeviceKey.key("2001:db8:1:2::10") != ShareDeviceKey.key("2001:db8:1:2::11"))
    }

    @Test("WebServer.isLocal accepts home-network addresses", arguments: [
        "127.0.0.1", "127.8.9.10", "10.0.0.5", "192.168.0.10", "172.16.0.1", "172.31.255.255", "169.254.3.4",
        "::1", "fe80::1", "FE80::abcd%en0", "fd12:3456::1", "fc00::1", "::ffff:192.168.1.2", "::ffff:10.1.2.3",
    ])
    func local(_ host: String) {
        #expect(WebServer.isLocal(host))
    }

    @Test("WebServer.isLocal refuses public addresses", arguments: [
        "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.169.0.1", "11.0.0.1", "1.2.3.4", "2001:db8::1", "::ffff:8.8.8.8",
        "", "0.0.0.0", "100.64.0.1",
    ])
    func notLocal(_ host: String) {
        #expect(!WebServer.isLocal(host))
    }

    @Test("Host check allows IP addresses, localhost and .local names, with or without a port", arguments: [
        "192.168.1.20", "192.168.1.20:8080", "localhost", "LOCALHOST:80", "my-mac.local", "My-Mac.local:8080",
        "[fe80::1]:8080", "[::1]", " 10.0.0.2 ",
    ])
    func allowedHost(_ host: String) {
        #expect(ShareController.isAllowedHost(host))
    }

    @Test("Host check refuses other names (DNS rebinding)", arguments: [
        "evil.com", "evil.com:8080", "192.168.1.20.evil.com", "localhost.evil.com", "local", "mac.local.evil.com",
        "1.2.3", "1.2.3.4.5", "256.1.1.1", "1.2.3.", "", "   ", "0x7f.0.0.1",
    ])
    func refusedHost(_ host: String) {
        #expect(!ShareController.isAllowedHost(host))
    }

    @Test("Host check refuses a missing Host header")
    func missingHost() {
        #expect(!ShareController.isAllowedHost(nil))
    }

    @Test("origin() keeps the address the device used and swaps the port")
    func origin() {
        #expect(ShareController.origin(host: "192.168.1.2:8080", port: 8081) == "http://192.168.1.2:8081")
        #expect(ShareController.origin(host: "[fe80::1]:8080", port: 9) == "http://[fe80::1]:9")
        #expect(ShareController.origin(host: nil, port: 80) == "http://localhost:80")
    }
}

// MARK: - Send to iPhone

@Suite("SendManifest.isSafe")
struct SendManifestTests {
    @Test("Destinations inside Media, Games and Documents, or an archive at the top, are safe", arguments: [
        "Media/Film.mp4", "Games/DOS/game.zip", "Documents/manual.pdf", "wikipedia.zim", "WIKI.ZIM", "Media/Show/S1/E1.mp4",
    ])
    func safe(_ path: String) {
        #expect(SendManifest.isSafe(path))
    }

    @Test("Anything that could land elsewhere is refused", arguments: [
        "", "/etc/passwd", "/Media/x.mp4", "../x.zim", "Media/../../x", "Media/./x.mp4", "Media//x.mp4", "Media/.hidden",
        ".zim", "notes.txt", "Other/file.mp4", "media/Film.mp4", "Media\\..\\x", "Media/x/", "Media/x/..",
    ])
    func unsafe(_ path: String) {
        #expect(!SendManifest.isSafe(path))
    }
}

// MARK: - Private details

@Suite("PrivateStore", .serialized)
struct PrivateStoreTests {
    struct Sample: Codable, Equatable { var name: String; var allergies: [String] }

    @Test("Round trip in the test home: sealed on disk, key in the test folder, erased cleanly")
    func roundTrip() throws {
        #if DEBUG
        let home = try TestSupport.testHome()
        try #require(PrivateStore.localFolder.path.hasPrefix(home.path), "the store must live in the test home")
        try #require(!PrivateStore.usesPassphrase)
        let sample = Sample(name: "Test Person", allergies: ["peanuts"])
        try PrivateStore.save(sample)
        defer { PrivateStore.erase() }
        let sealed = try Data(contentsOf: PrivateStore.fileURL)
        #expect(sealed.range(of: Data("peanuts".utf8)) == nil, "the file on disk is encrypted")
        #expect(FileManager.default.fileExists(atPath: home.appending(path: ".private/key").path), "the key is a test file, not a Keychain item")
        #expect(PrivateStore.load(Sample.self) == sample)
        PrivateStore.erase()
        #expect(PrivateStore.load(Sample.self) == nil)
        #else
        Issue.record("needs a Debug build")
        #endif
    }
}
