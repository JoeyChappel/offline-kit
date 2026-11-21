import Foundation
import Observation

@MainActor @Observable
final class DownloadJob: @MainActor Identifiable {
    enum State: Equatable { case queued, preparing, downloading, verifying, paused, done, failed(String) }

    let fileName: String
    let title: String
    let name: String           // catalog name, e.g. wikipedia_en_medicine
    let metalinkURL: URL
    let folder: URL
    var total: Int64
    var done: Int64 = 0
    var bytesPerSecond: Double = 0
    var state: State = .queued
    /// For single-URL downloads (AI models) that have no Kiwix .meta4 mirror list.
    var presetMeta: Metalink?
    fileprivate var task: Task<Void, Never>?

    var id: String { folder.path + "/" + fileName }
    var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var isActive: Bool { [.preparing, .downloading, .verifying].contains(state) }
    var isFinished: Bool { state == .done }

    init(fileName: String, title: String, name: String, metalinkURL: URL, folder: URL, total: Int64) {
        self.fileName = fileName
        self.title = title
        self.name = name
        self.metalinkURL = metalinkURL
        self.folder = folder
        self.total = total
    }

    /// "3.2 GB of 8.2 GB · 24 MB/s · 4 min left"
    var detail: String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch state {
        case .queued: return "Waiting · \(fmt(total))"
        case .preparing: return "Contacting mirrors…"
        case .paused: return "Paused · \(fmt(done)) of \(fmt(total))"
        case .verifying: return "Checking the file · \(Int(fraction * 100))%"
        case .done: return "Installed · \(fmt(total))"
        case .failed(let message): return message
        case .downloading:
            var parts = ["\(fmt(done)) of \(fmt(total))"]
            if bytesPerSecond > 0 {
                parts.append("\(fmt(Int64(bytesPerSecond)))/s")
                let seconds = Double(total - done) / bytesPerSecond
                let left = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
                parts.append("\(left) left")
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// Queue of archive downloads. One runs at a time, using several mirrors at once.
@MainActor @Observable
final class DownloadManager {
    private(set) var jobs: [DownloadJob] = []
    /// Called after an archive finishes so the library can pick it up.
    var onInstalled: (() -> Void)?

    var activeCount: Int { jobs.filter { $0.isActive || $0.state == .queued }.count }
    /// Download speed smoothed across chunks and carried between files, for steady time estimates.
    private(set) var smoothedSpeed: Double = 0

    /// One line of progress for everything in the list, for the sidebar, Library and onboarding.
    var summary: DownloadSummary? {
        guard !jobs.isEmpty else { return nil }
        let failed = jobs.filter { if case .failed = $0.state { return true } else { return false } }.count
        let finished = jobs.filter(\.isFinished).count
        let bytesTotal = jobs.reduce(Int64(0)) { $0 + $1.total }
        let bytesDone = jobs.reduce(Int64(0)) { $0 + ($1.isFinished ? $1.total : $1.done) }
        let running = jobs.contains { $0.isActive || $0.state == .queued }
        let remaining = Double(max(0, bytesTotal - bytesDone))
        return DownloadSummary(count: jobs.count, finished: finished, failed: failed,
                               bytesDone: bytesDone, bytesTotal: bytesTotal,
                               secondsLeft: running && smoothedSpeed > 0 ? remaining / smoothedSpeed : nil,
                               current: jobs.first(where: \.isActive)?.title,
                               isRunning: running)
    }

    #if DEBUG
    /// Test hook (-sampleDownloads YES): a believable in-progress batch, with no network, for screenshots.
    func insertSamples(folder: URL) {
        let gb: Int64 = 1_000_000_000
        let items: [(String, Int64, Int64, DownloadJob.State)] = [
            ("Ready.gov disaster plans", 2 * gb, 2 * gb, .done),
            ("WikiMed medical encyclopedia", 2 * gb, 2 * gb, .done),
            ("iFixit repair guides", 3 * gb, 1_200_000_000, .downloading),
            ("After a disaster", 645_000_000, 0, .queued),
            ("Safe drinking water", 21_000_000, 0, .queued),
        ]
        for (title, total, done, state) in items {
            let job = DownloadJob(fileName: title + ".zim", title: title, name: title, metalinkURL: URL(string: "https://example.invalid")!,
                                  folder: folder, total: total)
            job.done = done; job.state = state
            if state == .downloading { job.bytesPerSecond = 6_500_000 }
            jobs.append(job)
        }
        smoothedSpeed = 6_500_000
    }
    #endif

    fileprivate func note(speed: Double) {
        guard speed > 0 else { return }
        smoothedSpeed = smoothedSpeed == 0 ? speed : smoothedSpeed * 0.85 + speed * 0.15
    }

    func job(named name: String) -> DownloadJob? {
        jobs.last { $0.name == name && $0.state != .done }
    }

    func enqueue(_ entry: CatalogEntry, to folder: URL) {
        guard !jobs.contains(where: { $0.fileName == entry.fileName && $0.folder == folder && $0.state != .done }) else { return }
        jobs.append(DownloadJob(fileName: entry.fileName, title: entry.title, name: entry.name,
                                metalinkURL: entry.metalink, folder: folder, total: entry.size))
        pump()
    }

    /// Queues a built-in AI model into `folder` (a library's Models folder).
    func enqueue(model: LocalModel, to folder: URL) {
        guard !jobs.contains(where: { $0.fileName == model.fileName && $0.state != .done }) else { return }
        let job = DownloadJob(fileName: model.fileName, title: model.title, name: model.id,
                              metalinkURL: model.url, folder: folder, total: model.size)
        job.presetMeta = model.metalink
        jobs.append(job)
        pump()
    }

    /// Picks up partial downloads left in these folders (app quit, Mac slept, drive unplugged).
    func restore(from folders: [URL]) {
        for folder in folders + folders.map(LocalModels.folder(forLibrary:)) {
            for saved in ChunkedDownload.saved(in: folder)
            where !jobs.contains(where: { $0.fileName == saved.meta.fileName && $0.folder == folder }) {
                let model = LocalModels.all.first { $0.fileName == saved.meta.fileName }
                // Single-file downloads (AI models) resume only from the app's own list of models, never from
                // mirrors and hashes read back from a drive.
                if saved.metalinkURL.pathExtension != "meta4", model == nil { continue }
                let name = model?.id ?? saved.meta.fileName.replacingOccurrences(
                    of: #"(_(maxi|nopic|mini|full))?_\d{4}-\d{2}\.zim$"#, with: "", options: .regularExpression)
                let job = DownloadJob(fileName: saved.meta.fileName, title: model?.title ?? saved.title, name: name,
                                      metalinkURL: saved.metalinkURL, folder: folder, total: saved.meta.size)
                job.done = saved.bytesDone
                job.state = .paused
                // Single-file downloads (AI models) have no .meta4 to refetch.
                if saved.metalinkURL.pathExtension != "meta4" { job.presetMeta = model?.metalink }
                jobs.append(job)
            }
        }
    }

    /// Bytes that queued, running and paused downloads still have to write to the same drive as `folder`.
    /// Free space only shrinks as they arrive, so the space check subtracts this up front.
    func bytesStillNeeded(on folder: URL) -> Int64 {
        func volume(_ url: URL) -> AnyObject? {
            var probe = url
            while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" { probe.deleteLastPathComponent() }
            return (try? probe.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as AnyObject?
        }
        let target = volume(folder)
        return jobs.filter { job in
            switch job.state {
            case .queued, .preparing, .downloading, .verifying, .paused: return true
            default: return false
            }
        }.filter { job in
            guard let target, let other = volume(job.folder) else { return job.folder.standardizedFileURL == folder.standardizedFileURL }
            return target.isEqual(other)
        }.reduce(Int64(0)) { $0 + max(0, $1.total - $1.done) }
    }

    func pause(_ job: DownloadJob) {
        job.task?.cancel()
        job.task = nil
        job.state = .paused
        pump()
    }

    func resume(_ job: DownloadJob) {
        guard job.state == .paused || { if case .failed = job.state { return true } else { return false } }() else { return }
        job.state = .queued
        pump()
    }

    func resumeAll() { for job in jobs where job.state == .paused { job.state = .queued }; pump() }

    /// At launch, picks up only downloads into this Mac's own kit (or the drive the app runs from). Ones left on
    /// another drive wait for a click, so plugging a drive in never starts downloads by itself.
    func resumeOwn() {
        let portable = KitLocation.portableRoot?.standardizedFileURL.path
        for job in jobs where job.state == .paused {
            let path = job.folder.standardizedFileURL.path
            if !path.hasPrefix("/Volumes/") || (portable.map { path.hasPrefix($0 + "/") } ?? false) { job.state = .queued }
        }
        pump()
    }

    /// Stops the download and deletes its partial file.
    func cancel(_ job: DownloadJob) {
        job.task?.cancel()
        job.task = nil
        let fileName = job.fileName, folder = job.folder
        jobs.removeAll { $0 === job }
        Task.detached {
            try? await Task.sleep(for: .milliseconds(300))
            ChunkedDownload.discard(fileName: fileName, in: folder)
        }
        pump()
    }

    func clearFinished() { jobs.removeAll { $0.isFinished } }

    private func pump() {
        guard !jobs.contains(where: \.isActive), let next = jobs.first(where: { $0.state == .queued }) else { return }
        start(next)
    }

    private func start(_ job: DownloadJob) {
        job.state = .preparing
        job.task = Task { [weak self] in
            do {
                let meta: Metalink
                if job.metalinkURL.pathExtension == "meta4" {
                    guard job.metalinkURL.scheme == "https" else { throw DownloadError.server("The mirror list isn’t on a secure address.") }
                    meta = try await Metalink.fetch(job.metalinkURL)
                } else if let preset = job.presetMeta {
                    meta = preset
                } else {
                    throw DownloadError.server("Missing download details.")
                }
                guard Metalink.isSafeFileName(meta.fileName), meta.size > 0 else {
                    throw DownloadError.server("The download details didn’t look right, so nothing was downloaded.")
                }
                job.total = meta.size
                let download = ChunkedDownload(metalinkURL: job.metalinkURL, title: job.title, meta: meta, folder: job.folder)
                _ = try await download.run { progress in
                    Task { @MainActor in
                        guard job.task != nil else { return }
                        job.done = progress.done
                        job.total = progress.total
                        job.bytesPerSecond = progress.bytesPerSecond
                        if progress.phase != .verifying { self?.note(speed: progress.bytesPerSecond) }
                        job.state = progress.phase == .verifying ? .verifying : .downloading
                    }
                }
                // Paused or cancelled right as it finished: leave the job as the person set it.
                guard !Task.isCancelled else { return }
                job.done = job.total
                job.state = .done
                job.task = nil
                self?.onInstalled?()
            } catch is CancellationError {
                // Paused or cancelled: state already set.
            } catch let error as URLError where error.code == .cancelled {
                // Same as above.
            } catch {
                job.state = .failed(error.localizedDescription)
                job.task = nil
            }
            self?.pump()
        }
    }
}

/// Progress across every download in the list.
struct DownloadSummary: Equatable {
    let count: Int
    let finished: Int
    let failed: Int
    let bytesDone: Int64
    let bytesTotal: Int64
    let secondsLeft: Double?
    let current: String?
    let isRunning: Bool

    var fraction: Double { bytesTotal > 0 ? Double(bytesDone) / Double(bytesTotal) : 0 }
    var isComplete: Bool { finished == count }
    var isPaused: Bool { !isRunning && !isComplete && failed == 0 }

    /// "Downloading 3 of 9", "Paused", "All 9 downloaded"
    var headline: String {
        if isComplete { return count == 1 ? "Download finished" : "All \(count) downloads finished" }
        if failed > 0 && !isRunning { return failed == 1 ? "A download needs attention" : "\(failed) downloads need attention" }
        if isPaused { return "Downloads paused · \(finished) of \(count) done" }
        return "Downloading \(min(finished + 1, count)) of \(count)"
    }

    /// "2.1 GB of 7.5 GB · about 12 min left"
    var detail: String {
        let fmt = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        if isComplete { return "\(fmt(bytesTotal)) saved. Everything is in Library." }
        var parts = ["\(fmt(bytesDone)) of \(fmt(bytesTotal))"]
        if isRunning { parts.append(secondsLeft.map(Self.timeLeft) ?? "working out time left…") }
        return parts.joined(separator: " · ")
    }

    static func timeLeft(_ seconds: Double) -> String {
        switch seconds {
        case ..<60: return "less than a minute left"
        case ..<(10 * 60): return "about \(Int((seconds / 60).rounded(.up))) min left"
        case ..<(60 * 60): return "about \(Int((seconds / 300).rounded(.up)) * 5) min left"
        default:
            let tenths = Int((seconds / 600).rounded(.up))          // nearest 10 minutes, rounded up
            let hours = tenths / 6, minutes = (tenths % 6) * 10
            return minutes == 0 ? "about \(hours) hr left" : "about \(hours) hr \(minutes) min left"
        }
    }
}
