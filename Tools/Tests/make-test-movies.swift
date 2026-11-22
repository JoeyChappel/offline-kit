// Makes small test movies for the automatic artwork (MovieArtwork): a black opening, an optional title card with the
// movie's name in big letters, moving "scenes", and closing credits in small text. Everything is drawn here (Core
// Graphics and Core Text) and written with AVAssetWriter, so no downloads and no ffmpeg filters are needed.
//
//   swift Tools/Tests/make-test-movies.swift <out folder> [minutes for the long one, default 20]
//
// Writes:
//   The Lighthouse Keeper (2021).mp4   2 min: black 3 s, title card at 3–9 s, scenes, credits
//   Harbor Lights.mp4                  2 min: no title card (best frame), scenes, credits
//   Night Train (1999).mp4             <minutes> long: black 20 s, a studio card, title card at 70–76 s, scenes, credits
import AVFoundation
import CoreGraphics
import CoreText
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make-test-movies.swift <out folder> [long minutes]"); exit(1) }
let out = URL(fileURLWithPath: args[1], isDirectory: true)
let longMinutes = args.count > 2 ? Double(args[2]) ?? 20 : 20
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let width = 1280, height = 720, fps: Int32 = 24
let space = CGColorSpace(name: CGColorSpace.sRGB)!

enum Segment {
    case black(Double)
    case card(Double, lines: [String], size: CGFloat, background: (Double, Double, Double))
    case scenes(Double, seed: Int)
    case credits(Double)
    var length: Double {
        switch self { case .black(let d), .card(let d, _, _, _), .scenes(let d, _), .credits(let d): d }
    }
}

func font(_ size: CGFloat, bold: Bool) -> CTFont {
    CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
}

func drawCentered(_ text: String, size: CGFloat, bold: Bool, y: CGFloat, alpha: CGFloat, in ctx: CGContext) {
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font(size, bold: bold),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: alpha),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let bounds = CTLineGetBoundsWithOptions(line, [])
    ctx.textPosition = CGPoint(x: (CGFloat(width) - bounds.width) / 2 - bounds.minX, y: y)
    CTLineDraw(line, ctx)
}

/// A pseudo-random generator, so the scenes are the same every run.
struct Random { var state: UInt64; mutating func next() -> Double { state = state &* 6364136223846793005 &+ 1442695040888963407; return Double(state >> 11) / Double(1 << 53) } }

func render(_ segment: Segment, local t: Double, into ctx: CGContext) {
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    switch segment {
    case .black: break
    case .card(let d, let lines, let size, let bg):
        let fade = min(1, min(t / 0.8, (d - t) / 0.8))
        ctx.setFillColor(CGColor(srgbRed: bg.0 * fade, green: bg.1 * fade, blue: bg.2 * fade, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let total = CGFloat(lines.count) * size * 1.15
        for (i, line) in lines.enumerated() {
            let y = CGFloat(height) / 2 + total / 2 - CGFloat(i + 1) * size * 1.15 + size * 0.25
            drawCentered(line, size: size, bold: true, y: y, alpha: CGFloat(max(0, fade)), in: ctx)
        }
    case .scenes(_, let seed):
        // A new "shot" every 4 seconds: a sky gradient, hills and moving shapes with fine texture (sharp, colourful).
        let shot = Int(t / 4)
        var r = Random(state: UInt64(seed * 1000 + shot + 1))
        let top = (r.next(), r.next(), r.next()), bottom = (r.next() * 0.6, r.next() * 0.6, r.next() * 0.6)
        let gradient = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1),
                                                               CGColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: height), end: CGPoint(x: 0, y: 0), options: [])
        let drift = CGFloat(t.truncatingRemainder(dividingBy: 4)) * 40
        for _ in 0..<14 {
            ctx.setFillColor(CGColor(srgbRed: r.next(), green: r.next(), blue: r.next(), alpha: 0.85))
            let s = CGFloat(40 + r.next() * 220)
            ctx.fillEllipse(in: CGRect(x: CGFloat(r.next()) * CGFloat(width) + drift, y: CGFloat(r.next()) * CGFloat(height), width: s, height: s))
        }
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35))
        ctx.setLineWidth(2)
        for i in stride(from: 0, to: width, by: 24) {
            ctx.move(to: CGPoint(x: i, y: 0)); ctx.addLine(to: CGPoint(x: i + 60, y: Int(160 + r.next() * 80)))
        }
        ctx.strokePath()
    case .credits(let d):
        let names = ["Director of Photography", "Production Design", "Costume Supervisor", "Gaffer", "Key Grip",
                     "Sound Mixer", "Boom Operator", "Script Supervisor", "Location Manager", "Casting", "Editor",
                     "Colorist", "Music", "Visual Effects", "Catering", "Transportation", "Legal", "Accounting"]
        let scroll = CGFloat(t / d) * 900
        for (i, name) in names.enumerated() {
            let y = CGFloat(i) * -44 + scroll + 300
            guard y > -30 && y < CGFloat(height) else { continue }
            drawCentered("\(name)    A. Person \(i + 1)", size: 22, bold: false, y: y, alpha: 1, in: ctx)
        }
    }
}

func write(_ name: String, _ segments: [Segment]) throws {
    let url = out.appending(path: name)
    try? FileManager.default.removeItem(at: url)
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 2_000_000, AVVideoMaxKeyFrameIntervalKey: 48],
    ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
    writer.add(input)
    writer.startWriting()
    writer.startSession(atSourceTime: .zero)
    var frame: Int64 = 0
    var start = 0.0
    for segment in segments {
        let frames = Int(segment.length * Double(fps))
        // Static parts are drawn every 6th frame (still smooth enough to test, and much quicker to make).
        var buffer: CVPixelBuffer?
        for i in 0..<frames {
            let t = Double(i) / Double(fps)
            let redraw: Bool = switch segment { case .black: buffer == nil; case .scenes: i % 6 == 0 || buffer == nil; default: i % 3 == 0 || buffer == nil }
            if redraw {
                var fresh: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &fresh)
                guard let fresh else { throw NSError(domain: "pool", code: 1) }
                CVPixelBufferLockBaseAddress(fresh, [])
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(fresh), width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: CVPixelBufferGetBytesPerRow(fresh), space: space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                render(segment, local: t, into: ctx)
                CVPixelBufferUnlockBaseAddress(fresh, [])
                buffer = fresh
            }
            while !input.isReadyForMoreMediaData { usleep(1000) }
            adaptor.append(buffer!, withPresentationTime: CMTime(value: frame, timescale: fps))
            frame += 1
        }
        start += segment.length
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    print("wrote \(url.path) (\(Int(start)) s)")
}

let navy = (0.05, 0.08, 0.20)
try write("The Lighthouse Keeper (2021).mp4", [
    .black(3), .card(6, lines: ["THE LIGHTHOUSE", "KEEPER"], size: 110, background: navy),
    .scenes(96, seed: 1), .credits(15),
])
try write("Harbor Lights.mp4", [.black(2), .scenes(103, seed: 2), .credits(15)])
let long = longMinutes * 60
try write("Night Train (1999).mp4", [
    .black(20), .card(8, lines: ["NORTHWIND PICTURES", "presents"], size: 48, background: (0, 0, 0)), .black(42),
    .card(6, lines: ["NIGHT TRAIN"], size: 150, background: (0.15, 0.02, 0.02)),
    .scenes(max(60, long - 76 - 40), seed: 3), .credits(40),
])
