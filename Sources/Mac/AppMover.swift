import AppKit

/// Offers to move Offline Kit into Applications when it's opened straight from the disk image.
/// From there macOS runs it from a temporary read-only copy: it can't keep a kit beside itself,
/// and macOS refuses its alerts (power-out timers, supplies expiring).
@MainActor
enum AppMover {
    /// True when the app is running from somewhere it can't stay: a temporary copy macOS made
    /// ("App Translocation") or a read-only volume such as the mounted disk image.
    static var isRunningFromTemporaryPlace: Bool {
        let app = Bundle.main.bundleURL
        if app.path.contains("/AppTranslocation/") { return true }
        let readOnly = (try? app.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly
        return readOnly == true
    }

    static func offerMoveIfNeeded() {
        #if DEBUG
        guard !UserDefaults.standard.bool(forKey: "skipMoveCheck") else { return }
        #endif
        guard isRunningFromTemporaryPlace else { return }

        let target = destination()
        #if DEBUG
        // Test hook: -autoMove YES moves without asking (use with -moveDestination <scratch folder>).
        if UserDefaults.standard.bool(forKey: "autoMove") {
            do { try move(to: target); relaunch(at: target) } catch { NSLog("AppMover test: %@", error.localizedDescription) }
            return
        }
        #endif
        let alert = NSAlert()
        alert.messageText = "Move Offline Kit to your Applications folder?"
        alert.informativeText = """
            Offline Kit is running from the disk image. Move it to Applications so it can keep your \
            library and settings, and so its alerts work. The disk image can be ejected afterwards.
            """
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try move(to: target)
            relaunch(at: target)
        } catch {
            let failed = NSAlert()
            failed.alertStyle = .warning
            failed.messageText = "Couldn’t move Offline Kit"
            failed.informativeText = "\(error.localizedDescription)\n\nYou can drag Offline Kit from the disk image into the Applications folder instead."
            failed.runModal()
        }
    }

    /// /Applications when it's writable (an admin account), else ~/Applications.
    private static func destination() -> URL {
        #if DEBUG
        if let folder = UserDefaults.standard.string(forKey: "moveDestination") {
            return URL(fileURLWithPath: folder, isDirectory: true).appending(path: Bundle.main.bundleURL.lastPathComponent)
        }
        #endif
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let folder = FileManager.default.isWritableFile(atPath: system.path)
            ? system
            : FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory)
        return folder.appending(path: Bundle.main.bundleURL.lastPathComponent)
    }

    private static func move(to target: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) {
            // An older copy is already there. It can't be replaced while it's open.
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
                .contains { $0.bundleURL?.standardizedFileURL == target.standardizedFileURL }
            if running {
                throw MoveError.olderCopyOpen
            }
            // The Trash, not a permanent delete, so the old copy can be recovered.
            try fm.trashItem(at: target, resultingItemURL: nil)
        }
        try fm.copyItem(at: Bundle.main.bundleURL, to: target)
        // The copy keeps the download's quarantine flag, which would make macOS run it from a temporary
        // copy again. The app is notarized, so clearing the flag on our own copy is safe.
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", target.path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    private static func relaunch(at target: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        #if DEBUG
        // Keep a test run's stand-in home so the relaunched copy never touches the real kit.
        config.environment = ProcessInfo.processInfo.environment.filter { $0.key.hasPrefix("OFFLINEKIT_") }
        config.arguments = ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        NSWorkspace.shared.openApplication(at: target, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    enum MoveError: LocalizedError {
        case olderCopyOpen
        var errorDescription: String? {
            "An older Offline Kit in Applications is open. Quit it, then try again."
        }
    }
}
