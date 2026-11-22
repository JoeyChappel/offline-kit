import Foundation
import AVFoundation
import Vision
import CoreGraphics

// MARK: - Frame measurements

/// Brightness, contrast and sharpness of a frame, measured on a small grey copy.
struct FrameStats: Equatable, Sendable {
    /// Average brightness, 0…1.
    var mean: Double
    /// Standard deviation of brightness, 0…1.
    var deviation: Double
    /// 5th, 95th and 99th percentile brightness, 0…1.
    var low: Double
    var high: Double
    var peak: Double
    /// Variance of the Laplacian (0…255 scale): low for soft or blurry pictures.
    var sharpness: Double
    /// Share of pixels on a strong edge, 0…1: how much there is to look at.
    var detail: Double

    var contrast: Double { high - low }

    static func measure(_ image: CGImage, width: Int = 192) -> FrameStats? {
        guard image.width > 0, image.height > 0 else { return nil }
        let w = max(8, min(width, image.width))
        let h = max(8, Int((Double(w) * Double(image.height) / Double(image.width)).rounded()))
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        return measure(gray: pixels, width: w, height: h)
    }

    static func measure(gray pixels: [UInt8], width w: Int, height h: Int) -> FrameStats {
        var histogram = [Int](repeating: 0, count: 256)
        var sum = 0.0, squares = 0.0
        for p in pixels { histogram[Int(p)] += 1; let v = Double(p); sum += v; squares += v * v }
        let n = Double(pixels.count)
        let mean = sum / n
        let variance = max(0, squares / n - mean * mean)
        func percentile(_ q: Double) -> Double {
            let target = Int(q * n)
            var running = 0
            for (value, count) in histogram.enumerated() {
                running += count
                if running > target { return Double(value) / 255 }
            }
            return 1
        }
        var lapSum = 0.0, lapSquares = 0.0, edges = 0, inner = 0
        if w > 2 && h > 2 {
            for y in 1..<(h - 1) {
                let row = y * w
                for x in 1..<(w - 1) {
                    let c = Int(pixels[row + x])
                    let l = Int(pixels[row + x - 1]), r = Int(pixels[row + x + 1])
                    let u = Int(pixels[row - w + x]), d = Int(pixels[row + w + x])
                    let lap = Double(4 * c - l - r - u - d)
                    lapSum += lap; lapSquares += lap * lap
                    if abs(r - l) + abs(d - u) > 48 { edges += 1 }
                    inner += 1
                }
            }
        }
        let m = Double(max(1, inner))
        let lapMean = lapSum / m
        return FrameStats(mean: mean / 255, deviation: variance.squareRoot() / 255,
                          low: percentile(0.05), high: percentile(0.95), peak: percentile(0.99),
                          sharpness: max(0, lapSquares / m - lapMean * lapMean), detail: Double(edges) / m)
    }
}

/// Why a frame won't do as a movie's picture.
enum FrameRejection: String, Sendable {
    case black, flat, faded, blurry, credits
}

enum FrameCheck {
    /// Nothing to show: black (or nearly), or one flat colour. A title card's white words on black pass.
    static func isBlank(_ s: FrameStats) -> Bool { s.peak < 0.22 || s.deviation < 0.02 }

    /// The best-frame rules: no black, flat, washed-out or soft frames.
    static func rejection(_ s: FrameStats) -> FrameRejection? {
        if s.peak < 0.22 || s.mean < 0.07 { return .black }
        if s.deviation < 0.04 { return .flat }
        if s.contrast < 0.2 { return .faded }
        if s.sharpness < 20 { return .blurry }
        return nil
    }

    /// Lots of small lines of text: credits, a cast list, a disclaimer. Boxes are Vision's (0…1, either origin).
    static func looksLikeCredits(_ lines: [CGRect]) -> Bool {
        guard lines.count >= 5 else { return false }
        let heights = lines.map(\.height).sorted()
        return heights[heights.count / 2] < 0.05 || lines.count >= 10
    }
}

// MARK: - Title matching

/// Does text read off a frame say the movie's (or game's) title? Case, accents, punctuation and articles are ignored,
/// and small reading mistakes are forgiven ("TEARS 0F STEEL", "TEARSOFSTEEL").
enum TitleMatch {
    static let articles: Set<String> = ["the", "a", "an", "le", "la", "les", "el", "los", "der", "die", "das"]

    /// "The Lord of the Rings: Return (2003)" → ["lord", "of", "rings", "return"].
    static func words(_ text: String) -> [String] {
        let trimmed = MediaCatalog.displayTitle(text)
        let folded = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "&", with: " and ")
        let plain = String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })
        return plain.split(separator: " ").map(String.init).filter { !articles.contains($0) }
    }

    /// 0…1: how much of the title the text holds.
    static func score(_ recognized: String, title: String) -> Double {
        let wanted = words(title)
        guard !wanted.isEmpty else { return 0 }
        let seen = words(recognized)
        guard !seen.isEmpty else { return 0 }
        var matched = 0.0
        for word in wanted {
            let best = seen.map { similarity(word, $0) }.max() ?? 0
            let needed = word.count <= 2 ? 1.0 : 0.75
            if best >= needed { matched += best }
        }
        let byWord = matched / Double(wanted.count)
        // Words run together or split differently on screen: compare the letters alone.
        let target = Array(wanted.joined())
        let text = Array(seen.joined().prefix(400))
        var joined = 0.0
        if target.count >= 4, text.count >= target.count - 1 {
            for length in Set([target.count - 1, target.count, target.count + 1]) where length > 0 && length <= text.count {
                for start in 0...(text.count - length) {
                    joined = max(joined, similarity(target, Array(text[start..<(start + length)])))
                    if joined == 1 { break }
                }
            }
            if joined < 0.8 { joined = 0 }
        }
        return max(byWord, joined)
    }

    static func matches(_ recognized: String, title: String) -> Bool { score(recognized, title: title) >= 0.75 }

    static func similarity(_ a: String, _ b: String) -> Double { similarity(Array(a), Array(b)) }

    static func similarity(_ a: [Character], _ b: [Character]) -> Double {
        if a == b { return 1 }
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return 1 - Double(previous[b.count]) / Double(max(a.count, b.count))
    }
}

// MARK: - Reading text

struct TextLine: Sendable {
    var text: String
    var box: CGRect
}

enum FrameText {
    /// Lines of text Vision finds. `fast` for scanning many frames, accurate to confirm a few.
    static func read(_ image: CGImage, accurate: Bool, minimumHeight: Float = 0) -> [TextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = accurate ? .accurate : .fast
        // Off for both: language correction looks words up in the user's own lexicon (Contacts among it), which is
        // slow, needs nothing here, and could ask for access to Contacts.
        request.usesLanguageCorrection = false
        if minimumHeight > 0 { request.minimumTextHeight = minimumHeight }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            observation.topCandidates(1).first.map { TextLine(text: $0.string, box: observation.boundingBox) }
        }
    }

    /// The title-card score: how well the text matches, lifted for big words near the middle of the picture.
    static func titleScore(_ lines: [TextLine], title: String) -> Double {
        let all = lines.map(\.text).joined(separator: " ")
        let match = TitleMatch.score(all, title: title)
        guard match > 0 else { return 0 }
        let parts = lines.filter { TitleMatch.score($0.text, title: title) > 0.3 }
        let tallest = parts.map(\.box.height).max() ?? 0
        let centered = parts.map { 1 - min(1, hypot($0.box.midX - 0.5, $0.box.midY - 0.5) * 2) }.max() ?? 0
        return match * (0.7 + 0.3 * min(1, Double(tallest) / 0.12)) * (0.85 + 0.15 * Double(centered))
    }
}

// MARK: - Movies

/// A movie's picture: its title card when the opening shows the title, else the best-looking frame from the middle.
///
/// Title card: frames every 5 seconds through the first 5 minutes (at most a third of the movie, 60 frames) are read
/// with Vision's fast text recognition; the few whose text looks like the title are read again accurately, a second
/// either side, and the strongest match with big, centred words wins. Otherwise 12 frames between 8% and 70% lose the
/// black, flat, faded, soft and credit-like ones, and the rest are scored by Vision's aesthetics score with faces and
/// saliency as tie-breaks. Frames are decoded small (480 px) with a loose time tolerance; only the winner is read at 960.
enum MovieArtwork {
    struct Record: Codable {
        var art: String
        /// Ranked times: the automatic choice first, then the alternatives "Pick Another Frame" walks through.
        var times: [Double]
        var pick = 0
        var file: String?
        /// How long the look took, for timing reports.
        var seconds: Double?
    }

    private final class Picks: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Int] = [:]
    }
    private static let picks = Picks()

    static func hasPick(_ url: URL) -> Bool { (picks.lock.withLock { picks.values[url.path] } ?? 0) > 0 }

    nonisolated static func recordURL(_ key: String) -> URL { ArtworkFiles.folder.appending(path: "gen-\(key).json") }

    nonisolated static func readRecord(_ key: String) -> Record? {
        (try? Data(contentsOf: recordURL(key))).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
    }

    nonisolated static func writeRecord(_ record: Record, key: String) {
        try? FileManager.default.createDirectory(at: ArtworkFiles.folder, withIntermediateDirectories: true)
        try? JSONEncoder().encode(record).write(to: recordURL(key), options: .atomic)
    }

    /// The movie's picture, made now or found from before. Nil when no frame could be read.
    static func generate(_ url: URL, title: String) async -> (path: String, art: GeneratedArt)? {
        await Task.detached(priority: .utility) { () -> (String, GeneratedArt)? in
            guard let key = ArtworkRules.key(for: url, kind: "movie") else { return nil }
            if let record = readRecord(key) {
                picks.lock.withLock { picks.values[url.path] = record.pick }
                if let file = record.file {
                    let path = ArtworkFiles.folder.appending(path: file).path
                    if FileManager.default.fileExists(atPath: path) { return (path, GeneratedArt(rawValue: record.art) ?? .frame) }
                } else { return nil }
            }
            let started = Date()
            guard let analysis = await analyze(url, title: title), let time = analysis.times.first,
                  let image = await frame(url, at: time, size: 960) else {
                writeRecord(Record(art: GeneratedArt.none.rawValue, times: [], file: nil, seconds: Date().timeIntervalSince(started)), key: key)
                return nil
            }
            let file = "gen-\(key).jpg"
            guard ArtworkFiles.writeJPEG(image, to: ArtworkFiles.folder.appending(path: file)) else { return nil }
            writeRecord(Record(art: analysis.art.rawValue, times: analysis.times, file: file, seconds: Date().timeIntervalSince(started)), key: key)
            picks.lock.withLock { picks.values[url.path] = 0 }
            return (ArtworkFiles.folder.appending(path: file).path, analysis.art)
        }.value
    }

    /// "Pick Another Frame": the next time in the ranked list (wrapping round).
    static func nextFrame(_ url: URL) async -> (path: String, art: GeneratedArt)? { await choose(url) { ($0 + 1) } }

    /// "Reset Artwork": back to the automatic choice.
    static func resetPick(_ url: URL) async -> (path: String, art: GeneratedArt)? { await choose(url) { _ in 0 } }

    private static func choose(_ url: URL, _ next: @escaping @Sendable (Int) -> Int) async -> (path: String, art: GeneratedArt)? {
        await Task.detached(priority: .userInitiated) { () -> (String, GeneratedArt)? in
            guard let key = ArtworkRules.key(for: url, kind: "movie"), var record = readRecord(key), !record.times.isEmpty else { return nil }
            let pick = next(record.pick) % record.times.count
            guard let image = await frame(url, at: record.times[pick], size: 960) else { return nil }
            // A new name for each pick, so pictures already on screen see a new path and reload.
            let file = pick == 0 ? "gen-\(key).jpg" : "gen-\(key)-p\(pick).jpg"
            guard ArtworkFiles.writeJPEG(image, to: ArtworkFiles.folder.appending(path: file)) else { return nil }
            if let old = record.file, old != file, old != "gen-\(key).jpg" { try? FileManager.default.removeItem(at: ArtworkFiles.folder.appending(path: old)) }
            record.pick = pick
            record.file = file
            writeRecord(record, key: key)
            picks.lock.withLock { picks.values[url.path] = pick }
            let art: GeneratedArt = pick == 0 ? (GeneratedArt(rawValue: record.art) ?? .frame) : .frame
            return (ArtworkFiles.folder.appending(path: file).path, art == .none ? .frame : art)
        }.value
    }

    struct Analysis {
        var art: GeneratedArt
        var times: [Double]
    }

    /// Works out the ranked times. Separate from writing, for timing tests.
    static func analyze(_ url: URL, title: String) async -> Analysis? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0.5,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        let titleTime = await findTitleCard(asset, duration: duration, title: title)
        if Task.isCancelled { return nil }
        var ranked = await rankFrames(asset, duration: duration)
        if let titleTime {
            ranked.removeAll { abs($0 - titleTime) < 1 }
            ranked.insert(titleTime, at: 0)
        }
        guard !ranked.isEmpty else { return nil }
        return Analysis(art: titleTime != nil ? .titleCard : .frame, times: Array(ranked.prefix(12)))
    }

    private static func generator(_ asset: AVAsset, size: CGFloat, tolerance: Double) -> AVAssetImageGenerator {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: size, height: size)
        generator.requestedTimeToleranceBefore = CMTime(seconds: tolerance, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: tolerance, preferredTimescale: 600)
        return generator
    }

    /// Frames at these times, as they decode (some may be missing).
    private static func frames(_ asset: AVAsset, at times: [Double], size: CGFloat, tolerance: Double) async -> [(time: Double, image: CGImage)] {
        let generator = generator(asset, size: size, tolerance: tolerance)
        var out: [(Double, CGImage)] = []
        for await result in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            if Task.isCancelled { generator.cancelAllCGImageGeneration(); break }
            if let image = try? result.image, let actual = try? result.actualTime { out.append((actual.seconds, image)) }
        }
        return out
    }

    static func frame(_ url: URL, at seconds: Double, size: CGFloat) async -> CGImage? {
        let generator = generator(AVURLAsset(url: url), size: size, tolerance: 0.25)
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// The time of the frame that shows the title, if the opening has one.
    static func findTitleCard(_ asset: AVAsset, duration: Double, title: String) async -> Double? {
        guard !TitleMatch.words(title).isEmpty else { return nil }
        let end = min(300, max(15, duration * 0.35), duration - 0.25)
        let times = Array(stride(from: min(1, duration / 4), to: end, by: 5).prefix(60))
        guard !times.isEmpty else { return nil }
        var candidates: [(time: Double, score: Double)] = []
        let generator = generator(asset, size: 480, tolerance: 1.5)
        var sinceStrong: Int?
        for await result in generator.images(for: times.map { CMTime(seconds: $0, preferredTimescale: 600) }) {
            if Task.isCancelled { generator.cancelAllCGImageGeneration(); return nil }
            guard let image = try? result.image, let actual = try? result.actualTime else { continue }
            if let n = sinceStrong { if n >= 2 { generator.cancelAllCGImageGeneration(); break }; sinceStrong = n + 1 }
            guard let stats = FrameStats.measure(image, width: 128), !FrameCheck.isBlank(stats) else { continue }
            let lines = FrameText.read(image, accurate: false, minimumHeight: 0.03)
            let score = FrameText.titleScore(lines, title: title)
            if score >= 0.45 {
                candidates.append((actual.seconds, score))
                if score >= 0.85, sinceStrong == nil { sinceStrong = 0 }
            }
        }
        // Confirm the best few with accurate reading, a second either side (a title fading in or out reads better).
        var best: (time: Double, score: Double)?
        for candidate in candidates.sorted(by: { $0.score > $1.score }).prefix(3) {
            let around = [candidate.time, candidate.time + 1, max(0, candidate.time - 1)].filter { $0 < duration }
            for (time, image) in await frames(asset, at: around, size: 960, tolerance: 0.2) {
                guard let stats = FrameStats.measure(image, width: 128), !FrameCheck.isBlank(stats) else { continue }
                let score = FrameText.titleScore(FrameText.read(image, accurate: true), title: title) * (0.8 + 0.2 * min(1, stats.contrast / 0.6))
                if score > (best?.score ?? 0) { best = (time, score) }
            }
        }
        guard let best, best.score >= 0.6 else { return nil }
        return best.time
    }

    /// Times between 8% and 70%, best first, without black, flat, faded, soft or credit-like frames.
    static func rankFrames(_ asset: AVAsset, duration: Double) async -> [Double] {
        let times = (0..<12).map { duration * (0.08 + 0.62 * Double($0) / 11) }
        var scored: [(time: Double, score: Double)] = []
        var fallback: [(time: Double, score: Double)] = []
        for (time, image) in await frames(asset, at: times, size: 480, tolerance: 2) {
            if Task.isCancelled { return [] }
            guard let stats = FrameStats.measure(image) else { continue }
            if FrameCheck.rejection(stats) != nil {
                if !FrameCheck.isBlank(stats) { fallback.append((time, stats.deviation + stats.sharpness / 2000)) }
                continue
            }
            let lines = FrameText.read(image, accurate: false, minimumHeight: 0.015)
            if FrameCheck.looksLikeCredits(lines.map(\.box)) { continue }
            scored.append((time, score(image, stats: stats, text: lines.count)))
        }
        let ranked = scored.sorted { $0.score > $1.score }.map(\.time)
        return ranked.isEmpty ? fallback.sorted { $0.score > $1.score }.map(\.time) : ranked
    }

    /// Higher is better: Vision's aesthetics score where the system has it, faces and a clear subject as tie-breaks,
    /// and a little for sharpness and contrast (all there is when aesthetics scoring isn't available).
    static func score(_ image: CGImage, stats: FrameStats, text: Int) -> Double {
        var total = min(1, stats.sharpness / 600) * 0.15 + min(1, stats.contrast / 0.7) * 0.1 - Double(min(text, 4)) * 0.03
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        var requests: [VNRequest] = [faces, saliency]
        var aesthetics: VNRequest?
        if #available(macOS 15.0, iOS 18.0, *) {
            let request = VNCalculateImageAestheticsScoresRequest()
            requests.append(request)
            aesthetics = request
        }
        try? handler.perform(requests)
        if #available(macOS 15.0, iOS 18.0, *), let result = (aesthetics as? VNCalculateImageAestheticsScoresRequest)?.results?.first {
            total += Double(result.overallScore)
            if result.isUtility { total -= 0.3 }
        }
        if let found = faces.results, !found.isEmpty {
            let biggest = found.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 0
            total += 0.12 + min(0.08, Double(biggest))
        }
        if let salient = (saliency.results?.first)?.salientObjects?.max(by: { $0.confidence < $1.confidence }) {
            let box = salient.boundingBox
            total += 0.05 * Double(1 - min(1, hypot(box.midX - 0.5, box.midY - 0.5) * 2))
        }
        return total
    }
}
