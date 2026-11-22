import Foundation
import Testing

/// Shared helpers. Every test works in folders it makes under /tmp and removes afterwards. /tmp rather than $TMPDIR:
/// $TMPDIR is under /private/var, which SharePolicy treats as a system folder, so library-scope tests need a
/// neutral place.
enum TestSupport {
    /// The stand-in home (OFFLINEKIT_HOME, set by the OfflineKitTests scheme and Tools/Tests/run-tests.sh). Tests that
    /// reach settings, caches or the private store require it, so a misconfigured run fails instead of touching the
    /// real ~/OfflineKit, its settings or the Keychain.
    static func testHome() throws -> URL {
        let home = try #require(KitLocation.testHome, "OFFLINEKIT_HOME isn't set: run Tools/Tests/run-tests.sh or the OfflineKitTests scheme")
        let real = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        try #require(home.standardizedFileURL.path != real, "OFFLINEKIT_HOME must not be the real home folder")
        return home
    }

    /// The test bundle's Fixtures folder (Tests/Fixtures).
    static func fixture(_ name: String) throws -> URL {
        let folder = try #require(Bundle(for: BundleToken.self).url(forResource: "Fixtures", withExtension: nil))
        let url = folder.appending(path: name)
        try #require(FileManager.default.fileExists(atPath: url.path), "missing fixture \(name)")
        return url
    }
}

final class BundleToken {}

/// A fresh folder under /tmp, removed when the value goes away.
final class TempDir {
    let url: URL

    init(_ label: String = #function) throws {
        let safe = label.filter { $0.isLetter || $0.isNumber }.prefix(40)
        url = URL(fileURLWithPath: "/tmp", isDirectory: true).appending(path: "okit-tests-\(safe)-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    /// Writes a file (making its folders) and returns its URL.
    @discardableResult
    func file(_ path: String, _ contents: String = "x") throws -> URL {
        let url = self.url.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let url = self.url.appending(path: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A symbolic link at `path` pointing to `target`.
    @discardableResult
    func link(_ path: String, to target: URL) throws -> URL {
        let url = self.url.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        return url
    }
}

/// Waits for `condition` (polling), up to `timeout` seconds. True if it became true.
/// Runs on the caller's actor, so a main-actor test can read main-actor state in `condition` (without
/// `isolation` the polling ran on the global executor: a data race the Thread Sanitizer reported).
func eventually(timeout: Double = 3, isolation: isolated (any Actor)? = #isolation,
                _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@Suite("Test environment")
struct EnvironmentTests {
    @Test("Debug build with a stand-in home")
    func debugAndTestHome() throws {
        #if !DEBUG
        Issue.record("Tests must build in Debug: the OFFLINEKIT_HOME test hooks (settings, caches, test keys) are Debug-only")
        #endif
        let home = try TestSupport.testHome()
        #expect(KitLocation.caches.path.hasPrefix(home.path))
        #expect(PrivateStore.localFolder.path.hasPrefix(home.path))
        #expect(KitLocation.scansVolumes == false, "a test home never looks at /Volumes")
        #expect(KitLocation.portableRoot == nil)
    }
}
