import Foundation
import Observation
import CryptoKit

/// Who is using "Share on Wi-Fi": every phone, tablet, PC and app that has connected, what each is doing, and the
/// Mac's controls over them (sign out, block, approve new devices).
///
/// How a device is told apart, strongest first:
/// - its Wi-Fi/Ethernet hardware address (MAC) from this Mac's neighbor tables, when it's on the same network segment;
/// - a long-lived random id in an HttpOnly cookie (`okdev`), set on the first response that lacks one;
/// - the sign-in token it holds (the iPhone app sends its own);
/// - its IP address and kind of browser or app, for clients that keep no cookies.
///
/// None of these grants anything: access is still the PIN (and approval, when that's on). They only decide which row a
/// request belongs to, and what the Mac refuses. Blocks are checked before any routing, right after the Host check.
@MainActor @Observable
final class ShareDevices {
    static let shared = ShareDevices()

    // MARK: Model

    enum Kind: String, Codable, Sendable {
        case iPhone, iPad, androidPhone, androidTablet, mac, windows, chromebook, linux, appleTV, iPhoneApp, commandLine, unknown

        var symbol: String {
            switch self {
            case .iPhone, .iPhoneApp: "iphone"
            case .iPad: "ipad"
            case .androidPhone: "smartphone"
            case .androidTablet: "flipphone"
            case .mac: "laptopcomputer"
            case .windows, .linux: "pc"
            case .chromebook: "laptopcomputer"
            case .appleTV: "appletv"
            case .commandLine: "terminal"
            case .unknown: "questionmark.square.dashed"
            }
        }
    }

    struct Event: Identifiable, Hashable, Sendable {
        let id = UUID()
        let date: Date
        let symbol: String
        let text: String
    }

    struct Activity: Hashable, Sendable {
        var symbol: String
        var text: String
        var since: Date
    }

    struct Device: Identifiable, Hashable, Sendable {
        let id: String
        var cookieIDs: Set<String> = []
        var macs: Set<String> = []
        /// Most recent first.
        var ips: [String] = []
        var userAgent = ""
        var autoName = "Unknown device"
        var kind: Kind = .unknown
        /// The name the iPhone app reports for Send to iPhone ("Joey's iPhone"). Memory only.
        var appName: String?
        var nickname: String?
        var firstSeen: Date
        var lastSeen: Date
        var thisMac = false
        /// Sign-in tokens this device was handed or has used.
        var tokens: Set<String> = []
        var activity: Activity?
        var history: [Event] = []
        var bytesSent: Int64 = 0
        var openRequests = 0
        /// When it first asked to be let in, while "Ask before new devices connect" is on and it hasn't been allowed.
        var waitingSince: Date?

        var name: String {
            if let nickname, !nickname.isEmpty { return nickname }
            if let appName { return "Offline Kit on iPhone (\(appName))" }
            return autoName
        }
        var symbol: String { kind.symbol }
    }

    private(set) var devices: [String: Device] = [:]

    // Blocks: hardware addresses and device/cookie ids are kept; IP addresses only until the app quits (addresses are
    // handed to other devices later). Loopback is never blocked by address: that would block this Mac's own browser.
    private(set) var blockedIDs: Set<String> = []
    private(set) var blockedMACs: Set<String> = []
    private var blockedIPs: Set<String> = []

    // Approvals, in this Mac's own settings (never a drive's): remembered, and "allow once" for this run.
    private var approvedIDs: Set<String> = []
    private var approvedMACs: Set<String> = []
    private var onceIDs: Set<String> = []
    private var onceMACs: Set<String> = []
    private(set) var askFirst = false

    /// Devices waiting for the Mac to allow them, oldest first.
    var pending: [Device] {
        devices.values.filter { $0.waitingSince != nil && !isBlocked($0) && -$0.lastSeen.timeIntervalSinceNow < Self.pendingTimeout }
            .sorted { ($0.waitingSince ?? .distantPast) < ($1.waitingSince ?? .distantPast) }
    }

    static let onlineWindow: TimeInterval = 120
    static let pendingTimeout: TimeInterval = 120
    static let forgetAfter: TimeInterval = 30 * 24 * 3600
    static let maxDevices = 300
    static let historyLimit = 20

    @ObservationIgnored private weak var share: ShareController?
    @ObservationIgnored private weak var library: Library?
    @ObservationIgnored private weak var media: MediaLibrary?
    @ObservationIgnored private var isSignedIn: (String) -> Bool = { _ in false }
    @ObservationIgnored private var revoke: (Set<String>) -> Void = { _ in }
    @ObservationIgnored private var revokeAll: () -> Void = {}
    /// IP + kind of client → device, for clients that keep no cookie. This run only.
    @ObservationIgnored private var fallback: [String: String] = [:]
    /// The device each open response belongs to (for sign-in, bytes and the game-streaming hook).
    @ObservationIgnored private var responders: [ObjectIdentifier: String] = [:]
    /// The activity each device was last given by setActivity (a game), so ending it never clears a newer one.
    @ObservationIgnored private var externalActivity: [String: String] = [:]
    /// Bytes per open Send to iPhone download, for "312 MB so far".
    @ObservationIgnored private var transfers: [ObjectIdentifier: Int64] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var savedAt = Date.distantPast

    var isSharing: Bool { share?.isRunning ?? false }
    var hasPIN: Bool { !(share?.pin.isEmpty ?? true) }

    init() { load() }

    /// Called once by ShareController. The closures reach its private sign-in sessions; nothing else does.
    func attach(share: ShareController, library: Library, media: MediaLibrary,
                isSignedIn: @escaping (String) -> Bool, revoke: @escaping (Set<String>) -> Void, revokeAll: @escaping () -> Void) {
        self.share = share
        self.library = library
        self.media = media
        self.isSignedIn = isSignedIn
        self.revoke = revoke
        self.revokeAll = revokeAll
        #if DEBUG
        // Test hook: -openDevices YES opens the Connected Devices window at launch.
        if UserDefaults.standard.bool(forKey: "openDevices") {
            Task { @MainActor in try? await Task.sleep(for: .seconds(1)); ShareDevicesWindow.show(share: share) }
        }
        // Test hook (test home only): -shareDeviceActions "20:block:Edge,30:signout:Safari,40:allow:Android" runs the
        // window's actions at those seconds after launch on the first device whose name contains the text.
        if KitLocation.testHome != nil, let script = UserDefaults.standard.string(forKey: "shareDeviceActions") {
            Task { @MainActor in
                var elapsed = 0.0
                let steps: [[String]] = script.split(separator: ",").map { part -> [String] in
                    part.split(separator: ":", maxSplits: 2).map(String.init)
                }.filter { $0.count == 3 }
                for step in steps {
                    let at = Double(step[0]) ?? 0
                    try? await Task.sleep(for: .seconds(max(0, at - elapsed)))
                    elapsed = at
                    guard let device = self.devices.values.sorted(by: { $0.lastSeen > $1.lastSeen }).first(where: { $0.name.contains(step[2]) }) else {
                        NSLog("DEVICE-ACTION %@: no device matching %@", step[1], step[2]); continue
                    }
                    switch step[1] {
                    case "block": self.block(device.id)
                    case "unblock": self.unblock(device.id)
                    case "signout": self.signOut(device.id)
                    case "signoutall": self.signOutEveryone()
                    case "allow": self.allow(device.id, remember: true)
                    case "allowonce": self.allow(device.id, remember: false)
                    case "rename": self.rename(device.id, to: "Kids' tablet")
                    case "forget": self.forget(device.id)
                    default: break
                    }
                    NSLog("DEVICE-ACTION %@ done", step[1])
                }
            }
        }
        // Test hook: -neighborCheck YES logs how many IPv4/IPv6 neighbors the lookup sees and a digest of the
        // "ip mac" lines, to compare with `arp -an` / `ndp -an` without printing anyone's addresses.
        if UserDefaults.standard.bool(forKey: "neighborCheck") {
            Task.detached {
                let table = NeighborTable.read()
                for v6 in [false, true] {
                    let lines = table.filter { $0.key.contains(":") == v6 }.map { "\($0.key) \($0.value)" }.sorted().joined(separator: "\n")
                    let digest = SHA256.hash(data: Data(lines.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
                    NSLog("NEIGHBORS %@ count=%d digest=%@", v6 ? "v6" : "v4", table.filter { $0.key.contains(":") == v6 }.count, digest)
                }
            }
        }
        #endif
    }

    // MARK: Requests

    enum Port { case main, content }

    /// Every request on both ports passes through here first, right after the Host check. Works out which device sent
    /// it, records what it's doing, and answers it itself when the device is blocked or still waiting for approval.
    /// Returns false when the request has been answered and routing must stop.
    /// `session`: a sign-in the request carries some other way than its cookie (a book page in a sandboxed frame
    /// sends no cookies; its address holds a token tied to the device's sign-in).
    func admit(_ req: WebServer.Request, _ res: WebServer.Responder, port: Port, session: String? = nil) async -> Bool {
        let ip = NeighborTable.normalize(req.remoteHost) ?? ShareDeviceKey.key(req.remoteHost)
        let mac = await NeighborTable.shared.mac(for: req.remoteHost)
        let thisMac = await NeighborTable.shared.isThisMac(req.remoteHost)
        let ua = String((req.headers["user-agent"] ?? "").prefix(300))
        let cookie = req.cookies["okdev"].flatMap { Self.isDeviceID($0) ? $0 : nil }
        let token = (req.cookies["okpin"] ?? session).flatMap { isSignedIn($0) ? $0 : nil }

        let id = identify(ip: ip, ua: ua, cookie: cookie, token: token, mac: mac, thisMac: thisMac)
        let now = Date()
        var device = devices[id]!
        if device.ips.first != ip { device.ips.removeAll { $0 == ip }; device.ips.insert(ip, at: 0); device.ips = Array(device.ips.prefix(4)) }
        if let mac { device.macs.insert(mac) }
        if let cookie { device.cookieIDs.insert(cookie) }
        if let token { device.tokens.insert(token) }
        if !ua.isEmpty, device.userAgent != ua, Self.kind(ua: ua, path: req.path).kind != .unknown || device.userAgent.isEmpty {
            device.userAgent = ua
            let described = Self.kind(ua: ua, path: req.path)
            // An app's own requests and its video player differ: keep the more telling name.
            if !(device.kind == .appleTV && described.kind != .appleTV) { device.kind = described.kind; device.autoName = described.name }
        }
        if device.kind == .unknown || device.kind == .iPhoneApp || device.kind == .appleTV, Self.isOfflineKitApp(ua) {
            if req.path.hasPrefix("/api/send") { device.kind = .iPhoneApp; device.autoName = "Offline Kit on iPhone" }
            else if req.path == "/api/media" && device.kind != .iPhoneApp { device.kind = .appleTV; device.autoName = "Apple TV app" }
        }
        device.thisMac = thisMac
        if now.timeIntervalSince(device.lastSeen) > 2 || device.lastSeen == device.firstSeen { device.lastSeen = now }
        devices[id] = device
        if now.timeIntervalSince(savedAt) > 60 { scheduleSave() }   // last-seen times, at most about once a minute

        // Blocked: everything that names this device now counts, so clearing cookies or a new address doesn't get it back in.
        if isBlocked(device) || blockedMACs.contains(mac ?? "") || blockedIPs.contains(ip) {
            block(id, revokeSessions: true, record: false)
            var refused = devices[id]!
            if refused.activity?.text != "Blocked" { record(&refused, symbol: "hand.raised.fill", text: "Blocked") }
            devices[id] = refused
            offerCookie(res, id: id, had: cookie, port: port)
            res.closeAfterResponse()   // a blocked device's connection doesn't stay open for its next try
            await Self.sendRefusal(req, res, status: "blocked", message: "This device has been blocked on the Mac.")
            return false
        }

        // Waiting for approval: in addition to the PIN, never instead of it.
        if askFirst && !isApproved(device, mac: mac, cookie: cookie) {
            var waiting = devices[id]!
            if waiting.waitingSince == nil {
                waiting.waitingSince = now
                record(&waiting, symbol: "hourglass", text: "Asked to connect")
            }
            devices[id] = waiting
            ShareApprovalPanel.update()
            offerCookie(res, id: id, had: cookie, port: port)
            await Self.sendRefusal(req, res, status: "waiting", message: "Waiting for the Mac to allow this device…")
            return false
        }
        if devices[id]?.waitingSince != nil { devices[id]?.waitingSince = nil; ShareApprovalPanel.update() }

        offerCookie(res, id: id, had: cookie, port: port)
        track(res, device: id, download: port == .main && req.path.hasPrefix("/api/send/file/"))
        // Until it's signed in (with a PIN set), the only thing it can be doing is signing in.
        let signedIn = !hasPIN || token != nil
        if let activity = signedIn ? describe(req, port: port) : (req.path == "/" ? ("lock", "On the sign-in page") : nil) {
            var current = devices[id]!
            record(&current, symbol: activity.symbol, text: activity.text)
            devices[id] = current
        }
        if signedIn, req.method == "POST", req.path == "/api/send/received",
           let name = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["device"] as? String {
            let clean = String(name.filter { !$0.isNewline && $0.asciiValue.map { $0 >= 32 } ?? true }.prefix(60)).trimmingCharacters(in: .whitespaces)
            if !clean.isEmpty { devices[id]?.appName = clean; devices[id]?.kind = .iPhoneApp }
        }
        return true
    }

    /// A right PIN: the token belongs to the device that sent it (ShareController.login).
    func signedIn(token: String, _ res: WebServer.Responder) {
        guard let id = responders[ObjectIdentifier(res)], var device = devices[id] else { return }
        device.tokens.insert(token)
        record(&device, symbol: "lock.open.fill", text: "Signed in with the PIN")
        devices[id] = device
    }

    /// The device an open response belongs to, for code that answers requests (the game-streaming socket, for one).
    func deviceID(for res: WebServer.Responder) -> String? { responders[ObjectIdentifier(res)] }

    /// What a device is doing, for activity the request path alone doesn't show (playing a streamed game, for one).
    /// Pass nil when it ends: only the activity set here is cleared, so one recorded since stays ("Signed out from the
    /// Mac" or "Blocked from the Mac", which close a game's socket just before it reports it closed).
    func setActivity(device id: String, symbol: String = "gamecontroller.fill", text: String?) {
        guard var device = devices[id] else { return }
        if let text {
            let clipped = String(text.prefix(120))
            record(&device, symbol: symbol, text: clipped)
            externalActivity[id] = clipped
        } else if let set = externalActivity.removeValue(forKey: id), device.activity?.text == set {
            device.activity = nil
        }
        device.lastSeen = Date()
        devices[id] = device
    }

    /// "Playing <game>".
    func setPlaying(device id: String, game: String) { setActivity(device: id, symbol: "gamecontroller.fill", text: "Playing \(game)") }

    // MARK: Identity

    /// 64 lowercase hex characters: what `okdev` cookies look like. Anything else is ignored.
    nonisolated static func isDeviceID(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    nonisolated static func newID() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            return SHA256.hash(data: Data((UUID().uuidString + UUID().uuidString).utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// The device a request belongs to: by its cookie, then its hardware address, then its sign-in token, then its
    /// IP and kind of client. Creates one when nothing matches, and joins records that turn out to be the same device.
    private func identify(ip: String, ua: String, cookie: String?, token: String?, mac: String?, thisMac: Bool) -> String {
        let family = Self.kind(ua: ua, path: "").name
        let fallbackKey = ip + "|" + family
        let byCookie = cookie.flatMap { c in devices.values.first { $0.id == c || $0.cookieIDs.contains(c) }?.id }
        let byMAC = mac.flatMap { m in devices.values.filter { $0.macs.contains(m) }.max { $0.lastSeen < $1.lastSeen }?.id }
        let byToken = token.flatMap { t in devices.values.first { $0.tokens.contains(t) }?.id }
        let byFallback = fallback[fallbackKey].flatMap { devices[$0] != nil ? $0 : nil }

        var id: String
        if let byCookie {
            id = byCookie
            // The same hardware address under another record: the same device (cookies cleared, or seen before its address
            // was known). Two different kinds of client behind one address (a Wi-Fi extender that shares its own) stay apart.
            if let byMAC, byMAC != byCookie, devices[byMAC]?.autoName == devices[byCookie]?.autoName { merge(byMAC, into: byCookie) }
        } else if let found = byMAC ?? byToken ?? byFallback {
            id = found
        } else {
            id = cookie ?? Self.newID()
            let now = Date()
            devices[id] = Device(id: id, cookieIDs: [id], firstSeen: now, lastSeen: now)
            pruneIfNeeded()
            scheduleSave()
        }
        if let cookie, devices[id]?.cookieIDs.contains(cookie) == false { devices[id]?.cookieIDs.insert(cookie); scheduleSave() }
        if fallback.count > 2000 { fallback.removeAll() }
        fallback[fallbackKey] = id
        return id
    }

    /// Folds one record into another: blocked if either was, the earlier first-seen, both sets of names for it.
    private func merge(_ from: String, into: String) {
        guard let old = devices[from], var keep = devices[into] else { return }
        keep.cookieIDs.formUnion(old.cookieIDs)
        keep.macs.formUnion(old.macs)
        keep.tokens.formUnion(old.tokens)
        keep.firstSeen = min(keep.firstSeen, old.firstSeen)
        keep.bytesSent += old.bytesSent
        keep.history = Array((keep.history + old.history).sorted { $0.date > $1.date }.prefix(Self.historyLimit))
        if keep.nickname == nil { keep.nickname = old.nickname }
        if keep.appName == nil { keep.appName = old.appName }
        let wasBlocked = blockedIDs.contains(from)
        devices[from] = nil
        devices[into] = keep
        for (key, value) in fallback where value == from { fallback[key] = into }
        for (key, value) in responders where value == from { responders[key] = into }
        if wasBlocked { block(into, revokeSessions: true, record: false) }
        scheduleSave()
    }

    private func offerCookie(_ res: WebServer.Responder, id: String, had cookie: String?, port: Port) {
        // Only the main port sets it (the archive port is another origin, and reads the same cookie anyway).
        guard port == .main, cookie == nil else { return }
        res.extraHeaders.append(("Set-Cookie", "okdev=\(id); Path=/; Max-Age=63072000; SameSite=Strict; HttpOnly"))
    }

    // MARK: Bytes and open requests

    private func track(_ res: WebServer.Responder, device id: String, download: Bool) {
        let key = ObjectIdentifier(res)
        responders[key] = id
        if download { transfers[key] = 0 }
        devices[id]?.openRequests += 1
        res.onBytes = { count in
            Task { @MainActor in ShareDevices.shared.sent(count, device: id, key: key) }
        }
        res.onFinish = {
            Task { @MainActor in ShareDevices.shared.finished(device: id, key: key) }
        }
    }

    private func sent(_ count: Int64, device id: String, key: ObjectIdentifier) {
        devices[id]?.bytesSent += count
        devices[id]?.lastSeen = Date()
        if transfers[key] != nil { transfers[key]! += count }
    }

    private func finished(device id: String, key: ObjectIdentifier) {
        responders[key] = nil
        transfers[key] = nil
        if let open = devices[id]?.openRequests { devices[id]?.openRequests = max(0, open - 1) }
    }

    /// Bytes of the Send to iPhone downloads this device has open right now, or nil when it has none.
    func downloading(_ id: String) -> Int64? {
        let open = transfers.filter { responders[$0.key] == id }
        return open.isEmpty ? nil : open.values.reduce(0, +)
    }

    // MARK: State

    func isOnline(_ device: Device) -> Bool { device.openRequests > 0 || -device.lastSeen.timeIntervalSinceNow < Self.onlineWindow }

    func isBlocked(_ device: Device) -> Bool {
        blockedIDs.contains(device.id) || !device.cookieIDs.isDisjoint(with: blockedIDs) || !device.macs.isDisjoint(with: blockedMACs)
    }

    func isSignedIn(_ device: Device) -> Bool { hasPIN && device.tokens.contains(where: isSignedIn) }

    func isApproved(_ device: Device) -> Bool { isApproved(device, mac: device.macs.first, cookie: nil) }

    /// With a hardware address known, that address must be allowed (a device that reset its private Wi-Fi address asks
    /// again). Without one, the cookie or the record itself.
    private func isApproved(_ device: Device, mac: String?, cookie: String?) -> Bool {
        if let mac { return approvedMACs.contains(mac) || onceMACs.contains(mac) }
        let ids = approvedIDs.union(onceIDs)
        if let cookie { return ids.contains(cookie) }
        return ids.contains(device.id) || !device.cookieIDs.isDisjoint(with: ids)
    }

    var online: [Device] { devices.values.filter { isOnline($0) && !isBlocked($0) && $0.waitingSince == nil }.sorted { $0.lastSeen > $1.lastSeen } }
    var recent: [Device] { devices.values.filter { !isOnline($0) && !isBlocked($0) && $0.waitingSince == nil }.sorted { $0.lastSeen > $1.lastSeen } }
    var blocked: [Device] { devices.values.filter(isBlocked).sorted { $0.lastSeen > $1.lastSeen } }

    // MARK: Actions

    /// Revokes this device's sign-ins; with a PIN set it has to enter it again.
    func signOut(_ id: String) {
        guard var device = devices[id] else { return }
        revoke(device.tokens)
        device.tokens.removeAll()
        record(&device, symbol: "lock.fill", text: "Signed out from the Mac")
        devices[id] = device
    }

    func signOutEveryone() {
        revokeAll()
        for id in devices.keys { devices[id]?.tokens.removeAll() }
    }

    /// Refuses everything from this device (its ids, hardware addresses and current IP) and signs it out.
    func block(_ id: String) { block(id, revokeSessions: true, record: true) }

    private func block(_ id: String, revokeSessions: Bool, record shouldRecord: Bool) {
        guard var device = devices[id] else { return }
        GameStreamHub.shared.signOut(deviceID: id)   // a game it's playing ends too, PIN or not
        let before = (blockedIDs.count, blockedMACs.count)
        blockedIDs.insert(id)
        blockedIDs.formUnion(device.cookieIDs)
        blockedMACs.formUnion(device.macs)
        for ip in device.ips where !Self.isLoopback(ip) { blockedIPs.insert(ip) }
        // Blocked is the opposite of allowed.
        approvedIDs.subtract(device.cookieIDs); approvedIDs.remove(id); onceIDs.subtract(device.cookieIDs); onceIDs.remove(id)
        approvedMACs.subtract(device.macs); onceMACs.subtract(device.macs)
        if revokeSessions { revoke(device.tokens); device.tokens.removeAll() }
        device.waitingSince = nil
        if shouldRecord { record(&device, symbol: "hand.raised.fill", text: "Blocked from the Mac") }
        devices[id] = device
        if before != (blockedIDs.count, blockedMACs.count) || shouldRecord { saveTrusted(); scheduleSave() }
        ShareApprovalPanel.update()
    }

    func unblock(_ id: String) {
        guard var device = devices[id] else { return }
        blockedIDs.remove(id)
        blockedIDs.subtract(device.cookieIDs)
        blockedMACs.subtract(device.macs)
        blockedIPs.subtract(device.ips)
        record(&device, symbol: "hand.thumbsup", text: "Unblocked")
        devices[id] = device
        saveTrusted()
        scheduleSave()
    }

    /// Lets a waiting device in: remembered (by its hardware address and cookie), or just until the app quits.
    func allow(_ id: String, remember: Bool) {
        guard var device = devices[id] else { return }
        if remember {
            approvedIDs.insert(id); approvedIDs.formUnion(device.cookieIDs); approvedMACs.formUnion(device.macs)
        } else {
            onceIDs.insert(id); onceIDs.formUnion(device.cookieIDs); onceMACs.formUnion(device.macs)
        }
        device.waitingSince = nil
        record(&device, symbol: "checkmark.circle", text: remember ? "Allowed on the Mac" : "Allowed once on the Mac")
        devices[id] = device
        if remember { saveTrusted() }
        ShareApprovalPanel.update()
    }

    /// Takes back an approval: with "Ask before new devices connect" on, it has to be allowed again.
    func revokeApproval(_ id: String) {
        guard let device = devices[id] else { return }
        approvedIDs.remove(id); approvedIDs.subtract(device.cookieIDs); approvedMACs.subtract(device.macs)
        onceIDs.remove(id); onceIDs.subtract(device.cookieIDs); onceMACs.subtract(device.macs)
        saveTrusted()
    }

    func rename(_ id: String, to name: String) {
        let clean = Self.cleanNickname(name)
        devices[id]?.nickname = clean.isEmpty ? nil : clean
        scheduleSave()
    }

    /// Removes a device from the list. Blocked devices are unblocked first (so a block is never left where it can't be seen).
    func forget(_ id: String) {
        guard let device = devices[id], !isBlocked(device) else { return }
        revokeApproval(id)
        devices[id] = nil
        for (key, value) in fallback where value == id { fallback[key] = nil }
        scheduleSave()
    }

    func setAskFirst(_ on: Bool) {
        askFirst = on
        // When this is turned on, devices already using the Mac are allowed, so no one is cut off mid-movie.
        if on {
            for device in online where !isApproved(device) {
                approvedIDs.insert(device.id); approvedIDs.formUnion(device.cookieIDs); approvedMACs.formUnion(device.macs)
            }
        }
        saveTrusted()
        ShareApprovalPanel.update()
    }

    func stopSharing() { share?.enabled = false }

    // MARK: Activity

    private func record(_ device: inout Device, symbol: String, text: String) {
        let now = Date()
        // A new line in the history only when the activity changes (a movie is many requests, not many events).
        if device.activity?.text != text || now.timeIntervalSince(device.activity?.since ?? .distantPast) > 1800 {
            device.history.insert(Event(date: now, symbol: symbol, text: text), at: 0)
            if device.history.count > Self.historyLimit { device.history.removeLast(device.history.count - Self.historyLimit) }
            device.activity = Activity(symbol: symbol, text: text, since: now)
        }
    }

    /// What a request means, in plain words. Nil for requests that don't change what the device is doing (artwork,
    /// status checks, an archive page's images).
    private func describe(_ req: WebServer.Request, port: Port) -> (symbol: String, text: String)? {
        let path = req.path
        if port == .content {
            if path.hasPrefix("/book/") { return ("books.vertical", "Opening \(archiveTitle(String(path.dropFirst(6))))") }
            guard path.hasPrefix("/content/") else { return nil }
            let rest = path.dropFirst("/content/".count)
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            let id = String(rest[..<slash]), entry = String(rest[rest.index(after: slash)...])
            guard Self.isArticle(entry) else { return nil }
            let title = (entry.split(separator: "/").last.map(String.init) ?? entry)
                .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".html", with: "").replacingOccurrences(of: ".htm", with: "")
            return ("doc.text", "Reading “\(title.prefix(80))” in \(archiveTitle(id))")
        }
        switch (req.method, path) {
        case ("GET", "/"), ("GET", "/index.html"): return ("safari", "Browsing the library")
        case ("POST", "/api/login"): return nil
        case ("GET", "/api/search"): return ("magnifyingglass", "Searching the library")
        case ("POST", "/api/ask"): return ("sparkles", "Asking a question")
        case ("GET", "/api/media"): return ("play.rectangle.on.rectangle", "Browsing Watch & Listen")
        case ("POST", "/api/media/progress"):
            let id = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["id"] as? String
            return id.flatMap(mediaActivity)
        case ("GET", "/api/send"): return ("iphone.and.arrow.forward", "Checking Send to iPhone")
        case ("POST", "/api/send/received"):
            let item = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?["item"] as? String
            return ("checkmark.circle", "Received “\(sendTitle(item ?? ""))”")
        case ("GET", let p) where p.hasPrefix("/api/send/file/"):
            let item = p.dropFirst("/api/send/file/".count).split(separator: "/").first.map(String.init) ?? ""
            return ("arrow.down.circle", "Downloading “\(sendTitle(item))” to the phone")
        case ("GET", let p) where p.hasPrefix("/media/"):
            let parts = p.dropFirst("/media/".count).split(separator: "/").map(String.init)
            guard parts.count == 2, Int(parts[1]) != nil else { return nil }   // artwork isn't an activity
            return mediaActivity(parts[0])
        case ("GET", let p) where p.hasPrefix("/book/") || p.hasPrefix("/content/"):
            return nil   // redirected to the archive port, which records the article
        default: return nil
        }
    }

    private func mediaActivity(_ id: String) -> (symbol: String, text: String)? {
        guard let item = media?.items.first(where: { ShareController.mediaID($0) == id }) else { return nil }
        let title = MediaCatalog.title(item, media?.info[item.progressKey])
        switch item.kind {
        case .video: return ("play.tv", "Watching \(title)")
        case .audio: return ("headphones", "Listening to \(title)")
        case .book: return ("book", "Reading \(title)")
        }
    }

    private func archiveTitle(_ id: String) -> String {
        if id == PowerOutGuide.bookID { return "the power outage guide" }
        return library?.book(id)?.shortTitle ?? "an archive"
    }

    private func sendTitle(_ id: String) -> String { SendList.shared.entries.first { $0.id == id }?.title ?? "an item" }

    /// An article page rather than one of the images, scripts or styles it loads.
    nonisolated static func isArticle(_ entry: String) -> Bool {
        if entry.hasPrefix("-/") || entry.hasPrefix("I/") || entry.hasPrefix("_") || entry.hasPrefix("M/") { return false }
        let last = entry.split(separator: "/").last.map(String.init) ?? entry
        guard let dot = last.lastIndex(of: ".") else { return true }
        let ext = last[last.index(after: dot)...].lowercased()
        return ext == "html" || ext == "htm" || ext.count > 5 || ext.contains(" ")
    }

    // MARK: Refusals

    /// "blocked" or "waiting": JSON for the apps and the page's own requests, a small page for browsers.
    nonisolated static func sendRefusal(_ req: WebServer.Request, _ res: WebServer.Responder, status: String, message: String) async {
        let accept = (req.headers["accept"] ?? "").lowercased()
        let wantsPage = req.method == "GET" && !req.path.hasPrefix("/api/") && accept.contains("text/html")
        if wantsPage {
            let waiting = status == "waiting"
            let refresh = waiting ? "<meta http-equiv=\"refresh\" content=\"4\">" : ""
            let detail = waiting ? "Someone at the Mac needs to click Allow. This page checks again every few seconds."
                                 : "Ask the person who runs Offline Kit on the Mac if you think this is a mistake."
            let page = """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\(refresh)
            <title>Offline Kit</title><style>body{font:17px -apple-system,system-ui,sans-serif;margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f5f2;color:#1d2420}
            main{max-width:28rem;padding:2rem;text-align:center}h1{font-size:1.4rem}p{color:#5b625e;line-height:1.45}
            @media (prefers-color-scheme:dark){body{background:#151816;color:#eef1ec}p{color:#a5aca7}}</style></head>
            <body><main><h1>\(message)</h1><p>\(detail)</p></main></body></html>
            """
            await res.send(status: 403, contentType: "text/html; charset=utf-8", body: Data(page.utf8))
        } else {
            await res.send(status: 403, json: ["error": status, "message": message])
        }
    }

    // MARK: Names from the User-Agent

    nonisolated static func isOfflineKitApp(_ ua: String) -> Bool {
        ua.hasPrefix("Offline%20Kit/") || ua.hasPrefix("Offline Kit/") || ua.hasPrefix("OfflineKit")
    }

    /// "iPhone · Safari", "Android phone · Chrome", "Windows PC · Edge", "Apple TV app".
    nonisolated static func kind(ua: String, path: String) -> (kind: Kind, name: String) {
        let u = ua
        if u.isEmpty { return (.unknown, "Unknown device") }
        if u.contains("AppleCoreMedia") || u.contains("AppleTV") {
            if u.contains("Apple TV") || u.contains("AppleTV") { return (.appleTV, "Apple TV app") }
            if u.contains("iPad") { return (.iPad, "iPad · video player") }
            if u.contains("iPhone") { return (.iPhone, "iPhone · video player") }
            return (.mac, "Mac · video player")
        }
        if isOfflineKitApp(u) {
            if path.hasPrefix("/api/send") { return (.iPhoneApp, "Offline Kit on iPhone") }
            return (.iPhoneApp, "Offline Kit app")
        }
        if u.hasPrefix("curl/") || u.hasPrefix("Wget") || u.hasPrefix("python") { return (.commandLine, "Command line (\(u.split(separator: "/").first ?? ""))") }
        let browser: String = {
            if u.contains("Edg/") || u.contains("EdgiOS") || u.contains("EdgA/") { return "Edge" }
            if u.contains("OPR/") || u.contains("OPiOS") { return "Opera" }
            if u.contains("SamsungBrowser") { return "Samsung Internet" }
            if u.contains("Firefox/") || u.contains("FxiOS") { return "Firefox" }
            if u.contains("CriOS") || u.contains("Chrome/") { return "Chrome" }
            if u.contains("Safari/") || u.contains("AppleWebKit") { return "Safari" }
            return "browser"
        }()
        if u.contains("iPhone") || u.contains("iPod") { return (.iPhone, "iPhone · \(browser)") }
        if u.contains("iPad") { return (.iPad, "iPad · \(browser)") }
        if u.contains("Android") { return u.contains("Mobile") ? (.androidPhone, "Android phone · \(browser)") : (.androidTablet, "Android tablet · \(browser)") }
        if u.contains("CrOS") { return (.chromebook, "Chromebook · \(browser)") }
        if u.contains("Windows") { return (.windows, "Windows PC · \(browser)") }
        if u.contains("Macintosh") || u.contains("Mac OS X") { return (.mac, "Mac · \(browser)") }
        if u.contains("Linux") { return (.linux, "Linux PC · \(browser)") }
        return (.unknown, browser == "browser" ? "Unknown device" : browser)
    }

    nonisolated static func cleanNickname(_ name: String) -> String {
        String(name.filter { !$0.isNewline && ($0.asciiValue.map { $0 >= 32 && $0 != 127 } ?? true) }.prefix(40))
            .trimmingCharacters(in: .whitespaces)
    }

    nonisolated static func isLoopback(_ ip: String) -> Bool { ip == "::1" || ip.hasPrefix("127.") }

    // MARK: Saving

    // What's kept on disk: each device's id(s), nickname, generic description ("iPhone · Safari"), first and last seen
    // times; the block list; and (in this Mac's own settings) the approvals and the "ask first" choice. Never IP
    // addresses, history, what anyone watched or read, or the names phones report. Hardware addresses only in the
    // block and approval lists.

    private struct Saved: Codable {
        var id: String
        var cookies: [String]?
        var nickname: String?
        var name: String
        var kind: Kind
        var first: Date
        var last: Date
    }

    private static let devicesKey = "shareDevices"
    private static let blockedIDsKey = "shareBlockedDevices"
    private static let blockedMACsKey = "shareBlockedMACs"
    private static let approvedIDsKey = "shareApprovedDevices"
    private static let approvedMACsKey = "shareApprovedMACs"
    private static let askFirstKey = "shareAskFirst"

    /// Where approvals and blocks are kept. From a drive, the drive's settings file can't be trusted (anyone could
    /// have written it): those go in this Mac's own settings, and the drive's may only add blocks.
    private static let trusted: KitSettings? = {
        guard KitLocation.isPortable else { return nil }   // nil: KitSettings.shared is this Mac's own
        if let home = KitLocation.testHome { return KitSettings(fileURL: home.appending(path: "Offline Kit Mac Settings.plist")) }
        return KitSettings(fileURL: nil)   // UserDefaults
    }()

    private func load() {
        let settings = KitSettings.shared
        let mine = Self.trusted ?? settings
        if let text = settings.string(forKey: Self.devicesKey), let data = text.data(using: .utf8),
           let saved = try? JSONDecoder().decode([Saved].self, from: data) {
            for item in saved.prefix(Self.maxDevices) where Self.isDeviceID(item.id) {
                guard -item.last.timeIntervalSinceNow < Self.forgetAfter || item.nickname != nil else { continue }
                let cookies = Set((item.cookies ?? []).filter(Self.isDeviceID).prefix(8)).union([item.id])
                devices[item.id] = Device(id: item.id, cookieIDs: cookies, autoName: String(item.name.prefix(60)), kind: item.kind,
                                          nickname: item.nickname.map(Self.cleanNickname), firstSeen: item.first, lastSeen: min(item.last, Date()))
            }
        }
        // Blocks: this Mac's own, plus any a drive adds. Approvals and the "ask first" choice: this Mac's own only,
        // except that a drive may turn asking on (never off).
        func list(_ store: KitSettings, _ key: String) -> Set<String> { Set((store.stringArray(forKey: key) ?? []).prefix(2000)) }
        blockedIDs = list(mine, Self.blockedIDsKey).union(list(settings, Self.blockedIDsKey)).filter(Self.isDeviceID)
        blockedMACs = list(mine, Self.blockedMACsKey).union(list(settings, Self.blockedMACsKey)).filter(Self.isMAC)
        approvedIDs = list(mine, Self.approvedIDsKey).filter(Self.isDeviceID)
        approvedMACs = list(mine, Self.approvedMACsKey).filter(Self.isMAC)
        askFirst = (mine.bool(forKey: Self.askFirstKey) ?? false) || (settings.bool(forKey: Self.askFirstKey) ?? false)
        #if DEBUG
        // Test hook: -shareAskFirst YES turns on approval for this run (in a test home only).
        if KitLocation.testHome != nil, UserDefaults.standard.bool(forKey: "shareAskFirst") { askFirst = true }
        #endif
    }

    nonisolated static func isMAC(_ value: String) -> Bool {
        value.count == 17 && value.split(separator: ":").count == 6 && value.split(separator: ":").allSatisfy { $0.count == 2 && UInt8($0, radix: 16) != nil }
    }

    private func saveTrusted() {
        let mine = Self.trusted ?? KitSettings.shared
        mine.set(blockedIDs.sorted(), forKey: Self.blockedIDsKey)
        mine.set(blockedMACs.sorted(), forKey: Self.blockedMACsKey)
        mine.set(approvedIDs.sorted(), forKey: Self.approvedIDsKey)
        mine.set(approvedMACs.sorted(), forKey: Self.approvedMACsKey)
        mine.set(askFirst, forKey: Self.askFirstKey)
        if Self.trusted != nil {
            // The drive's own copy of the blocks, so an unblock here sticks, and the drive's "ask first" follows this Mac's.
            KitSettings.shared.set(blockedIDs.sorted(), forKey: Self.blockedIDsKey)
            KitSettings.shared.set(blockedMACs.sorted(), forKey: Self.blockedMACsKey)
            KitSettings.shared.set(askFirst, forKey: Self.askFirstKey)
        }
    }

    /// Writes the device list a few seconds after it changes, not on every request.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }
            self.savedAt = Date()
            let saved = self.devices.values.map { d in
                Saved(id: d.id, cookies: Array(d.cookieIDs.subtracting([d.id]).sorted().prefix(8)), nickname: d.nickname,
                      name: d.autoName, kind: d.kind, first: d.firstSeen, last: d.lastSeen)
            }
            if let data = try? JSONEncoder().encode(saved) {
                KitSettings.shared.set(String(decoding: data, as: UTF8.self), forKey: Self.devicesKey)
            }
        }
    }

    /// Forgets unnamed, unblocked devices not seen for 30 days, and past the cap the longest-unseen of them.
    private func pruneIfNeeded() {
        let keep: (Device) -> Bool = { [self] in $0.nickname != nil || isBlocked($0) || isApproved($0) }
        for (id, device) in devices where !keep(device) && -device.lastSeen.timeIntervalSinceNow > Self.forgetAfter { devices[id] = nil }
        guard devices.count > Self.maxDevices else { return }
        let spare = devices.values.filter { !keep($0) && !isOnline($0) }.sorted { $0.lastSeen < $1.lastSeen }
        for device in spare.prefix(devices.count - Self.maxDevices) { devices[device.id] = nil }
        if devices.count > Self.maxDevices {
            for device in devices.values.filter({ !keep($0) }).sorted(by: { $0.lastSeen < $1.lastSeen }).prefix(devices.count - Self.maxDevices) {
                devices[device.id] = nil
            }
        }
    }
}
