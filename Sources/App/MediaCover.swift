import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import AVFoundation
import CryptoKit

/// Cover art people choose themselves. Saved beside the media so it travels with the drive and shows on the
/// web view and Apple TV too; it never overwrites art that came with the files, so the original can come back.
/// Bumped whenever a cover is set or removed, so artwork already on screen reloads even when the file name is reused.
@Observable final class CoverStamp {
    static let shared = CoverStamp()
    var value = 0
}

enum MediaCover {
    /// "Movie.cover.jpg" beside a video, song or book; "cover-custom.jpg" inside an album or audiobook folder.
    static func customURL(for item: MediaItem) -> URL {
        if item.kind == .audio, isFolderItem(item) {
            return item.tracks[0].deletingLastPathComponent().appending(path: "cover-custom.jpg")
        }
        let file = item.tracks[0]
        return file.deletingPathExtension().appendingPathExtension("cover.jpg")
    }

    /// Albums and audiobooks are folders of tracks; loose songs sit directly in the Media folder (or its Music folder).
    static func isFolderItem(_ item: MediaItem) -> Bool {
        !MediaLibrary.holdsLooseTracks(item.tracks[0].deletingLastPathComponent(), root: item.root)
    }

    /// Cards ask on every redraw (their menus), so the answer is kept until a cover changes or the library is rescanned.
    private final class CustomAnswers: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: Bool] = [:]
    }
    private static let customAnswers = CustomAnswers()
    static func forgetCustomAnswers() { customAnswers.lock.withLock { customAnswers.values.removeAll() } }

    static func hasCustom(_ item: MediaItem) -> Bool {
        if let known = customAnswers.lock.withLock({ customAnswers.values[item.id] }) { return known }
        let answer = FileManager.default.fileExists(atPath: customURL(for: item).path)
        customAnswers.lock.withLock { customAnswers.values[item.id] = answer }
        return answer
    }

    /// The custom cover for a media file found by the scan, if one has been set.
    nonisolated static func sidecar(for file: URL) -> URL? {
        let url = file.deletingPathExtension().appendingPathExtension("cover.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Saves the chosen picture (any common image format), downsized to a sensible size, as the custom cover.
    static func set(_ image: URL, for item: MediaItem) throws {
        let scoped = image.startAccessingSecurityScopedResource()
        defer { if scoped { image.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(image as CFURL, nil),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                           kCGImageSourceThumbnailMaxPixelSize: 1600,
                                                                           kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
        else { throw CoverError.notAnImage }
        let target = customURL(for: item)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CoverError.cantWrite
        }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CoverError.cantWrite }
        CoverStamp.shared.value += 1
        forgetCustomAnswers()
    }

    /// Saves a picture made in the app ("Use Generated Cover") as the custom cover.
    static func set(_ picture: CGImage, for item: MediaItem) throws {
        let target = customURL(for: item)
        guard let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CoverError.cantWrite
        }
        CGImageDestinationAddImage(destination, picture, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CoverError.cantWrite }
        CoverStamp.shared.value += 1
        forgetCustomAnswers()
    }

    /// Removes the custom cover; the original art (embedded, cover.jpg or video still) shows again.
    static func reset(for item: MediaItem) {
        try? FileManager.default.removeItem(at: customURL(for: item))
        CoverStamp.shared.value += 1
        forgetCustomAnswers()
    }

    enum CoverError: LocalizedError {
        case notAnImage, cantWrite
        var errorDescription: String? {
            switch self {
            case .notAnImage: "That file isn’t a picture Offline Kit can read. Try a JPEG, PNG or HEIC."
            case .cantWrite: "Couldn’t save the cover next to this item. Check that its drive is connected and not read-only."
            }
        }
    }
}

/// "Choose Cover Art…" and "Use Original Art", for detail screens and right-click menus.
struct CoverArtButtons: View {
    let item: MediaItem
    @Environment(MediaLibrary.self) private var media
    @Environment(Library.self) private var library
    @State private var picking = false
    @State private var error: String?

    var body: some View {
        Button("Choose Cover Art…", systemImage: "photo") { picking = true }
            .disabled(item.unavailable != nil)
            .help(item.unavailable != nil ? "Available once the files are back" : "Pick a picture to show for this")
            .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
                guard case .success(let url) = result else { return }
                do {
                    try MediaCover.set(url, for: item)
                    Task { await media.reload(library: library) }
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .alert("Couldn’t set the cover", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        if MediaCover.hasCustom(item) {
            Button("Use Original Art", systemImage: "arrow.uturn.backward") {
                MediaCover.reset(for: item)
                Task { await media.reload(library: library) }
            }
        }
        GeneratedArtButtons(item: item)
    }
}

/// "Pick Another Frame" and "Reset Artwork" for a movie's generated picture; "Use Generated Cover" for music and books
/// that came with art of their own (see AutoArtwork).
struct GeneratedArtButtons: View {
    let item: MediaItem
    @Environment(MediaLibrary.self) private var media

    var body: some View {
        let info = media.info[item.progressKey]
        if AutoArtwork.canPickFrame(item, info: info) {
            Button("Pick Another Frame", systemImage: "film.stack") { AutoArtwork.shared.pickAnotherFrame(item) }
                .help("Show a different moment from this video")
        }
        if AutoArtwork.canResetFrame(item, info: info) {
            Button("Reset Artwork", systemImage: "arrow.counterclockwise") { AutoArtwork.shared.resetFrame(item) }
                .help("Go back to the picture Offline Kit chose")
        }
        if AutoArtwork.canUseGeneratedCover(item, info: info) {
            Button("Use Generated Cover", systemImage: "textformat") { AutoArtwork.shared.useGeneratedCover(item) }
                .help("Show a cover with the title and genre instead of the art that came with it")
        }
    }
}

/// Right-click on a media card: Show in Finder, Choose Cover Art…, Use Original Art. The picker lives on the card,
/// not in the menu, because the menu is gone by the time the picker opens.
struct MediaCardMenu: ViewModifier {
    let item: MediaItem
    @Environment(MediaLibrary.self) private var media
    @Environment(Library.self) private var library

    func body(content: Content) -> some View {
        // The picture chooser and its error alert live once on the screen (see mediaCoverPicker), not on every card.
        content
            .contextMenu {
                #if os(macOS)
                ShowInFinderButton(url: item.tracks[0]).disabled(item.unavailable != nil)
                SendToPhoneButton(media: item, info: media.info[item.progressKey]).disabled(item.unavailable != nil)
                #endif
                Button("Choose Cover Art…", systemImage: "photo") { CoverPicker.shared.choose(for: item) }.disabled(item.unavailable != nil)
                if item.unavailable == nil, MediaCover.hasCustom(item) {
                    Button("Use Original Art", systemImage: "arrow.uturn.backward") {
                        MediaCover.reset(for: item)
                        Task { await media.reload(library: library) }
                    }
                }
                GeneratedArtButtons(item: item)
            }
    }
}

/// Which item "Choose Cover Art…" was picked for. One chooser per screen reads it.
@MainActor @Observable final class CoverPicker {
    static let shared = CoverPicker()
    private(set) var item: MediaItem?
    /// Goes up with each request, so asking again for the same item opens the chooser again.
    private(set) var ticket = 0
    func choose(for item: MediaItem) { self.item = item; ticket += 1 }
    func finish() { item = nil }
}

/// The one picture chooser and error alert for every card's "Choose Cover Art…". Put on the screen that shows the cards.
private struct MediaCoverPickerHost: ViewModifier {
    @Environment(MediaLibrary.self) private var media
    @Environment(Library.self) private var library
    @State private var picking = false
    @State private var error: String?

    func body(content: Content) -> some View {
        content
            .onChange(of: CoverPicker.shared.ticket) { picking = true }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.image]) { result in
                let item = CoverPicker.shared.item
                CoverPicker.shared.finish()
                guard let item, case .success(let url) = result else { return }
                do {
                    try MediaCover.set(url, for: item)
                    Task { await media.reload(library: library) }
                } catch {
                    self.error = error.localizedDescription
                }
            }
            .alert("Couldn’t set the cover", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
    }
}

extension View {
    func mediaCardMenu(_ item: MediaItem) -> some View { modifier(MediaCardMenu(item: item)) }
    /// The chooser behind the cards' "Choose Cover Art…" (one for the whole screen).
    func mediaCoverPicker() -> some View { modifier(MediaCoverPickerHost()) }
}

/// The frame a video was last stopped on. Until the video is finished, it stands in for the automatic still,
/// so Keep Watching shows where you left off. Kept in the cache folder, one picture per video.
enum PlaybackStill {
    nonisolated static var folder: URL {
        KitLocation.caches.appending(path: "OfflineKit/media-info/stills", directoryHint: .isDirectory)
    }

    nonisolated static func hash(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Saved stills by hashed progress key.
    nonisolated static func saved() -> [String: String] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var result: [String: String] = [:]
        for file in files where file.pathExtension == "jpg" {
            guard let hash = file.deletingPathExtension().lastPathComponent.split(separator: "-").first else { continue }
            result[String(hash)] = file.path
        }
        return result
    }

    /// Grabs the frame at `seconds`. The name includes the time, so artwork already on screen sees a new path and reloads.
    nonisolated static func capture(_ file: URL, at seconds: Double, key: String) async -> String? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image else { return nil }
        let url = folder.appending(path: "\(hash(key))-\(Int(seconds * 10)).jpg")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url.path : nil
    }
}
