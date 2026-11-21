import Foundation
import AVFoundation
import CryptoKit

struct MediaTrackInfo: Codable, Hashable, Sendable {
    var title: String
    var duration: Double?
    var artist: String?
}

enum MediaSort: String, CaseIterable, Identifiable {
    case title, titleDescending, added, played, year, duration, artist
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: "Title A–Z"
        case .titleDescending: "Title Z–A"
        case .added: "Recently added"
        case .played: "Recently played"
        case .year: "Release year"
        case .duration: "Duration"
        case .artist: "Artist, then album"
        }
    }
}

enum MusicBrowse: String, CaseIterable, Identifiable {
    case albums = "Albums", artists = "Artists", genres = "Genres", songs = "Songs"
    var id: String { rawValue }
}

extension MediaCatalog {
    static func title(_ item: MediaItem, _ info: MediaInfo?) -> String {
        item.kind == .audio && category(item, info) == .music ? (info?.album ?? displayTitle(item.title)) : displayTitle(item.title)
    }
    static func creator(_ info: MediaInfo?) -> String { info?.albumArtist ?? info?.artist ?? info?.author ?? "Unknown artist" }
    static func trackTitle(_ item: MediaItem, _ info: MediaInfo?, _ index: Int) -> String {
        if let tracks = info?.tracks, tracks.indices.contains(index) { return tracks[index].title }
        return MediaLibrary.prettyTitle(item.tracks[index].deletingPathExtension().lastPathComponent)
    }
    static func genres(_ items: [MediaItem], info: [String: MediaInfo], filter: MediaFilter) -> [String] {
        Array(Set(items.filter { filter == .all || category($0, info[$0.progressKey]) == filter }.compactMap { info[$0.progressKey]?.genre }))
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func select(_ items: [MediaItem], info: [String: MediaInfo], progress: [String: MediaProgress],
                       filter: MediaFilter = .all, genre: String? = nil, query: String = "", sort: MediaSort = .title,
                       unfinished: Bool = false) -> [MediaItem] {
        let selected = items.filter { item in
            let i = info[item.progressKey]
            return (filter == .all || category(item, i) == filter)
                && (genre == nil || i?.genre?.localizedCaseInsensitiveCompare(genre!) == .orderedSame)
                && (!unfinished || progress[item.progressKey]?.finished != true)
                && (query.isEmpty || [title(item, i), creator(i), i?.genre ?? "", i?.studio ?? "", i?.series ?? ""].contains { $0.localizedStandardContains(query) }
                    || (i?.tracks ?? []).contains { $0.title.localizedStandardContains(query) })
        }
        return selected.sorted { a, b in
            let ai = info[a.progressKey], bi = info[b.progressKey]
            switch sort {
            case .added: if ai?.added != bi?.added { return (ai?.added ?? .distantPast) > (bi?.added ?? .distantPast) }
            case .played:
                let ap = progress[a.progressKey]?.updated ?? .distantPast, bp = progress[b.progressKey]?.updated ?? .distantPast
                if ap != bp { return ap > bp }
            case .year: if ai?.year != bi?.year { return (ai?.year ?? 0) > (bi?.year ?? 0) }
            case .duration: if ai?.duration != bi?.duration { return (ai?.duration ?? .infinity) < (bi?.duration ?? .infinity) }
            case .artist:
                let order = creator(ai).localizedStandardCompare(creator(bi))
                if order != .orderedSame { return order == .orderedAscending }
            default: break
            }
            let order = title(a, ai).localizedStandardCompare(title(b, bi))
            if order == .orderedSame { return a.id < b.id }
            return sort == .titleDescending ? order == .orderedDescending : order == .orderedAscending
        }
    }
    static func nextVideo(after item: MediaItem, items: [MediaItem], info: [String: MediaInfo], progress: [String: MediaProgress]) -> MediaItem? {
        guard item.kind == .video, let genre = info[item.progressKey]?.genre else { return nil }
        return related(to: item, items: items, info: info).first {
            $0.kind == .video && info[$0.progressKey]?.genre == genre && progress[$0.progressKey]?.finished != true && !isInProgress(progress[$0.progressKey])
        }
    }
    static func related(to item: MediaItem, items: [MediaItem], info: [String: MediaInfo]) -> [MediaItem] {
        let i = info[item.progressKey]
        return items.filter { $0.id != item.id && category($0, info[$0.progressKey]) == category(item, i) }
            .sorted { a, b in
                let am = i?.genre != nil && info[a.progressKey]?.genre == i?.genre
                let bm = i?.genre != nil && info[b.progressKey]?.genre == i?.genre
                return am != bm ? am : a.title.localizedStandardCompare(b.title) == .orderedAscending
            }
    }
}

/// Embedded tags are read off the main thread and cached by file revision. The original files are never changed.
struct AudioTags: Sendable {
    var title: String?
    var album: String?
    var artist: String?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var disc = 1
    var number = 0
    var duration: Double?
    var artwork: Data?

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var values: [String: AudioTags] = [:]
    }
    private static let cache = Cache()
    static func read(_ url: URL) async -> AudioTags {
        let revision = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = "\(url.path)|\(revision?.fileSize ?? 0)|\(revision?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        if let hit = cache.lock.withLock({ cache.values[key] }) { return hit }
        let asset = AVURLAsset(url: url)
        var tag = AudioTags()
        for entry in (try? await asset.load(.metadata)) ?? [] {
            let common = entry.commonKey?.rawValue.lowercased() ?? ""
            let id = entry.identifier?.rawValue.lowercased() ?? ""
            if common == "artwork", let data = try? await entry.load(.dataValue) { tag.artwork = data; continue }
            if id.contains("trkn") || id.contains("disk"), let data = try? await entry.load(.dataValue), data.count >= 4 {
                let number = Int(data[data.startIndex + 2]) * 256 + Int(data[data.startIndex + 3])
                if id.contains("disk") { tag.disc = number } else { tag.number = number }
                continue
            }
            guard let value = try? await entry.load(.stringValue), !value.isEmpty else { continue }
            if common == "title" { tag.title = value }
            else if common == "albumname" { tag.album = value }
            else if common == "artist" { tag.artist = value }
            else if id.contains("tpe2") || id.contains("aart") || id.contains("albumartist") { tag.albumArtist = value }
            else if id.contains("genre") || id.contains("tcon") || id.contains("©gen") || id.contains("a9gen") { tag.genre = value }
            else if id.contains("trck") { tag.number = Int(value.split(separator: "/").first ?? "") ?? 0 }
            else if id.contains("tpos") { tag.disc = Int(value.split(separator: "/").first ?? "") ?? 1 }
            else if id.contains("year") || id.contains("date") || id.contains("©day") || id.contains("a9day") || id.contains("tyer") {
                tag.year = Int(value.prefix(4))
            }
        }
        if let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 { tag.duration = duration.seconds }
        cache.lock.withLock { cache.values[key] = tag }
        return tag
    }

    static func organize(_ items: [MediaItem]) async -> [MediaItem] {
        var tags: [URL: AudioTags] = [:]
        let urls = items.filter { $0.kind == .audio }.flatMap(\.tracks)
        await withTaskGroup(of: (URL, AudioTags).self) { group in
            var iterator = urls.makeIterator()
            func add() { if let url = iterator.next() { group.addTask { (url, await read(url)) } } }
            for _ in 0..<3 { add() }
            for await (url, tag) in group { tags[url] = tag; add() }
        }
        var groups: [String: (MediaItem, [URL])] = [:]
        var output = items.filter { $0.kind != .audio }
        for item in items where item.kind == .audio {
            for url in item.tracks {
                let tag = tags[url] ?? AudioTags()
                let spoken = url.pathExtension.lowercased() == "m4b" || url.pathComponents.contains { $0.lowercased().contains("audiobook") || $0.lowercased() == "librivox" }
                let albumKey = tag.album.map { "\($0.lowercased())|\((tag.albumArtist ?? tag.artist ?? "Unknown artist").lowercased())" }
                let groupKey = !spoken && albumKey != nil ? "\(item.root.path)|\(albumKey!)" : item.id
                if groups[groupKey] == nil { groups[groupKey] = (item, []) }
                groups[groupKey]?.1.append(url)
            }
        }
        for (_, group) in groups {
            let tracks = group.1.sorted { a, b in
                let at = tags[a] ?? AudioTags(), bt = tags[b] ?? AudioTags()
                if at.disc != bt.disc { return at.disc < bt.disc }
                if at.number != bt.number { return at.number < bt.number }
                return a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
            }
            let base = group.0
            let album = tags[tracks[0]]?.album
            // Keep existing progress keys for ordinary one-folder albums. Split/merged tagged albums use a portable tag key.
            let sameFolder = tracks.allSatisfy { $0.deletingLastPathComponent() == base.tracks[0].deletingLastPathComponent() }
            let unchanged = sameFolder && Set(tracks) == Set(base.tracks)
            var key: String? = nil
            if !unchanged, let album {
                let name = "\(album.lowercased())|\((tags[tracks[0]]?.albumArtist ?? tags[tracks[0]]?.artist ?? "Unknown artist").lowercased())"
                key = "/@albums/" + SHA256.hash(data: Data(name.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
            }
            output.append(MediaItem(kind: .audio, title: album ?? base.title, tracks: tracks, root: base.root, cover: base.cover, catalogKey: key))
        }
        return output.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}

struct MediaSong: Identifiable {
    let item: MediaItem
    let index: Int
    var id: String { "\(item.id)#\(index)" }
}
extension MediaCatalog {
    static func songs(_ items: [MediaItem], info: [String: MediaInfo], query: String = "", sort: MediaSort = .title) -> [MediaSong] {
        let songs = items.flatMap { item in item.tracks.indices.map { MediaSong(item: item, index: $0) } }.filter { song in
            guard !query.isEmpty else { return true }
            let i = info[song.item.progressKey]
            return [trackTitle(song.item, i, song.index), title(song.item, i), creator(i), i?.genre ?? ""].contains { $0.localizedStandardContains(query) }
        }
        if sort == .duration {
            return songs.sorted {
                let a = info[$0.item.progressKey]?.tracks?[$0.index].duration ?? .infinity
                let b = info[$1.item.progressKey]?.tracks?[$1.index].duration ?? .infinity
                return a == b ? $0.id < $1.id : a < b
            }
        }
        guard sort == .title || sort == .titleDescending else { return songs }
        return songs.sorted {
            let a = trackTitle($0.item, info[$0.item.progressKey], $0.index), b = trackTitle($1.item, info[$1.item.progressKey], $1.index)
            let order = a.localizedStandardCompare(b)
            return order == .orderedSame ? $0.id < $1.id : sort == .titleDescending ? order == .orderedDescending : order == .orderedAscending
        }
    }
}
