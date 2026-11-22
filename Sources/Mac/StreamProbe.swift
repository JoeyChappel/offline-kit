#if DEBUG
import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox
import QuartzCore

/// Test hook (-streamQualityProbe YES): decodes what game streaming sends, as the device would, and measures it
/// against the game's own picture: PSNR over RGB and SSIM over brightness (8×8 blocks), twice a second. H.264 needs
/// every frame decoded (each builds on the last), so this costs a hardware decode per frame; it's for test runs only.
final class StreamProbe: @unchecked Sendable {
    private let queue = DispatchQueue(label: "OfflineKit.GameStream.probe", qos: .utility)
    private let lock = NSLock()
    private var psnr: [Double] = []
    private var ssim: [Double] = []
    // Probe queue only.
    private var decoder: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var lastMeasured: TimeInterval = 0
    private var busy = false

    func takeResults() -> [String: Any] {
        lock.withLock {
            defer { psnr.removeAll(); ssim.removeAll() }
            guard !psnr.isEmpty else { return [:] }
            return ["psnr": psnr.reduce(0, +) / Double(psnr.count), "psnrMin": psnr.min() ?? 0,
                    "ssim": ssim.reduce(0, +) / Double(ssim.count)]
        }
    }

    private func record(_ result: (psnr: Double, ssim: Double)) {
        lock.withLock { psnr.append(result.psnr); ssim.append(result.ssim) }
    }

    /// Whether it's time for another measurement (twice a second), checked on the probe queue.
    private func due() -> Bool {
        let now = CACurrentMediaTime()
        guard now - lastMeasured >= 0.5 else { return false }
        lastMeasured = now
        return true
    }

    func sentImage(original: CGImage, encoded: Data) {
        queue.async { [self] in
            guard due(), let source = CGImageSourceCreateWithData(encoded as CFData, nil),
                  let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
            let w = decoded.width, h = decoded.height
            // A scaled-down picture is measured against the game's picture scaled the same way.
            guard let a = Self.pixels(original, width: w, height: h), let b = Self.pixels(decoded, width: w, height: h) else { return }
            record(Self.compare(a, b, width: w, height: h))
        }
    }

    func sentH264(image: CGImage, config: Data?, frame: Data, keyframe: Bool, width: Int, height: Int) {
        queue.async { [self] in
            if let config, let parsed = VideoWire.parseConfig(config) { makeDecoder(avcC: parsed.avcC) }
            guard let decoder, let format else { return }
            let measure = due()
            guard let sample = Self.sampleBuffer(frame, format: format) else { return }
            var decoded: CVImageBuffer?
            VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
                if status == noErr { decoded = buffer }
            }
            guard measure, let decoded, let reference = Self.pixels(image, width: width, height: height) else { return }
            CVPixelBufferLockBaseAddress(decoded, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(decoded) else { return }
            let row = CVPixelBufferGetBytesPerRow(decoded)
            var tight = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<height { memcpy(&tight[y * width * 4], base + y * row, width * 4) }
            record(Self.compare(reference, tight, width: width, height: height))
            save(reference, tight, width: width, height: height)
        }
    }

    /// -streamProbeSave <folder>: the first few measured pairs as PNG files (reference, then as decoded), to look at.
    private var saved = 0
    private func save(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) {
        guard saved < 6, let folder = UserDefaults.standard.string(forKey: "streamProbeSave") else { return }
        saved += 1
        for (name, pixels) in [("ref", a), ("dec", b)] {
            var copy = pixels
            copy.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                      let image = context.makeImage(),
                      let out = CGImageDestinationCreateWithURL(URL(fileURLWithPath: folder).appendingPathComponent("\(saved)-\(name).png") as CFURL,
                                                                UTType.png.identifier as CFString, 1, nil) else { return }
                CGImageDestinationAddImage(out, image, nil)
                CGImageDestinationFinalize(out)
            }
        }
    }

    private func makeDecoder(avcC: Data) {
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil; format = nil
        var made: CMFormatDescription?
        guard let units = Self.parameterSets(avcC), units.count >= 2 else { return }
        let status = units[0].withUnsafeBytes { sps in units[1].withUnsafeBytes { pps in
            let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
            let sizes = [units[0].count, units[1].count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers,
                                                                       parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &made)
        } }
        guard status == noErr, let made else { return }
        let output = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA] as CFDictionary
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: made, decoderSpecification: nil, imageBufferAttributes: output,
                                           outputCallback: nil, decompressionSessionOut: &session) == noErr else { return }
        decoder = session; format = made
    }

    /// The first SPS and PPS in an avcC record.
    static func parameterSets(_ avcC: Data) -> [Data]? {
        let b = [UInt8](avcC)
        guard b.count > 8 else { return nil }
        var i = 6
        let spsLength = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
        guard b.count >= i + spsLength + 3 else { return nil }
        let sps = Data(b[i..<(i + spsLength)]); i += spsLength
        i += 1   // PPS count
        let ppsLength = Int(b[i]) << 8 | Int(b[i + 1]); i += 2
        guard b.count >= i + ppsLength else { return nil }
        return [sps, Data(b[i..<(i + ppsLength)])]
    }

    static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var size = data.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
                                        sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }

    /// A picture's pixels at a size, BGRA: whole-number enlargements repeat pixels (as the encoder's input does),
    /// anything else is filtered.
    static func pixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        let ok = out.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return false }
            let whole = width % image.width == 0 && height % image.height == 0
            context.interpolationQuality = whole ? .none : .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? out : nil
    }

    /// PSNR over the three colour channels, and mean SSIM over 8×8 blocks of brightness, for two BGRA pictures.
    static func compare(_ a: [UInt8], _ b: [UInt8], width: Int, height: Int) -> (psnr: Double, ssim: Double) {
        var squared: Double = 0
        for i in stride(from: 0, to: width * height * 4, by: 4) {
            for c in 0..<3 { let d = Double(Int(a[i + c]) - Int(b[i + c])); squared += d * d }
        }
        let mse = squared / Double(width * height * 3)
        let psnr = mse == 0 ? 99 : min(99, 10 * log10(255 * 255 / mse))
        func luma(_ p: [UInt8], _ i: Int) -> Double { 0.114 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.299 * Double(p[i + 2]) }
        let c1: Double = 6.5025, c2: Double = 58.5225   // (0.01 × 255)², (0.03 × 255)²
        var total: Double = 0, blocks = 0
        for by in stride(from: 0, through: height - 8, by: 8) {
            for bx in stride(from: 0, through: width - 8, by: 8) {
                var sa = 0.0, sb = 0.0, saa = 0.0, sbb = 0.0, sab = 0.0
                for y in by..<(by + 8) {
                    for x in bx..<(bx + 8) {
                        let i = (y * width + x) * 4
                        let p = luma(a, i), q = luma(b, i)
                        sa += p; sb += q; saa += p * p; sbb += q * q; sab += p * q
                    }
                }
                let n = 64.0
                let ma = sa / n, mb = sb / n
                let va = saa / n - ma * ma, vb = sbb / n - mb * mb, cov = sab / n - ma * mb
                total += ((2 * ma * mb + c1) * (2 * cov + c2)) / ((ma * ma + mb * mb + c1) * (va + vb + c2))
                blocks += 1
            }
        }
        return (psnr, blocks > 0 ? total / Double(blocks) : 1)
    }
}

/// Test hook (-streamDumpFrames <folder>): keeps the first 600 changed pictures the stream sends as PNG files.
final class FrameDump: @unchecked Sendable {
    private let folder: URL
    private let queue = DispatchQueue(label: "OfflineKit.GameStream.dump", qos: .utility)
    private var count = 0

    init(folder: String) {
        self.folder = URL(fileURLWithPath: folder)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
    }

    /// -streamDumpSkip <n>: skips the first n pictures (title screens).
    private var skip = UserDefaults.standard.integer(forKey: "streamDumpSkip")

    func add(_ image: CGImage) {
        queue.async { [self] in
            if skip > 0 { skip -= 1; return }
            guard count < 600 else { return }
            let url = folder.appendingPathComponent(String(format: "frame-%04d.png", count))
            count += 1
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}
#endif
