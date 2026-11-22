import Foundation
import Testing

/// Drive-mode settings: one plist, written once changes pause (KitSettings.writeDelay), or at once on flush().
@Suite("KitSettings in drive mode")
struct KitSettingsTests {
    func plist(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test("Changes are held, then written once they stop")
    func debounce() async throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "Offline Kit Settings.plist")
        let settings = KitSettings(fileURL: file)
        for n in 0..<20 { settings.set("value \(n)", forKey: "calculator") }
        settings.set(true, forKey: "shareOnWiFi")
        #expect(settings.string(forKey: "calculator") == "value 19", "reads see the change at once")
        #expect(!FileManager.default.fileExists(atPath: file.path), "nothing is written while changes keep coming")
        let written = await eventually(timeout: KitSettings.writeDelay + 2) { FileManager.default.fileExists(atPath: file.path) }
        try #require(written)
        let saved = try plist(file)
        #expect(saved["calculator"] as? String == "value 19")
        #expect(saved["shareOnWiFi"] as? Bool == true)
    }

    @Test("flush() writes at once, and is cheap when nothing is waiting")
    func flush() throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "Offline Kit Settings.plist")
        let settings = KitSettings(fileURL: file)
        settings.flush()
        #expect(!FileManager.default.fileExists(atPath: file.path), "nothing waiting, nothing written")
        settings.set(["a", "b"], forKey: "shareNetworks")
        settings.flush()
        #expect(try plist(file)["shareNetworks"] as? [String] == ["a", "b"])
        // A flush cancels the pending write: changing the file behind its back shows nothing rewrites it.
        try Data().write(to: file)
        Thread.sleep(forTimeInterval: KitSettings.writeDelay + 0.2)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test("A new store reads the file back; nil removes a key")
    func reload() throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "Offline Kit Settings.plist")
        let first = KitSettings(fileURL: file)
        first.set("1234", forKey: "sharePIN")
        first.set(["x"], forKey: "list")
        first.set(false, forKey: "flag")
        first.flush()
        let second = KitSettings(fileURL: file)
        #expect(second.string(forKey: "sharePIN") == "1234")
        #expect(second.stringArray(forKey: "list") == ["x"])
        #expect(second.bool(forKey: "flag") == false)
        #expect(second.string(forKey: "flag") == nil, "a value of another type reads as nil")
        second.set(nil, forKey: "sharePIN")
        second.flush()
        #expect(KitSettings(fileURL: file).string(forKey: "sharePIN") == nil)
    }

    @Test("A damaged settings file starts empty instead of failing")
    func damaged() throws {
        let tmp = try TempDir()
        let file = try tmp.file("Offline Kit Settings.plist", "not a plist")
        #expect(KitSettings(fileURL: file).string(forKey: "anything") == nil)
    }

    @Test("Writes from many threads all land")
    func concurrent() throws {
        let tmp = try TempDir()
        let file = tmp.url.appending(path: "Offline Kit Settings.plist")
        let settings = KitSettings(fileURL: file)
        DispatchQueue.concurrentPerform(iterations: 200) { n in
            settings.set(n, forKey: "key\(n % 50)")
            if n % 7 == 0 { settings.flush() }
        }
        settings.flush()
        #expect(try plist(file).count == 50)
    }

    @Test("The shared store uses the test home's settings file, not this Mac's preferences")
    func sharedUsesTestHome() throws {
        let home = try TestSupport.testHome()
        let key = "okitTestProbe-\(UUID().uuidString)"
        KitSettings.shared.set("yes", forKey: key)
        KitSettings.shared.flush()
        defer { KitSettings.shared.set(nil, forKey: key); KitSettings.shared.flush() }
        #expect(UserDefaults.standard.object(forKey: key) == nil)
        let file = home.appending(path: "Offline Kit Settings.plist")
        #expect(try plist(file)[key] as? String == "yes")
    }
}
