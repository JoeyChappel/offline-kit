import Foundation
import SwiftUI
import AVFoundation


// Minimal archive-library fixture; all media scanning, metadata, sorting and playback code is production code.
@MainActor final class Library { var folders: [URL] { [KitLocation.home.appending(path: "OfflineKit/Library")] } }

@main struct MediaCatalogChecks {
    @MainActor static func main() async throws {
        let media = MediaLibrary()
        await media.reload(library: Library())
        let videos = MediaCatalog.select(media.items, info: media.info, progress: [:], filter: .video)
        precondition(videos.count == 4)
        precondition(MediaCatalog.genres(media.items, info: media.info, filter: .video) == ["Adventure", "Animation", "Documentary"])
        let adventures = MediaCatalog.select(media.items, info: media.info, progress: [:], filter: .video, genre: "Adventure", sort: .titleDescending)
        precondition(adventures.map(\.title) == ["Coastal Trail", "Across the Valley"])
        let albums = MediaCatalog.select(media.items, info: media.info, progress: [:], filter: .music, sort: .artist)
        precondition(albums.count == 3)
        precondition(Set(albums.map { MediaCatalog.creator(media.info[$0.progressKey]) }) == ["Mara Ellis", "North Street Quartet"])
        let album = albums.first { $0.title == "Evening Light" }!
        precondition(album.tracks.count == 2)
        let info = media.info[album.progressKey]!
        precondition(info.tracks?.map(\.title) == ["First Light", "The Long Way Home"])
        precondition(info.genre == "Folk")
        let spoken = MediaCatalog.select(media.items, info: media.info, progress: [:], filter: .audiobooks)
        precondition(spoken.count == 2 && spoken.allSatisfy { $0.tracks.count == 2 })
        let p = MediaProgress(track: 1, seconds: 20)
        let f = MediaCatalog.fraction(album, p, info)!
        precondition(f > 0.73 && f < 0.78, "Progress includes elapsed time within the current track")
        let finished = [album.progressKey: MediaProgress(track: 1, seconds: 0, finished: true)]
        precondition(!MediaCatalog.select(media.items, info: media.info, progress: finished, filter: .music, unfinished: true).contains(album))
        let collection = MediaCatalog.build(items: media.items, progress: [:], info: media.info, filter: .video, genre: "Adventure", sort: .titleDescending)
        precondition(collection.featured == nil && collection.shelves.first?.items == adventures)
        let search = MediaCatalog.select(media.items, info: media.info, progress: [:], filter: .music, query: "Mara")
        precondition(search.count == 2)
        let songs = MediaCatalog.songs(albums, info: media.info, query: "Long Way", sort: .title)
        precondition(songs.count == 3 && songs.allSatisfy { MediaCatalog.trackTitle($0.item, media.info[$0.item.progressKey], $0.index) == "The Long Way Home" })
        media.saveProgress(p, for: album)
        let playback = MediaPlayback(item: album, library: media)
        precondition(playback.track == 1 && playback.current == 20, "Resume preserves the stored track and time")
        playback.load(track: 0)
        playback.setSleep(endOfChapter: true)
        precondition(playback.sleepAtChapterEnd)
        playback.setSleep(minutes: 15)
        precondition(!playback.sleepAtChapterEnd && playback.sleepDeadline! > Date().addingTimeInterval(890))
        playback.setSleep()
        precondition(playback.sleepDeadline == nil)
        playback.cleanUp()
        precondition(media.progress[album.progressKey]?.track == 0)
        // Completing the last chapter stays complete after the player is closed.
        let ending = MediaPlayback(item: album, library: media)
        ending.load(track: album.tracks.count - 1)
        NotificationCenter.default.post(name: AVPlayerItem.didPlayToEndTimeNotification, object: ending.player.currentItem)
        ending.cleanUp()
        precondition(media.progress[album.progressKey]?.finished == true)
        print("PASS: genres, sorting, metadata album/artist grouping, numeric tracks, audiobook classification, elapsed progress, resume, sleep settings and finished-state persistence.")
    }
}
