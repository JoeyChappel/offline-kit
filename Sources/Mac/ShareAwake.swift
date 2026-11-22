import Foundation

/// Keeps the Mac from going to sleep on its own while another device is using Share on Wi-Fi, so a movie or a book
/// on a phone doesn't stop partway. Only for the few minutes after a device's last request: an idle Mac with no one
/// using Share sleeps as usual, and so does one that merely has sharing turned on. The screen can still turn off.
/// (Playing a game on another device holds its own, stronger activity: see GameStreamHub.)
@MainActor
final class ShareAwake {
    static let shared = ShareAwake()
    /// How long after the last request from another device the Mac stays awake.
    static let window: TimeInterval = 5 * 60

    private var activity: NSObjectProtocol?
    private var lastUse = Date.distantPast
    private var watcher: Task<Void, Never>?

    var isHolding: Bool { activity != nil }

    /// A device made a request. Cheap enough to call on every one.
    func deviceUsed() {
        lastUse = Date()
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                         reason: "A device is using Share on Wi-Fi")
        watcher = Task { [weak self] in
            // Sleep until the window after the latest request has passed; a newer request pushes it back.
            while let self, !Task.isCancelled {
                let left = Self.window - Date().timeIntervalSince(self.lastUse)
                if left <= 0 { self.release(); return }
                try? await Task.sleep(for: .seconds(left + 1))
            }
        }
    }

    /// Lets the Mac sleep again (the window passed, or sharing stopped).
    func release() {
        watcher?.cancel()
        watcher = nil
        if let held = activity { ProcessInfo.processInfo.endActivity(held) }
        activity = nil
    }
}
