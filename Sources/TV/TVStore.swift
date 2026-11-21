import Foundation
import Network
import Observation

/// A Mac running Offline Kit with Share on Wi-Fi turned on.
struct TVServer: Identifiable, Hashable {
    let name: String
    let baseURL: URL
    var id: String { baseURL.absoluteString }
}

struct TVTrack: Decodable, Hashable {
    let title: String
    let url: String
    var duration: Double? = nil
}

struct TVProgress: Codable, Hashable {
    var track: Int
    var seconds: Double
    var finished: Bool
}

/// Something to watch or listen to, served by the Mac's Watch & Listen library.
struct TVItem: Decodable, Identifiable, Hashable {
    enum Kind: String, Decodable { case video, audio }
    let id: String
    let kind: Kind
    let title: String
    let tracks: [TVTrack]
    let cover: String?
    var progress: TVProgress?
    // Sent by newer Macs (the Netflix-style catalog); older ones leave these out.
    var thumb: String? = nil
    var meta: String? = nil
    var duration: Double? = nil
    var category: String? = nil
    var genre: String? = nil
    var artist: String? = nil
    var year: Int? = nil
    // Organize with AI details, when the Mac has them.
    var summary: String? = nil
    var studio: String? = nil
    var series: String? = nil
    var ageRating: String? = nil
    var aiGuess: [String]? = nil

    /// How far through, 0…1, when known.
    var fraction: Double? {
        guard let p = progress, isInProgress else { return nil }
        let durations = tracks.map { $0.duration ?? 0 }
        if durations.allSatisfy({ $0 > 0 }) { return min(1, (durations.prefix(max(0, p.track)).reduce(0, +) + p.seconds) / durations.reduce(0, +)) }
        if tracks.count > 1 { return Double(p.track) / Double(tracks.count) }
        guard let d = duration, d > 0 else { return nil }
        return min(1, p.seconds / d)
    }

    /// Started but not finished: worth a "Continue" row.
    var isInProgress: Bool {
        guard let p = progress, !p.finished else { return false }
        return p.seconds > 5 || p.track > 0
    }
}

struct TVShelf: Decodable, Hashable, Identifiable {
    let title: String
    let items: [String]
    var id: String { title }
}

struct TVSong: Decodable, Identifiable {
    let item: String
    let index: Int
    var id: String { "\(item)#\(index)" }
}
struct TVArtist: Decodable, Identifiable {
    let name: String
    let items: [String]
    var id: String { name }
}
private struct MediaResponse: Decodable {
    let name: String
    let items: [TVItem]
    var shelves: [TVShelf]? = nil
    var featured: String? = nil
    var genres: [String]? = nil
    var results: [String]? = nil
    var artists: [TVArtist]? = nil
    var songs: [TVSong]? = nil
}

/// Finds Offline Kit on the home network, signs in with the PIN if one is set, and loads Watch & Listen.
@MainActor @Observable
final class TVStore {
    enum Phase: Equatable { case searching, needsPIN, loading, ready, failed(String) }

    private(set) var phase: Phase = .searching
    private(set) var servers: [TVServer] = []
    private(set) var server: TVServer?
    private(set) var items: [TVItem] = []
    /// Rows and the banner item, as the Mac lays them out. Empty from older Macs.
    private(set) var shelves: [TVShelf] = []
    private(set) var featuredID: String?
    var filter = "all"
    var genre = ""
    var sort = "title"
    var query = ""
    private(set) var genres: [String] = []
    private(set) var results: [String] = []
    private(set) var artists: [TVArtist] = []
    private(set) var songs: [TVSong] = []
    var pinError: String?

    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var resolving: [String: NWConnection] = [:]
    @ObservationIgnored private let session = URLSession.shared

    private static let savedServerKey = "server"
    private static let savedNameKey = "serverName"

    // MARK: Connecting

    /// Tries the last Mac first, then searches the network.
    func start() async {
        #if DEBUG
        // Test hook: -serverAddress 127.0.0.1:8082 connects straight to a test server (the simulator shares the Mac's network).
        if let address = UserDefaults.standard.string(forKey: "serverAddress") { await connect(address: address); return }
        #endif
        if let saved = UserDefaults.standard.string(forKey: Self.savedServerKey), let url = URL(string: saved) {
            let name = UserDefaults.standard.string(forKey: Self.savedNameKey) ?? "Mac"
            if await connect(TVServer(name: name, baseURL: url), quietly: true) { return }
        }
        browse()
    }

    func browse() {
        phase = .searching
        server = nil
        browser?.cancel()
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_http._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.handle(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func handle(_ results: Set<NWBrowser.Result>) {
        for result in results {
            guard case .bonjour(let txt) = result.metadata, txt["app"] == "offlinekit" else { continue }
            let key = "\(result.endpoint)"
            guard resolving[key] == nil else { continue }
            let name = txt["name"] ?? "Mac"
            // Resolve to an IPv4 address and port.
            let params = NWParameters.tcp
            if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
            let connection = NWConnection(to: result.endpoint, using: params)
            connection.stateUpdateHandler = { [weak self] state in
                guard case .ready = state else { return }
                if case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint {
                    var address = "\(host)"
                    if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
                    if let url = URL(string: "http://\(address):\(port.rawValue)") {
                        Task { @MainActor in self?.found(TVServer(name: name, baseURL: url)) }
                    }
                }
                connection.cancel()
            }
            connection.start(queue: .main)
            resolving[key] = connection
        }
    }

    private func found(_ server: TVServer) {
        guard !servers.contains(server) else { return }
        servers.append(server)
        servers.sort { $0.name < $1.name }
        #if DEBUG
        // Test hook: -autoConnect YES picks the first Mac found (no remote needed in the simulator).
        if UserDefaults.standard.bool(forKey: "autoConnect"), phase == .searching { Task { await connect(server) } }
        #endif
    }

    /// Typed by hand: "192.168.1.20:8080", "your-mac.local:8080" or a full http:// address.
    func connect(address: String) async {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.lowercased().hasPrefix("http") { text = "http://" + text }
        guard let url = URL(string: text), url.host != nil else {
            phase = .failed("That doesn’t look like an address. Try something like 192.168.1.20:8080.")
            return
        }
        await connect(TVServer(name: url.host ?? "Mac", baseURL: url), quietly: false)
    }

    @discardableResult
    func connect(_ server: TVServer, quietly: Bool = false) async -> Bool {
        self.server = server
        phase = .loading
        do {
            try await load()
            browser?.cancel()
            UserDefaults.standard.set(server.baseURL.absoluteString, forKey: Self.savedServerKey)
            UserDefaults.standard.set(server.name, forKey: Self.savedNameKey)
            return true
        } catch TVError.needsPIN {
            phase = .needsPIN
            return true
        } catch {
            if quietly { self.server = nil; return false }
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
        let status = (try? await session.data(for: request)).flatMap { ($0.1 as? HTTPURLResponse)?.statusCode }
        if status == 200 {
            pinError = nil
            await connect(server)
        } else {
            pinError = "That PIN didn’t work. It’s on the Mac in Offline Kit › Share on Wi-Fi."
        }
    }

    func forgetServer() {
        UserDefaults.standard.removeObject(forKey: Self.savedServerKey)
        servers = []
        resolving.values.forEach { $0.cancel() }
        resolving = [:]
        items = []
        browse()
    }

    // MARK: Library

    enum TVError: Error { case needsPIN, server }

    func load() async throws {
        guard let server else { return }
        var components = URLComponents(url: server.baseURL.appending(path: "api/media"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "filter", value: filter), URLQueryItem(name: "genre", value: genre), URLQueryItem(name: "sort", value: sort), URLQueryItem(name: "q", value: query)]
        let (data, response) = try await session.data(from: components.url!)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw TVError.needsPIN }
        guard status == 200 else { throw TVError.server }
        let decoded = try JSONDecoder().decode(MediaResponse.self, from: data)
        items = decoded.items
        shelves = decoded.shelves ?? []
        featuredID = decoded.featured
        genres = decoded.genres ?? []
        results = decoded.results ?? decoded.items.map(\.id)
        artists = decoded.artists ?? []
        songs = decoded.songs ?? decoded.items.filter { $0.category == "music" }.flatMap { item in item.tracks.indices.map { TVSong(item: item.id, index: $0) } }
        self.server = TVServer(name: decoded.name, baseURL: server.baseURL)
        phase = .ready
    }

    func refresh() async {
        do { try await load() } catch TVError.needsPIN { phase = .needsPIN } catch {}
    }

    func url(_ path: String) -> URL? {
        guard let server else { return nil }
        return URL(string: path, relativeTo: server.baseURL)?.absoluteURL
    }

    /// Cookies from signing in, for AVPlayer (which doesn't share URLSession's cookie store).
    func cookies(for url: URL) -> [HTTPCookie] {
        HTTPCookieStorage.shared.cookies(for: url) ?? []
    }

    /// Saves the place on the Mac, so the Mac, iPhone and Apple TV all pick up in the same spot.
    func saveProgress(_ progress: TVProgress, for item: TVItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].progress = progress }
        guard let url = url("/api/media/progress") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["id": item.id, "track": progress.track, "seconds": progress.seconds, "finished": progress.finished]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task { _ = try? await session.data(for: request) }
    }
}
