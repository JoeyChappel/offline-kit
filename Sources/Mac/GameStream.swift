import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GameController

// Game streaming for Share on Wi-Fi: a phone or tablet's browser plays the Mac's games. The Mac runs the emulator (the
// same GameSession as its own game window, so saves, autosave, "Continue playing" and play history all work as usual)
// and sends picture and sound over a WebSocket; the browser sends buttons, taps and keys back. A browser can also be a
// controller only, for a game shown on the Mac's own window (a second player, or player 1 when the Mac has no pad).
//
// Wire format (see play.js):
//   Mac to browser, binary: [1 = JPEG | 3 = PNG][u32 seq][u16 encode time, 0.1 ms][u16 width][u16 height][image]
//                           [2][interleaved stereo s16 samples at the core's rate]
//   Mac to browser, text: JSON {"t": "started" | "busy" | "ended" | "error" | "toast" | "pong" | "controller" | ...}
//   Browser to Mac, binary: [1][button][down]  [2][down][u16 key][u32 char][u16 mods]  [3][f32 dx][f32 dy] (game pixels)
//                           [4][f32 x][f32 y] (0...1 across the picture)  [5][mouse button][down]  [6] release all
//                           [7][u32 seq] picture shown  [8][i8 wheel notches]
//   Browser to Mac, text: JSON {"t": "hello" | "pause" | "resume" | "save" | "load" | "quit" | "mute" | "slot" | "ping"}

/// Takes a streamed game's frames and sound off the emulation thread and sends them to the device that's playing.
/// Pictures are encoded one at a time on their own queue, and a new one is only taken when the last has been handed to
/// the network and the device has shown (acknowledged) all but one of those before it, so a slow phone or busy Wi-Fi
/// drops frames instead of building up delay.
final class StreamOutput: GameStreamSink, @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = DispatchQueue(label: "OfflineKit.GameStream.encode", qos: .userInteractive)
    // Guarded by `lock`.
    private var socket: WebSocket?
    private var muted = false
    private var encoding = false
    private var videoInFlight = false
    private var audioInFlight = 0
    private var seq: UInt32 = 0
    private var lastAcked: UInt32 = 0
    private var lastSentAt = Date.distantPast
    private var sentTimes: [UInt32: Date] = [:]
    private var lastEncoded: Data?
    private var frameSize = CGSize.zero
    // Measurements, for the device's stats line.
    private var framesSent = 0
    private var bytesSent = 0
    private var encodeTotal: Double = 0
    private var roundTrips: [Double] = []
    private var statsSince = Date()

    func attach(_ socket: WebSocket?) {
        lock.withLock {
            self.socket = socket
            encoding = false
            videoInFlight = false
            audioInFlight = 0
            lastAcked = seq
            sentTimes.removeAll()
            lastEncoded = nil   // a fresh device gets the current picture even if nothing changes
        }
    }

    func setMuted(_ value: Bool) { lock.withLock { muted = value } }

    /// The size of the last picture, in game pixels.
    var pictureSize: CGSize { lock.withLock { frameSize } }

    /// The device has drawn picture `seq`.
    func acknowledge(_ ack: UInt32) {
        lock.withLock {
            guard ack &- lastAcked < 0x8000_0000 else { return }   // older than one already acknowledged
            lastAcked = ack
            if let sent = sentTimes.removeValue(forKey: ack) {
                roundTrips.append(-sent.timeIntervalSinceNow * 1000)
                if roundTrips.count > 120 { roundTrips.removeFirst(roundTrips.count - 120) }
            }
            sentTimes = sentTimes.filter { $0.key &- ack < 0x8000_0000 }
        }
    }

    /// Frames sent per second, kilobits per second, average encode and picture round trip (send to shown) in ms,
    /// since the last call.
    func takeStats() -> [String: Any] {
        lock.withLock {
            let seconds = max(0.001, -statsSince.timeIntervalSinceNow)
            let trips = roundTrips.sorted()
            let stats: [String: Any] = [
                "fps": Double(framesSent) / seconds,
                "kbps": Double(bytesSent) * 8 / 1000 / seconds,
                "encodeMs": framesSent > 0 ? encodeTotal / Double(framesSent) : 0,
                "frameRTT": trips.isEmpty ? 0 : trips[trips.count / 2],
            ]
            framesSent = 0; bytesSent = 0; encodeTotal = 0; roundTrips.removeAll(); statsSince = Date()
            return stats
        }
    }

    // MARK: GameStreamSink (emulation thread)

    func streamFrame(_ image: CGImage) {
        let go = lock.withLock { () -> Bool in
            frameSize = CGSize(width: image.width, height: image.height)
            guard socket != nil, !encoding, !videoInFlight else { return false }
            // The device hasn't shown the frame before last: wait, unless it has gone quiet (a lost message
            // shouldn't stop the picture for good).
            if seq &- lastAcked > 1 && -lastSentAt.timeIntervalSinceNow < 0.5 { return false }
            encoding = true
            return true
        }
        guard go else { return }
        encoder.async { [weak self] in self?.encodeAndSend(image) }
    }

    func streamAudio(_ samples: UnsafePointer<Int16>, frames: Int) {
        guard frames > 0 else { return }
        let target = lock.withLock { () -> WebSocket? in
            // Sound is small; a few messages may wait, beyond that the connection is behind and sound is dropped.
            guard let socket, !muted, audioInFlight < 12 else { return nil }
            audioInFlight += 1
            return socket
        }
        guard let target else { return }
        var message = Data(capacity: 1 + frames * 4)
        message.append(2)
        samples.withMemoryRebound(to: UInt8.self, capacity: frames * 4) { message.append($0, count: frames * 4) }
        target.send(binary: message) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.audioInFlight -= 1 }
        }
    }

    // MARK: Encoding

    private func encodeAndSend(_ image: CGImage) {
        let started = Date()
        // Small console pictures compress best (and exactly) as PNG; bigger DOS and ScummVM screens go as JPEG.
        let pixels = image.width * image.height
        var encoded = Self.encode(image, png: pixels <= 320 * 240)
        var type: UInt8 = pixels <= 320 * 240 ? 3 : 1
        // A busy picture that PNG can't squeeze: JPEG is several times smaller.
        if type == 3, let data = encoded, data.count > 48_000 {
            encoded = Self.encode(image, png: false)
            type = 1
        }
        let encodeMs = -started.timeIntervalSinceNow * 1000
        let send = lock.withLock { () -> (WebSocket, UInt32)? in
            defer { encoding = false }
            guard let socket, let encoded else { return nil }
            if encoded == lastEncoded { return nil }   // nothing on screen changed
            lastEncoded = encoded
            seq &+= 1
            videoInFlight = true
            lastSentAt = Date()
            sentTimes[seq] = lastSentAt
            framesSent += 1
            bytesSent += encoded.count
            encodeTotal += encodeMs
            return (socket, seq)
        }
        guard let (socket, number) = send, let encoded else { return }
        var message = Data(capacity: encoded.count + 11)
        message.append(type)
        withUnsafeBytes(of: number.littleEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(min(65535, encodeMs * 10)).littleEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(clamping: image.width).littleEndian) { message.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(clamping: image.height).littleEndian) { message.append(contentsOf: $0) }
        message.append(encoded)
        socket.send(binary: message) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.videoInFlight = false }
        }
    }

    private static func encode(_ image: CGImage, png: Bool) -> Data? {
        let data = NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        let options: [CFString: Any] = png ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.72]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Runs game streaming: which device is playing which game, the browsers used as controllers, take-over, and pausing
/// when a device drops off (the game waits a few minutes for it, then saves and stops).
@MainActor
final class GameStreamHub {
    static let shared = GameStreamHub()

    /// How long a streamed game waits, paused and saved, for its device to come back.
    static let reconnectWindow: TimeInterval = 180
    /// Devices connected at once: one playing plus a few controllers. More are turned away.
    static let maxClients = 6

    weak var games: GameLibrary?
    weak var library: Library?

    /// One connected browser.
    final class Client {
        enum Role { case undecided, player, controller }
        let socket: WebSocket
        var device: String
        var role = Role.undecided
        /// Controllers: which player's buttons they press (1 or 2).
        var player = 1
        /// Buttons held right now, let go when the device leaves or changes player.
        var held = Set<Int>()
        /// Controllers: the game their player number was chosen for; a new game on the Mac chooses again.
        var gameID: String?
        /// The sign-in it connected with and its Connected Devices id: signing that device out or blocking it ends this too.
        let signIn: String?
        let deviceID: String?
        init(socket: WebSocket, device: String, signIn: String?, deviceID: String?) {
            self.socket = socket; self.device = device; self.signIn = signIn; self.deviceID = deviceID
        }
    }

    /// The game playing on a device (or paused, waiting for it to come back).
    private final class Stream {
        let session: GameSession
        let output: StreamOutput
        var player: Client?
        var stopTask: Task<Void, Never>?
        /// Set while the hub itself is stopping it, so the "stopped" reports don't reach the device twice.
        var ending = false
        /// ScummVM's cursor, in game pixels, kept in step with the device's taps (see pointer(x:y:)).
        var cursor: CGPoint?
        var cursorFrame = CGSize.zero
        init(session: GameSession, output: StreamOutput) { self.session = session; self.output = output }
    }

    private var stream: Stream? { didSet { updateActivity() } }
    private var clients: [ObjectIdentifier: Client] = [:]
    private var statsTimer: Timer?
    /// Held while a device is playing: with no window on screen, macOS would otherwise nap the app and slow the game
    /// and its encoding to a crawl (measured: 60 frames a second fell to 10).
    private var activity: NSObjectProtocol?

    private func updateActivity() {
        let playing = stream?.player != nil
        if playing && activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                                                             reason: "Playing a game on another device")
        } else if !playing, let held = activity {
            ProcessInfo.processInfo.endActivity(held)
            activity = nil
        }
    }

    // MARK: Connections

    /// A signed-in browser opened the play socket (ShareController has checked sign-in, Host and Origin).
    func accept(_ socket: WebSocket, device: String, signIn: String? = nil, deviceID: String? = nil) {
        guard clients.count < Self.maxClients else {
            socket.start(onMessage: { _ in }, onClose: {})
            socket.send(json: ["t": "error", "title": "Too many devices", "message": "Too many devices are connected to games right now."])
            socket.close(code: 1013)
            return
        }
        let client = Client(socket: socket, device: device, signIn: signIn, deviceID: deviceID)
        clients[ObjectIdentifier(client)] = client
        // Strictly in order (a button's press must never arrive after its release), on the main thread.
        socket.start(onMessage: { [weak self, weak client] message in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let client else { return }
                    self.handle(message, from: client)
                }
            }
        }, onClose: { [weak self, weak client] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let client else { return }
                    self.closed(client)
                }
            }
        })
        startStatsTimer()
    }

    /// Sharing turned off: every device is let go, and a streamed game is saved and stopped.
    func shutDown() {
        for client in clients.values {
            client.socket.send(json: ["t": "ended", "reason": "stopped", "text": "Sharing was turned off on the Mac."])
            client.socket.close(code: 1001)
        }
        clients.removeAll()
        if let stream { end(stream) }
        statsTimer?.invalidate()
        statsTimer = nil
    }

    /// The PIN changed: every device must sign in again. A streamed game pauses and saves, as when a device drops off.
    func signOutAll() {
        for client in clients.values {
            client.socket.send(json: ["t": "error", "title": "Sign in again", "message": "The PIN was changed on the Mac."])
            client.socket.close(code: 4401, reason: "Signed out")
        }
    }

    /// One device was signed out or blocked in Connected Devices: its games end the same way (paused and saved).
    func signOut(signIns: Set<String>) {
        for client in clients.values where client.signIn.map(signIns.contains) == true {
            client.socket.send(json: ["t": "error", "title": "Signed out", "message": "This device was signed out on the Mac."])
            client.socket.close(code: 4401, reason: "Signed out")
        }
    }

    func signOut(deviceID: String) {
        for client in clients.values where client.deviceID == deviceID {
            client.socket.send(json: ["t": "error", "title": "Blocked", "message": "This device has been blocked on the Mac."])
            client.socket.close(code: 4403, reason: "Blocked")
        }
    }

    private func closed(_ client: Client) {
        clients[ObjectIdentifier(client)] = nil
        if let id = client.deviceID { ShareDevices.shared.setActivity(device: id, text: nil) }
        switch client.role {
        case .player:
            guard let stream, stream.player === client else { break }
            stream.player = nil
            updateActivity()
            stream.output.attach(nil)
            stream.session.releasePlayer(1)
            // Paused and saved right away; a device that comes back within a few minutes carries on.
            stream.session.pauseAndSave()
            stream.stopTask?.cancel()
            stream.stopTask = Task { @MainActor [weak self, weak stream] in
                try? await Task.sleep(for: .seconds(Self.reconnectWindow))
                guard !Task.isCancelled, let self, let stream, self.stream === stream, stream.player == nil else { return }
                self.end(stream)
            }
        case .controller:
            for button in client.held { GameSession.current?.set(RetroButton(rawValue: button) ?? .B, false, player: client.player) }
        case .undecided:
            break
        }
        if clients.isEmpty { statsTimer?.invalidate(); statsTimer = nil }
    }

    // MARK: Messages

    private func handle(_ message: WebSocket.Message, from client: Client) {
        switch message {
        case .binary(let data): input(data, from: client)
        case .text(let text):
            guard let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  let type = json["t"] as? String else { return }
            command(type, json, from: client)
        }
    }

    private func command(_ type: String, _ json: [String: Any], from client: Client) {
        switch type {
        case "hello":
            guard client.role == .undecided else { return }
            // The page knows an iPad from a Mac (their browsers send the same User-Agent); letters and spaces only.
            if let name = json["device"] as? String {
                let clean = String(name.filter { $0.isLetter || $0.isNumber || $0 == " " }.prefix(30))
                if !clean.isEmpty { client.device = clean }
            }
            if json["mode"] as? String == "controller" { becomeController(client) }
            else { play(json, client: client) }
        case "ping":
            var reply: [String: Any] = ["t": "pong", "ts": json["ts"] ?? 0]
            if client.role == .controller { reply.merge(controllerStatus(client)) { $1 } }
            client.socket.send(json: reply)
        case "slot":
            guard client.role == .controller, let wanted = json["player"] as? Int, wanted == 1 || wanted == 2 else { return }
            for button in client.held { GameSession.current?.set(RetroButton(rawValue: button) ?? .B, false, player: client.player) }
            client.held.removeAll()
            client.player = (wanted == 2 && GameSession.current?.game.system.supportsSecondPlayer == true) ? 2 : 1
            client.gameID = GameSession.current?.game.id
            client.socket.send(json: ["t": "controller"].merging(controllerStatus(client)) { $1 })
        default:
            guard client.role == .player, let stream, stream.player === client else { return }
            let session = stream.session
            switch type {
            case "pause": session.setPaused(true)
            case "resume": if session.isPaused { session.setPaused(false) }
            case "save": session.saveState()
            case "load": session.loadState()
            case "mute": stream.output.setMuted(json["on"] as? Bool ?? false)
            case "reset": session.reset()
            case "quit":
                client.socket.send(json: ["t": "ended", "reason": "quit"])
                end(stream)
                client.socket.close()
            default: break
            }
        }
    }

    /// Player input: buttons, keys and the pointer, in the compact binary form.
    private func input(_ data: Data, from client: Client) {
        let bytes = [UInt8](data)
        guard let kind = bytes.first else { return }
        if client.role == .controller {
            guard kind == 1 || kind == 6, let session = GameSession.current, session.isRunning else { return }
            if client.gameID != session.game.id { chooseSlot(client, for: session) }
            if kind == 6 {
                session.releasePlayer(client.player); client.held.removeAll(); return
            }
            guard bytes.count >= 3, let button = RetroButton(rawValue: Int(bytes[1])) else { return }
            let down = bytes[2] != 0
            if down { client.held.insert(button.rawValue) } else { client.held.remove(button.rawValue) }
            session.set(button, down, player: client.player)
            return
        }
        guard client.role == .player, let stream, stream.player === client else { return }
        let session = stream.session
        func float(_ at: Int) -> Double {
            guard bytes.count >= at + 4 else { return 0 }
            let value = Float(bitPattern: UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24)
            return value.isFinite ? Double(value) : 0
        }
        switch kind {
        case 1:
            guard bytes.count >= 3, let button = RetroButton(rawValue: Int(bytes[1])) else { return }
            if bytes[2] == 0 || !session.isPaused { session.set(button, bytes[2] != 0) }
        case 2:
            guard bytes.count >= 10 else { return }
            let key = UInt32(bytes[2]) | UInt32(bytes[3]) << 8
            let character = UInt32(bytes[4]) | UInt32(bytes[5]) << 8 | UInt32(bytes[6]) << 16 | UInt32(bytes[7]) << 24
            let modifiers = UInt16(bytes[8]) | UInt16(bytes[9]) << 8
            session.key(key, down: bytes[1] != 0, character: character, modifiers: modifiers)
        case 3:
            let dx = max(-2000, min(2000, float(1))), dy = max(-2000, min(2000, float(5)))
            session.moveMouse(dx: dx, dy: dy)
        case 4:
            pointer(stream, x: max(0, min(1, float(1))), y: max(0, min(1, float(5))))
        case 5:
            guard bytes.count >= 3, let button = RetroMouseButton(rawValue: Int(bytes[1])) else { return }
            session.mouseButton(button, bytes[2] != 0)
        case 6:
            session.releaseInput()
        case 7:
            guard bytes.count >= 5 else { return }
            stream.output.acknowledge(UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24)
        case 8:
            guard bytes.count >= 2 else { return }
            session.scroll(Int(Int8(bitPattern: bytes[1])))
        default: break
        }
    }

    /// A tap at a place on the picture (0...1 each way). The cores take relative mouse motion, so, as the Mac window does
    /// for ScummVM, the cursor is pinned to the top-left once and every move after sends the difference.
    private func pointer(_ stream: Stream, x: Double, y: Double) {
        let frame = stream.output.pictureSize
        guard frame.width > 0, frame.height > 0 else { return }
        let target = CGPoint(x: min((x * frame.width).rounded(.down), frame.width - 1),
                             y: min((y * frame.height).rounded(.down), frame.height - 1))
        if stream.cursor == nil || frame != stream.cursorFrame {
            stream.session.pinMouseToCorner()
            stream.cursor = .zero
            stream.cursorFrame = frame
        }
        guard let cursor = stream.cursor, target != cursor else { return }
        stream.session.moveMouse(dx: target.x - cursor.x, dy: target.y - cursor.y)
        stream.cursor = target
    }

    // MARK: Playing

    /// "hello" from a player: {"id": game id, "resume": Bool, "takeover": Bool}.
    private func play(_ json: [String: Any], client: Client) {
        guard let id = json["id"] as? String, let game = games?.games.first(where: { Self.gameID($0) == id }) else {
            client.socket.send(json: ["t": "error", "title": "Game not found",
                                      "message": "That game isn't on the Mac any more. Go back and pick it again."])
            return
        }
        let takeover = json["takeover"] as? Bool ?? false
        var resume = json["resume"] as? Bool ?? false

        // The device coming back to its paused game (or another device picking it up) carries straight on.
        if let stream, stream.player == nil, stream.session.isRunning, stream.session.game.id == game.id {
            attach(client, to: stream, resumed: true)
            return
        }
        if let current = GameSession.current, current.isRunning, !takeover {
            let title = current.game.title
            var reply: [String: Any] = ["t": "busy", "title": title, "sameGame": current.game.id == game.id]
            if let stream, stream.session === current {
                if let other = stream.player {
                    reply["where"] = "device"
                    reply["text"] = "\(Self.withArticle(other.device)) is playing \(title)."
                } else {
                    reply["where"] = "paused"
                    reply["text"] = "\(title) is paused, waiting for the device that was playing it."
                }
            } else {
                reply["where"] = "mac"
                reply["text"] = "The Mac is playing \(title)."
            }
            client.socket.send(json: reply)
            return
        }
        // Taking over the same game: carry on from where the other player was (stopping writes their autosave).
        if let current = GameSession.current, current.isRunning, current.game.id == game.id { resume = true }
        if let stream {
            if let other = stream.player {
                other.socket.send(json: ["t": "ended", "reason": "replaced",
                                         "text": "\(Self.withArticle(client.device)) took over. Your place was saved."])
                other.socket.close()
            }
            end(stream)
        }
        let output = StreamOutput()
        let session = GameSession(game: game, resumeSavedState: resume, streamSink: output)
        let newStream = Stream(session: session, output: output)
        session.onToast = { [weak newStream] text in newStream?.player?.socket.send(json: ["t": "toast", "text": text]) }
        session.onStop = { [weak self, weak newStream] reason in
            guard let self, let newStream else { return }
            self.stopped(newStream, reason: reason)
        }
        session.start()   // stops whatever the Mac window was playing (it saves first)
        if let failure = session.failure {
            client.socket.send(json: ["t": "error", "title": failure.title, "message": failure.message])
            return
        }
        stream = newStream
        attach(client, to: newStream, resumed: false)
    }

    private func attach(_ client: Client, to stream: Stream, resumed: Bool) {
        stream.stopTask?.cancel()
        stream.stopTask = nil
        client.role = .player
        stream.player = client
        updateActivity()
        if let id = client.deviceID { ShareDevices.shared.setPlaying(device: id, game: stream.session.game.title) }
        stream.cursor = nil
        stream.output.attach(client.socket)
        let session = stream.session
        let system = session.game.system
        client.socket.send(json: [
            "t": "started", "title": session.game.title, "system": system.rawValue, "systemName": system.name,
            "aspect": Double(system.aspectRatio), "sampleRate": session.sampleRate, "fps": session.framesPerSecond,
            "layout": system.usesKeyboardAndMouse ? "pointer" : (system.hasShoulderButtons ? "pad-shoulders" : "pad"),
            "pointer": system == .dos ? "relative" : "absolute",
            "saveStates": system.hasSaveStates, "resumed": resumed,
        ])
        if session.isPaused { session.setPaused(false) }
    }

    /// The hub stops a streamed game: saved, stopped, forgotten.
    private func end(_ stream: Stream) {
        stream.ending = true
        stream.stopTask?.cancel()
        stream.output.attach(nil)
        stream.session.stop()
        if self.stream === stream { self.stream = nil }
    }

    /// A streamed game stopped: by the hub, because it ended, or because the Mac started another game.
    private func stopped(_ stream: Stream, reason: GameSession.Ending?) {
        if self.stream === stream { self.stream = nil }
        guard !stream.ending, let player = stream.player else { return }
        stream.output.attach(nil)
        switch reason {
        case .finished:
            player.socket.send(json: ["t": "ended", "reason": "finished", "text": "\(stream.session.game.title) has closed."])
        case .replaced:
            // The Mac started a game; it's only `current` once this report is over.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let title = GameSession.current?.game.title
                    player.socket.send(json: ["t": "ended", "reason": "replaced",
                                              "text": title.map { "The Mac started playing \($0). Your place was saved." }
                                                ?? "Another game started on the Mac. Your place was saved."])
                }
            }
        case nil:
            player.socket.send(json: ["t": "ended", "reason": "stopped", "text": "The game was stopped on the Mac."])
        }
    }

    // MARK: Controllers

    private func becomeController(_ client: Client) {
        client.role = .controller
        if let id = client.deviceID { ShareDevices.shared.setActivity(device: id, text: "Using as a game controller") }
        client.socket.send(json: ["t": "controller"].merging(controllerStatus(client)) { $1 })
    }

    /// Player 2 when the game has one and player 1 is taken (the Mac has a game controller, a device is streaming the
    /// game, or another phone is player 1); otherwise player 1.
    private func chooseSlot(_ client: Client, for session: GameSession) {
        for button in client.held { session.set(RetroButton(rawValue: button) ?? .B, false, player: client.player) }
        client.held.removeAll()
        let p1Taken = !GCController.controllers().isEmpty
            || clients.values.contains { $0 !== client && $0.role == .controller && $0.player == 1 && $0.gameID == session.game.id }
            || (stream?.session === session && stream?.player != nil)
        client.player = session.game.system.supportsSecondPlayer && p1Taken ? 2 : 1
        client.gameID = session.game.id
    }

    private func controllerStatus(_ client: Client) -> [String: Any] {
        guard let session = GameSession.current, session.isRunning else {
            return ["title": NSNull(), "player": client.player, "twoPlayers": false]
        }
        if client.gameID != session.game.id { chooseSlot(client, for: session) }
        let system = session.game.system
        return ["title": session.game.title, "system": system.rawValue, "systemName": system.name,
                "player": client.player, "twoPlayers": system.supportsSecondPlayer,
                "layout": system.hasShoulderButtons ? "pad-shoulders" : "pad",
                "keyboardGame": system.usesKeyboardAndMouse]
    }

    // MARK: Stats

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let hub = GameStreamHub.shared
                guard let stream = hub.stream, let player = stream.player else { return }
                player.socket.send(json: ["t": "stats"].merging(stream.output.takeStats()) { $1 })
            }
        }
    }

    // MARK: Games list

    /// URL-safe id for a game, from its path (stable across launches).
    nonisolated static func gameID(_ game: Game) -> String {
        Data(game.url.path.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// "an iPhone", "an Android phone", "a phone".
    nonisolated static func withArticle(_ device: String) -> String {
        let first = device.lowercased().first
        return (first.map { "aeiou".contains($0) } ?? false ? "An " : "A ") + device
    }
}
