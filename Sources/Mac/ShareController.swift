import SwiftUI
import Network
import SystemConfiguration
import CoreImage
import CoreImage.CIFilterBuiltins

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
            enabled ? start() : stop()
        }
    }
    var pin: String {
        didSet {
            KitSettings.shared.set(pin, forKey: "sharePIN")
            sessions.removeAll()   // a new PIN signs everyone out
        }
    }
    /// Signed-in browsers and devices: random tokens handed out at sign-in, never the PIN itself.
    @ObservationIgnored private var sessions = Set<String>()
    /// Wrong PINs in a row from each device, and when it may guess again (the wait doubles after the fifth miss).
    /// Per device, so one device guessing can't lock the rest of the household out.
    @ObservationIgnored private var failedLogins: [String: Int] = [:]
    @ObservationIgnored private var lockedUntil: [String: Date] = [:]

    @ObservationIgnored private var server: WebServer?
    /// Archive pages are served from a second port, a separate web origin: scripts inside an archive can't read
    /// or drive the sharing controls on the main port, even though the browser is signed in to both.
    @ObservationIgnored private var contentServer: WebServer?
    @ObservationIgnored private var contentPort: UInt16 = 0
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private weak var model: AskModel?
    @ObservationIgnored private weak var media: MediaLibrary?
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
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "shareOnLaunch") { start(); return }   // test hook; does not change the saved setting
        #endif
        if enabled { start() }
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
        // Changes come only from Offline Kit's own page and apps: JSON, sent from this same address.
        if req.method == "POST" {
            let json = (req.headers["content-type"] ?? "").lowercased().hasPrefix("application/json")
            let sameOrigin = req.headers["origin"].map { $0.lowercased() == "http://" + (req.headers["host"] ?? "").lowercased() } ?? true
            guard json, sameOrigin else { await res.send(status: 403, json: ["error": "forbidden"]); return }
        }
        recentDevices[req.remoteHost] = Date()

        // Pages that work before the PIN is entered.
        switch (req.method, req.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            await res.send(status: 200, contentType: "text/html; charset=utf-8", body: Data(WebApp.html.utf8))
            return
        case ("GET", "/assets/watch-forest.jpg"):
            guard let url = Bundle.main.url(forResource: "watch-forest", withExtension: "jpg") else {
                await res.send(status: 404, text: ""); return
            }
            await res.sendFile(url, contentType: "image/jpeg", rangeHeader: req.headers["range"])
            return
        case ("GET", "/favicon.ico"):
            await res.send(status: 404, text: "")
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
        case ("POST", "/api/media/progress"):
            await mediaProgress(req, res)
        case ("GET", let path) where path.hasPrefix("/media/"):
            await mediaFile(path: path, range: req.headers["range"], res)
        case (_, let path) where path == "/api/send" || path.hasPrefix("/api/send/"):
            await SendList.shared.handle(req, res, macName: Host.current().localizedName ?? "Mac")   // Send to iPhone
        default:
            await res.send(status: 404, text: "Not found")
        }
    }

    private func status() -> [String: Any] {
        let model = self.model
        let engine = model?.engineLabel(libraryFolders: library?.folders ?? []).name ?? "No answer model yet"
        let books = library?.books ?? []
        return ["name": Host.current().localizedName ?? "Mac", "archives": books.count,
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

    /// Checks the PIN. Right answers get a random session token as the cookie; wrong ones count toward a lockout
    /// that applies to every device, so guessing a 4-digit PIN takes days rather than seconds.
    private func login(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        if pin.isEmpty { await res.send(json: ["ok": true]); return }
        let device = req.remoteHost
        if let until = lockedUntil[device], Date() < until {
            await res.send(status: 429, json: ["ok": false, "error": "wait", "seconds": Int(until.timeIntervalSinceNow.rounded(.up))])
            return
        }
        let sent = (try? JSONSerialization.jsonObject(with: req.body) as? [String: String])?["pin"] ?? ""
        if Self.constantTimeEqual(sent, pin) {
            failedLogins[device] = nil
            let token = Self.newToken()
            sessions.insert(token)
            await res.send(json: ["ok": true, "token": token],
                           headers: ["Set-Cookie": "okpin=\(token); Path=/; SameSite=Strict; HttpOnly"])
        } else {
            let misses = (failedLogins[device] ?? 0) + 1
            failedLogins[device] = misses
            if misses >= 5 { lockedUntil[device] = Date().addingTimeInterval(min(3600, 15 * pow(2, Double(misses - 5)))) }
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
        let home = Self.origin(host: req.headers["host"], port: port) + "/"
        if !pin.isEmpty && !(req.cookies["okpin"].map { sessions.contains($0) } ?? false) {
            await res.redirect(to: home)
            return
        }
        switch (req.method, req.path) {
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

    private func mediaList(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        guard let media, let library else { await res.send(status: 503, json: ["error": "Not ready"]); return }
        // Served from what's already loaded: the library rescans itself when files change (LibraryWatcher, ScanGate).
        // Only a library that hasn't been read yet this launch is scanned here.
        if media.items.isEmpty { await media.reload(library: library) }
        // Books aren't sent: the web view and Apple TV can't open them yet.
        // Linked media on an unplugged drive isn't sent: phones and the Apple TV couldn't play it.
        let items: [[String: Any]] = media.items.filter { $0.kind != .book && $0.unavailable == nil }.map { item in
            let id = Self.mediaID(item)
            let info = media.info[item.progressKey]
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
            entry["related"] = MediaCatalog.related(to: item, items: media.items.filter { $0.kind != .book }, info: media.info).prefix(12).map(Self.mediaID)
            if let next = MediaCatalog.nextVideo(after: item, items: media.items, info: media.info, progress: media.progress) { entry["upNext"] = Self.mediaID(next) }
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
            if let p = media.progress[item.progressKey] {
                entry["progress"] = ["track": p.track, "seconds": p.seconds, "finished": p.finished, "updated": p.updated?.timeIntervalSince1970 ?? 0]
            }
            return entry
        }
        // The same banner and rows as Watch & Listen on the Mac.
        let available = media.items.filter { $0.kind != .book && $0.unavailable == nil }
        let filter = MediaFilter(rawValue: req.query["filter"] ?? "all") ?? .all
        let sort = MediaSort(rawValue: req.query["sort"] ?? "title") ?? .title
        let genre = req.query["genre"].flatMap { $0.isEmpty ? nil : $0 }
        let query = req.query["q"] ?? ""
        let unfinished = req.query["unfinished"] == "true"
        let catalog = MediaCatalog.build(items: available, progress: media.progress, info: media.info, filter: filter,
                                         genre: genre, query: query, sort: sort, unfinished: unfinished)
        let results = MediaCatalog.select(available, info: media.info, progress: media.progress, filter: filter,
                                          genre: genre, query: query, sort: sort, unfinished: unfinished)
        var body: [String: Any] = [
            "name": Host.current().localizedName ?? "Mac", "items": items,
            "results": results.map(Self.mediaID),
            "songs": MediaCatalog.songs(results.filter { MediaCatalog.category($0, media.info[$0.progressKey]) == .music }, info: media.info, query: query, sort: sort)
                .map { ["item": Self.mediaID($0.item), "index": $0.index] as [String: Any] },
            "genres": MediaCatalog.genres(available, info: media.info, filter: filter),
            "artists": Dictionary(grouping: results.filter { MediaCatalog.category($0, media.info[$0.progressKey]) == .music }, by: { MediaCatalog.creator(media.info[$0.progressKey]) })
                .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { ["name": $0.key, "items": $0.value.map(Self.mediaID)] as [String: Any] },
            "shelves": catalog.shelves.map { ["title": $0.title, "items": $0.items.map(Self.mediaID)] },
        ]
        if let featured = catalog.featured { body["featured"] = Self.mediaID(featured) }
        await res.send(json: body)
    }

    /// {"id": "...", "track": 2, "seconds": 812.5, "finished": false}
    private func mediaProgress(_ req: WebServer.Request, _ res: WebServer.Responder) async {
        guard let body = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any],
              let id = body["id"] as? String, let item = mediaItem(id) else {
            await res.send(status: 404, json: ["error": "Unknown item"]); return
        }
        let track = min(max(0, body["track"] as? Int ?? 0), item.tracks.count - 1)
        let seconds = max(0, (body["seconds"] as? Double) ?? Double(body["seconds"] as? Int ?? 0))
        media?.saveProgress(MediaProgress(track: track, seconds: seconds, finished: body["finished"] as? Bool ?? false), for: item)
        await res.send(json: ["ok": true])
    }

    /// /media/<id>/<track index> or /media/<id>/cover
    private func mediaFile(path: String, range: String?, _ res: WebServer.Responder) async {
        let parts = path.dropFirst("/media/".count).split(separator: "/").map(String.init)
        if media?.items.isEmpty ?? true, let media, let library { await media.reload(library: library) }
        guard parts.count == 2, let item = mediaItem(parts[0]) else { await res.send(status: 404, text: "Not found"); return }
        let url: URL
        if parts[1] == "cover", let cover = item.cover { url = cover }
        else if parts[1] == "thumb", let thumb = item.cover?.path ?? media?.info[item.progressKey]?.thumb { url = URL(fileURLWithPath: thumb) }
        else if let index = Int(parts[1]), item.tracks.indices.contains(index) { url = item.tracks[index] }
        else { await res.send(status: 404, text: "Not found"); return }
        // Only real files that stay where the library is: a link on a drive can't hand out this Mac's files.
        let isFile = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        guard isFile, !SharePolicy.isOffLimits(url),
              SharePolicy.real(url).hasPrefix(SharePolicy.real(KitLocation.caches) + "/") || SharePolicy.staysOnDrive(url, libraryRoot: item.root) else {
            await res.send(status: 404, text: "Not found"); return
        }
        await res.sendFile(url, contentType: Self.mimeType(url), rangeHeader: range)
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
