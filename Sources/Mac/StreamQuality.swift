import Foundation

/// Adaptive picture quality for game streaming: the one place that decides how good the picture is, from how the
/// connection to the device is doing. StreamOutput measures, hands in a `Sample` twice a second, and applies the step.
///
/// What it watches, and why:
/// - **Queueing delay**: a frame's round trip (sent, decoded and drawn on the device, acknowledged) minus the lowest
///   round trip seen lately. On Wi-Fi a link that can't keep up shows first as delay growing in the router's buffers,
///   long before anything is lost, so this is the main signal. Over 25 ms (at 60 fps; 1.5 frame times) is congestion,
///   over 120 ms is severe; under 15 ms (or a frame time, if longer) is clean, which leaves room for Wi-Fi's jitter.
/// - **Frames held back**: pictures the game made that waited because the device hadn't caught up. Over a third held
///   back with any queueing at all means the link, not the screen, sets the frame rate.
/// - **Decode time** on the device: over 90% of a frame time means the phone itself can't keep up, so the picture
///   gets smaller or slower rather than just lower bitrate (which wouldn't help it).
///
/// How it moves: one step down after a second of congestion (two steps if both half seconds were severe, and for
/// H.264 at least to the first step below the bitrate the picture actually took, since a cap above that does
/// nothing); one step up after 2 seconds clean (4 for a step that failed before). A step up that brings congestion back within 5 seconds was too far: that step is
/// not tried again for a while (5 s, doubling to a minute), so quality doesn't seesaw. The first 2 seconds of a
/// stream (decoder starting, first keyframe) never count as congestion. Steps run best to worst:
/// bitrate (or JPEG quality) first, then picture size, then 30 frames a second.
struct StreamQuality: Equatable {
    enum Codec: Equatable { case h264, image }

    struct Step: Equatable {
        /// H.264 target, bits per second (0 on the picture path).
        var bitrate: Int = 0
        /// Picture path: JPEG quality, or 0 for PNG where the picture is small (lossless).
        var jpegQuality: Double = 0
        /// Picture size against the game's: 2 doubles each pixel (sharp colour edges after 4:2:0), 0.5 halves.
        var scale: Double = 1
        /// Every other frame (30 a second for most games).
        var halfRate = false
    }

    enum Link: String { case good, ok, weak }

    struct Sample: Equatable {
        var now: TimeInterval
        /// Median and lowest frame round trip in this window, ms (nil when nothing was acknowledged).
        var rtt: Double?
        var minRTT: Double?
        /// Pictures that waited on the device, and pictures sent.
        var heldBack: Int = 0
        var sent: Int = 0
        /// The device's decode time per frame, ms, as it last reported.
        var decodeMs: Double?
        /// What the picture actually took, kilobits per second.
        var kbps: Double?
        /// The game's frame rate.
        var fps: Double = 60
    }

    let codec: Codec
    let small: Bool
    let steps: [Step]
    private(set) var index = 0
    /// Lowest round trip over the last 10 seconds (window minimums), ms.
    private var minimums: [Double] = []
    private var congestedWindows = 0
    private var severeWindows = 0
    private var cleanSince: TimeInterval?
    private var lastChange: TimeInterval = -.infinity
    private var lastUp: TimeInterval = -.infinity
    private var lastCongested: TimeInterval = -.infinity
    private var blockedUntil: [Int: TimeInterval] = [:]
    private var backoff: TimeInterval = 5
    /// When the first window came in: the first 2 seconds (decoder starting, first keyframe) don't count as congestion.
    private var firstSample: TimeInterval?
    /// The last window's queueing delay, ms (for the stats line).
    private(set) var queueMs: Double = 0

    var step: Step { steps[index] }
    var baseRTT: Double { minimums.min() ?? 0 }

    /// Small screens (NES, Game Boy, GBA, PC Engine; up to 320×240) or big ones (DOS, ScummVM).
    /// `startAt`: the first step (a game that changed screen size keeps about the quality its connection had).
    init(codec: Codec, gameWidth: Int, gameHeight: Int, startAt: Int = 0) {
        self.codec = codec
        self.small = Self.isSmall(width: gameWidth, height: gameHeight)
        self.steps = Self.ladder(codec: codec, small: small)
        self.index = max(0, min(steps.count - 1, startAt))
    }

    static func isSmall(width: Int, height: Int) -> Bool { width * height <= 320 * 240 }

    /// The steps, best first. H.264 bitrates were picked by measuring pixel art and DOS text (see GameStream notes):
    /// small screens are encoded at twice their size, where 4:2:0 colour keeps every game pixel's own colour.
    static func ladder(codec: Codec, small: Bool) -> [Step] {
        switch (codec, small) {
        case (.h264, true):
            // Measured at double size: a still or simple screen takes 0.1-0.3 Mbit/s, a busy scrolling one 0.5-1.
            return [Step(bitrate: 4_000_000, scale: 2), Step(bitrate: 2_000_000, scale: 2), Step(bitrate: 1_000_000, scale: 2),
                    Step(bitrate: 700_000, scale: 1), Step(bitrate: 450_000, scale: 1), Step(bitrate: 350_000, scale: 1, halfRate: true)]
        case (.h264, false):
            return [Step(bitrate: 16_000_000), Step(bitrate: 10_000_000), Step(bitrate: 6_000_000), Step(bitrate: 4_000_000),
                    Step(bitrate: 3_000_000, scale: 0.75), Step(bitrate: 2_000_000, scale: 0.5),
                    Step(bitrate: 1_500_000, scale: 0.5, halfRate: true)]
        case (.image, true):
            return [Step(), Step(jpegQuality: 0.7), Step(jpegQuality: 0.5), Step(jpegQuality: 0.5, halfRate: true),
                    Step(jpegQuality: 0.35, halfRate: true)]
        case (.image, false):
            return [Step(jpegQuality: 0.72), Step(jpegQuality: 0.6), Step(jpegQuality: 0.5), Step(jpegQuality: 0.4),
                    Step(jpegQuality: 0.4, scale: 0.75), Step(jpegQuality: 0.4, scale: 0.5),
                    Step(jpegQuality: 0.35, scale: 0.5, halfRate: true)]
        }
    }

    /// Takes one window's measurements; true when the step changed.
    mutating func update(_ s: Sample) -> Bool {
        let frameMs = 1000 / max(1, s.fps)
        if firstSample == nil { firstSample = s.now }
        let warmingUp = s.now - (firstSample ?? s.now) < 2
        if let m = s.minRTT {
            minimums.append(m)
            if minimums.count > 20 { minimums.removeFirst(minimums.count - 20) }
        }
        let base = baseRTT
        queueMs = s.rtt.map { max(0, $0 - base) } ?? 0
        let total = s.heldBack + s.sent
        let held = total > 0 ? Double(s.heldBack) / Double(total) : 0
        let shownMs = frameMs * (step.halfRate ? 2 : 1)
        let decodeLimited = (s.decodeMs ?? 0) > shownMs * 0.9
        let severe = !warmingUp && queueMs > 120
        let congested = !warmingUp && (severe || queueMs > max(20, frameMs * 1.5) || (held > 0.33 && queueMs > 4) || decodeLimited)
        let clean = queueMs < max(15, frameMs) && held < 0.1 && (s.decodeMs ?? 0) < shownMs * 0.6

        if congested {
            lastCongested = s.now
            congestedWindows += 1
            severeWindows = severe ? severeWindows + 1 : 0
            cleanSince = nil
            // Two windows in a row (a second): one bad half second is more often a hiccup (a phone's pause, a busy
            // moment on the Mac) than the link.
            guard congestedWindows >= 2, s.now - lastChange >= 1, index < steps.count - 1 else { return false }
            let drop = severeWindows >= 2 ? 2 : 1
            // A step up that didn't hold: don't try it again for a while.
            if s.now - lastUp < 5 {
                blockedUntil[index] = s.now + backoff
                backoff = min(60, backoff * 2)
            }
            var next = min(steps.count - 1, index + drop)
            // A target above what the picture actually takes changes nothing (a still screen, or simple pixel art
            // using a fraction of it): go straight to the first step below that.
            // Past bitrate steps only: it goes on into the first smaller (or slower) step at most, never through it.
            if codec == .h264, let kbps = s.kbps, kbps > 0 {
                while next < steps.count - 1, Double(steps[next].bitrate) > kbps * 1000 * 0.85 {
                    let resized = steps[next + 1].scale != steps[next].scale || steps[next + 1].halfRate != steps[next].halfRate
                    next += 1
                    if resized { break }
                }
            }
            if decodeLimited, let smaller = steps.indices.first(where: { $0 > index && (steps[$0].scale < step.scale || (steps[$0].halfRate && !step.halfRate)) }) {
                next = max(next, smaller)
            }
            index = next
            lastChange = s.now
            congestedWindows = 0
            severeWindows = 0
            return true
        }
        congestedWindows = 0
        severeWindows = 0
        guard clean else { cleanSince = nil; return false }
        if cleanSince == nil { cleanSince = s.now }
        // Held for a while after the last step up: that level is fine, so later probes back off less.
        if s.now - lastUp > 10, s.now - lastCongested > 10 { backoff = 5 }
        // Back up after 2 seconds clean, or 4 for a step that has failed before.
        guard index > 0, let since = cleanSince else { return false }
        let wait: TimeInterval = blockedUntil[index - 1] == nil ? 2 : 4
        guard s.now - since >= wait, s.now - lastChange >= wait, s.now >= blockedUntil[index - 1, default: 0] else { return false }
        index -= 1
        lastChange = s.now
        lastUp = s.now
        cleanSince = s.now
        return true
    }

    /// For the device's indicator: good near the top with no recent congestion, weak at the bottom two steps or
    /// congested in the last 3 seconds, ok otherwise.
    func link(now: TimeInterval) -> Link {
        if now - lastCongested < 3 || index >= steps.count - 2 { return .weak }
        if index <= 1 && now - lastCongested > 5 && queueMs < 15 { return .good }
        return .ok
    }

    /// Frames that may be on their way to the device at once: enough to cover the round trip (so a 30 ms Wi-Fi link
    /// still gets every frame at 60 fps), never fewer than 2 (as before), never more than 5. Delay can't build up
    /// behind them: a frame also waits while the oldest one out is older than the round trip plus two frame times.
    static func framesInFlight(baseRTT: Double, fps: Double) -> Int {
        let frameMs = 1000 / max(1, fps)
        return max(2, min(5, Int((baseRTT / frameMs).rounded(.up)) + 1))
    }

    /// How old the oldest unacknowledged frame may get before new ones wait, ms.
    static func queueLimit(baseRTT: Double, fps: Double) -> Double {
        baseRTT + max(30, 2000 / max(1, fps))
    }
}
