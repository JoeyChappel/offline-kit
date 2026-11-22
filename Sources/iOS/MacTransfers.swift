import Foundation
import Network
import Observation
import UIKit

/// "From your Mac": finds Offline Kit on the home network, lists what the Mac picked with Send to iPhone, and
/// downloads it with a background URLSession, so downloads carry on while the phone is locked or in another app.
/// Files land in the phone's own library (Documents/Media, Games, Documents, or a reference archive at the top),
/// where Watch, Books, Play and Library find them like anything else on the phone.
@MainActor @Observable
final class MacTransfers {
    static let shared = MacTransfers()
    nonisolated static let sessionID = "com.joeychappel.offlinekit.from-mac"

    // MARK: Finding the Mac

    struct Server: Identifiable, Hashable {
        let name: String
        let baseURL: URL
        var id: String { baseURL.absoluteString }
    }

    enum Phase: Equatable { case idle, searching, needsPIN, loading, ready, failed(String) }

    private(set) var phase: Phase = .idle
    private(set) var servers: [Server] = []
    private(set) var server: Server?
    private(set) var items: [SendManifest.Item] = []
    var pinError: String?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolving: [String: NWConnection] = [:]
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// Session tokens the Macs handed out at sign-in, one per Mac address (a Mac never accepts the PIN itself).
    private var tokens: [String: String] { defaults.dictionary(forKey: "fromMacTokens") as? [String: String] ?? [:] }
    private static func address(_ url: URL) -> String { "\(url.host()?.lowercased() ?? ""):\(url.port ?? 80)" }

    /// Tries the last Mac first, then searches the network.
    func start() async {
        guard phase == .idle || phase == .searching || isFailed else { return }
        #if DEBUG
        // Test hook: -fromMacAddress 127.0.0.1:8085 connects straight to a test server (the simulator shares the Mac's network).
        if let address = defaults.string(forKey: "fromMacAddress") { await connect(address: address); return }
        #endif
        if let saved = defaults.string(forKey: "fromMacServer"), let url = URL(string: saved) {
            if await connect(Server(name: defaults.string(forKey: "fromMacName") ?? "Mac", baseURL: url), quietly: true) { return }
        }
        browse()
    }

    private var isFailed: Bool { if case .failed = phase { true } else { false } }

    func browse() {
        phase = .searching
        server = nil
        items = []
        browser?.cancel()
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_http._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Same discovery as the Apple TV app: Bonjour "_http._tcp" with Offline Kit's TXT record, resolved to an IPv4 address.
    private func handle(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .bonjour(let txt) = result.metadata, txt["app"] == "offlinekit" else { continue }
            let key = "\(result.endpoint)"
            guard resolving[key] == nil else { continue }
            let name = txt["name"] ?? "Mac"
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let connection = NWConnection(to: result.endpoint, using: params)
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                    var address = "\(host)"
                    if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
                    if let url = URL(string: "http://\(address):\(port.rawValue)") {
                        Task { @MainActor in self?.found(Server(name: name, baseURL: url)) }
                    }
                }
                connection.cancel()
            }
            connection.start(queue: .main)
            resolving[key] = connection
        }
    }

    private func found(_ server: Server) {
        guard !servers.contains(server) else { return }
        servers.append(server)
        servers.sort { $0.name < $1.name }
    }

    /// Typed by hand: "192.168.1.20:8080", "your-mac.local:8080" or a full http:// address.
    func connect(address: String) async {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") { text = "http://" + text }
        guard let url = URL(string: text), let host = url.host, !host.isEmpty else {
            phase = .failed("That doesn’t look like an address. Try something like 192.168.1.20:8080.")
            return
        }
        // Home network only: never send anything to an internet address.
        guard Self.isHomeNetwork(host) else {
            phase = .failed("That address isn’t on your home network. Use the address shown on the Mac in Offline Kit › Share on Wi-Fi.")
            return
        }
        await connect(Server(name: host, baseURL: url), quietly: false)
    }

    @discardableResult
    func connect(_ server: Server, quietly: Bool = false) async -> Bool {
        self.server = server
        phase = .loading
        do {
            try await load()
            browser?.cancel()
            defaults.set(server.baseURL.absoluteString, forKey: "fromMacServer")
            defaults.set(self.server?.name ?? server.name, forKey: "fromMacName")
            return true
        } catch LoadError.needsPIN {
            phase = .needsPIN
            return true
        } catch LoadError.refused(let message, let waiting) {
            refused(message, waiting: waiting, server: server)
            return true
        } catch {
            if quietly { self.server = nil; phase = .idle; return false }
            phase = .failed("Couldn’t reach Offline Kit on \(server.name). Check that the Mac is awake, the app is open and Share on Wi-Fi is on.")
            return false
        }
    }

    func signIn(pin: String) async {
        guard let server else { return }
        var request = URLRequest(url: server.baseURL.appending(path: "api/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["pin": pin])
        let reply = try? await URLSession.shared.data(for: request)
        let status = (reply?.1 as? HTTPURLResponse)?.statusCode
        if status == 200 {
            pinError = nil
            let token = reply.flatMap { try? JSONSerialization.jsonObject(with: $0.0) as? [String: Any] }?["token"] as? String
            var saved = tokens
            saved[Self.address(server.baseURL)] = token
            defaults.set(saved, forKey: "fromMacTokens")
            await connect(server)
        } else if status == 403, let refusal = reply.flatMap({ Self.refusal($0.0) }) {
            pinError = refusal.message
        } else if status == 429 {
            pinError = "Too many wrong tries. Wait a few minutes, then try again."
        } else {
            pinError = "That PIN didn’t work. It’s on the Mac in Offline Kit › Share on Wi-Fi."
        }
    }

    func forgetMac() {
        defaults.removeObject(forKey: "fromMacServer")
        defaults.removeObject(forKey: "fromMacName")
        servers = []
        browse()
    }

    enum LoadError: Error { case needsPIN, server, refused(String, waiting: Bool) }

    /// The Mac's Connected Devices refusal: {"error": "waiting" | "blocked", "message": "..."} with status 403.
    nonisolated static func refusal(_ data: Data) -> (message: String, waiting: Bool)? {
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let kind = body["error"] as? String, kind == "waiting" || kind == "blocked" else { return nil }
        let fallback = kind == "waiting" ? "Waiting for the Mac to allow this device…" : "This device has been blocked on the Mac."
        return ((body["message"] as? String).map { String($0.prefix(200)) } ?? fallback, kind == "waiting")
    }

    /// Shows why the Mac refused, and while it's waiting for someone at the Mac to click Allow, checks again every few seconds.
    private func refused(_ message: String, waiting: Bool, server: Server) {
        phase = .failed(message)
        guard waiting else { return }
        // Checks quietly (no loading screen in between) until the Mac answers differently.
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(4))
                guard let self, self.phase == .failed(message), self.server?.baseURL == server.baseURL else { return }
                do { try await self.load(); return }
                catch LoadError.refused(let now, true) where now == message { continue }
                catch { await self.connect(server); return }
            }
        }
    }

    func load() async throws {
        guard let server else { return }
        let (data, response) = try await URLSession.shared.data(for: request(server.baseURL.appending(path: "api/send")))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw LoadError.needsPIN }
        if status == 403, let refusal = Self.refusal(data) { throw LoadError.refused(refusal.message, waiting: refusal.waiting) }
        guard status == 200 else { throw LoadError.server }
        let manifest = try JSONDecoder().decode(SendManifest.self, from: data)
        items = manifest.items.filter { $0.files.allSatisfy { SendManifest.isSafe($0.path) } }
        self.server = Server(name: manifest.name, baseURL: server.baseURL)
        phase = .ready
        // Things already here count as done on the Mac too.
        for item in items where isOnPhone(item) && !item.receivedBy.contains(Self.deviceName) { report(item.id) }
        // The Mac is back: carry on with downloads that stopped when it went away.
        for (id, job) in jobs where job.isFailed && items.contains(where: { $0.id == id }) { resume(id) }
    }

    func refresh() async {
        do { try await load() } catch LoadError.needsPIN { phase = .needsPIN } catch LoadError.refused(let message, let waiting) {
            if let server { refused(message, waiting: waiting, server: server) }
        } catch {
            // Keep the list on screen while downloads are under way; their rows say what stopped.
            if server != nil, items.isEmpty { phase = .failed("Lost the connection to the Mac. Check that it’s awake and on the same Wi-Fi.") }
        }
    }

    /// A request to the Mac, with the sign-in cookie when there is one (background sessions don't share cookies reliably).
    private func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // Only to the Mac that issued it, never to another address a list of files might name.
        if let server, Self.address(url) == Self.address(server.baseURL), let token = tokens[Self.address(url)], !token.isEmpty {
            request.setValue("okpin=\(token)", forHTTPHeaderField: "Cookie")
        }
        return request
    }

    nonisolated static func isHomeNetwork(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".local") { return true }
        if h == "::1" || h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") || h.hasPrefix("169.254.") { return true }
        if h.hasPrefix("fe80:") || h.hasPrefix("fd") || h.hasPrefix("fc") { return true }
        if h.hasPrefix("172."), let second = Int(h.split(separator: ".")[1]), (16...31).contains(second) { return true }
        return false
    }

    static var deviceName: String { UIDevice.current.name }

    /// Tells the Mac this phone has the item, so its Send to iPhone list shows it as done.
    func report(_ id: String) {
        guard let server else { return }
        var request = request(server.baseURL.appending(path: "api/send/received"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["item": id, "device": Self.deviceName])
        Task {
            _ = try? await URLSession.shared.data(for: request)
            if let index = items.firstIndex(where: { $0.id == id }), !items[index].receivedBy.contains(Self.deviceName) {
                items[index].receivedBy.append(Self.deviceName)
            }
        }
    }

    // MARK: What's on the phone

    nonisolated static var libraryRoot: URL { URL.documentsDirectory }

    nonisolated static func destination(_ path: String) -> URL? {
        guard SendManifest.isSafe(path) else { return nil }
        return libraryRoot.appending(path: path, directoryHint: .notDirectory)
    }

    nonisolated static func isPresent(_ file: SendManifest.File) -> Bool {
        guard let url = destination(file.path),
              let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return false }
        return Int64(size) == file.size
    }

    func isOnPhone(_ item: SendManifest.Item) -> Bool { item.files.allSatisfy(Self.isPresent) }

    /// Bytes still to download for these items (files already here don't count).
    func needed(_ items: [SendManifest.Item]) -> Int64 {
        items.flatMap(\.files).filter { !Self.isPresent($0) }.reduce(0) { $0 + $1.size }
    }

    var freeSpace: Int64 {
        #if DEBUG
        if let gb = ProcessInfo.processInfo.environment["OFFLINEKIT_FAKE_FREE_GB"].flatMap(Double.init) { return Int64(gb * 1e9) }
        #endif
        let values = try? Self.libraryRoot.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return max(values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeAvailableCapacity ?? 0))
    }

    // MARK: Downloads

    enum FileState: String, Codable { case queued, running, paused, failed, done }

    struct FileJob: Codable, Hashable {
        var path: String
        var size: Int64
        var modified: Double
        /// Path on the Mac ("/api/send/file/…"), resolved against the Mac's current address when a download starts.
        var url: String
        var state: FileState = .queued
        var written: Int64 = 0
    }

    /// One item being downloaded from the Mac.
    struct Job: Codable, Identifiable, Hashable {
        var id: String
        var title: String
        var kind: SendKind
        var files: [FileJob]
        var error: String?
        /// The Mac's address when these downloads started. Its port can change when the Mac restarts.
        var base: String?

        var size: Int64 { files.reduce(0) { $0 + $1.size } }
        var written: Int64 { files.reduce(0) { $0 + ($1.state == .done ? $1.size : min($1.written, $1.size)) } }
        var fraction: Double { size > 0 ? Double(written) / Double(size) : 0 }
        var isDone: Bool { files.allSatisfy { $0.state == .done } }
        var isRunning: Bool { files.contains { $0.state == .running || $0.state == .queued } }
        var isPaused: Bool { !isRunning && files.contains { $0.state == .paused } }
        var isFailed: Bool { !isRunning && files.contains { $0.state == .failed } }
    }

    private(set) var jobs: [String: Job] = [:]
    /// Called after an item finishes, so the libraries rescan and it shows in Watch, Books, Play or Library.
    @ObservationIgnored var onItemFinished: (() -> Void)?
    @ObservationIgnored private var backgroundCompletion: (() -> Void)?

    @ObservationIgnored private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.allowsCellularAccess = false   // the Mac is on home Wi-Fi
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: TransferDelegate(), delegateQueue: nil)
    }()

    var activeCount: Int { jobs.values.filter(\.isRunning).count }

    init() {
        if let data = try? Data(contentsOf: Self.stateFile), let saved = try? JSONDecoder().decode([String: Job].self, from: data) {
            jobs = saved
        }
    }

    /// Reconnects to downloads the system kept going while the app was closed.
    func restore() {
        // Nothing saved means nothing to reconnect to; the background session (about 70 ms to create) waits until a
        // transfer starts or the system relaunches the app for one.
        guard !jobs.isEmpty else { return }
        _ = session
        #if DEBUG
        // Test hook: -fromMacOpen YES goes to Get, where the From your Mac card opens itself.
        if defaults.bool(forKey: "fromMacOpen") {
            Task { try? await Task.sleep(for: .seconds(1)); NotificationCenter.default.post(name: .openGetResources, object: nil) }
        }
        #endif
        session.getAllTasks { tasks in
            let live = Set(tasks.compactMap { $0.state == .running ? $0.taskDescription : nil })
            Task { @MainActor in
                // A file marked running with no task behind it (the app was quit from the switcher): resume it.
                for (id, job) in self.jobs {
                    for file in job.files where file.state == .running && !live.contains(Self.describe(id, file.path)) {
                        self.setState(id, file.path, .queued)
                    }
                }
                for (id, job) in self.jobs where job.files.contains(where: { $0.state == .queued }) { self.startQueued(id) }
            }
        }
    }

    /// Called by the system when it relaunches the app to finish background downloads.
    func handleBackgroundEvents() async {
        _ = session
        // The events may already have been delivered (the session was recreated at launch).
        if eventsDelivered { eventsDelivered = false; return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in backgroundCompletion = { done.resume() } }
    }

    fileprivate func backgroundEventsFinished() {
        guard let completion = backgroundCompletion else { eventsDelivered = true; return }
        backgroundCompletion = nil
        completion()
    }
    @ObservationIgnored private var eventsDelivered = false

    /// Starts downloading. Returns a message instead when the phone doesn't have room.
    func download(_ items: [SendManifest.Item]) -> String? {
        let wanted = items.filter { !isOnPhone($0) && jobs[$0.id] == nil }
        let needed = needed(wanted)
        let free = freeSpace
        if needed > free {
            return "These need \(Self.bytes(needed)), but this iPhone has \(Self.bytes(free)) free. Pick fewer, or free up space in Settings › General › iPhone Storage."
        }
        for item in items where isOnPhone(item) && !item.receivedBy.contains(Self.deviceName) { report(item.id) }
        guard let server else { return nil }
        for item in wanted {
            let files = item.files.map { file in
                var job = FileJob(path: file.path, size: file.size, modified: file.modified, url: file.url)
                if Self.isPresent(file) { job.state = .done }
                return job
            }
            jobs[item.id] = Job(id: item.id, title: item.title, kind: item.kind, files: files, base: server.baseURL.absoluteString)
            startQueued(item.id)
        }
        save()
        return nil
    }

    private func startQueued(_ id: String) {
        guard var job = jobs[id], let base = server?.baseURL ?? job.base.flatMap(URL.init(string:)) else { return }
        job.error = nil
        // The Mac came back at a different address: partial downloads point at the old one, so those files start over.
        if let old = job.base, old != base.absoluteString {
            for file in job.files { try? FileManager.default.removeItem(at: Self.resumeFile(file.path)) }
        }
        job.base = base.absoluteString
        for index in job.files.indices where job.files[index].state == .queued {
            let file = job.files[index]
            guard let url = URL(string: file.url, relativeTo: base)?.absoluteURL, Self.address(url) == Self.address(base),
                  url.scheme == base.scheme else { job.files[index].state = .failed; continue }
            let task: URLSessionDownloadTask
            if let resume = try? Data(contentsOf: Self.resumeFile(file.path)) {
                task = session.downloadTask(withResumeData: resume)
                try? FileManager.default.removeItem(at: Self.resumeFile(file.path))
            } else {
                task = session.downloadTask(with: request(url))
            }
            task.taskDescription = Self.describe(id, file.path)
            task.countOfBytesClientExpectsToReceive = file.size
            task.resume()
            job.files[index].state = .running
        }
        jobs[id] = job
        save()
    }

    func pause(_ id: String) {
        session.getAllTasks { tasks in
            let mine = tasks.filter { $0.taskDescription.map { Self.parse($0)?.id == id } ?? false }
            Task { @MainActor in
                guard var job = self.jobs[id] else { return }
                for index in job.files.indices where job.files[index].state == .running || job.files[index].state == .queued {
                    job.files[index].state = .paused
                }
                self.jobs[id] = job
                self.save()
                for case let task as URLSessionDownloadTask in mine {
                    guard let path = task.taskDescription.flatMap(Self.parse)?.path else { continue }
                    task.cancel(byProducingResumeData: { data in
                        if let data { try? data.write(to: Self.resumeFile(path), options: .atomic) }
                    })
                }
            }
        }
    }

    /// Resume after a pause, or try again after a failure. Partly downloaded files carry on where they stopped.
    func resume(_ id: String) {
        guard var job = jobs[id] else { return }
        for index in job.files.indices where job.files[index].state == .paused || job.files[index].state == .failed {
            job.files[index].state = .queued
        }
        jobs[id] = job
        startQueued(id)
    }

    func cancel(_ id: String) {
        session.getAllTasks { tasks in
            tasks.filter { $0.taskDescription.map { Self.parse($0)?.id == id } ?? false }.forEach { $0.cancel() }
        }
        for file in jobs[id]?.files ?? [] { try? FileManager.default.removeItem(at: Self.resumeFile(file.path)) }
        jobs[id] = nil
        save()
    }

    // MARK: Delegate callbacks (main actor)

    fileprivate func progress(_ description: String, written: Int64) {
        guard let (id, path) = Self.parse(description), var job = jobs[id],
              let index = job.files.firstIndex(where: { $0.path == path }) else { return }
        job.files[index].written = written
        if job.files[index].state == .queued { job.files[index].state = .running }
        jobs[id] = job   // not saved on every tick; saved on state changes
    }

    fileprivate func finished(_ description: String) {
        guard let (id, path) = Self.parse(description) else { return }
        try? FileManager.default.removeItem(at: Self.resumeFile(path))
        setState(id, path, .done)
        guard let job = jobs[id], job.isDone else { return }
        jobs[id] = nil
        save()
        report(id)
        onItemFinished?()
    }

    fileprivate func failed(_ description: String, message: String, resumeData: Data?) {
        guard let (id, path) = Self.parse(description), let job = jobs[id],
              let file = job.files.first(where: { $0.path == path }) else { return }
        if let resumeData { try? resumeData.write(to: Self.resumeFile(path), options: .atomic) }
        if file.state == .paused || file.state == .done { return }   // cancelled for a pause, or already in place
        setState(id, path, .failed)
        jobs[id]?.error = message
        save()
    }

    private func setState(_ id: String, _ path: String, _ state: FileState) {
        guard var job = jobs[id], let index = job.files.firstIndex(where: { $0.path == path }) else { return }
        job.files[index].state = state
        if state == .done { job.files[index].written = job.files[index].size }
        jobs[id] = job
        save()
    }

    // MARK: Storage

    /// Kept in Application Support, not Documents, so the Files app and the library scan never see it.
    nonisolated static var stateFolder: URL {
        let folder = URL.applicationSupportDirectory.appending(path: "FromMac", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder.appending(path: "Resume"), withIntermediateDirectories: true)
        return folder
    }
    nonisolated static var stateFile: URL { stateFolder.appending(path: "jobs.json") }
    nonisolated static func resumeFile(_ path: String) -> URL {
        let safe = Data(path.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return stateFolder.appending(path: "Resume/\(safe.suffix(200)).resume")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(jobs) { try? data.write(to: Self.stateFile, options: .atomic) }
    }

    nonisolated static func describe(_ id: String, _ path: String) -> String { id + "\n" + path }
    nonisolated static func parse(_ description: String) -> (id: String, path: String)? {
        let parts = description.split(separator: "\n", maxSplits: 1).map(String.init)
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }

    nonisolated static func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

/// URLSession delegate. Runs on the session's queue: the downloaded file has to be moved before this returns.
private final class TransferDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let description = downloadTask.taskDescription else { return }
        // With a resumed download, totalBytesWritten counts from where it picked up.
        Task { @MainActor in MacTransfers.shared.progress(description, written: totalBytesWritten) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let description = downloadTask.taskDescription, let (_, path) = MacTransfers.parse(description) else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 206 else {
            let message = status == 401 ? "The Mac asked for its PIN. Open From your Mac and enter it." : "The Mac couldn’t send this file (error \(status))."
            Task { @MainActor in MacTransfers.shared.failed(description, message: message, resumeData: nil) }
            return
        }
        guard let destination = MacTransfers.destination(path) else { return }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.moveItem(at: location, to: destination)
            // Keep the Mac's date: the library skips a reference archive changed in the last two minutes as still downloading.
            let modified = MacTransfers.modifiedDate(description: description)
            if let modified { try? fm.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path) }
            Task { @MainActor in MacTransfers.shared.finished(description) }
        } catch {
            let message = "Couldn’t save it on this iPhone: \(error.localizedDescription)"
            Task { @MainActor in MacTransfers.shared.failed(description, message: message, resumeData: nil) }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let description = task.taskDescription else { return }
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let message = (error as? URLError)?.code == .cancelled ? "Stopped." :
            "Lost the connection to the Mac. Tap Retry when it’s awake and on the same Wi-Fi."
        Task { @MainActor in MacTransfers.shared.failed(description, message: message, resumeData: resumeData) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in MacTransfers.shared.backgroundEventsFinished() }
    }
}

extension MacTransfers {
    /// The Mac's modification date for a file being downloaded, read from the saved job list (safe off the main actor).
    nonisolated static func modifiedDate(description: String) -> Date? {
        guard let (id, path) = parse(description), let data = try? Data(contentsOf: stateFile),
              let jobs = try? JSONDecoder().decode([String: Job].self, from: data),
              let file = jobs[id]?.files.first(where: { $0.path == path }), file.modified > 0 else { return nil }
        return Date(timeIntervalSince1970: file.modified)
    }
}
