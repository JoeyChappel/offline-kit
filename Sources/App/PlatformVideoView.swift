import SwiftUI
import AVKit

/// The system video player, wrapped directly. SwiftUI's VideoPlayer crashes on macOS 27.2 while setting up its
/// type metadata (inside _AVKit_SwiftUI), so it isn't used.
#if os(macOS)
struct PlatformVideoView: NSViewRepresentable {
    let player: AVPlayer
    var controls = true
    func makeNSView(context: Context) -> AVPlayerView {
        let view = FocusingPlayerView()
        view.takesFocus = controls
        view.player = player
        view.controlsStyle = controls ? .floating : .none
        view.showsFullScreenToggleButton = true
        view.allowsPictureInPicturePlayback = true
        // Offline Kit fills in Now Playing itself (SystemMediaControls); two writers would fight over it.
        view.updatesNowPlayingInfoCenter = false
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    /// The full player takes the keyboard when it opens, so its keys work without a click first.
    final class FocusingPlayerView: AVPlayerView {
        var takesFocus = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard takesFocus, let window else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
    }
}
#else
struct PlatformVideoView: UIViewControllerRepresentable {
    let player: AVPlayer
    var controls = true
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = controls
        controller.updatesNowPlayingInfoCenter = false
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
#endif

