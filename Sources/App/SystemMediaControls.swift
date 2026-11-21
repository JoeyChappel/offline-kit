import Foundation
import MediaPlayer
import ImageIO
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The keyboard's play/pause and skip keys, Control Center, the Lock Screen and AirPods: they drive whatever
/// Offline Kit is playing, and they show its title, artwork and position.
@MainActor
final class SystemMediaControls {
    static let shared = SystemMediaControls()

    /// The item playing now. Commands go to it; a player that's been closed lets go (see `clear`).
    private weak var playback: MediaPlayback?
    private var registered = false
    private var artworkPath: String?
    private var artwork: MPMediaItemArtwork?

    /// Called by the player whenever what's shown should change: a new item or track, play or pause, a jump.
    func update(_ playback: MediaPlayback, info: MediaInfo?) {
        registerIfNeeded()
        self.playback = playback
        let center = MPNowPlayingInfoCenter.default()
        let item = playback.item
        var details: [String: Any] = [
            MPMediaItemPropertyTitle: playback.trackTitle,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: playback.current,
            MPNowPlayingInfoPropertyPlaybackRate: playback.isPlaying ? Double(playback.rate) : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: item.kind == .video ? MPNowPlayingInfoMediaType.video.rawValue : MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if playback.duration > 0 { details[MPMediaItemPropertyPlaybackDuration] = playback.duration }
        if item.tracks.count > 1 {
            details[MPMediaItemPropertyAlbumTitle] = MediaCatalog.title(item, info)
            details[MPNowPlayingInfoPropertyPlaybackQueueIndex] = playback.track
            details[MPNowPlayingInfoPropertyPlaybackQueueCount] = item.tracks.count
        }
        if let creator = info?.albumArtist ?? info?.artist ?? info?.author { details[MPMediaItemPropertyArtist] = creator }
        let path = item.cover?.path ?? info?.thumb
        if let artwork, path == artworkPath { details[MPMediaItemPropertyArtwork] = artwork }
        center.nowPlayingInfo = details
        #if os(macOS)
        // On the Mac the media keys go to the app that says it's playing.
        center.playbackState = playback.isPlaying ? .playing : .paused
        #endif

        let commands = MPRemoteCommandCenter.shared()
        let chapters = item.tracks.count > 1
        commands.nextTrackCommand.isEnabled = true
        commands.previousTrackCommand.isEnabled = true
        commands.skipForwardCommand.isEnabled = !chapters
        commands.skipBackwardCommand.isEnabled = !chapters
        commands.changePlaybackPositionCommand.isEnabled = playback.duration > 0

        if path != artworkPath { loadArtwork(path) }
    }

    /// The player closed: nothing is playing any more.
    func clear(_ playback: MediaPlayback) {
        guard self.playback === playback || self.playback == nil else { return }
        self.playback = nil
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nil
        #if os(macOS)
        center.playbackState = .stopped
        #endif
    }

    private func registerIfNeeded() {
        guard !registered else { return }
        registered = true
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in self?.perform { $0.play() } ?? .noActionableNowPlayingItem }
        commands.pauseCommand.addTarget { [weak self] _ in self?.perform { $0.pause() } ?? .noActionableNowPlayingItem }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.perform { $0.toggle() } ?? .noActionableNowPlayingItem }
        // The keyboard's ⏭ and ⏮ keys: the next or previous chapter or song, or a jump within a single file.
        commands.nextTrackCommand.addTarget { [weak self] _ in
            self?.perform { $0.item.tracks.count > 1 ? $0.next() : $0.skip(Self.jump($0)) } ?? .noActionableNowPlayingItem
        }
        commands.previousTrackCommand.addTarget { [weak self] _ in
            self?.perform { $0.item.tracks.count > 1 ? $0.previous() : $0.skip(-Self.jump($0)) } ?? .noActionableNowPlayingItem
        }
        commands.skipForwardCommand.preferredIntervals = [15]
        commands.skipBackwardCommand.preferredIntervals = [15]
        commands.skipForwardCommand.addTarget { [weak self] event in
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            return self?.perform { $0.skip(seconds) } ?? .noActionableNowPlayingItem
        }
        commands.skipBackwardCommand.addTarget { [weak self] event in
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval ?? 15
            return self?.perform { $0.skip(-seconds) } ?? .noActionableNowPlayingItem
        }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.perform { playback in
                guard playback.duration > 0 else { return }
                playback.seek(to: event.positionTime / playback.duration)
            } ?? .noActionableNowPlayingItem
        }
    }

    /// Video jumps 10 seconds (like ← and →); audio jumps 15.
    private static func jump(_ playback: MediaPlayback) -> Double { playback.item.kind == .video ? 10 : 15 }

    /// Commands arrive on the main thread; anything else is moved there.
    nonisolated private func perform(_ action: @escaping @MainActor (MediaPlayback) -> Void) -> MPRemoteCommandHandlerStatus {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                guard let playback else { return .noActionableNowPlayingItem }
                action(playback)
                return .success
            }
        }
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                if let playback = self?.playback { action(playback) }
            }
        }
        return .success
    }

    /// Reads the cover or video still in the background, then shows it with the title.
    private func loadArtwork(_ path: String?) {
        artworkPath = path
        artwork = nil
        guard let path else { return }
        Task {
            let image = await Task.detached(priority: .utility) { () -> CGImage? in
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
                return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 600,
                                                                       kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            }.value
            guard let image, artworkPath == path else { return }
            #if os(macOS)
            let picture = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            #else
            let picture = UIImage(cgImage: image)
            #endif
            let size = CGSize(width: image.width, height: image.height)
            let made = MPMediaItemArtwork(boundsSize: size) { _ in picture }
            artwork = made
            var details = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            guard !details.isEmpty else { return }
            details[MPMediaItemPropertyArtwork] = made
            MPNowPlayingInfoCenter.default().nowPlayingInfo = details
        }
    }
}
