import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import GameController
import QuartzCore

// Game streaming for Share on Wi-Fi: a phone or tablet's browser plays the Mac's games. The Mac runs the emulator (the
// same GameSession as its own game window, so saves, autosave, "Continue playing" and play history all work as usual)
// and sends picture and sound over a WebSocket; the browser sends buttons, taps and keys back. A browser can also be a
// controller only, for a game shown on the Mac's own window (a second player, or player 1 when the Mac has no pad).
//
// The picture goes as hardware H.264 (see StreamVideo) to browsers that can decode it (WebCodecs; the page says so in
// its hello), else as PNG or JPEG as before. Either way StreamQuality adjusts it to the connection.
//
// Wire format (see play.js):
//   Mac to browser, binary: [1 = JPEG | 3 = PNG][u32 seq][u16 encode time, 0.1 ms][u16 width][u16 height][image]
//                           [4][u32 seq][u16 encode time][u16 width][u16 height][u8 flags][H.264, AVCC] (VideoWire)
//                           [5][H.264 decoder config] (VideoWire)
//                           [2][interleaved stereo s16 samples at the core's rate]
//   Mac to browser, text: JSON {"t": "started" | "busy" | "ended" | "error" | "toast" | "pong" | "controller" | ...}
//   Browser to Mac, binary: [1][button][down]  [2][down][u16 key][u32 char][u16 mods]  [3][f32 dx][f32 dy] (game pixels)
//                           [4][f32 x][f32 y] (0...1 across the picture)  [5][mouse button][down]  [6] release all
//                           [7][u32 seq] picture shown  [8][i8 wheel notches]
//   Browser to Mac, text: JSON {"t": "hello" | "pause" | "resume" | "save" | "load" | "quit" | "mute" | "slot" | "ping"
//                               | "keyframe" (its decoder lost its place) | "video" (H.264 failed there: pictures instead)}

/// Takes a streamed game's frames and sound off the emulation thread and sends them to the device that's playing.
/// Pictures are encoded one at a time on their own queue, and a new one is only taken when the last has been handed to
/// the network and the device has shown (acknowledged) enough of those before it (see StreamQuality.framesInFlight),
/// so a slow phone or busy Wi-Fi drops frames instead of building up delay.
final class StreamOutput: GameStreamSink, @unchecked Sendable {
    /// How pictures go to the device.
    enum Video: Equatable, Sendable {
        case image
        case h264(H264Encoder.Profile)
    }

    private let lock = NSLock()
    private let encoder = DispatchQueue(label: "OfflineKit.GameStream.encode", qos: .userInteractive)
    // Guarded by `lock`.
    private var socket: WebSocket?
    private var video = Video.image
    private var muted = false
    private var encoding = false
    private var videoInFlight = false
    private var audioInFlight = 0
    private var seq: UInt32 = 0
    private var lastAcked: UInt32 = 0
    private var lastSentAt: TimeInterval = 0
    private var sentTimes: [UInt32: (at: TimeInterval, bytes: Int)] = [:]
    /// The last picture sent, to skip unchanged ones by comparing pixels before encoding (holding it keeps its pixel
    /// memory from going back to the core's pool, so it stays as sent).
    private var lastSent: CGImage?
    private var frameSize = CGSize.zero
    /// The quality step in use (the emulation thread needs its frame rate), the frames allowed out at once and how old
    /// the oldest may get (see StreamQuality).
    private var step = StreamQuality.Step()
    private var inFlightLimit = 2
    private var queueLimit: TimeInterval = 0.5
    private var skipNext = false
    /// H.264: the next frame must be a keyframe (a device joined, or its decoder asked), and the decoder setup the
    /// device has (sent again when it changes or the device is new).
    private var wantKeyframe = true
    private var configSent: Data?
    /// H.264: an unchanged picture is encoded again a couple of times, so a still screen sharpens to full quality
    /// (the rate control makes a big change blurry for a frame or two).
    private var refreshesLeft = 0
    /// This half second's measurements, for StreamQuality.
    private var window = Window()
    private var lastTick: TimeInterval = 0
    private var clientDecodeMs: Double?
    /// The game's frame rate, as measured (DOS games change it with the video mode).
    private var gameFps: Double = 60
    private var link = StreamQuality.Link.good
    private var quality: StreamQuality?
    // Measurements, for the device's stats line.
    private var framesSent = 0
    private var bytesSent = 0
    private var encodeTotal: Double = 0
    private var roundTrips: [Double] = []
    private var statsSince = CACurrentMediaTime()
    private var lastKind = "png"
    /// Pictures not sent, by why: the encoder was still busy, the device hadn't caught up, the rate control left it out.
    private var skippedBusy = 0
    private var skippedHeld = 0
    private var skippedDropped = 0

    // Encoder queue only.
    private var h264: H264Encoder?
    private var h264Failed = false
    /// Encodes that failed outright (not frames the rate control left out); a few in a row and pictures go as PNG/JPEG.
    private var encodeFailures = 0
    /// Encoder queue only: the size of the last encoded picture, to size the next one's buffer in one go.
    private var lastEncodedSize = 0

    private struct Window {
        var started = CACurrentMediaTime()
        var coreFrames = 0
        var heldBack = 0
        var sent = 0
        var dropped = 0
        var bytes = 0
        var roundTrips: [Double] = []
    }

    #if DEBUG
    /// Test hooks: -streamQualityProbe YES measures the picture against the game's own (PSNR, SSIM) in the stats;
    /// -streamDumpFrames <folder> keeps the first 600 changed pictures as PNG files, for measuring encoders offline.
    private let probe: StreamProbe? = UserDefaults.standard.bool(forKey: "streamQualityProbe") ? StreamProbe() : nil
    private let dump = UserDefaults.standard.string(forKey: "streamDumpFrames").map { FrameDump(folder: $0) }
    #endif

    func attach(_ socket: WebSocket?, video: Video = .image) {
        lock.withLock {
            self.socket = socket
            self.video = Self.allowH264 ? video : .image
            encoding = false
            videoInFlight = false
            audioInFlight = 0
            lastAcked = seq
            sentTimes.removeAll()
            lastSent = nil   // a fresh device gets the current picture even if nothing changes
            wantKeyframe = true
            configSent = nil
            clientDecodeMs = nil
            quality = nil    // and starts at the best quality, stepping down if its connection needs it
            window = Window()
        }
    }

    /// The Mac can turn H.264 off (`defaults write ... streamVideo image`), for comparing or if a device misbehaves.
    static var allowH264: Bool { UserDefaults.standard.string(forKey: "streamVideo") != "image" }

    /// What a device gets, from what its hello says it can decode: {"video": {"h264": ["high", "main", "baseline"]}}.
    /// The Mac prefers High (the most compression for the same picture), then Main, then Constrained Baseline.
    static func chooseVideo(hello: [String: Any]) -> Video {
        guard let offer = hello["video"] as? [String: Any], let profiles = offer["h264"] as? [String] else { return .image }
        for profile in H264Encoder.Profile.allCases where profiles.contains(profile.rawValue) { return .h264(profile) }
        return .image
    }

    func setMuted(_ value: Bool) { lock.withLock { muted = value } }

    /// The device's decoder lost its place (or was reset): start again from a keyframe, with the setup.
    func requestKeyframe() { lock.withLock { wantKeyframe = true; configSent = nil } }

    /// H.264 didn't work on the device after all (its decoder failed): pictures go as PNG or JPEG from now on.
    func fallBackToImages() {
        lock.withLock {
            guard video != .image else { return }
            video = .image
            quality = nil
        }
    }

    /// The device's own measurements, from its check-in every 2 seconds.
    func clientReport(decodeMs: Double?) { lock.withLock { clientDecodeMs = decodeMs } }

    /// The size of the last picture, in game pixels.
    var pictureSize: CGSize { lock.withLock { frameSize } }

    /// The device has drawn picture `seq`. `from`: the connection it came on; only the attached device's count.
    func acknowledge(_ ack: UInt32, from sender: WebSocket? = nil) {
        let now = CACurrentMediaTime()
        lock.withLock {
            if let sender, sender !== socket { return }   // a device that has since been replaced or let go
            guard ack &- lastAcked < 0x8000_0000 else { return }   // older than one already acknowledged
            lastAcked = ack
            if let sent = sentTimes.removeValue(forKey: ack) {
                let trip = (now - sent.at) * 1000
                roundTrips.append(trip)
                if roundTrips.count > 120 { roundTrips.removeFirst(roundTrips.count - 120) }
                window.roundTrips.append(trip)
            }
            sentTimes = sentTimes.filter { $0.key &- ack < 0x8000_0000 }
        }
    }

    /// Frames sent per second, kilobits per second, average encode and picture round trip (send to shown) in ms,
    /// since the last call, with how the picture goes and the connection indicator.
    func takeStats() -> [String: Any] {
        lock.withLock {
            let now = CACurrentMediaTime()
            let seconds = max(0.001, now - statsSince)
            let trips = roundTrips.sorted()
            var stats: [String: Any] = [
                "fps": Double(framesSent) / seconds,
                "kbps": Double(bytesSent) * 8 / 1000 / seconds,
                "encodeMs": framesSent > 0 ? encodeTotal / Double(framesSent) : 0,
                "frameRTT": trips.isEmpty ? 0 : trips[trips.count / 2],
                "video": lastKind,
                "link": link.rawValue,
                "scale": step.scale,
                "halfRate": step.halfRate,
                "busy": skippedBusy, "held": skippedHeld, "dropped": skippedDropped,
            ]
            if let quality {
                stats["level"] = quality.index
                stats["levels"] = quality.steps.count
                stats["queueMs"] = quality.queueMs
                stats["baseRTT"] = quality.baseRTT
                if step.bitrate > 0 { stats["targetKbps"] = step.bitrate / 1000 }
                if step.jpegQuality > 0 { stats["jpegQuality"] = step.jpegQuality }
            }
            #if DEBUG
            if let probe { stats.merge(probe.takeResults()) { $1 } }
            #endif
            framesSent = 0; bytesSent = 0; encodeTotal = 0; roundTrips.removeAll(); statsSince = now
            skippedBusy = 0; skippedHeld = 0; skippedDropped = 0
            return stats
        }
    }

    // MARK: GameStreamSink (emulation thread)

    func streamFrame(_ image: CGImage) {
        let now = CACurrentMediaTime()
        var tick = false
        let previous = lock.withLock { () -> CGImage?? in
            frameSize = CGSize(width: image.width, height: image.height)
            guard socket != nil else { return nil }
            window.coreFrames += 1
            if now - lastTick >= 0.5 { lastTick = now; tick = true }
            if step.halfRate {
                skipNext.toggle()
                if skipNext { return nil }
            }
            guard !encoding else { skippedBusy += 1; return nil }
            // The device hasn't caught up: wait, unless it has gone quiet (a lost message shouldn't stop the picture
            // for good).
            let out = Int(seq &- lastAcked)
            let oldest = sentTimes[lastAcked &+ 1]?.at ?? now
            if videoInFlight || out >= inFlightLimit || (out > 1 && now - oldest > queueLimit) {
                if now - lastSentAt < 0.5 { window.heldBack += 1; skippedHeld += 1; return nil }
            }
            encoding = true
            return .some(lastSent)
        }
        if tick { encoder.async { [weak self] in self?.tick() } }
        guard let previous else { return }
        // Nothing on screen changed (a still menu, a DOS prompt): a comparison of the pixels, a few microseconds,
        // instead of encoding the picture to find out. `lastSent` can't change while `encoding` is set.
        var refresh = false
        if let previous, Self.samePixels(previous, image) {
            refresh = lock.withLock {
                guard refreshesLeft > 0, now - lastSentAt > 0.1 else { encoding = false; return false }
                refreshesLeft -= 1
                return true
            }
            if !refresh { return }
        }
        encoder.async { [weak self] in self?.encodeAndSend(image, refresh: refresh) }
    }

    /// True when two pictures from the core have the same size, layout and pixels.
    static func samePixels(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height, a.bytesPerRow == b.bytesPerRow, a.bitmapInfo == b.bitmapInfo,
              a.bitsPerPixel == b.bitsPerPixel,
              // The core's pictures wrap plain memory: these hand it back without copying.
              let x = a.dataProvider?.data, let y = b.dataProvider?.data else { return false }
        let count = CFDataGetLength(x)
        guard count == CFDataGetLength(y), let p = CFDataGetBytePtr(x), let q = CFDataGetBytePtr(y) else { return false }
        return p == q || memcmp(p, q, count) == 0
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

    // MARK: Quality (encoder queue)

    /// Twice a second: this window's measurements go to StreamQuality, and its step is applied.
    private func tick() {
        let now = CACurrentMediaTime()
        lock.withLock {
            let w = window
            window = Window()
            guard var q = quality else { return }
            let seconds = max(0.05, now - w.started)
            if w.coreFrames >= 10 { gameFps = Double(w.coreFrames) / seconds }
            let fps = gameFps
            let trips = w.roundTrips.sorted()
            // A frame still out counts as a round trip at least as long as it has been gone: a link that has stalled
            // (nothing acknowledged at all) must still read as congested.
            let waiting = sentTimes[lastAcked &+ 1].map { (now - $0.at) * 1000 }
            let median = trips.isEmpty ? nil : trips[trips.count / 2]
            let rtt = waiting.map { max($0, median ?? 0) } ?? median
            let sample = StreamQuality.Sample(now: now, rtt: rtt, minRTT: trips.first,
                                              heldBack: w.heldBack, sent: w.sent, decodeMs: clientDecodeMs,
                                              kbps: Double(w.bytes) * 8 / 1000 / seconds, fps: fps)
            _ = q.update(sample)
            quality = q
            step = q.step
            link = q.link(now: now)
            inFlightLimit = StreamQuality.framesInFlight(baseRTT: q.baseRTT, fps: fps)
            queueLimit = StreamQuality.queueLimit(baseRTT: q.baseRTT, fps: fps) / 1000
        }
    }

    /// The step to encode with, starting the quality controller for this picture size and path if needed.
    private func currentStep(for image: CGImage, codec: StreamQuality.Codec) -> StreamQuality.Step {
        lock.withLock {
            let small = StreamQuality.isSmall(width: image.width, height: image.height)
            if let q = quality, q.codec == codec, q.small == small { return q.step }
            // New device, new path, or the game changed screen size (a DOS game switching modes): start from the step
            // closest to the old one's bitrate, or the top.
            var start = 0
            if let old = quality, old.codec == codec, old.index > 0 {
                let ladder = StreamQuality.ladder(codec: codec, small: small)
                start = ladder.firstIndex { $0.bitrate <= old.step.bitrate } ?? ladder.count - 1
            }
            let q = StreamQuality(codec: codec, gameWidth: image.width, gameHeight: image.height, startAt: start)
            quality = q
            step = q.step
            return q.step
        }
    }

    // MARK: Encoding (encoder queue)

    private func encodeAndSend(_ image: CGImage, refresh: Bool) {
        #if DEBUG
        if !refresh { dump?.add(image) }
        #endif
        let (video, keyframe) = lock.withLock { (self.video, self.wantKeyframe) }
        if lock.withLock({ encodeFailures }) >= 5 { h264Failed = true; h264 = nil }
        if case .h264(let profile) = video, !h264Failed {
            if encodeH264(image, profile: profile, keyframe: keyframe, refresh: refresh) { return }
            h264Failed = true   // no hardware encoder (or it failed): pictures instead
            h264 = nil
        }
        if refresh { lock.withLock { encoding = false }; return }
        encodeImage(image)
    }

    private func encodeH264(_ image: CGImage, profile: H264Encoder.Profile, keyframe: Bool, refresh: Bool) -> Bool {
        let step = currentStep(for: image, codec: .h264)
        // H.264 works in whole 2×2 blocks of colour: even sizes.
        let width = max(2, Int((Double(image.width) * step.scale).rounded()) & ~1)
        let height = max(2, Int((Double(image.height) * step.scale).rounded()) & ~1)
        let fps = lock.withLock { gameFps } / (step.halfRate ? 2.0 : 1.0)
        var forceKey = keyframe
        if h264 == nil || h264?.width != width || h264?.height != height || h264?.profile != profile {
            h264 = nil
            guard let made = H264Encoder(width: width, height: height, fps: fps, bitrate: step.bitrate, profile: profile) else { return false }
            h264 = made
            forceKey = true
        }
        guard let session = h264 else { return false }
        session.setRate(bitrate: step.bitrate, fps: fps)
        guard let buffer = session.makeBuffer(), PixelCopy.copy(image, into: buffer) else { return false }
        if forceKey { lock.withLock { wantKeyframe = false } }
        let gameWidth = image.width, gameHeight = image.height
        session.encode(buffer, keyframe: forceKey) { [weak self] result in
            self?.sendH264(result, image: image, gameWidth: gameWidth, gameHeight: gameHeight, width: width, height: height,
                           profile: profile, refresh: refresh)
        }
        return true
    }

    /// On the encoder's own thread, as each frame comes out.
    private func sendH264(_ result: H264Encoder.Result, image: CGImage, gameWidth: Int, gameHeight: Int, width: Int, height: Int,
                          profile: H264Encoder.Profile, refresh: Bool) {
        let output: H264Encoder.Output
        switch result {
        case .frame(let frame): output = frame
        case .dropped:
            // Left out by the rate control: the encoder carries on from its last frame (and makes the next one a
            // keyframe itself if this was to be one).
            lock.withLock { encoding = false; window.dropped += 1; skippedDropped += 1 }
            return
        case .failed:
            lock.withLock { encoding = false; wantKeyframe = true; encodeFailures += 1 }
            return
        }
        let now = CACurrentMediaTime()
        let send = lock.withLock { () -> (WebSocket, UInt32, Data?)? in
            defer { encoding = false }
            guard let socket else { return nil }
            var config: Data?
            if output.keyframe, let avcC = output.avcC, avcC != configSent, let codec = VideoWire.codecString(avcC: avcC) {
                config = VideoWire.config(codec: codec, codedWidth: width, codedHeight: height, gameWidth: gameWidth, gameHeight: gameHeight, avcC: avcC)
                configSent = avcC
            }
            // A device that hasn't got the setup can't use this frame: start it with a keyframe instead.
            if configSent == nil { wantKeyframe = true; return nil }
            lastSent = image
            seq &+= 1
            videoInFlight = true
            lastSentAt = now
            sentTimes[seq] = (now, output.data.count)
            framesSent += 1
            bytesSent += output.data.count + (config?.count ?? 0)
            encodeTotal += output.encodeMs
            window.sent += 1
            window.bytes += output.data.count
            lastKind = "h264"
            encodeFailures = 0
            refreshesLeft = refresh ? refreshesLeft : 2
            return (socket, seq, config)
        }
        guard let (socket, number, config) = send else { return }
        if let config { socket.send(binary: config) }
        var message = VideoWire.frameHeader(seq: number, encodeMs: output.encodeMs, width: width, height: height,
                                            keyframe: output.keyframe, capacity: output.data.count)
        message.append(output.data)
        #if DEBUG
        probe?.sentH264(image: image, config: config, frame: output.data, keyframe: output.keyframe, width: width, height: height)
        #endif
        socket.send(binary: message) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.videoInFlight = false }
        }
    }

    private func encodeImage(_ original: CGImage) {
        let started = CACurrentMediaTime()
        let step = currentStep(for: original, codec: .image)
        let image = step.scale < 1 ? Self.scaled(original, by: step.scale) ?? original : original
        // Small console pictures compress best (and exactly) as PNG; bigger DOS and ScummVM screens go as JPEG.
        let pixels = image.width * image.height
        let png = step.jpegQuality == 0 && pixels <= 320 * 240
        let quality = step.jpegQuality > 0 ? step.jpegQuality : 0.72
        var encoded = Self.encode(image, png: png, quality: quality, sizeHint: lastEncodedSize)
        var type: UInt8 = png ? 3 : 1
        // A busy picture that PNG can't squeeze: JPEG is several times smaller.
        if type == 3, let data = encoded, data.count > 48_000 {
            encoded = Self.encode(image, png: false, quality: quality, sizeHint: data.count / 2)
            type = 1
        }
        lastEncodedSize = encoded?.count ?? 0
        let encodeMs = (CACurrentMediaTime() - started) * 1000
        let now = CACurrentMediaTime()
        let send = lock.withLock { () -> (WebSocket, UInt32)? in
            defer { encoding = false }
            guard let socket, encoded != nil else { return nil }
            lastSent = original
            seq &+= 1
            videoInFlight = true
            lastSentAt = now
            sentTimes[seq] = (now, encoded?.count ?? 0)
            framesSent += 1
            bytesSent += encoded?.count ?? 0
            encodeTotal += encodeMs
            window.sent += 1
            window.bytes += encoded?.count ?? 0
            lastKind = type == 3 ? "png" : "jpeg"
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
        #if DEBUG
        probe?.sentImage(original: original, encoded: encoded)
        #endif
        socket.send(binary: message) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.videoInFlight = false }
        }
    }

    /// A smaller copy of a picture (filtered), for the lowest quality steps on the picture path.
    static func scaled(_ image: CGImage, by scale: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// PNG without per-row filter choice: libpng otherwise tries every filter on every row, which was three quarters of
    /// the encoding time, and for console pictures (flat colours, sharp edges) the result is no bigger (measured: an NES
    /// frame 1.0 ms and 2.3 KB before, 0.27 ms and 2.1 KB after).
    private static let pngOptions = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGCompressionFilter: 0x08]] as CFDictionary   // IMAGEIO_PNG_FILTER_NONE

    static func encode(_ image: CGImage, png: Bool, quality: Double = 0.72, sizeHint: Int = 0) -> Data? {
        // Sized for about what the last picture took, so the encoder doesn't grow the buffer step by step.
        let data = NSMutableData(capacity: max(16_384, sizeHint + sizeHint / 4)) ?? NSMutableData()
        let type = (png ? UTType.png : UTType.jpeg).identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(data, type, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, png ? pngOptions : [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

/// Where a device's "picture shown" messages go: the output of the game it plays. Set on the main thread, read on the
/// connection's own queue. The output also checks the message came on the connection it sends to.
final class AckRoute: @unchecked Sendable {
    private let lock = NSLock()
    private weak var _output: StreamOutput?
    var output: StreamOutput? {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
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
        /// The game it plays, for "picture shown" messages, which are handled where they arrive (see accept).
        let acks = AckRoute()
        /// How its pictures go: H.264 when its browser said it can decode it (see StreamOutput.chooseVideo).
        var video = StreamOutput.Video.image
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
        /// Paused because the device went quiet (see checkQuiet); it carries on when the device is heard again.
        var quietPaused = false
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
        let acks = client.acks
        // Strictly in order (a button's press must never arrive after its release), on the main thread. "Picture shown"
        // (one per frame, 60 a second) goes straight to the game's output instead: it only moves a counter there, and
        // waking the main thread for each one was most of what streaming asked of it.
        socket.start(onMessage: { [weak self, weak client, weak socket] message in
            if case .binary(let data) = message, data.count >= 5, data.first == 7 {
                if let socket, let output = acks.output {
                    let ack = data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 1, as: UInt32.self)) }
                    output.acknowledge(ack, from: socket)
                }
                return
            }
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
        // Not while the same device still plays on another connection (it reconnected before this one was noticed gone).
        if let id = client.deviceID, !clients.values.contains(where: { $0.deviceID == id && $0.role != .undecided }) {
            ShareDevices.shared.setActivity(device: id, text: nil)
        }
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
        // The device is back after going quiet (its page checks in every 2 seconds): the game carries on.
        if let stream, stream.player === client, stream.quietPaused {
            stream.quietPaused = false
            if stream.session.isPaused { stream.session.setPaused(false) }
        }
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
            client.video = StreamOutput.chooseVideo(hello: json)
            if json["mode"] as? String == "controller" { becomeController(client) }
            else { play(json, client: client) }
        case "ping":
            if let id = client.deviceID { ShareDevices.shared.stillThere(device: id) }
            if let stream, stream.player === client { stream.output.clientReport(decodeMs: json["dec"] as? Double) }
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
            case "keyframe": stream.output.requestKeyframe()
            case "video": stream.output.fallBackToImages()
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
            guard bytes.count >= 5 else { return }   // normally handled as it arrives (see accept)
            stream.output.acknowledge(UInt32(bytes[1]) | UInt32(bytes[2]) << 8 | UInt32(bytes[3]) << 16 | UInt32(bytes[4]) << 24, from: client.socket)
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
        // The same device reconnecting after a Wi-Fi blip, before its old connection was noticed gone (that takes up to
        // half a minute with no word from it). A page checks in every 2 seconds, so an old connection quiet for longer
        // is the one that dropped: this one carries straight on instead of being asked to take over from itself.
        if let stream, let other = stream.player, other !== client, let id = client.deviceID, other.deviceID == id,
           other.socket.quietFor > 3, stream.session.isRunning, stream.session.game.id == game.id {
            stream.player = nil   // so the old socket closing doesn't pause the game
            other.role = .undecided
            other.socket.send(json: ["t": "ended", "reason": "replaced", "text": "This game carried on in another window."])
            other.socket.close(code: 1001, reason: "Reconnected")
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
        stream.quietPaused = false
        stream.output.attach(client.socket, video: client.video)
        client.acks.output = stream.output
        let session = stream.session
        let system = session.game.system
        client.socket.send(json: [
            "t": "started", "title": session.game.title, "system": system.rawValue, "systemName": system.name,
            "aspect": Double(system.aspectRatio), "sampleRate": session.sampleRate, "fps": session.framesPerSecond,
            "layout": system.usesKeyboardAndMouse ? "pointer" : (system.hasShoulderButtons ? "pad-shoulders" : "pad"),
            "pointer": system == .dos ? "relative" : "absolute",
            "joystick": system == .dos && session.joystickMode,
            "saveStates": system.hasSaveStates, "resumed": resumed,
            "video": client.video == .image || !StreamOutput.allowH264 ? "image" : "h264",
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
                "joystick": system == .dos && session.joystickMode,
                "keyboardGame": system.usesKeyboardAndMouse]
    }

    // MARK: Stats

    private func startStatsTimer() {
        guard statsTimer == nil else { return }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            MainActor.assumeIsolated {
                let hub = GameStreamHub.shared
                guard let stream = hub.stream, let player = stream.player else { return }
                hub.checkQuiet(stream, player: player)
                player.socket.send(json: ["t": "stats"].merging(stream.output.takeStats()) { $1 })
            }
        }
    }

    /// Nothing heard from the playing device for this long: its page checks in every 2 seconds, so it has gone (locked
    /// without saying so, out of Wi-Fi range). The game pauses instead of running for nobody until the connection times
    /// out (30 seconds), and carries on as soon as the device is heard again.
    static let quietPause: TimeInterval = 5

    private func checkQuiet(_ stream: Stream, player: Client) {
        guard !stream.quietPaused, !stream.session.isPaused, stream.session.isRunning,
              player.socket.quietFor > Self.quietPause else { return }
        stream.quietPaused = true
        stream.session.setPaused(true)
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
