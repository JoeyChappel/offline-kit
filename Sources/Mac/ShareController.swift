import SwiftUI
import Network
import SystemConfiguration
import CoreImage
import CoreImage.CIFilterBuiltins
import CryptoKit

/// "Share on Wi-Fi": serves the library and Ask to phones, tablets and PCs on the home network.
/// Read-only. Optional PIN. Only private (home network) addresses can connect.
@MainActor @Observable
final class ShareController {
    private(set) var isRunning = false
    private(set) var port: UInt16 = 0
    private(set) var error: String?
    private(set) var recentDevices: [String: Date] = [:]
    private(set) var questionsAnswered = 0

    var enabled: Bool {
        didSet {
            KitSettings.shared.set(enabled, forKey: "shareOnWiFi")
            if enabled {
                // Turned on here, on this network: this is the network to share on.
                KitSettings.shared.set(Self.currentNetworks().sorted(), forKey: Self.networksKey)
                pausedOnOtherNetwork = false
                start()
            } else {
                pausedOnOtherNetwork = false
                if error == Self.pausedMessage { error = nil }
                stop()
            }
            watchNetwork()
        }
    }
    /// Sharing is on but waiting: this Mac moved to a network other than the one sharing was turned on for
    /// (a café, a hotel, a work VPN). It starts again by itself back on that network.
    private(set) var pausedOnOtherNetwork = false
    @ObservationIgnored private var networkMonitor: NWPathMonitor?
    private static let networksKey = "shareNetworks"
    var pin: String {
        didSet {
            guard pin != oldValue else { return }
            KitSettings.shared.set(pin, forKey: "sharePIN")
            sessions.removeAll()   // a new PIN signs everyone out
            bookTokens.removeAll()
            GameStreamHub.shared.signOutAll()   // including devices playing games or acting as controllers
        }
    }
    /// Signed-in browsers and devices: random tokens handed out at sign-in, never the PIN itself.
    @ObservationIgnored private var sessions = Set<String>()
    /// Wrong PINs in a row from each device, and when it may guess again (the wait doubles after the fifth miss).
    /// Per device, so one device guessing can't lock the rest of the household out.
    @ObservationIgnored private var failedLogins: [String: Int] = [:]
    @ObservationIgnored private var lockedUntil: [String: Date] = [:]
    /// Wrong PINs from all devices together since the last right one. A device can take on new addresses
    /// (IPv6 makes that easy), so past a household-sized budget every new sign-in waits; signed-in devices carry on.
    @ObservationIgnored private var totalMisses = 0
    @ObservationIgnored private var everyoneLockedUntil: Date?
    static let missBudget = 20

    @ObservationIgnored private var server: WebServer?
    /// Archive pages are served from a second port, a separate web origin: scripts inside an archive can't read
    /// or drive the sharing controls on the main port, even though the browser is signed in to both.
    @ObservationIgnored private var contentServer: WebServer?
    @ObservationIgnored private var contentPort: UInt16 = 0
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private weak var model: AskModel?
    @ObservationIgnored private weak var media: MediaLibrary?
    @ObservationIgnored private weak var games: GameLibrary?
    @ObservationIgnored private var askBusy = false

    init() {
        // Running from a drive, the setting comes from the drive's own settings file, which anyone could have
        // written: sharing starts off on this Mac until it's turned on here.
        enabled = KitLocation.isPortable ? false : (KitSettings.shared.bool(forKey: "shareOnWiFi") ?? false)
        pin = KitSettings.shared.string(forKey: "sharePIN") ?? ""
        #if DEBUG
        // Test hook: -sharePIN 1234 uses that PIN for this run (in a test home only, so the real setting is untouched).
        if KitLocation.testHome != nil, let test = UserDefaults.standard.string(forKey: "sharePIN") { pin = test }
        #endif
    }

    func attach(library: Library, model: AskModel, media: MediaLibrary) {
        self.library = library
        self.model = model
        self.media = media
        // Connected Devices: the only way in to the sign-in sessions from outside this class.
        ShareDevices.shared.attach(share: self, library: library, media: media,
                                   isSignedIn: { [weak self] in self?.sessions.contains($0) ?? false },
                                   revoke: { [weak self] in
                                       self?.sessions.subtract($0)
                                       GameStreamHub.shared.signOut(signIns: $0)   // and any game it's playing
                                   },
                                   revokeAll: { [weak self] in
                                       self?.sessions.removeAll()
                                       self?.bookTokens.removeAll()
                                       GameStreamHub.shared.signOutAll()
                                   })
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "shareOnLaunch") { start(); return }   // test hook; does not change the saved setting
        #endif
        if enabled { startIfOnSharedNetwork() }
        watchNetwork()
    }

    /// Games for the Play tab and game streaming (see GameStream).
    func attach(games: GameLibrary) {
        self.games = games
        GameStreamHub.shared.games = games
        GameStreamHub.shared.library = library
    }

    // MARK: Which network

    /// The Wi-Fi and Ethernet networks this Mac is on, as "network/mask" (192.168.1.0/255.255.255.0).
    nonisolated static func currentNetworks() -> Set<String> {
        var result = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, let mask = ifa.ifa_netmask, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            func text(_ value: in_addr_t) -> String {
                var a = in_addr(s_addr: value)
                var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                return inet_ntop(AF_INET, &a, &buffer, socklen_t(buffer.count)).map { String(cString: $0) } ?? ""
            }
            let network = text(ip & bits)
            if !network.hasPrefix("169.254.") { result.insert("\(network)/\(text(bits))") }
        }
        return result
    }

    /// True when this Mac is on a network sharing was turned on for (or no network was recorded yet: sharing
    /// turned on before this check existed, which records the network it starts on).
    private func onSharedNetwork() -> Bool {
        guard let saved = KitSettings.shared.stringArray(forKey: Self.networksKey), !saved.isEmpty else { return true }
        return !Self.currentNetworks().isDisjoint(with: saved)
    }

    private func startIfOnSharedNetwork() {
        if onSharedNetwork() {
            if KitSettings.shared.stringArray(forKey: Self.networksKey)?.isEmpty ?? true {
                KitSettings.shared.set(Self.currentNetworks().sorted(), forKey: Self.networksKey)
            }
            pausedOnOtherNetwork = false
            start()
        } else {
            pausedOnOtherNetwork = true
            error = Self.pausedMessage
        }
    }

    static let pausedMessage = "Paused: this Mac is on a different network from the one sharing was turned on for. It starts again back on that network. To share here, turn sharing off and on."

    /// While sharing is on, pauses it on other networks and resumes it back on the shared one.
    private func watchNetwork() {
        guard enabled else { networkMonitor?.cancel(); networkMonitor = nil; return }
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.enabled else { return }
                // Interfaces settle a moment after the path changes.
                try? await Task.sleep(for: .seconds(1))
                if self.onSharedNetwork() {
                    if self.pausedOnOtherNetwork || !self.isRunning { self.startIfOnSharedNetwork() }
                } else if self.isRunning || !self.pausedOnOtherNetwork {
                    self.stop()
                    self.pausedOnOtherNetwork = true
                    self.error = Self.pausedMessage
                }
            }
        }
        monitor.start(queue: .global(qos: .utility))
        networkMonitor = monitor
    }

    var activeDevices: Int {
        let cutoff = Date().addingTimeInterval(-300)
        return recentDevices.values.filter { $0 > cutoff }.count
    }

    // MARK: Addresses

    /// "Your-MacBook.local", which iPhones, iPads and Macs resolve on the home network.
    var localHostName: String? {
        (SCDynamicStoreCopyLocalHostName(nil) as String?).map { $0 + ".local" }
    }

    /// IPv4 addresses on Wi-Fi/Ethernet, for Android and Windows devices that don't resolve .local names.
    var ipAddresses: [String] {
        var result: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0, (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("bridge") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                // 169.254.x.x is a self-assigned address (no router answered): other devices can't reach it.
                if WebServer.isLocal(ip), !ip.hasPrefix("169.254.") { result.append(ip) }
            }
        }
        return result
    }

    var primaryURL: String? {
        guard isRunning else { return nil }
        if let name = localHostName { return "http://\(name.lowercased()):\(port)" }
        return ipAddresses.first.map { "http://\($0):\(port)" }
    }

    var ipURLs: [String] { ipAddresses.map { "http://\($0):\(port)" } }

    func qrCode(for text: String) -> Image? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return Image(decorative: cg, scale: 1).interpolation(.none)
    }

    // MARK: Start and stop

    private func start() {
        guard server == nil else { return }
        error = nil
        let server = WebServer { [weak self] request, responder in
            await self?.route(request, responder)
        }
        do {
            // The last port used comes first, so a phone's bookmark keeps working after a relaunch.
            let lastPort = KitSettings.shared.string(forKey: "shareLastPort").flatMap { UInt16($0) }
            try server.start(ports: 8080...8099, preferred: lastPort, serviceName: "Offline Kit") { [weak self] problem in
                Task { @MainActor in
                    if let problem { self?.error = problem; self?.isRunning = false }
                }
            }
            let articles = WebServer { [weak self] request, responder in
                await self?.routeContent(request, responder)
            }
            try articles.start(ports: 8100...8119, serviceName: nil) { _ in }
            self.server = server
            contentServer = articles
            port = server.port
            KitSettings.shared.set(String(server.port), forKey: "shareLastPort")
            contentPort = articles.port
            isRunning = true
        } catch {
            // The main server may already be listening and advertising: take it down so it doesn't
            // hold its port and Bonjour name while pointing at nothing.
            server.stop()
            self.error = "Couldn't start sharing: \(error.localizedDescription)"
        }
    }

    private func stop() {
        ShareAwake.shared.release()
        GameStreamHub.shared.shutDown()
        server?.stop()
        server = nil
        contentServer?.stop()
        contentServer = nil
        isRunning = false
    }

    // MARK: Routing

    private func route(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        // Only requests addressed to this Mac by its local name or address: a web page elsewhere can't
        // point its own domain at the Mac ("DNS rebinding") and read the library through the visitor's browser.
        guard Self.isAllowedHost(req.headers["host"]) else {
            await res.send(status: 421, text: "Open Offline Kit using this Mac's address on your network.")
            return
        }
        // Connected Devices: blocked devices, and new ones waiting for approval, stop here, before any routing.
        guard await ShareDevices.shared.admit(req, res, port: .main) else { return }
        // Changes come only from Offline Kit's own page and apps: JSON, sent from this same address.
        if req.method == "POST" {
            let json = (req.headers["content-type"] ?? "").lowercased().hasPrefix("application/json")
            let sameOrigin = req.headers["origin"].map { $0.lowercased() == "http://" + (req.headers["host"] ?? "").lowercased() } ?? true
            guard json, sameOrigin else { await res.send(status: 403, json: ["error": "forbidden"]); return }
        }
        recentDevices[req.remoteHost] = Date()

        // Pages that work before the PIN is entered. The Home Screen icon and manifest are among them:
        // iOS fetches those without the sign-in cookie.
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            // The page only changes with the app: devices keep a copy and ask each time whether it is still current.
            await Self.sendVersioned(Self.indexPage, contentType: "text/html; charset=utf-8", req, res)
            return
        case ("GET", "/manifest.webmanifest"):
            await Self.sendVersioned(Self.manifest, contentType: "application/manifest+json", req, res)
            return
        case ("GET", "/apple-touch-icon.png"), ("GET", "/apple-touch-icon-precomposed.png"), ("GET", "/assets/icon-180.png"):
            await Self.sendIcon(180, req, res)
            return
        case ("GET", "/assets/icon-192.png"):
            await Self.sendIcon(192, req, res)
            return
        case ("GET", "/assets/icon-512.png"):
            await Self.sendIcon(512, req, res)
            return
        case ("GET", "/assets/watch-forest.jpg"):
            guard let url = Bundle.main.url(forResource: "watch-forest", withExtension: "jpg") else {
                await res.send(status: 404, text: ""); return
            }
            await res.sendFile(url, contentType: "image/jpeg", rangeHeader: req.headers["range"],
                               cacheControl: "private, max-age=86400", requestHeaders: req.headers)
            return
        case ("GET", "/favicon.ico"):
            await res.send(status: 404, text: "")
            return
        case ("GET", "/assets/play.js"):
            // The game player (no secrets in it; everything it does needs sign-in).
            await sendCached(PlayScript.player, contentType: "text/javascript; charset=utf-8", req, res)
            return
        case ("POST", "/api/login"):
            await login(req, res)
            return
        default: break
        }

        if !pin.isEmpty && !(req.cookies["okpin"].map { sessions.contains($0) } ?? false) {
            if req.path.hasPrefix("/api/") { await res.send(status: 401, json: ["error": "pin"]) }
            else { await res.redirect(to: "/") }
            return
        }

        switch (req.method, req.path) {
        case ("GET", "/api/status"):
            await res.send(json: status())
        case ("GET", "/api/books"):
            await res.send(json: books())
        case ("GET", "/api/search"):
            await search(req, res)
        case ("POST", "/api/ask"):
            await ask(req, res)
        case ("GET", let path) where path.hasPrefix("/book/") || path.hasPrefix("/content/"):
            // Articles open on the archive port (see contentServer).
            let target = req.rawPath + (req.rawQuery.map { "?" + $0 } ?? "")
            await res.redirect(to: Self.origin(host: req.headers["host"], port: contentPort) + target)
        case ("GET", "/api/media"):
            await mediaList(req, res)
        case ("GET", "/api/media/detail"):
            await mediaDetail(req, res)
        case ("GET", "/api/read"):
            await readList(req, res)
        case ("GET", "/api/read/book"):
            await readBook(req, res)
        case ("POST", "/api/media/progress"):
            await mediaProgress(req, res)
        case ("GET", let path) where path.hasPrefix("/media/"):
            await mediaFile(path: path, range: req.headers["range"], width: ShareArtwork.bucket(req.query["w"]), requestHeaders: req.headers, res)
        case ("GET", "/api/games"):
            await gameList(res)
        case ("GET", let path) where path.hasPrefix("/api/games/art/"):
            await gameArt(id: String(path.dropFirst("/api/games/art/".count)), req, res)
        case ("GET", "/api/play/socket"):
            await playSocket(req, res)
        case ("GET", "/play-test"):
            await sendCached(PlayScript.testPage, contentType: "text/html; charset=utf-8", req, res)
        case (_, let path) where path == "/api/send" || path.hasPrefix("/api/send/"):
            await SendList.shared.handle(req, res, macName: Host.current().localizedName ?? "Mac", libraries: library?.folders ?? [])   // Send to iPhone
        default:
            await res.send(status: 404, text: "Not found")
        }
    }

    /// A page or script that only changes with the app: devices keep a copy and check it with a cheap 304.
    private func sendCached(_ file: (data: Data, etag: String), contentType: String, _ req: WebServer.Request, _ res: WebServer.Responder) async {
        let headers = ["ETag": file.etag, "Cache-Control": "no-cache"]
        if WebServer.isNotModified(req.headers, etag: file.etag, modified: .distantPast) {
            await res.send(status: 304, contentType: contentType, body: Data(), headers: headers)
        } else {
            await res.send(status: 200, contentType: contentType, body: file.data, headers: headers)
        }
    }

    // MARK: Games

    /// GET /api/games: {"games": [{"id", "title", "system", "systemName", "art", "lastPlayed", "canResume"}]}.
    private func gameList(_ res: WebServer.Responder) async {
        guard let games, let library else { await res.send(status: 503, json: ["error": "Not ready"]); return }
        await games.reloadIfChanged(library: library)   // a few stat calls when nothing changed
        let list = games.games, played = games.lastPlayed
        let entries: [[String: Any]] = await Task.detached(priority: .userInitiated) {
            list.filter { $0.system != .atari2600 }.map { game in
                let id = GameStreamHub.gameID(game)
                let artStamp = (try? game.thumbnailURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return ["id": id, "title": game.title, "system": game.system.rawValue, "systemName": game.system.name,
                        "art": artStamp.map { "/api/games/art/\(id)?v=\(Int($0.timeIntervalSince1970))" } ?? NSNull(),
                        "lastPlayed": played[game.id].map { $0.timeIntervalSince1970.rounded() } ?? NSNull(),
                        "canResume": game.canResume]
            }
        }.value
        await res.send(json: ["games": entries])
    }

    /// GET /api/games/art/<id>: the game's shelf picture (its last frame), cached like other artwork.
    private func gameArt(id: String, _ req: WebServer.Request, _ res: WebServer.Responder) async {
        guard let game = games?.games.first(where: { GameStreamHub.gameID($0) == id }) else {
            await res.send(status: 404, text: "Not found"); return
        }
        let url = game.thumbnailURL
        let folders = library?.folders ?? []
        let allowed = await Task.detached(priority: .userInitiated) {
            (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
                && SharePolicy.Scope(libraries: folders).allows(url)
        }.value
        guard allowed else { await res.send(status: 404, text: "Not found"); return }
        // ?w=: a copy sized for the tile (checked above, like the original).
        if let width = ShareArtwork.bucket(req.query["w"]), let copy = await ShareArtwork.resized(url, width: width) {
            await res.sendFile(copy.url, contentType: copy.contentType, rangeHeader: nil, cacheControl: "private, max-age=300", requestHeaders: req.headers)
            return
        }
        await res.sendFile(url, contentType: "image/png", rangeHeader: nil, cacheControl: "private, max-age=300", requestHeaders: req.headers)
    }

    /// GET /api/play/socket: the WebSocket a browser plays a game (or acts as a controller) over. Signed in like every
    /// other route (checked before this), and the Origin must be this same address, so another web page can't open it.
    private func playSocket(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        guard let origin = req.headers["origin"]?.lowercased(),
              origin == "http://" + (req.headers["host"] ?? "").lowercased() else {
            await res.send(status: 403, json: ["error": "forbidden"]); return
        }
        guard games != nil else { await res.send(status: 503, json: ["error": "Not ready"]); return }
        let deviceID = ShareDevices.shared.deviceID(for: res)
        guard let socket = await res.upgradeToWebSocket(req) else { return }
        GameStreamHub.shared.accept(socket, device: Self.deviceName(req.headers["user-agent"] ?? ""),
                                    signIn: req.cookies["okpin"], deviceID: deviceID)
    }

    /// "iPhone", "iPad", "Android phone"…, for "An iPhone is playing Sky Loop".
    nonisolated static func deviceName(_ userAgent: String) -> String {
        if userAgent.contains("iPhone") { return "iPhone" }
        if userAgent.contains("iPad") { return "iPad" }
        if userAgent.contains("Android") { return userAgent.contains("Mobile") ? "Android phone" : "Android tablet" }
        if userAgent.contains("Macintosh") { return "iPad or Mac" }
        if userAgent.contains("Windows") { return "Windows PC" }
        return "device"
    }

    /// The sharing page, built once: it is the same for every device until the app is updated.
    nonisolated private static let indexPage = versioned(WebApp.slim(WebApp.html))
    /// What a phone or tablet reads when the page is added to its Home Screen.
    nonisolated private static let manifest = versioned(WebApp.manifest)

    /// Text that only changes with the app, with an ETag made from its contents.
    nonisolated private static func versioned(_ text: String) -> (data: Data, etag: String) {
        let data = Data(text.utf8)
        return (data, "\"\(digest(data))\"")
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Sends a page that only changes with the app: devices keep a copy and ask each time whether it is still current.
    nonisolated private static func sendVersioned(_ page: (data: Data, etag: String), contentType: String,
                                                  _ req: WebServer.Request, _ res: WebServer.Responder) async {
        let headers = ["ETag": page.etag, "Cache-Control": "no-cache"]
        if WebServer.isNotModified(req.headers, etag: page.etag, modified: .distantPast) {
            await res.send(status: 304, contentType: contentType, body: Data(), headers: headers)
        } else {
            await res.send(status: 200, contentType: contentType, body: page.data, headers: headers)
        }
    }

    /// The app icon, sized for Home Screens (bundled PNGs made from the app's own icon).
    nonisolated private static func sendIcon(_ size: Int, _ req: WebServer.Request, _ res: WebServer.Responder) async {
        guard let url = Bundle.main.url(forResource: "web-icon-\(size)", withExtension: "png") else {
            await res.send(status: 404, text: ""); return
        }
        await res.sendFile(url, contentType: "image/png", rangeHeader: nil,
                           cacheControl: "private, max-age=86400", requestHeaders: req.headers)
    }

    /// Changes each launch, so an ETag made from a revision counter (which starts again at 0) never matches an old copy.
    nonisolated private static let launchTag = String(UInt32.random(in: 0...UInt32.max), radix: 36)

    /// The Mac's name. Looking it up can be slow, so it's remembered for a minute.
    nonisolated private static let macNameCache = NSLock()
    nonisolated(unsafe) private static var macNameValue: (name: String, at: Date)?
    nonisolated static var macName: String {
        macNameCache.withLock {
            if let hit = macNameValue, -hit.at.timeIntervalSinceNow < 60 { return hit.name }
            let name = Host.current().localizedName ?? "Mac"
            macNameValue = (name, Date())
            return name
        }
    }

    private func status() -> [String: Any] {
        let model = self.model
        let engine = model?.engineLabel(libraryFolders: library?.folders ?? []).name ?? "No answer model yet"
        let books = library?.books ?? []
        return ["name": Self.macName, "archives": books.count,
                "articles": books.reduce(0) { $0 + Int($1.archive.articleCount) }, "engine": engine]
    }

    private func books() -> [[String: Any]] {
        (library?.books ?? []).map { book in
            ["id": book.id, "title": book.shortTitle, "fullTitle": book.title, "kind": book.kind.title,
             "kindOrder": book.kind.rawValue, "articles": Int(book.archive.articleCount),
             "size": ByteCountFormatter.string(fromByteCount: book.fileSize, countStyle: .file),
             "summary": book.archive.summary, "hasIcon": book.archive.illustration != nil]
        }
    }

    /// ?q=...&book=<id optional>&mode=title|text
    private func search(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        let q = (req.query["q"] ?? "").trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { await res.send(json: ["results": []]); return }
        let wanted = req.query["book"]; let targets = (library?.books ?? []).filter { book in wanted.map { book.id == $0 } ?? true }
        let fullText = req.query["mode"] == "text"
        let results: [[String: Any]] = await Task.detached(priority: .userInitiated) {
            var out: [[String: Any]] = []
            for book in targets {
                let hits = fullText ? book.archive.search(q, limit: 4) : book.archive.suggest(q, limit: targets.count == 1 ? 15 : 3)
                for hit in hits {
                    out.append(["title": hit.title, "book": book.shortTitle, "bookID": book.id,
                                "url": ShareController.contentURL(id: book.id, path: hit.path),
                                "snippet": HTMLText.stripTags(hit.snippet)])
                }
            }
            return out
        }.value
        await res.send(json: ["results": results])
    }

    /// Checks the PIN. Right answers get a random session token as the cookie. Wrong ones count toward a lockout
    /// per device and, past `missBudget`, for every new sign-in, so guessing a 4-digit PIN takes months, not minutes.
    private func login(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        if pin.isEmpty { await res.send(json: ["ok": true]); return }
        let device = ShareDeviceKey.key(req.remoteHost)
        if let until = [lockedUntil[device], everyoneLockedUntil].compactMap({ $0 }).max(), Date() < until {
            await res.send(status: 429, json: ["ok": false, "error": "wait", "seconds": Int(until.timeIntervalSinceNow.rounded(.up))])
            return
        }
        let sent = (try? JSONSerialization.jsonObject(with: req.body) as? [String: String])?["pin"] ?? ""
        if Self.constantTimeEqual(sent, pin) {
            failedLogins[device] = nil
            totalMisses = 0
            everyoneLockedUntil = nil
            let token = Self.newToken()
            sessions.insert(token)
            ShareDevices.shared.signedIn(token: token, res)
            await res.send(json: ["ok": true, "token": token],
                           headers: ["Set-Cookie": "okpin=\(token); Path=/; SameSite=Strict; HttpOnly"])
        } else {
            let misses = (failedLogins[device] ?? 0) + 1
            failedLogins[device] = misses
            if misses >= 5 { lockedUntil[device] = Date().addingTimeInterval(min(3600, 15 * pow(2, Double(misses - 5)))) }
            totalMisses += 1
            if totalMisses >= Self.missBudget {
                everyoneLockedUntil = Date().addingTimeInterval(min(3600, 30 * pow(2, Double(totalMisses - Self.missBudget))))
            }
            if failedLogins.count > 500 { failedLogins.removeAll(); lockedUntil = lockedUntil.filter { $0.value > Date() } }
            try? await Task.sleep(for: .milliseconds(600))
            await res.send(status: 401, json: ["ok": false])
        }
    }

    nonisolated private static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return UUID().uuidString + UUID().uuidString }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { diff |= Int((i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)) }
        return diff == 0
    }

    /// The Host a request was sent to: an IP address, "localhost" or a ".local" name, with any port.
    nonisolated static func isAllowedHost(_ value: String?) -> Bool {
        guard var host = value?.lowercased().trimmingCharacters(in: .whitespaces), !host.isEmpty else { return false }
        if host.hasPrefix("[") { return host.contains("]") }                      // an IPv6 address
        if let colon = host.lastIndex(of: ":") { host = String(host[..<colon]) }  // drop the port
        if host == "localhost" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// The archive port: articles and the files they load, behind the same Host check and sign-in as the main port.
    private func routeContent(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        guard Self.isAllowedHost(req.headers["host"]) else {
            await res.send(status: 421, text: "Open Offline Kit using this Mac's address on your network.")
            return
        }
        // Connected Devices. A book page's frame sends no cookie, so its token's sign-in says which device it is.
        guard await ShareDevices.shared.admit(req, res, port: .content, session: bookSession(req.path)) else { return }
        let home = Self.origin(host: req.headers["host"], port: port) + "/"
        // Book pages load inside a sandboxed frame, which carries no cookie: the address itself holds a token handed
        // to a signed-in device (see bookToken), and it stops working when that device is signed out.
        if req.method == "GET", req.path == "/epub-reader.js" {
            await res.send(status: 200, contentType: "text/javascript; charset=utf-8", body: Data(WebApp.bookFrameScript.utf8),
                           headers: ["Cache-Control": "private, max-age=86400", "ETag": Self.bookScriptTag])
            return
        }
        if req.method == "GET", req.path.hasPrefix("/epub/") {
            await epubFile(req, res)
            return
        }
        if !pin.isEmpty && !(req.cookies["okpin"].map { sessions.contains($0) } ?? false) {
            await res.redirect(to: home)
            return
        }
        switch (req.method, req.path) {
        case ("GET", let path) where path.hasPrefix("/pdf/"):
            await pdfFile(req, res)
        case ("GET", let path) where path.hasPrefix("/book/"):
            let id = String(path.dropFirst("/book/".count))
            if let main = library?.book(id)?.mainPage { await res.redirect(to: Self.contentURL(id: main.bookID, path: main.path)) }
            else { await res.send(status: 404, text: "That archive isn't available.") }
        case ("GET", let path) where path.hasPrefix("/content/"):
            await content(path: path, range: req.headers["range"], home: home, res)
        default:
            await res.redirect(to: home)
        }
    }

    /// Archive pages load only from their own archive (no tracking pixels or remote scripts). The bar's link home
    /// is a navigation, which this doesn't restrict.
    nonisolated static let articlePolicy = "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:"

    /// "http://<the address the device used>:<port>", from the request's Host header.
    nonisolated static func origin(host: String?, port: UInt16) -> String {
        var name = host ?? "localhost"
        if name.hasPrefix("[") { name = String(name[...(name.firstIndex(of: "]") ?? name.index(before: name.endIndex))]) }
        else if let colon = name.lastIndex(of: ":") { name = String(name[..<colon]) }
        return "http://\(name):\(port)"
    }

    nonisolated static func contentURL(id: String, path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#;")
        return "/content/\(id)/" + (path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path)
    }

    /// Serves archive files. HTML pages get a slim "Back to Offline Kit" bar.
    private func content(path: String, range rangeHeader: String?, home: String, _ res: WebServer.Responder) async {
        let rest = path.dropFirst("/content/".count)
        guard let slash = rest.firstIndex(of: "/") else { await res.send(status: 404, text: "Not found"); return }
        let id = String(rest[..<slash])
        let entry = String(rest[rest.index(after: slash)...])
        // Ask's built-in power-out guide is cited like an article; serve its section as a page.
        if id == PowerOutGuide.bookID, let page = PowerOutGuide.html(section: entry) {
            await res.send(status: 200, contentType: "text/html; charset=utf-8", body: Data(page.utf8),
                           headers: ["Content-Security-Policy": Self.articlePolicy]); return
        }
        guard let archive = ArchiveRegistry.shared.archive(id) else { await res.send(status: 404, text: "That archive isn't available."); return }
        // A byte-range request for a video or audio file reads just those bytes from the archive, not the whole entry each seek.
        if let rangeHeader {
            let ranged: (mime: String, lower: Int, upper: Int, total: Int, data: Data)? = await Task.detached(priority: .userInitiated) {
                guard let info = archive.info(atPath: entry), info.path == entry, !info.mimeType.hasPrefix("text/html"),
                      let range = ByteRange(header: rangeHeader, total: Int(info.totalSize)) else { return nil }
                // An open-ended request ("bytes=0-") is answered with at most 16 MB, like movies sent from disk.
                let upper = rangeHeader.hasSuffix("-") ? min(range.upper, range.lower + 16 * 1024 * 1024 - 1) : range.upper
                guard let data = archive.data(atPath: entry, offset: UInt(range.lower), length: UInt(upper - range.lower + 1)) else { return nil }
                return (info.mimeType, range.lower, range.lower + data.count - 1, Int(info.totalSize), data)
            }.value
            if let ranged {
                await res.send(status: 206, contentType: ranged.mime, body: ranged.data,
                               headers: ["Accept-Ranges": "bytes", "Content-Range": "bytes \(ranged.lower)-\(ranged.upper)/\(ranged.total)",
                                         "Content-Security-Policy": Self.articlePolicy])
                return
            }
        }
        let found: ZimContent? = await Task.detached(priority: .userInitiated) { archive.content(atPath: entry) }.value
        guard let found else { await res.send(status: 404, text: "Not in this archive."); return }
        if found.path != entry {
            await res.redirect(to: Self.contentURL(id: id, path: found.path))   // keep relative links right after a redirect
            return
        }
        var body = found.data
        if found.mimeType.hasPrefix("text/html"), let html = String(data: body, encoding: .utf8),
           let bodyTag = html.range(of: "<body[^>]*>", options: [.regularExpression, .caseInsensitive]) {
            var page = html
            page.insert(contentsOf: WebApp.articleBar(home: home), at: bodyTag.upperBound)
            body = Data(page.utf8)
        }
        if let range = ByteRange(header: rangeHeader, total: body.count) {
            let slice = body.subdata(in: range.lower..<(range.upper + 1))
            await res.send(status: 206, contentType: found.mimeType, body: slice,
                           headers: ["Accept-Ranges": "bytes", "Content-Range": "bytes \(range.lower)-\(range.upper)/\(body.count)",
                                     "Content-Security-Policy": Self.articlePolicy])
        } else {
            await res.send(status: 200, contentType: found.mimeType, body: body,
                           headers: ["Cache-Control": "max-age=3600", "Accept-Ranges": "bytes", "Content-Security-Policy": Self.articlePolicy])
        }
    }

    // MARK: Watch & Listen (Apple TV)

    /// URL-safe id for a media item, from its progress key (stable across launches and drives).
    nonisolated static func mediaID(_ item: MediaItem) -> String {
        Data(item.progressKey.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func mediaItem(_ id: String) -> MediaItem? {
        media?.items.first { Self.mediaID($0) == id }
    }

    /// What the phones' search box and the Apple TV ask for. The item list is the heavy part and doesn't depend on the
    /// search, sort or filter, so it is encoded once per library revision and reused; only the search results, shelves and
    /// so on are worked out per request. All of it is built off the main thread. "More like this" and "Up next" are not
    /// in the list (they cost a sort per item): `/api/media/detail` gives them for the one item that is opened.
    private func mediaList(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        guard let media, let library else { await res.send(status: 503, json: ["error": "Not ready"]); return }
        // Served from what's already loaded: the library rescans itself when files change (LibraryWatcher, ScanGate).
        // Only a library that hasn't been read yet this launch is scanned here.
        if media.items.isEmpty { await media.reload(library: library) }
        observeMedia()
        let revision = mediaRevision
        // The answer only changes with the library: a device that has this revision already gets a 304.
        let etag = "\"m\(Self.launchTag)-\(revision)-\(Self.digest(Data((req.rawQuery ?? "").utf8)))\""
        if WebServer.isNotModified(req.headers, etag: etag, modified: .distantPast) {
            await res.send(status: 304, contentType: "application/json; charset=utf-8", body: Data(),
                           headers: ["ETag": etag, "Cache-Control": "no-cache"])
            return
        }
        let snapshot = MediaSnapshot(items: media.items, info: media.info, progress: media.progress)
        let cachedItems = itemsCache.flatMap { $0.revision == revision ? $0.json : nil }
        let filter = MediaFilter(rawValue: req.query["filter"] ?? "all") ?? .all
        let sort = MediaSort(rawValue: req.query["sort"] ?? "title") ?? .title
        let genre = req.query["genre"].flatMap { $0.isEmpty ? nil : $0 }
        let query = req.query["q"] ?? ""
        let unfinished = req.query["unfinished"] == "true"
        let built: (items: Data, rest: Data) = await Task.detached(priority: .userInitiated) {
            let itemsJSON = cachedItems ?? Self.encodeItems(snapshot)
            let rest = Self.encodeResults(snapshot, filter: filter, sort: sort, genre: genre, query: query, unfinished: unfinished)
            return (itemsJSON, rest)
        }.value
        if cachedItems == nil, revision == mediaRevision { itemsCache = (revision, built.items) }
        let headers = ["ETag": etag, "Cache-Control": "no-cache"]
        // ?items=0: just the shelves and results, for a page that already has the item list.
        if req.query["items"] == "0" {
            await res.send(status: 200, contentType: "application/json; charset=utf-8", body: built.rest, headers: headers)
            return
        }
        // {"items": <cached array>, <the rest of the object>}
        var body = Data(#"{"items":"#.utf8)
        body.append(built.items)
        body.append(UInt8(ascii: ","))
        body.append(built.rest.dropFirst())
        await res.send(status: 200, contentType: "application/json; charset=utf-8", body: body, headers: headers)
    }

    /// Copies of what the media list is made from, handed to a background task.
    private struct MediaSnapshot: Sendable {
        let items: [MediaItem]
        let info: [String: MediaInfo]
        let progress: [String: MediaProgress]
    }

    /// Bumped whenever the library's items, details or play positions change, so the encoded list can be reused until then.
    @ObservationIgnored private var mediaRevision = 0
    @ObservationIgnored private var itemsCache: (revision: Int, json: Data)?
    @ObservationIgnored private var observingMedia = false

    private func observeMedia() {
        guard let media, !observingMedia else { return }
        observingMedia = true
        withObservationTracking {
            _ = media.items; _ = media.info; _ = media.progress
        } onChange: { [weak self] in
            // Called as the change starts, on the main thread (the library is main-actor): count it now so a request that
            // arrives before the next line runs can't reuse the old list.
            MainActor.assumeIsolated { self?.mediaRevision += 1 }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observingMedia = false
                self.mediaRevision += 1   // anything that changed before watching resumed
                self.observeMedia()
            }
        }
    }

    /// The array of items, JSON-encoded.
    nonisolated private static func encodeItems(_ snapshot: MediaSnapshot) -> Data {
        let items: [[String: Any]] = snapshot.items.filter { $0.kind != .book && $0.unavailable == nil }.map { item in
            let id = mediaID(item)
            let info = snapshot.info[item.progressKey]
            var entry: [String: Any] = [
                "id": id, "kind": item.kind.rawValue, "title": MediaCatalog.title(item, info),
                "category": MediaCatalog.category(item, info).rawValue,
                "meta": MediaCatalog.meta(item, info),
                "tracks": item.tracks.enumerated().map { index, url in
                    var track: [String: Any] = ["title": MediaCatalog.trackTitle(item, info, index), "url": "/media/\(id)/\(index)"]
                    if let details = info?.tracks, details.indices.contains(index), let duration = details[index].duration { track["duration"] = duration }
                    return track
                },
            ]
            if item.cover != nil { entry["cover"] = "/media/\(id)/cover" }
            if info?.thumb != nil || item.cover != nil { entry["thumb"] = "/media/\(id)/thumb" }
            entry["artist"] = MediaCatalog.creator(info)
            entry["added"] = info?.added.timeIntervalSince1970 ?? 0
            if let d = info?.duration { entry["duration"] = d }
            if let y = info?.year { entry["year"] = y }
            if let g = info?.genre { entry["genre"] = g }
            // Organize with AI details (added fields only; older clients ignore them).
            if let v = info?.subgenre { entry["subgenre"] = v }
            if let v = info?.studio { entry["studio"] = v }
            if let v = info?.series { entry["series"] = v }
            if let v = info?.seriesOrder { entry["seriesOrder"] = v }
            if let v = info?.ageRating { entry["ageRating"] = v }
            if let v = info?.summary { entry["summary"] = v }
            if let v = info?.guessed, !v.isEmpty { entry["aiGuess"] = v }
            if let p = snapshot.progress[item.progressKey] {
                entry["progress"] = ["track": p.track, "seconds": p.seconds, "finished": p.finished, "updated": p.updated?.timeIntervalSince1970 ?? 0]
            }
            return entry
        }
        return (try? JSONSerialization.data(withJSONObject: items)) ?? Data("[]".utf8)
    }

    /// The part of the answer that depends on the search, sort and filter, as one JSON object (without "items").
    nonisolated private static func encodeResults(_ snapshot: MediaSnapshot, filter: MediaFilter, sort: MediaSort,
                                                   genre: String?, query: String, unfinished: Bool) -> Data {
        let info = snapshot.info, progress = snapshot.progress
        // The same banner and rows as Watch & Listen on the Mac.
        let available = snapshot.items.filter { $0.kind != .book && $0.unavailable == nil }
        let catalog = MediaCatalog.build(items: available, progress: progress, info: info, filter: filter,
                                         genre: genre, query: query, sort: sort, unfinished: unfinished)
        let results = MediaCatalog.select(available, info: info, progress: progress, filter: filter,
                                          genre: genre, query: query, sort: sort, unfinished: unfinished)
        let music = results.filter { MediaCatalog.category($0, info[$0.progressKey]) == .music }
        let genres = MediaCatalog.genres(available, info: info, filter: filter)
        var body: [String: Any] = [
            "name": macName,
            "results": results.map(mediaID),
            "songs": MediaCatalog.songs(music, info: info, query: query, sort: sort)
                .map { ["item": mediaID($0.item), "index": $0.index] as [String: Any] },
            "genres": genres,
            // The SF Symbol the Mac shows for each genre; the page draws its own picture for it.
            "genreIcons": Dictionary(genres.map { ($0, GenreIcon.symbol(for: $0)) }, uniquingKeysWith: { a, _ in a }),
            "artists": Dictionary(grouping: music, by: { MediaCatalog.creator(info[$0.progressKey]) })
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { ["name": $0.key, "items": $0.value.map(mediaID)] as [String: Any] },
            "shelves": catalog.shelves.map { ["title": $0.title, "items": $0.items.map(mediaID)] },
        ]
        if let featured = catalog.featured { body["featured"] = mediaID(featured) }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    /// GET /api/media/detail?id=<id>: what is worked out only for the item that is opened: "More like this" and the video
    /// that plays next.
    private func mediaDetail(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        if media?.items.isEmpty ?? true, let media, let library { await media.reload(library: library) }
        guard let media, let id = req.query["id"], let item = mediaItem(id) else {
            await res.send(status: 404, json: ["error": "Unknown item"]); return
        }
        let snapshot = MediaSnapshot(items: media.items, info: media.info, progress: media.progress)
        let body: [String: Any] = await Task.detached(priority: .userInitiated) {
            var body: [String: Any] = [
                "related": MediaCatalog.related(to: item, items: snapshot.items.filter { $0.kind != .book }, info: snapshot.info).prefix(12).map(ShareController.mediaID),
            ]
            if let next = MediaCatalog.nextVideo(after: item, items: snapshot.items, info: snapshot.info, progress: snapshot.progress) {
                body["upNext"] = ShareController.mediaID(next)
            }
            return body
        }.value
        await res.send(json: body)
    }

    /// {"id": "...", "track": 2, "seconds": 812.5, "finished": false}
    private func mediaProgress(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let id = body["id"] as? String, let item = mediaItem(id) else {
            await res.send(status: 404, json: ["error": "Unknown item"]); return
        }
        if item.kind == .book {
            // The same place BookReader saves: the chapter (or PDF page) in `track` and, for an EPUB, how far down it in
            // `seconds` (0…1). A finished book starts again from the beginning.
            let parts = max(1, media?.info[item.progressKey]?.parts ?? Int.max)
            let track = min(max(0, body["track"] as? Int ?? 0), parts - 1)
            let fraction = min(1, max(0, (body["seconds"] as? Double) ?? 0))
            let finished = body["finished"] as? Bool ?? false
            let isPDF = item.tracks[0].pathExtension.lowercased() == "pdf"
            media?.saveProgress(MediaProgress(track: finished ? 0 : track, seconds: finished || isPDF ? 0 : fraction, finished: finished), for: item)
            await res.send(json: ["ok": true])
            return
        }
        let track = min(max(0, body["track"] as? Int ?? 0), item.tracks.count - 1)
        let seconds = max(0, (body["seconds"] as? Double) ?? Double(body["seconds"] as? Int ?? 0))
        media?.saveProgress(MediaProgress(track: track, seconds: seconds, finished: body["finished"] as? Bool ?? false), for: item)
        await res.send(json: ["ok": true])
    }

    /// /media/<id>/<track index> or /media/<id>/cover. Artwork with `width` (from ?w=) is sent as a copy at most that wide.
    private func mediaFile(path: String, range: String?, width: Int? = nil, requestHeaders: [String: String], _ res: WebServer.Responder) async {
        let parts = path.dropFirst("/media/".count).split(separator: "/").map(String.init)
        if media?.items.isEmpty ?? true, let media, let library { await media.reload(library: library) }
        guard parts.count == 2, let item = mediaItem(parts[0]) else { await res.send(status: 404, text: "Not found"); return }
        let url: URL
        if parts[1] == "cover", let cover = item.cover { url = cover }
        else if parts[1] == "thumb", let thumb = item.cover?.path ?? media?.info[item.progressKey]?.thumb { url = URL(fileURLWithPath: thumb) }
        else if let index = Int(parts[1]), item.tracks.indices.contains(index) { url = item.tracks[index] }
        else { await res.send(status: 404, text: "Not found"); return }
        guard await shareable(url) else {
            await res.send(status: 404, text: "Not found"); return
        }
        // Artwork is small and rarely changes: devices keep it for a few minutes, then check with a cheap 304.
        // Video and audio are never cached (they stream by range).
        let isArtwork = parts[1] == "cover" || parts[1] == "thumb"
        // A phone-sized copy, made from the file just checked (see ShareArtwork).
        if isArtwork, let width, let copy = await ShareArtwork.resized(url, width: width) {
            await res.sendFile(copy.url, contentType: copy.contentType, rangeHeader: nil,
                               cacheControl: "private, max-age=300", requestHeaders: requestHeaders)
            return
        }
        await res.sendFile(url, contentType: Self.mimeType(url), rangeHeader: range,
                           cacheControl: isArtwork ? "private, max-age=300" : nil, requestHeaders: requestHeaders)
    }

    /// Only real files that stay where the library is: a link on a drive can't hand out this Mac's files.
    private func shareable(_ url: URL) async -> Bool {
        let isFile = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        guard isFile else { return false }
        let folders = library?.folders ?? []
        return await Task.detached(priority: .userInitiated) { SharePolicy.Scope(libraries: folders).allows(url) }.value
    }

    nonisolated private static func mimeType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "mp3": "audio/mpeg"
        case "m4a", "m4b", "aac": "audio/mp4"
        case "wav": "audio/wav"
        case "aiff": "audio/aiff"
        case "flac": "audio/flac"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        default: "application/octet-stream"
        }
    }

    // MARK: Read (EPUB and PDF books)

    /// GET /api/read: the books in the media library (EPUB and PDF), with the same rows the Mac shows under Books.
    private func readList(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        guard let media, let library else { await res.send(status: 503, json: ["error": "Not ready"]); return }
        if media.items.isEmpty { await media.reload(library: library) }
        observeMedia()
        let revision = mediaRevision
        let etag = "\"r\(Self.launchTag)-\(revision)\""
        let headers = ["ETag": etag, "Cache-Control": "no-cache"]
        if WebServer.isNotModified(req.headers, etag: etag, modified: .distantPast) {
            await res.send(status: 304, contentType: "application/json; charset=utf-8", body: Data(), headers: headers)
            return
        }
        let snapshot = MediaSnapshot(items: media.items, info: media.info, progress: media.progress)
        let body = await Task.detached(priority: .userInitiated) { Self.encodeBooks(snapshot) }.value
        await res.send(status: 200, contentType: "application/json; charset=utf-8", body: body, headers: headers)
    }

    nonisolated private static func isPDF(_ item: MediaItem) -> Bool { item.tracks[0].pathExtension.lowercased() == "pdf" }

    nonisolated private static func encodeBooks(_ snapshot: MediaSnapshot) -> Data {
        let info = snapshot.info, progress = snapshot.progress
        let books = snapshot.items.filter { $0.kind == .book && $0.unavailable == nil }
        let list: [[String: Any]] = books.map { item in
            let id = mediaID(item)
            let details = info[item.progressKey]
            var entry: [String: Any] = [
                "id": id, "title": MediaCatalog.title(item, details), "format": isPDF(item) ? "pdf" : "epub",
                "meta": MediaCatalog.meta(item, details), "added": details?.added.timeIntervalSince1970 ?? 0,
            ]
            if let v = details?.author, !v.isEmpty { entry["author"] = v }
            if details?.thumb != nil || item.cover != nil { entry["thumb"] = "/media/\(id)/thumb" }
            if let v = details?.genre { entry["genre"] = v }
            if let v = details?.parts { entry["parts"] = v }
            if let v = details?.summary { entry["summary"] = v }
            if let v = details?.series { entry["series"] = v }
            if let v = details?.year { entry["year"] = v }
            if let p = progress[item.progressKey] {
                entry["progress"] = ["track": p.track, "seconds": p.seconds, "finished": p.finished, "updated": p.updated?.timeIntervalSince1970 ?? 0]
                if let f = MediaCatalog.fraction(item, p, details) { entry["fraction"] = f }
            }
            return entry
        }
        let catalog = MediaCatalog.build(items: books, progress: progress, info: info, filter: .books)
        let genres = MediaCatalog.genres(books, info: info, filter: .books)
        let body: [String: Any] = [
            "books": list,
            "shelves": catalog.shelves.map { ["title": $0.title, "items": $0.items.map(mediaID)] },
            "genres": genres,
            "genreIcons": Dictionary(genres.map { ($0, GenreIcon.symbol(for: $0)) }, uniquingKeysWith: { a, _ in a }),
        ]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    /// GET /api/read/book?id=<id>: what the reader needs to open one book. An EPUB's chapters load from the archive
    /// port inside a sandboxed frame (see epubFile); a PDF opens in the browser's own viewer from there too.
    private func readBook(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        if media?.items.isEmpty ?? true, let media, let library { await media.reload(library: library) }
        guard let id = req.query["id"], let item = mediaItem(id), item.kind == .book, item.unavailable == nil else {
            await res.send(status: 404, json: ["error": "That book isn't on the Mac any more."]); return
        }
        guard await shareable(item.tracks[0]) else {
            await res.send(status: 404, json: ["error": "That book isn't on the Mac any more."]); return
        }
        let content = Self.origin(host: req.headers["host"], port: contentPort)
        var body: [String: Any] = ["id": id]
        if let p = media?.progress[item.progressKey] {
            body["progress"] = ["track": p.track, "seconds": p.seconds, "finished": p.finished, "updated": p.updated?.timeIntervalSince1970 ?? 0]
        }
        if Self.isPDF(item) {
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/?#;")
            let name = item.tracks[0].lastPathComponent.addingPercentEncoding(withAllowedCharacters: allowed) ?? "book.pdf"
            body["format"] = "pdf"
            body["file"] = content + "/pdf/\(id)/\(name)"
            await res.send(json: body)
            return
        }
        guard let (book, _) = await openEPUB(item) else {
            await res.send(status: 422, json: ["error": "This book can't be opened. The EPUB file may be damaged or protected with DRM."]); return
        }
        body["format"] = "epub"
        body["title"] = book.title
        if let author = book.author { body["author"] = author }
        body["chapters"] = book.chapters.map { ["title": $0.title, "path": $0.path] }
        body["base"] = content + "/epub/\(bookToken(session: req.cookies["okpin"] ?? "", book: id))/"
        await res.send(json: body)
    }

    /// Open EPUBs, by media id: a reader turning pages asks for a chapter at a time, and the zip's directory is read once.
    @ObservationIgnored private var openBooks: [String: (file: URL, modified: Date?, book: EPUBBook, zip: ZipReader, used: Date)] = [:]

    private func openEPUB(_ item: MediaItem) async -> (EPUBBook, ZipReader)? {
        let id = Self.mediaID(item), url = item.tracks[0]
        let modified = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let hit = openBooks[id], hit.file == url, hit.modified == modified {
            openBooks[id]?.used = Date()
            return (hit.book, hit.zip)
        }
        guard await shareable(url),
              let opened = await Task.detached(priority: .userInitiated, operation: { EPUBBook.open(url) }).value else { return nil }
        if openBooks.count >= 4, let oldest = openBooks.min(by: { $0.value.used < $1.value.used })?.key { openBooks[oldest] = nil }
        openBooks[id] = (url, modified, opened.0, opened.1, Date())
        return opened
    }

    /// Random tokens that stand for (signed-in device, book). A book's pages are addressed by token, so they load in a
    /// sandboxed frame that sends no cookie; the token stops working when that device's sign-in does (a new PIN).
    @ObservationIgnored private var bookTokens: [String: (book: String, session: String)] = [:]

    private func bookToken(session: String, book: String) -> String {
        if let known = bookTokens.first(where: { $0.value.book == book && $0.value.session == session })?.key { return known }
        if bookTokens.count > 300 { bookTokens.removeAll() }
        let token = Self.newToken()
        bookTokens[token] = (book, session)
        return token
    }

    /// The sign-in behind a /epub/<token>/… address, for telling which device a cookieless book page belongs to.
    private func bookSession(_ path: String) -> String? {
        guard path.hasPrefix("/epub/") else { return nil }
        let token = path.dropFirst("/epub/".count).prefix { $0 != "/" }
        return bookTokens[String(token)]?.session
    }

    /// The media id a token opens, while the device it was given to is still signed in.
    private func bookForToken(_ token: String) -> String? {
        guard let entry = bookTokens[token], pin.isEmpty || sessions.contains(entry.session) else { return nil }
        return entry.book
    }

    nonisolated private static let bookScriptTag = "\"\(digest(Data(WebApp.bookFrameScript.utf8)))\""

    /// /epub/<token>/<path in the zip>, on the archive port. Pages get the reader's small script (by nonce) and a policy
    /// that blocks the book's own scripts, anything from elsewhere, and being framed by anything but Offline Kit's page.
    private func epubFile(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        let rest = req.path.dropFirst("/epub/".count)
        guard let slash = rest.firstIndex(of: "/"),
              let id = bookForToken(String(rest[..<slash])), let item = mediaItem(id), item.kind == .book,
              let (_, zip) = await openEPUB(item) else {
            await res.send(status: 404, text: "Not found"); return
        }
        let entry = String(rest[rest.index(after: slash)...])
        guard let data = await Task.detached(priority: .userInitiated, operation: { zip.data(entry) }).value else {
            await res.send(status: 404, text: "Not in this book."); return
        }
        let ext = (entry as NSString).pathExtension.lowercased()
        let mime = Self.bookMime(ext)
        let nonce = String(Self.newToken().prefix(32))
        var body = data
        if ["xhtml", "xht", "html", "htm"].contains(ext), var page = String(data: data, encoding: .utf8) {
            let tag = #"<script src="/epub-reader.js" nonce="\#(nonce)"></script>"#
            if let head = page.range(of: #"<head\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
                page.insert(contentsOf: tag, at: head.upperBound)
            } else if let html = page.range(of: #"<html\b[^>]*>"#, options: [.regularExpression, .caseInsensitive]) {
                page.insert(contentsOf: "<head>" + tag + "</head>", at: html.upperBound)
            }
            body = Data(page.utf8)
        }
        let me = Self.origin(host: req.headers["host"], port: contentPort)
        let parent = Self.origin(host: req.headers["host"], port: port)
        let policy = "default-src 'self' \(me); script-src 'nonce-\(nonce)'; style-src 'self' \(me) 'unsafe-inline'; "
            + "img-src 'self' \(me) data:; font-src 'self' \(me) data:; media-src 'self' \(me); connect-src 'none'; "
            + "object-src 'none'; base-uri 'none'; form-action 'none'; frame-ancestors \(parent); sandbox allow-scripts"
        await res.send(status: 200, contentType: mime, body: body,
                       headers: ["Content-Security-Policy": policy, "Cache-Control": "private, max-age=600", "Referrer-Policy": "no-referrer"])
    }

    nonisolated private static func bookMime(_ ext: String) -> String {
        switch ext {
        case "xhtml", "xht": "application/xhtml+xml; charset=utf-8"
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "otf", "ttf", "woff", "woff2": "font/\(ext)"
        case "mp3": "audio/mpeg"
        case "m4a", "mp4": "audio/mp4"
        default: "application/octet-stream"
        }
    }

    /// /pdf/<id>/<name>.pdf, on the archive port, for the browser's own PDF viewer (ranges, so big files open quickly).
    private func pdfFile(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        let parts = req.path.dropFirst("/pdf/".count).split(separator: "/", maxSplits: 1).map(String.init)
        if media?.items.isEmpty ?? true, let media, let library { await media.reload(library: library) }
        guard let id = parts.first, let item = mediaItem(id), item.kind == .book, Self.isPDF(item), item.unavailable == nil,
              await shareable(item.tracks[0]) else {
            await res.send(status: 404, text: "Not found"); return
        }
        await res.sendFile(item.tracks[0], contentType: "application/pdf", rangeHeader: req.headers["range"],
                           cacheControl: "private, max-age=300", requestHeaders: req.headers)
    }

    // MARK: Ask

    private func ask(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        let question = ((try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["question"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.count < 2000 else { await res.send(status: 400, json: ["error": "Empty question"]); return }
        guard !askBusy else {
            await res.send(status: 429, json: ["error": "The Mac is answering another question. Try again in a moment."])
            return
        }
        guard let model, let library else { await res.send(status: 503, json: ["error": "Not ready"]); return }
        askBusy = true
        defer { askBusy = false }

        await res.startEventStream()
        model.libraryFolders = library.folders
        guard let engine = await model.resolveEngine() else {
            await res.event("error", "No answer model is ready on the Mac. Download the answer model in Get Resources on the Mac, or turn on Apple Intelligence.")
            res.finish()
            return
        }
        // Each event reports whether the device is still there; once it's gone, stop so the Mac isn't
        // generating for nobody and other devices can ask (returning ends the stream, which cancels the engine).
        guard await res.event("engine", engine.displayName) else { res.finish(); return }
        var budget = engine.sourceBudget
        let archives = library.books.map(\.archive)
        var sources = await Task.detached(priority: .userInitiated) {
            Retriever.retrieve(question: question, archives: archives, budgetChars: budget)
        }.value
        guard await res.event("sources", sources.map(Self.sourceJSON)) else { res.finish(); return }

        for attempt in 0..<3 {
            do {
                var last = Date.distantPast
                var text = ""
                for try await partial in engine.stream(instructions: AskModel.instructions,
                                                       prompt: AskModel.prompt(question: question, sources: sources)) {
                    text = partial
                    if Date().timeIntervalSince(last) > 0.08 {
                        last = Date()
                        // Leaving the loop terminates the engine's stream, which cancels generation.
                        guard await res.event("answer", text) else { res.finish(); return }
                    }
                }
                guard await res.event("answer", text), await res.event("done", true) else { res.finish(); return }
                questionsAnswered += 1
                break
            } catch where (AppleEngine.isContextOverflow(error) || LlamaError.isContextOverflow(error)) && attempt < 2 && sources.count > 1 {
                budget /= 2
                sources = Array(sources.prefix(max(1, sources.count / 2)))
                await res.event("sources", sources.map(Self.sourceJSON))
            } catch {
                await res.event("error", error.localizedDescription)
                break
            }
        }
        res.finish()
    }

    nonisolated private static func sourceJSON(_ s: Source) -> [String: Any] {
        ["n": s.id, "title": s.ref.title, "book": s.bookTitle, "url": contentURL(id: s.ref.bookID, path: s.ref.path)]
    }
}
