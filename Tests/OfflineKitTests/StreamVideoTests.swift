import Foundation
import Testing
import CoreGraphics
import CoreVideo

/// Game streaming's H.264 path: what a device's hello gets it, the message framing play.js reads, the pixel copy into
/// the encoder, and the adaptive quality controller's decisions.
@Suite("Game streaming video")
struct StreamVideoTests {

    // MARK: Negotiation

    @Test("The hello decides the picture path: the best H.264 profile the browser offers, else PNG/JPEG")
    func negotiation() {
        #expect(StreamOutput.chooseVideo(hello: ["t": "hello", "id": "x"]) == .image, "an older page says nothing: pictures")
        #expect(StreamOutput.chooseVideo(hello: ["video": ["h264": ["baseline", "main", "high"]]]) == .h264(.high))
        #expect(StreamOutput.chooseVideo(hello: ["video": ["h264": ["main", "baseline"]]]) == .h264(.main))
        #expect(StreamOutput.chooseVideo(hello: ["video": ["h264": ["baseline"]]]) == .h264(.baseline))
        #expect(StreamOutput.chooseVideo(hello: ["video": ["h264": [String]()]]) == .image, "WebCodecs but no profile it can decode")
        #expect(StreamOutput.chooseVideo(hello: ["video": ["h264": ["vp9"]]]) == .image)
        #expect(StreamOutput.chooseVideo(hello: ["video": ["h264": "high"]]) == .image, "a malformed offer is ignored")
        #expect(StreamOutput.chooseVideo(hello: ["video": true]) == .image)
    }

    // MARK: Framing

    @Test("A frame message is the 12-byte header play.js reads, then the AVCC data")
    func frameFraming() throws {
        let payload = Data([0, 0, 0, 3, 0x65, 0x88, 0x84, 0, 0, 0, 2, 0x41, 0x9A])
        var message = VideoWire.frameHeader(seq: 0x0102_0304, encodeMs: 2.37, width: 512, height: 480, keyframe: true)
        message.append(payload)
        #expect(Array(message.prefix(12)) == [4, 0x04, 0x03, 0x02, 0x01, 23, 0, 0x00, 0x02, 0xE0, 0x01, 1])
        let frame = try #require(VideoWire.parseFrame(message))
        #expect(frame == VideoWire.Frame(seq: 0x0102_0304, encodeMs: 2.3, width: 512, height: 480, keyframe: true, payload: payload))
        let delta = VideoWire.frameHeader(seq: 7, encodeMs: 99_999, width: 70_000, height: 2, keyframe: false)
        #expect(delta[11] == 0)
        #expect(VideoWire.parseFrame(delta)?.encodeMs == 6553.5, "encode time is clamped to the field")
        #expect(VideoWire.parseFrame(delta)?.width == 65535, "sizes are clamped, not wrapped")
        #expect(VideoWire.parseFrame(Data([4, 1, 2])) == nil)
        #expect(VideoWire.parseFrame(Data([1] + [UInt8](repeating: 0, count: 20))) == nil, "a JPEG message isn't a frame")
        #expect(VideoWire.nalUnits(payload) == [Data([0x65, 0x88, 0x84]), Data([0x41, 0x9A])])
        #expect(VideoWire.nalUnits(Data([0, 0, 0, 9, 1])) == nil, "a length past the end")
    }

    @Test("A config message carries the codec string, both sizes and the avcC record")
    func configFraming() throws {
        let avcC = Data([1, 0x64, 0x00, 0x1F, 0xFF, 0xE1, 0, 4, 0x67, 0x64, 0, 0x1F, 1, 0, 2, 0x68, 0xEE])
        let codec = try #require(VideoWire.codecString(avcC: avcC))
        #expect(codec == "avc1.64001F")
        #expect(VideoWire.codecString(avcC: Data([1, 0x42, 0xC0, 0x1E])) == "avc1.42C01E")
        #expect(VideoWire.codecString(avcC: Data([0, 0x42, 0xC0, 0x1E])) == nil, "not version 1")
        #expect(VideoWire.codecString(avcC: Data([1, 0x42])) == nil)
        let message = VideoWire.config(codec: codec, codedWidth: 512, codedHeight: 480, gameWidth: 256, gameHeight: 240, avcC: avcC)
        #expect(message[0] == 5)
        #expect(Array(message[1..<9]) == [0x00, 0x02, 0xE0, 0x01, 0x00, 0x01, 0xF0, 0x00])
        #expect(message[9] == 11)
        #expect(String(bytes: message[10..<21], encoding: .ascii) == "avc1.64001F")
        #expect(VideoWire.parseConfig(message) == VideoWire.Config(codec: codec, codedWidth: 512, codedHeight: 480,
                                                                   gameWidth: 256, gameHeight: 240, avcC: avcC))
        #expect(VideoWire.parseConfig(Data([5, 0, 2, 0, 2, 0, 1, 0, 1, 40, 0x61])) == nil, "codec longer than the message")
    }

    @Test("The hardware encoder's first frame is a keyframe with a matching config, and parses as play.js would")
    func encodedStream() async throws {
        let picture = try #require(SharePerformanceTests.corePicture(width: 256, height: 240) { x, y in
            (x / 8 + y / 8) % 2 == 0 ? 0x00FC_7460 : 0x0010_2080
        })
        guard let encoder = H264Encoder(width: 512, height: 480, fps: 60, bitrate: 2_000_000, profile: .high) else {
            withKnownIssue("No hardware H.264 encoder on this Mac") { Issue.record("encoder unavailable") }
            return
        }
        var results: [H264Encoder.Output] = []
        for i in 0..<3 {
            let buffer = try #require(encoder.makeBuffer())
            #expect(PixelCopy.copy(picture, into: buffer))
            let result = await withCheckedContinuation { (done: CheckedContinuation<H264Encoder.Result, Never>) in
                encoder.encode(buffer, keyframe: i == 0, time: Double(i) / 60) { done.resume(returning: $0) }
            }
            if case .frame(let output) = result { results.append(output) }
        }
        let first = try #require(results.first)
        #expect(first.keyframe)
        let avcC = try #require(first.avcC)
        let codec = try #require(VideoWire.codecString(avcC: avcC))
        #expect(codec.hasPrefix("avc1.64"), "High profile")
        let units = try #require(VideoWire.nalUnits(first.data))
        #expect(units.contains { ($0.first ?? 0) & 0x1F == 5 }, "an IDR slice")
        if results.count > 1 {
            #expect(!results[1].keyframe)
            #expect(results[1].avcC == nil)
        }
        var message = VideoWire.frameHeader(seq: 1, encodeMs: first.encodeMs, width: 512, height: 480, keyframe: true)
        message.append(first.data)
        #expect(VideoWire.parseFrame(message)?.payload == first.data)
    }

    // MARK: Pixel copy

    @Test("Doubling repeats each game pixel; ARGB pictures from 16-bit cores come out BGRA")
    func pixelCopy() throws {
        let colour: (Int, Int) -> UInt32 = { x, y in UInt32(x + 1) << 16 | UInt32(y + 1) << 8 | 0x33 }
        let bgra = try #require(SharePerformanceTests.corePicture(width: 4, height: 2, colour))
        let doubled: [UInt32] = try #require(Self.copy(bgra, width: 8, height: 4)).map { $0 & 0xFFFFFF }
        var expected: [UInt32] = []
        for y in 0..<4 { for x in 0..<8 { expected.append(colour(x / 2, y / 2)) } }
        #expect(doubled == expected)
        // The same colours laid out as ARGB in memory (big-endian), as the 16-bit cores' pictures are.
        let argb = try #require(Self.bigEndianPicture(width: 4, height: 2, colour))
        #expect(!PixelCopy.isBGRA(argb))
        let swapped: [UInt32] = try #require(Self.copy(argb, width: 8, height: 4)).map { $0 & 0xFFFFFF }
        #expect(swapped == expected)
        let same: [UInt32] = try #require(Self.copy(argb, width: 4, height: 2)).map { $0 & 0xFFFFFF }
        let plain: [UInt32] = (0..<8).map { i in colour(i % 4, i / 4) }
        #expect(same == plain)
        // Halving is filtered: a flat picture stays flat (to within rounding).
        let flat = try #require(SharePerformanceTests.corePicture(width: 8, height: 8) { _, _ in 0x00336699 })
        let half = try #require(Self.copy(flat, width: 4, height: 4))
        for p in half {
            for (shift, want) in [(0, 0x99), (8, 0x66), (16, 0x33)] {
                let got = Int((p >> UInt32(shift)) & 0xFF)
                #expect(abs(got - want) <= 1)
            }
        }
    }

    /// Copies into a fresh BGRA pixel buffer and reads it back as 32-bit pixels.
    static func copy(_ image: CGImage, width: Int, height: Int) -> [UInt32]? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess, let buffer,
              PixelCopy.copy(image, into: buffer) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(buffer)!, row = CVPixelBufferGetBytesPerRow(buffer)
        return (0..<height).flatMap { y in (0..<width).map { x in (base + y * row).load(fromByteOffset: x * 4, as: UInt32.self) } }
    }

    static func bigEndianPicture(width: Int, height: Int, _ pixel: (Int, Int) -> UInt32) -> CGImage? {
        var bytes = [UInt32](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { bytes[y * width + x] = pixel(x, y).bigEndian } }
        guard let provider = CGDataProvider(data: bytes.withUnsafeBytes { Data($0) } as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: Adaptive quality

    /// Runs the controller over windows half a second apart from `start`, each with these measurements.
    static func run(_ q: inout StreamQuality, from start: Double, seconds: Double, rtt: Double, minRTT: Double? = nil,
                    held: Int = 0, sent: Int = 30, decode: Double? = 2, fps: Double = 60) -> [Int] {
        var levels: [Int] = []
        var t = start
        while t < start + seconds - 0.001 {
            t += 0.5
            _ = q.update(StreamQuality.Sample(now: t, rtt: rtt, minRTT: minRTT ?? rtt, heldBack: held, sent: sent, decodeMs: decode, fps: fps))
            levels.append(q.index)
        }
        return levels
    }

    @Test("A clean link stays at the best step; queueing delay steps down once a second")
    func stepsDown() {
        var q = StreamQuality(codec: .h264, gameWidth: 256, gameHeight: 240)
        #expect(q.step == StreamQuality.Step(bitrate: 4_000_000, scale: 2), "small screens start doubled at the top bitrate")
        #expect(Self.run(&q, from: 0, seconds: 10, rtt: 30).allSatisfy { $0 == 0 }, "30 ms of plain round trip is not congestion")
        #expect(q.baseRTT == 30)
        #expect(q.link(now: 10) == .good)
        // 40 ms of queueing on top of the 30 ms base: down one step after a second, then each second.
        let levels = Self.run(&q, from: 10, seconds: 3, rtt: 70, minRTT: 60)
        #expect(levels == [0, 1, 1, 2, 2, 3])
        #expect(q.link(now: 13) == .weak)
        #expect(q.queueMs == 40)
    }

    @Test("H.264 steps straight below the bitrate the picture actually takes (a cap above it does nothing)")
    func belowActual() {
        var q = StreamQuality(codec: .h264, gameWidth: 640, gameHeight: 400)
        _ = Self.run(&q, from: 0, seconds: 2, rtt: 5)
        var t = 2.0
        for _ in 0..<2 {
            t += 0.5
            _ = q.update(StreamQuality.Sample(now: t, rtt: 60, minRTT: 50, sent: 30, decodeMs: 2, kbps: 3_000, fps: 60))
        }
        #expect(q.index == 4, "10, 6 and 4 Mbit/s skipped while the picture took 3, into the first smaller size and no further")
        #expect(q.step == StreamQuality.Step(bitrate: 3_000_000, scale: 0.75))
        // A small screen whose picture takes less than every step: one step, not straight to the bottom.
        var small = StreamQuality(codec: .h264, gameWidth: 256, gameHeight: 240)
        _ = Self.run(&small, from: 0, seconds: 2, rtt: 5)
        for t in [2.5, 3.0] { _ = small.update(StreamQuality.Sample(now: t, rtt: 60, minRTT: 50, sent: 30, decodeMs: 2, kbps: 200, fps: 60)) }
        #expect(small.index == 3, "past the doubled steps into the first normal-size one, not to the bottom")
        var image = StreamQuality(codec: .image, gameWidth: 640, gameHeight: 400)
        for i in 1...8 { _ = image.update(StreamQuality.Sample(now: Double(i) / 2, rtt: i < 7 ? 5 : 60, minRTT: 5, sent: 30, kbps: 3_000)) }
        #expect(image.index == 1, "JPEG quality steps always change the size, so one at a time")
    }

    @Test("The first 2 seconds (decoder starting up) never count as congestion")
    func warmUp() {
        var q = StreamQuality(codec: .h264, gameWidth: 256, gameHeight: 240)
        #expect(Self.run(&q, from: 0, seconds: 2, rtt: 300, minRTT: 1).allSatisfy { $0 == 0 })
        #expect(q.link(now: 2) != .weak)
        #expect(Self.run(&q, from: 2, seconds: 1, rtt: 300, minRTT: 1) == [0, 2], "then a second of severe delay drops two steps")
    }

    @Test("A second of severe delay drops two steps; one bad half second alone changes nothing")
    func severe() {
        var q = StreamQuality(codec: .h264, gameWidth: 640, gameHeight: 400)
        _ = Self.run(&q, from: 0, seconds: 2, rtt: 5)
        #expect(Self.run(&q, from: 2, seconds: 0.5, rtt: 200) == [0])
        #expect(Self.run(&q, from: 2.5, seconds: 0.5, rtt: 5) == [0], "a hiccup")
        #expect(Self.run(&q, from: 3, seconds: 2, rtt: 200) == [0, 2, 2, 4])
        _ = Self.run(&q, from: 3, seconds: 5, rtt: 200)
        #expect(q.index == q.steps.count - 1)
        #expect(q.step.halfRate && q.step.scale == 0.5, "big screens end smaller and at half rate")
    }

    @Test("Frames held back with some delay count as congestion; held back alone (a busy encoder) doesn't")
    func heldBack() {
        var q = StreamQuality(codec: .image, gameWidth: 640, gameHeight: 400)
        _ = Self.run(&q, from: 0, seconds: 2, rtt: 10)
        #expect(Self.run(&q, from: 2, seconds: 1, rtt: 10, minRTT: 10, held: 30, sent: 30).last == 0, "no delay: not the link")
        #expect(Self.run(&q, from: 3, seconds: 1, rtt: 16, minRTT: 15, held: 30, sent: 30).last == 1)
    }

    @Test("A phone that can't decode in time gets a smaller or slower picture, not just a lower bitrate")
    func decodeLimited() {
        var q = StreamQuality(codec: .h264, gameWidth: 256, gameHeight: 240)
        _ = Self.run(&q, from: 0, seconds: 2, rtt: 5)
        _ = Self.run(&q, from: 2, seconds: 1, rtt: 5, decode: 18)
        #expect(q.step.scale == 1, "straight past the doubled steps")
        #expect(q.index == q.steps.firstIndex { $0.scale == 1 })
    }

    @Test("Recovery: a step up after 2 clean seconds; one that brings delay back is held off, doubling, and waits 4")
    func recovery() {
        var q = StreamQuality(codec: .h264, gameWidth: 640, gameHeight: 400, startAt: 3)
        #expect(q.index == 3)
        let up = Self.run(&q, from: 0, seconds: 7, rtt: 10)
        #expect(up.firstIndex(of: 2) == 4, "after 2 seconds clean (the fifth window)")
        #expect(up.firstIndex(of: 1) == 8)
        #expect(up.last == 0)
        // Congestion right after that last step up (at 6.5 s): back down, and the top step is off limits for 5 s.
        _ = Self.run(&q, from: 7, seconds: 1, rtt: 60, minRTT: 50)
        #expect(q.index == 1)
        let held = Self.run(&q, from: 8, seconds: 5, rtt: 10)
        #expect(held.prefix(9).allSatisfy { $0 == 1 }, "4 s clean (it failed before) and the 5 s hold")
        #expect(held.last == 0)
        // Fails again straight away: the hold doubles to 10 s.
        _ = Self.run(&q, from: 13, seconds: 1, rtt: 60, minRTT: 50)
        #expect(q.index == 1)
        let longer = Self.run(&q, from: 14, seconds: 10, rtt: 10)
        #expect(longer.prefix(19).allSatisfy { $0 == 1 })
        #expect(longer.last == 0)
    }

    @Test("Ladders: H.264 doubles small screens and keeps big ones native; every ladder runs best to worst")
    func ladders() {
        for codec in [StreamQuality.Codec.h264, .image] {
            for small in [true, false] {
                let steps = StreamQuality.ladder(codec: codec, small: small)
                #expect(steps.count >= 5)
                for (a, b) in zip(steps, steps.dropFirst()) {
                    if codec == .h264 { #expect(b.bitrate < a.bitrate) }
                    #expect(b.scale <= a.scale)
                    #expect(!a.halfRate || b.halfRate, "half rate only at the end")
                }
            }
        }
        #expect(StreamQuality.ladder(codec: .h264, small: true)[0].scale == 2)
        #expect(StreamQuality.ladder(codec: .h264, small: false)[0].scale == 1)
        #expect(StreamQuality.ladder(codec: .image, small: true)[0] == StreamQuality.Step(), "small screens start as PNG, as before")
        #expect(StreamQuality.isSmall(width: 320, height: 240) && !StreamQuality.isSmall(width: 640, height: 400))
    }

    @Test("Frames in flight cover the round trip, at least 2 and at most 5")
    func window() {
        #expect(StreamQuality.framesInFlight(baseRTT: 1, fps: 60) == 2, "a fast link behaves as before")
        #expect(StreamQuality.framesInFlight(baseRTT: 30, fps: 60) == 3)
        #expect(StreamQuality.framesInFlight(baseRTT: 45, fps: 60) == 4)
        #expect(StreamQuality.framesInFlight(baseRTT: 300, fps: 60) == 5)
        #expect(StreamQuality.queueLimit(baseRTT: 30, fps: 60) == 63.333333333333336)
        #expect(StreamQuality.queueLimit(baseRTT: 2, fps: 30) == 2 + 2000.0 / 30)
    }
}
