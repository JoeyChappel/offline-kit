import AppKit
import CryptoKit
import Security

/// The note publish-release.sh puts beside every release: which build is newest and where to get it.
struct UpdateManifest: Codable, Equatable, Sendable {
    let version: String
    let build: Int
    /// The zipped app (not the disk image): it unpacks without mounting anything.
    let url: URL
    let sha256: String
    let size: Int64
    let notes: String
    let minimumSystem: String?
}

/// Keeps Offline Kit current. About once a day, when the Mac is online, it asks the downloads page which build
/// is newest. Nothing changes until the person chooses Install: then it downloads the new app, checks it's
/// intact and signed by the same developer, quits, swaps it in and reopens. Library, settings and progress live
/// outside the app, so they carry over untouched.
@MainActor @Observable
final class AppUpdater {
    static let shared = AppUpdater()

    static let feed = URL(string: "https://github.com/JoeyChappel/offline-kit/releases/latest/download/latest.json")!
    /// For anyone the in-app update can't serve: always the newest disk image.
    static let downloadPage = URL(string: "https://github.com/JoeyChappel/offline-kit/releases/latest/download/OfflineKit.dmg")!
    nonisolated private static let teamID = "QF9W87MQ59"

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateManifest)
        case downloading(UpdateManifest, received: Int64)
        case verifying(UpdateManifest)
        case installing(UpdateManifest)
        /// What went wrong, in plain words; the manifest when there's an update to retry.
        case failed(String, UpdateManifest?)
    }

    private(set) var phase: Phase = .idle
    /// The update window (a sheet on the main window) is open.
    var showingSheet = false
    private(set) var lastChecked: Date?
    var checksAutomatically: Bool {
        didSet { UserDefaults.standard.set(checksAutomatically, forKey: Keys.automatic) }
    }

    private enum Keys {
        static let automatic = "updates.automatic"
        static let skipped = "updates.skippedBuild"
        static let lastChecked = "updates.lastChecked"
    }

    private var started = false
    private var work: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        checksAutomatically = defaults.object(forKey: Keys.automatic) as? Bool ?? true
        lastChecked = defaults.object(forKey: Keys.lastChecked) as? Date
    }

    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var currentBuild: Int { Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0 }

    /// The update the sidebar mentions: one on offer that wasn't skipped, or one on its way in.
    var pending: UpdateManifest? {
        switch phase {
        case .available(let manifest):
            return manifest.build == UserDefaults.standard.integer(forKey: Keys.skipped) ? nil : manifest
        case .downloading(let manifest, _), .verifying(let manifest), .installing(let manifest):
            return manifest
        case .failed(_, let manifest):
            return manifest
        default:
            return nil
        }
    }

    var isBusy: Bool {
        switch phase {
        case .checking, .downloading, .verifying, .installing: true
        default: false
        }
    }

    private var feedURL: URL {
        #if DEBUG
        if let custom = UserDefaults.standard.string(forKey: "updateFeed"), let url = URL(string: custom) { return url }
        #endif
        return Self.feed
    }

    // MARK: Checking

    /// Starts the once-a-day check. Debug builds only check when given a test feed (-updateFeed <url>).
    func startAutomaticChecks() {
        guard !started else { return }
        started = true
        var testing = false
        #if DEBUG
        guard UserDefaults.standard.string(forKey: "updateFeed") != nil else { return }
        testing = true
        #endif
        Task {
            // Let the library load first; an update is never urgent.
            try? await Task.sleep(for: .seconds(testing ? 2 : 30))
            while true {
                let due = lastChecked.map { -$0.timeIntervalSinceNow > 20 * 3600 } ?? true
                if checksAutomatically, due || testing, !isBusy, !showingSheet {
                    var asked = false
                    #if DEBUG
                    // Test hook: -updateCheckNow YES checks as if chosen from the menu (the update window opens).
                    asked = testing && UserDefaults.standard.bool(forKey: "updateCheckNow")
                    #endif
                    await check(userInitiated: asked)
                    testing = false
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    /// Asks which build is newest. A check the person asked for opens the update window to show the answer;
    /// an automatic one stays quiet unless there's something new, and says nothing when the Mac is offline.
    func check(userInitiated: Bool) async {
        if userInitiated { showingSheet = true }
        if isBusy { return }
        if userInitiated, case .available = phase {
            // Already found one: show it again, even if it was skipped.
            UserDefaults.standard.removeObject(forKey: Keys.skipped)
        }
        phase = .checking
        do {
            let manifest = try await Self.fetchManifest(feedURL)
            lastChecked = Date()
            UserDefaults.standard.set(lastChecked, forKey: Keys.lastChecked)
            if manifest.build <= Self.currentBuild {
                phase = .upToDate
            } else if let needed = manifest.minimumSystem, !Self.systemIsAtLeast(needed) {
                let message = "Offline Kit \(manifest.version) needs macOS \(needed) or later. This Mac has macOS \(ProcessInfo.processInfo.operatingSystemVersionString)."
                phase = userInitiated ? .failed(message, nil) : .idle
            } else {
                if userInitiated { UserDefaults.standard.removeObject(forKey: Keys.skipped) }
                phase = .available(manifest)
                #if DEBUG
                // Test hook: -updateAuto YES installs without waiting for a click.
                if UserDefaults.standard.bool(forKey: "updateAuto") { install() }
                #endif
            }
        } catch {
            phase = userInitiated ? .failed(Self.describe(error, checking: true), nil) : .idle
        }
    }

    /// "Later": the sidebar keeps a quiet reminder.
    func later() { showingSheet = false }

    /// "Skip This Version": no reminders until a newer one comes out (or the person checks by hand).
    func skip() {
        if case .available(let manifest) = phase {
            UserDefaults.standard.set(manifest.build, forKey: Keys.skipped)
        }
        showingSheet = false
    }

    // MARK: Installing

    func install() {
        let manifest: UpdateManifest
        switch phase {
        case .available(let found), .failed(_, .some(let found)): manifest = found
        default: return
        }
        showingSheet = true
        work = Task { await run(manifest) }
    }

    /// Stops a download. Once the swap has begun it can't be stopped.
    func cancel() {
        guard case .downloading(let manifest, _) = phase else { return }
        work?.cancel()
        phase = .available(manifest)
    }

    private func run(_ manifest: UpdateManifest) async {
        let target = Bundle.main.bundleURL
        do {
            try Self.checkCanReplace(target)
            phase = .downloading(manifest, received: 0)
            let zip = try await download(manifest)
            try Task.checkCancellation()
            phase = .verifying(manifest)
            let bundleID = Bundle.main.bundleIdentifier ?? ""
            let requirement = Self.requirement(bundleID: bundleID)
            let newApp = try await Task.detached(priority: .userInitiated) {
                try Self.prepare(zip: zip, manifest: manifest, target: target, bundleID: bundleID, requirement: requirement)
            }.value
            try Task.checkCancellation()
            phase = .installing(manifest)
            // Give the window a moment to say what's happening before it closes.
            try? await Task.sleep(for: .milliseconds(800))
            try await relaunch(into: newApp, replacing: target, manifest: manifest)
        } catch is CancellationError {
            if case .downloading = phase { phase = .available(manifest) }
        } catch {
            if (error as? URLError)?.code == .cancelled { phase = .available(manifest); return }
            NSLog("Update failed: %@", String(describing: error))
            phase = .failed(Self.describe(error, checking: false), manifest)
        }
    }

    private func download(_ manifest: UpdateManifest) async throws -> URL {
        let folder = KitLocation.caches.appending(path: "Updates", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)   // an earlier attempt's leftovers
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: "OfflineKit-\(manifest.build).zip")
        let transfer = UpdateDownload(destination: destination) { [weak self] received in
            Task { @MainActor in
                guard let self, case .downloading(let current, _) = self.phase, current == manifest else { return }
                self.phase = .downloading(manifest, received: received)
            }
        }
        return try await transfer.start(manifest.url)
    }

    /// Quits, and a small helper swaps in the new app once this copy has closed, then opens it.
    private func relaunch(into newApp: URL, replacing target: URL, manifest: UpdateManifest) async throws {
        let script = newApp.deletingLastPathComponent().appending(path: "install-update.sh")
        try Self.installScript.write(to: script, atomically: true, encoding: .utf8)

        var open = [String]()
        #if DEBUG
        // Keep a test run's stand-in home and launch options, so the reopened copy never touches the real kit.
        open.append("-n")
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("OFFLINEKIT_") {
            open += ["--env", "\(key)=\(value)"]
        }
        open.append(target.path)
        open += ["--args"] + ProcessInfo.processInfo.arguments.dropFirst()
        #else
        open.append(target.path)
        #endif

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/zsh")
        helper.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, target.path] + open
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        // macOS won't quit an app while a sheet is open on one of its windows (it answers "User canceled"),
        // so close this window and any other sheet first.
        showingSheet = false
        try? await Task.sleep(for: .milliseconds(500))
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        try helper.run()

        NSApp.terminate(nil)
        // Still running: something on screen stopped the quit. Nothing was replaced; it can be tried again.
        NSLog("Update: quit was refused")
        helper.terminate()
        showingSheet = true
        phase = .failed("Offline Kit didn’t quit, so the update wasn’t installed. Close any open windows or messages, then choose Install again.", manifest)
    }

    /// Waits up to a minute for the old copy to close, swaps the apps (putting the old one back if anything
    /// fails), then opens whichever copy is in place.
    private static let installScript = """
        #!/bin/zsh
        pid=$1 new=$2 target=$3
        shift 3
        for i in {1..600}; do kill -0 $pid 2>/dev/null || break; sleep 0.1; done
        kill -0 $pid 2>/dev/null && exit 1
        old="${new:h}/Previous Offline Kit.app"
        if mv "$target" "$old"; then
          if mv "$new" "$target"; then rm -rf "$old"; else mv "$old" "$target"; fi
        fi
        open "$@"
        rm -rf "${new:h}"
        """

    // MARK: Checks (off the main thread)

    nonisolated private static func fetchManifest(_ url: URL) async throws -> UpdateManifest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw UpdateError.server(http.statusCode) }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        #if !DEBUG
        guard manifest.url.scheme == "https" else { throw UpdateError.damaged }
        #endif
        return manifest
    }

    nonisolated private static func systemIsAtLeast(_ version: String) -> Bool {
        let parts = version.split(separator: ".").compactMap { Int($0) }
        guard let major = parts.first else { return true }
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: major, minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0))
    }

    /// The app can only replace itself where it may write: not inside the disk image or macOS's temporary copy,
    /// and not in an Applications folder this account can't change.
    nonisolated private static func checkCanReplace(_ target: URL) throws {
        let path = target.path
        let readOnly = (try? target.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
        if readOnly || path.contains("/AppTranslocation/") { throw UpdateError.temporaryCopy }
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: target.deletingLastPathComponent().path), fm.isWritableFile(atPath: path) else {
            throw UpdateError.notAllowed
        }
    }

    /// The new app must come from the same developer (Developer ID, team QF9W87MQ59) and be the same app.
    nonisolated private static func requirement(bundleID: String) -> String {
        #if DEBUG
        // Test hook: -updateAdHoc YES accepts an ad-hoc signed test build (debug builds aren't Developer ID signed).
        if UserDefaults.standard.bool(forKey: "updateAdHoc") { return "identifier \"\(bundleID)\"" }
        #endif
        // Developer ID only (the two certificate markers), so a same-team development build can't pass as an update.
        return "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\" "
            + "and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
    }

    /// Checks the download, unpacks it beside the app (same drive, so the swap is instant) and checks the new app.
    nonisolated private static func prepare(zip: URL, manifest: UpdateManifest, target: URL,
                                            bundleID: String, requirement: String) throws -> URL {
        defer { try? FileManager.default.removeItem(at: zip) }
        try checkHash(zip, manifest: manifest)

        let fm = FileManager.default
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        guard let newApp = try fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let info = NSDictionary(contentsOf: newApp.appending(path: "Contents/Info.plist")) else {
            throw UpdateError.damaged
        }
        guard info["CFBundleIdentifier"] as? String == bundleID,
              info["CFBundleVersion"] as? String == String(manifest.build) else {
            throw UpdateError.wrongApp
        }

        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(newApp as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess, let req else {
            throw UpdateError.unsigned
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var problem: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(code, flags, req, &problem) == errSecSuccess else {
            if let problem { NSLog("Update signature: %@", String(describing: problem.takeRetainedValue())) }
            throw UpdateError.unsigned
        }
        // Not downloaded by a browser, so there's no quarantine flag to clear, but a copy carried over from
        // somewhere else could have one: it would make macOS open the app from a temporary copy.
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])
        return newApp
    }

    nonisolated private static func checkHash(_ file: URL, manifest: UpdateManifest) throws {
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
        guard Int64(size) == manifest.size else { throw UpdateError.damaged }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        let digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == manifest.sha256.lowercased() else { throw UpdateError.damaged }
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.damaged }
    }

    enum UpdateError: Error {
        case server(Int), damaged, wrongApp, unsigned, temporaryCopy, notAllowed
    }

    nonisolated private static func describe(_ error: Error, checking: Bool) -> String {
        if let url = error as? URLError {
            switch url.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost,
                 .dnsLookupFailed, .timedOut, .internationalRoamingOff, .dataNotAllowed:
                return "This Mac isn’t online right now. Offline Kit works fine without updating; try again when it’s connected."
            default:
                break
            }
        }
        switch error as? UpdateError {
        case .server(let status):
            return status == 404
                ? "The downloads page doesn’t have update details yet. Try again later."
                : "The downloads page didn’t answer properly (error \(status)). Try again later."
        case .damaged:
            return "The download didn’t arrive intact, so nothing was changed. Try again."
        case .wrongApp, .unsigned:
            return "The download didn’t pass Offline Kit’s safety check (it isn’t signed by Offline Kit’s developer), so it wasn’t installed."
        case .temporaryCopy:
            return "Offline Kit is running from the disk image or a temporary copy, so it can’t update itself. Move it to Applications first, or download the new version and drag it there."
        case .notAllowed:
            return "This Mac account isn’t allowed to change Offline Kit where it is. Ask whoever installed it to update it, or download the new version."
        case nil:
            return checking ? "Couldn’t check for updates. Try again later." : "The update couldn’t be installed. Nothing was changed. Try again later."
        }
    }
}

/// One file download with progress, cancelled along with the task that awaits it.
private final class UpdateDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var cancelled = false
    private var saved: Result<URL, Error>?
    private var lastReport = Date.distantPast

    init(destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func start(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                lock.lock()
                defer { lock.unlock() }
                if cancelled { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.timeoutIntervalForRequest = 60
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                self.task = task
                task.resume()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard -lastReport.timeIntervalSinceNow > 0.1 else { return }
        lastReport = Date()
        progress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            saved = .failure(AppUpdater.UpdateError.server(http.statusCode))
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            saved = .success(destination)
        } catch {
            saved = .failure(error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        let result: Result<URL, Error> = error.map { .failure($0) } ?? saved ?? .failure(AppUpdater.UpdateError.damaged)
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
