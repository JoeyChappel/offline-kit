import SwiftUI
import AVKit

/// Full-screen player. Plays chapters in order and saves the place on the Mac every few seconds.
struct TVPlayerView: View {
    @Environment(TVStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let playback: TVPlayback
    @State private var controller = TVPlayerController()

    var body: some View {
        TVPlayerRepresentable(player: controller.player)
            .ignoresSafeArea()
            .background(.black)
            .overlay(alignment: .center) {
                if playback.item.kind == .audio {
                    VStack(spacing: 20) {
                        if let picture = playback.item.thumb ?? playback.item.cover, let url = store.url(picture) {
                            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { ProgressView() }
                                .frame(width: 360, height: playback.item.category == "audiobooks" ? 480 : 360)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                        } else {
                            Text(playback.item.title).font(.largeTitle.bold()).frame(width: 400, height: 300)
                                .background(LinearGradient(colors: [.teal.opacity(0.5), .black], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 20))
                        }
                        Text(playback.item.title).font(.largeTitle.bold()).foregroundStyle(.white)
                        if playback.item.tracks.count > 1 {
                            Text("\(playback.item.category == "music" ? "Track" : "Chapter") \(controller.track + 1) of \(playback.item.tracks.count)").font(.title3).foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .allowsHitTesting(false)
                }
            }
            .onAppear {
                controller.start(playback, store: store) { dismiss() }
            }
            .onDisappear { controller.stop() }
    }
}

@MainActor @Observable
final class TVPlayerController {
    let player = AVPlayer()
    private(set) var track = 0
    @ObservationIgnored private var item: TVItem?
    @ObservationIgnored private weak var store: TVStore?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var onFinished: (() -> Void)?
    @ObservationIgnored private var readyObservation: NSKeyValueObservation?

    func start(_ playback: TVPlayback, store: TVStore, onFinished: @escaping () -> Void) {
        self.item = playback.item
        self.store = store
        self.onFinished = onFinished
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        load(track: playback.track, at: playback.seconds)
        #if DEBUG
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.item != nil else { timer.invalidate(); return }
                let p = self.player
                print("TVPLAYER track=\(self.track) t=\(p.currentTime().seconds) status=\(p.timeControlStatus.rawValue) wait=\(p.reasonForWaitingToPlay?.rawValue ?? "-") item=\(p.currentItem?.status.rawValue ?? -1) err=\(p.currentItem?.error?.localizedDescription ?? "-")")
            }
        }
        #endif
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 10, preferredTimescale: 1), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save(finished: false) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.advance()
            }
        }
    }

    func stop() {
        save(finished: false)
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
    }

    private func load(track index: Int, at seconds: Double) {
        guard let item, let store, item.tracks.indices.contains(index), let url = store.url(item.tracks[index].url) else { return }
        track = index
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: store.cookies(for: url)])
        let playerItem = AVPlayerItem(asset: asset)
        let title = AVMutableMetadataItem()
        title.identifier = .commonIdentifierTitle
        title.value = (item.tracks.count > 1 ? "\(item.title) · \(item.tracks[index].title)" : item.title) as NSString
        title.extendedLanguageTag = "und"
        playerItem.externalMetadata = [title]
        player.replaceCurrentItem(with: playerItem)
        // Start once the item is ready (and after any seek); calling play() earlier can leave audio-only items paused.
        readyObservation = playerItem.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .readyToPlay else { return }
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                self.readyObservation = nil
                if seconds > 0 {
                    await self.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
                }
                self.player.play()
            }
        }
    }

    private func advance() {
        guard let item else { return }
        if track + 1 < item.tracks.count {
            load(track: track + 1, at: 0)
            save(finished: false)
        } else {
            store?.saveProgress(TVProgress(track: 0, seconds: 0, finished: true), for: item)
            self.item = nil          // nothing left to save on dismiss
            onFinished?()
        }
    }

    private func save(finished: Bool) {
        guard let item, let store else { return }
        let seconds = player.currentTime().seconds
        store.saveProgress(TVProgress(track: track, seconds: seconds.isFinite ? seconds : 0, finished: finished), for: item)
    }
}

private struct TVPlayerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {}
}
