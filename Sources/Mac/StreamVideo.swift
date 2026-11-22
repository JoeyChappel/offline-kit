import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import VideoToolbox
import Accelerate
import QuartzCore

// H.264 video for game streaming (see GameStream): the Mac's hardware encoder makes the picture a small, steady stream
// that a phone's browser decodes in hardware (WebCodecs). Pictures that don't go this way still go as PNG or JPEG.

/// The H.264 messages on the play socket. Byte layouts, little-endian (see play.js):
///   frame:  [4][u32 seq][u16 encode time, 0.1 ms][u16 width][u16 height][u8 flags: 1 = keyframe][AVCC NAL units]
///   config: [5][u16 coded width][u16 coded height][u16 game width][u16 game height][u8 n][codec, n ASCII bytes][avcC]
/// A config always comes just before the keyframe it describes, and again whenever the encoder changes (size, profile).
enum VideoWire {
    static let frameType: UInt8 = 4
    static let configType: UInt8 = 5
    static let frameHeaderSize = 12

    static func frameHeader(seq: UInt32, encodeMs: Double, width: Int, height: Int, keyframe: Bool, capacity: Int = 0) -> Data {
        var message = Data(capacity: frameHeaderSize + capacity)
        message.append(frameType)
        append(&message, seq)
        append(&message, UInt16(max(0, min(65535, encodeMs * 10))))
        append(&message, UInt16(clamping: width))
        append(&message, UInt16(clamping: height))
        message.append(keyframe ? 1 : 0)
        return message
    }

    static func config(codec: String, codedWidth: Int, codedHeight: Int, gameWidth: Int, gameHeight: Int, avcC: Data) -> Data {
        let name = Data(codec.utf8.prefix(255))
        var message = Data(capacity: 10 + name.count + avcC.count)
        message.append(configType)
        append(&message, UInt16(clamping: codedWidth))
        append(&message, UInt16(clamping: codedHeight))
        append(&message, UInt16(clamping: gameWidth))
        append(&message, UInt16(clamping: gameHeight))
        message.append(UInt8(name.count))
        message.append(name)
        message.append(avcC)
        return message
    }

    /// The WebCodecs codec string ("avc1.PPCCLL") for an avcC record (ISO 14496-15): its profile, constraint flags and
    /// level bytes, in hex.
    static func codecString(avcC: Data) -> String? {
        let bytes = [UInt8](avcC.prefix(4))
        guard bytes.count == 4, bytes[0] == 1 else { return nil }
        return String(format: "avc1.%02X%02X%02X", bytes[1], bytes[2], bytes[3])
    }

    struct Frame: Equatable {
        var seq: UInt32, encodeMs: Double, width: Int, height: Int, keyframe: Bool, payload: Data
    }

    static func parseFrame(_ data: Data) -> Frame? {
        let b = [UInt8](data.prefix(frameHeaderSize))
        guard b.count == frameHeaderSize, b[0] == frameType else { return nil }
        return Frame(seq: UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24,
                     encodeMs: Double(UInt16(b[5]) | UInt16(b[6]) << 8) / 10,
                     width: Int(UInt16(b[7]) | UInt16(b[8]) << 8), height: Int(UInt16(b[9]) | UInt16(b[10]) << 8),
                     keyframe: b[11] & 1 != 0, payload: data.dropFirst(frameHeaderSize))
    }

    struct Config: Equatable {
        var codec: String, codedWidth: Int, codedHeight: Int, gameWidth: Int, gameHeight: Int, avcC: Data
    }

    static func parseConfig(_ data: Data) -> Config? {
        let b = [UInt8](data)
        guard b.count >= 10, b[0] == configType else { return nil }
        let n = Int(b[9])
        guard b.count >= 10 + n, let codec = String(bytes: b[10..<(10 + n)], encoding: .ascii) else { return nil }
        func u16(_ at: Int) -> Int { Int(UInt16(b[at]) | UInt16(b[at + 1]) << 8) }
        return Config(codec: codec, codedWidth: u16(1), codedHeight: u16(3), gameWidth: u16(5), gameHeight: u16(7),
                      avcC: Data(b[(10 + n)...]))
    }

    /// Splits AVCC data (4-byte big-endian lengths) into NAL units; nil if the lengths don't add up.
    static func nalUnits(_ avcc: Data) -> [Data]? {
        var units: [Data] = []
        var i = avcc.startIndex
        while i < avcc.endIndex {
            guard avcc.endIndex - i >= 4 else { return nil }
            let n = Int(avcc[i]) << 24 | Int(avcc[i + 1]) << 16 | Int(avcc[i + 2]) << 8 | Int(avcc[i + 3])
            guard n > 0, avcc.endIndex - (i + 4) >= n else { return nil }
            units.append(avcc[(i + 4)..<(i + 4 + n)])
            i += 4 + n
        }
        return units
    }

    private static func append<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// Copies a picture from the core into an encoder's pixel buffer in one pass, scaled: whole-number scales repeat each
/// game pixel (sharp, as on screen), smaller ones are filtered. The core's pictures are BGRA in memory, or ARGB for the
/// 16-bit cores (byte-swapped here, so the buffer is always BGRA).
enum PixelCopy {
    /// True when the picture's memory is BGRA (little-endian 32-bit, alpha or skip first).
    static func isBGRA(_ image: CGImage) -> Bool {
        image.bitmapInfo.contains(.byteOrder32Little) && image.bitsPerPixel == 32
    }

    static func copy(_ image: CGImage, into buffer: CVPixelBuffer) -> Bool {
        guard image.bitsPerPixel == 32, let data = image.dataProvider?.data, let src = CFDataGetBytePtr(data) else { return false }
        let swap = !isBGRA(image)
        let sw = image.width, sh = image.height, srcRow = image.bytesPerRow
        guard CFDataGetLength(data) >= srcRow * sh else { return false }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let dst = CVPixelBufferGetBaseAddress(buffer) else { return false }
        let dw = CVPixelBufferGetWidth(buffer), dh = CVPixelBufferGetHeight(buffer), dstRow = CVPixelBufferGetBytesPerRow(buffer)
        if dw % sw == 0 && dh % sh == 0 && dw / sw == dh / sh {
            let k = dw / sw
            for y in 0..<sh {
                let from = UnsafeRawPointer(src + y * srcRow).assumingMemoryBound(to: UInt32.self)
                let firstRow = (dst + y * k * dstRow).assumingMemoryBound(to: UInt32.self)
                switch (k, swap) {
                case (1, false): memcpy(firstRow, from, sw * 4)
                case (1, true): for x in 0..<sw { firstRow[x] = from[x].byteSwapped }
                default:
                    var o = 0
                    for x in 0..<sw {
                        let p = swap ? from[x].byteSwapped : from[x]
                        for _ in 0..<k { firstRow[o] = p; o += 1 }
                    }
                }
                for r in 1..<max(1, k) { memcpy(dst + (y * k + r) * dstRow, firstRow, dw * 4) }
            }
            return true
        }
        // Any other size: a filtered scale, then the byte order.
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src), height: vImagePixelCount(sh), width: vImagePixelCount(sw), rowBytes: srcRow)
        var target = vImage_Buffer(data: dst, height: vImagePixelCount(dh), width: vImagePixelCount(dw), rowBytes: dstRow)
        guard vImageScale_ARGB8888(&source, &target, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
        if swap {
            let order: [UInt8] = [3, 2, 1, 0]
            guard vImagePermuteChannels_ARGB8888(&target, &target, order, vImage_Flags(kvImageNoFlags)) == kvImageNoError else { return false }
        }
        return true
    }
}

/// One hardware H.264 encoder at a fixed size: real time, no frame reordering (no B-frames, so every frame can be shown
/// as soon as it's decoded), low-latency rate control, a keyframe every 2 seconds and whenever asked.
final class H264Encoder: @unchecked Sendable {
    enum Profile: String, CaseIterable, Sendable {
        case high, main, baseline
        var level: CFString {
            switch self {
            case .high: kVTProfileLevel_H264_High_AutoLevel
            case .main: kVTProfileLevel_H264_Main_AutoLevel
            case .baseline: kVTProfileLevel_H264_ConstrainedBaseline_AutoLevel
            }
        }
    }

    enum Result {
        case frame(Output)
        /// The rate control left this picture out (it didn't fit the bitrate); the stream carries on without it.
        case dropped
        case failed
    }

    struct Output {
        /// AVCC NAL units (4-byte lengths), as WebCodecs takes them with an avcC description.
        var data: Data
        var keyframe: Bool
        /// The decoder setup for this stream, on keyframes.
        var avcC: Data?
        var encodeMs: Double
    }

    let width: Int
    let height: Int
    let profile: Profile
    private let session: VTCompressionSession
    private let pool: CVPixelBufferPool
    private(set) var bitrate: Int
    private(set) var fps: Double

    init?(width: Int, height: Int, fps: Double, bitrate: Int, profile: Profile) {
        self.width = width; self.height = height; self.profile = profile; self.bitrate = bitrate; self.fps = fps
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
                                     kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                           kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                                           kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        var made: VTCompressionSession?
        guard VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
                                         encoderSpecification: spec as CFDictionary, imageBufferAttributes: attributes as CFDictionary,
                                         compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &made) == noErr,
              let session = made else { return nil }
        self.session = session
        let settings: [CFString: CFTypeRef] = [
            kVTCompressionPropertyKey_RealTime: kCFBooleanTrue,
            kVTCompressionPropertyKey_ProfileLevel: profile.level,
            kVTCompressionPropertyKey_AllowFrameReordering: kCFBooleanFalse,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 2 as CFNumber,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: Int(fps * 2) as CFNumber,
            kVTCompressionPropertyKey_ExpectedFrameRate: fps as CFNumber,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in settings where VTSessionSetProperty(session, key: key, value: value) != noErr {
            if key == kVTCompressionPropertyKey_ProfileLevel || key == kVTCompressionPropertyKey_RealTime { VTCompressionSessionInvalidate(session); return nil }
        }
        if profile != .baseline { VTSessionSetProperty(session, key: kVTCompressionPropertyKey_H264EntropyMode, value: kVTH264EntropyMode_CABAC) }
        Self.applyRate(session, bitrate: bitrate, fps: fps)
        VTCompressionSessionPrepareToEncodeFrames(session)
        guard let pool = VTCompressionSessionGetPixelBufferPool(session) else { VTCompressionSessionInvalidate(session); return nil }
        self.pool = pool
    }

    deinit { VTCompressionSessionInvalidate(session) }

    /// The target bitrate. The low-latency rate control keeps to it frame by frame, dropping a frame rather than
    /// overshooting (measured: a screen of random text at 4 Mbit/s came out at 4.04, with frames dropped), so no
    /// separate data-rate cap is needed.
    private static func applyRate(_ session: VTCompressionSession, bitrate: Int, fps: Double) {
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
    }

    func setRate(bitrate: Int, fps: Double) {
        if bitrate != self.bitrate { Self.applyRate(session, bitrate: bitrate, fps: fps); self.bitrate = bitrate }
        if fps != self.fps {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
            self.fps = fps
        }
    }

    /// A buffer from the encoder's own pool (IOSurface-backed, so the hardware reads it in place).
    func makeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// Encodes one picture; `done` is called once, on the encoder's thread. `time`: the picture's time in seconds
    /// (now, when nil).
    func encode(_ buffer: CVPixelBuffer, keyframe: Bool, time at: Double? = nil, done finish: @escaping @Sendable (Result) -> Void) {
        let once = EncodeOnce(finish)
        let done = { (result: Result) in once.run(result) }
        let started = CACurrentMediaTime()
        // Real time: frames that didn't change aren't sent, and the rate control should see the gaps.
        let time = CMTime(seconds: at ?? started, preferredTimescale: 90_000)
        let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let status = VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: time, duration: .invalid,
                                                     frameProperties: properties, infoFlagsOut: nil) { status, flags, sample in
            guard status == noErr else { done(.failed); return }
            guard let sample, !flags.contains(.frameDropped), let block = CMSampleBufferGetDataBuffer(sample) else { done(.dropped); return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let isKey = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
            var avcC: Data?
            if isKey, let format = CMSampleBufferGetFormatDescription(sample),
               let atoms = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any] {
                avcC = atoms["avcC"] as? Data
            }
            let length = CMBlockBufferGetDataLength(block)
            var data = Data(count: length)
            let copied = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard copied == kCMBlockBufferNoErr else { done(.failed); return }
            done(.frame(Output(data: data, keyframe: isKey, avcC: avcC, encodeMs: (CACurrentMediaTime() - started) * 1000)))
        }
        if status != noErr { done(.failed) }
    }
}

/// Runs a completion at most once (an encode can fail both right away and in its callback).
private final class EncodeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var body: ((T) -> Void)?
    init(_ body: @escaping (T) -> Void) { self.body = body }
    func run(_ value: T) {
        let body = lock.withLock { () -> ((T) -> Void)? in defer { self.body = nil }; return self.body }
        body?(value)
    }
}
