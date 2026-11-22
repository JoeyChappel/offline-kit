import Foundation
import Observation

/// Runs one library scan at a time, so an older scan can never finish last and put back a stale list.
/// A request that arrives while a scan runs waits for one more scan that starts after it, so a file added
/// mid-scan is always picked up, and every caller sees fresh results when its `await` returns.
/// Requests that pile up during one scan share the next one.
@MainActor
final class ScanGate {
    private var running = false
    private var rerun = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    /// The newest request's scan; every request for one library scans the same way.
    private var latest: (@MainActor () async -> Void)?

    func run(_ scan: @escaping @MainActor () async -> Void) async {
        latest = scan
        if running {
            await withCheckedContinuation { waiting.append($0) }
            return
        }
        running = true
        await scan()
        while rerun || !waiting.isEmpty, let next = latest {
            // Everyone waiting now asked after the last scan started; this scan starts after all of them.
            let served = waiting
            waiting = []
            rerun = false
            await next()
            served.forEach { $0.resume() }
        }
        running = false
        latest = nil
    }

    /// Asks for one more pass after the running one, for something that changed mid-scan. Does nothing when idle.
    func runAgain() { if running { rerun = true } }

    var isRunning: Bool { running }
}

/// Bumped when files appear or change for lists that are read straight from disk (PDFs, answer models),
/// so the views showing them draw again.
@MainActor @Observable
final class KitChanges {
    static let shared = KitChanges()
    private(set) var documents = 0
    private(set) var models = 0

    func documentsChanged() { documents += 1 }
    func modelsChanged() { LocalModels.invalidateInstalledCache(); models += 1 }
}
