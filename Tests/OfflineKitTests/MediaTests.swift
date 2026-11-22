import Foundation
import Testing

// MARK: - Genre icons

@Suite("GenreIcon")
struct GenreIconTests {
    @Test("Genres map to symbols by keyword at the start of a word", arguments: [
        ("Science Fiction", "sparkles"), ("Sci-Fi", "sparkles"), ("Fantasy", "wand.and.stars"), ("Mystery & Thriller", "magnifyingglass"),
        ("Horror", "moon.stars"), ("Adventure", "map"), ("Children's", "teddybear"), ("Kids & Family", "teddybear"),
        ("Romance", "heart"), ("Comedy", "theatermasks"), ("Documentary", "globe.americas"), ("Non-Fiction", "globe.americas"),
        ("Biography", "building.columns"), ("Poetry", "text.quote"), ("Science", "atom"), ("Animation", "paintpalette"),
        ("Western", "flame"), ("Cooking", "fork.knife"), ("Classical", "music.quarternote.3"), ("Jazz", "music.mic"),
        ("Folk", "guitars"), ("Rock", "bolt"), ("Pop", "star"), ("Hip-Hop", "headphones"), ("Rap", "headphones"),
        ("Soundtrack", "film"), ("Classic Literature", "book.closed"), ("Short Films", "film"), ("Podcast", "mic"),
        ("True Crime", "magnifyingglass"), ("", "tag"), ("Zzyzx", "tag"),
    ])
    func symbol(_ genre: String, _ expected: String) {
        #expect(GenreIcon.symbol(for: genre) == expected)
    }

    @Test("A keyword inside a longer word doesn't match")
    func wordStart() {
        #expect(GenreIcon.symbol(for: "Grapes") == "tag", "\"rap\" isn't at a word start")
        #expect(GenreIcon.symbol(for: "Biography") != "headphones")
        #expect(GenreIcon.symbol(for: "Software") == "tag", "\"war\" isn't at a word start")
    }

    @Test("Specific genres win over broad ones")
    func order() {
        #expect(GenreIcon.symbol(for: "Science Fiction") != GenreIcon.symbol(for: "Science"))
        #expect(GenreIcon.symbol(for: "Folk Rock") == "guitars")
    }
}

// MARK: - Titles and the meta line

/// Items with paths unique to each call, so MediaCatalog's memos never carry over between tests.
func mediaItem(_ kind: MediaItem.Kind, _ title: String, tracks: [String], folder: String = "Media") -> MediaItem {
    let root = URL(fileURLWithPath: "/tmp/okit-tests-media-\(UUID().uuidString)/\(folder)")
    return MediaItem(kind: kind, title: title, tracks: tracks.map { root.appending(path: $0) }, root: root, cover: nil)
}

@Suite("Media titles and details")
struct MediaTitleTests {
    @Test("File names become titles: underscores and track numbers go", arguments: [
        ("Tears_of_Steel", "Tears of Steel"), ("01 - Intro", "Intro"), ("02. The Long Way Home", "The Long Way Home"),
        ("3-Ending", "Ending"), ("1984", "1984"), ("  Spaced  ", "Spaced"), ("Big_Buck_Bunny (2008)", "Big Buck Bunny (2008)"),
    ])
    func prettyTitle(_ raw: String, _ expected: String) {
        #expect(MediaLibrary.prettyTitle(raw) == expected)
    }

    @Test("A year in brackets is read and hidden from the display title")
    func years() {
        #expect(MediaCatalog.year(in: "Tears of Steel (2012)") == 2012)
        #expect(MediaCatalog.year(in: "Nosferatu (1922)") == 1922)
        #expect(MediaCatalog.year(in: "Film (1750)") == nil)
        #expect(MediaCatalog.year(in: "Film 2012") == nil)
        #expect(MediaCatalog.displayTitle("Tears of Steel (2012)") == "Tears of Steel")
        #expect(MediaCatalog.displayTitle("Tears of Steel (2012) Remastered") == "Tears of Steel (2012) Remastered")
        #expect(MediaCatalog.displayTitle("Plain") == "Plain")
    }

    static let english = Locale.current.language.languageCode?.identifier == "en"

    @Test("Meta lines for video, music, audiobooks and books", .enabled(if: english, "durations are formatted in the current language"))
    func meta() {
        let film = mediaItem(.video, "Tears of Steel", tracks: ["Tears of Steel.mp4"])
        #expect(MediaCatalog.meta(film, MediaInfo(duration: 734, year: 2012, genre: "Animation", added: Date())) == "2012 · 12 min · Animation")
        #expect(MediaCatalog.meta(film, MediaInfo(duration: 30, year: nil, genre: nil, added: Date())) == "Under 1 min")
        #expect(MediaCatalog.meta(film, nil) == "")
        let album = mediaItem(.audio, "Evening Light", tracks: ["Music/Mara/Evening Light/1.mp3", "Music/Mara/Evening Light/2.mp3"])
        #expect(MediaCatalog.meta(album, MediaInfo(duration: 600, year: 2020, genre: "Folk", added: Date())) == "2020 · Album · 2 songs · 10 min · Folk")
        let song = mediaItem(.audio, "Single", tracks: ["Music/Single.mp3"])
        #expect(MediaCatalog.meta(song, MediaInfo(duration: 200, year: nil, genre: nil, added: Date())) == "Song · 3 min")
        let book = mediaItem(.audio, "Peter Rabbit", tracks: (1...9).map { "Audiobooks/Peter Rabbit/\($0).mp3" })
        #expect(MediaCatalog.meta(book, MediaInfo(duration: 10_680, year: nil, genre: nil, added: Date())) == "Audiobook · 9 chapters · 2 hr, 58 min")
        let epub = mediaItem(.book, "Walden", tracks: ["Books/Walden.epub"])
        var info = MediaInfo(duration: nil, year: nil, genre: "Nature & Essays", added: Date())
        info.author = "Henry David Thoreau"
        info.parts = 18
        #expect(MediaCatalog.meta(epub, info) == "Book · Henry David Thoreau · 18 chapters · Nature & Essays")
        let pdf = mediaItem(.book, "Manual", tracks: ["Documents/Manual.pdf"])
        var pdfInfo = MediaInfo(duration: nil, year: nil, genre: nil, added: Date())
        pdfInfo.parts = 120
        #expect(MediaCatalog.meta(pdf, pdfInfo) == "Book · 120 pages")
    }

    @Test("A one-page PDF or one-chapter book says so in the singular")
    func singular() {
        let pdf = mediaItem(.book, "Card", tracks: ["Documents/Card.pdf"])
        var info = MediaInfo(duration: nil, year: nil, genre: nil, added: Date())
        info.parts = 1
        #expect(MediaCatalog.meta(pdf, info) == "Book · 1 page")
    }

    @Test("Audio is an audiobook or music by its files, folders and tags")
    func category() {
        #expect(MediaCatalog.category(mediaItem(.audio, "A", tracks: ["x/book.m4b"]), nil) == .audiobooks)
        #expect(MediaCatalog.category(mediaItem(.audio, "B", tracks: ["Audiobooks/B/1.mp3", "Audiobooks/B/2.mp3"]), nil) == .audiobooks)
        #expect(MediaCatalog.category(mediaItem(.audio, "C", tracks: ["Music/C/1.mp3", "Music/C/2.mp3"]), nil) == .music)
        let tagged = MediaInfo(duration: nil, year: nil, genre: "Spoken Word", added: Date())
        #expect(MediaCatalog.category(mediaItem(.audio, "D", tracks: ["Other/D/1.mp3", "Other/D/2.mp3"]), tagged) == .audiobooks)
        #expect(MediaCatalog.category(mediaItem(.audio, "E", tracks: ["Other/E/Chapter 1.mp3", "Other/E/Chapter 2.mp3"]), nil) == .audiobooks)
        let long = MediaInfo(duration: 2 * 3600, year: nil, genre: nil, added: Date())
        #expect(MediaCatalog.category(mediaItem(.audio, "F", tracks: ["Other/F/a.mp3", "Other/F/b.mp3"]), long) == .audiobooks)
        #expect(MediaCatalog.category(mediaItem(.audio, "G", tracks: ["Other/G/a.mp3", "Other/G/b.mp3"]), nil) == .music)
        #expect(MediaCatalog.category(mediaItem(.video, "H", tracks: ["H.mp4"]), nil) == .video)
        #expect(MediaCatalog.category(mediaItem(.book, "I", tracks: ["I.pdf"]), nil) == .books)
    }

    @Test("Progress keys are relative to the Media folder; albums are keyed by folder, loose songs by file")
    func progressKeys() {
        let album = mediaItem(.audio, "Album", tracks: ["Music/Artist/Album/1.mp3", "Music/Artist/Album/2.mp3"])
        #expect(album.progressKey == "/Music/Artist/Album")
        let song = mediaItem(.audio, "Song", tracks: ["Music/Song.mp3"])
        #expect(song.progressKey == "/Music/Song.mp3")
        let film = mediaItem(.video, "Film", tracks: ["Films/Film.mp4"])
        #expect(film.progressKey == "/Films/Film.mp4")
        var linked = film
        linked.catalogKey = "/@linked/abc"
        #expect(linked.progressKey == "/@linked/abc")
    }
}

// MARK: - Progress

@Suite("Media progress")
struct MediaProgressTests {
    @Test("In progress: a few seconds in or past the first track, and not finished")
    func inProgress() {
        #expect(!MediaCatalog.isInProgress(nil))
        #expect(!MediaCatalog.isInProgress(MediaProgress(track: 0, seconds: 3)))
        #expect(MediaCatalog.isInProgress(MediaProgress(track: 0, seconds: 6)))
        #expect(MediaCatalog.isInProgress(MediaProgress(track: 2, seconds: 0)))
        #expect(!MediaCatalog.isInProgress(MediaProgress(track: 2, seconds: 100, finished: true)))
        // Books keep the place in a chapter as 0…1.
        #expect(MediaCatalog.isInProgress(MediaProgress(track: 0, seconds: 0.5), kind: .book))
        #expect(!MediaCatalog.isInProgress(MediaProgress(track: 0, seconds: 0.005), kind: .book))
    }

    @Test("Fraction through: by time for a film, by chapter lengths for an album, by parts for a book")
    func fraction() throws {
        let film = mediaItem(.video, "Film", tracks: ["Film.mp4"])
        let filmInfo = MediaInfo(duration: 1000, year: nil, genre: nil, added: Date())
        #expect(MediaCatalog.fraction(film, MediaProgress(track: 0, seconds: 250), filmInfo) == 0.25)
        #expect(MediaCatalog.fraction(film, MediaProgress(track: 0, seconds: 5000), filmInfo) == 1)
        #expect(MediaCatalog.fraction(film, MediaProgress(track: 0, seconds: 250, finished: true), filmInfo) == nil)
        #expect(MediaCatalog.fraction(film, MediaProgress(track: 0, seconds: 250), nil) == nil)
        let album = mediaItem(.audio, "Album", tracks: ["Music/A/1.mp3", "Music/A/2.mp3"])
        var albumInfo = MediaInfo(duration: 400, year: nil, genre: nil, added: Date())
        albumInfo.tracks = [MediaTrackInfo(title: "One", duration: 100), MediaTrackInfo(title: "Two", duration: 300)]
        #expect(MediaCatalog.fraction(album, MediaProgress(track: 1, seconds: 100), albumInfo) == 0.5)
        #expect(MediaCatalog.fraction(album, MediaProgress(track: 1, seconds: 0), nil) == 0.5, "without lengths, by track count")
        let pdf = mediaItem(.book, "Manual", tracks: ["Manual.pdf"])
        var pdfInfo = MediaInfo(duration: nil, year: nil, genre: nil, added: Date())
        pdfInfo.parts = 10
        #expect(MediaCatalog.fraction(pdf, MediaProgress(track: 5, seconds: 0.9), pdfInfo) == 0.5, "a PDF counts whole pages")
        let epub = mediaItem(.book, "Walden", tracks: ["Walden.epub"])
        #expect(MediaCatalog.fraction(epub, MediaProgress(track: 5, seconds: 0.5), pdfInfo) == 0.55)
    }

    @Test("Finished items move to Watch Again, in-progress ones to Keep Watching")
    func shelves() throws {
        let a = mediaItem(.video, "Alpha", tracks: ["Alpha.mp4"])
        let b = mediaItem(.video, "Bravo", tracks: ["Bravo.mp4"])
        let c = mediaItem(.video, "Charlie", tracks: ["Charlie.mp4"])
        let info = Dictionary(uniqueKeysWithValues: [a, b, c].map { ($0.progressKey, MediaInfo(duration: 600, year: nil, genre: nil, added: Date())) })
        let progress = [a.progressKey: MediaProgress(track: 0, seconds: 0, finished: true, updated: Date()),
                        b.progressKey: MediaProgress(track: 0, seconds: 120, updated: Date())]
        let catalog = MediaCatalog.build(items: [a, b, c], progress: progress, info: info, filter: .video)
        let titles = catalog.shelves.map(\.title)
        let watchAgain = try #require(catalog.shelves.first { $0.title == "Watch Again" }, "shelves: \(titles)")
        #expect(watchAgain.items == [a])
        #expect(catalog.shelves.contains { $0.items.contains(b) && $0.title != "Watch Again" })
        let unfinished = MediaCatalog.select([a, b, c], info: info, progress: progress, filter: .video, unfinished: true)
        #expect(!unfinished.contains(a))
        #expect(unfinished.contains(b) && unfinished.contains(c))
    }

    @Test("Progress survives a JSON round trip, and older saves without a date still load")
    func codable() throws {
        let saved = try JSONEncoder().encode(MediaProgress(track: 3, seconds: 12.5, finished: true, updated: Date(timeIntervalSince1970: 100)))
        #expect(try JSONDecoder().decode(MediaProgress.self, from: saved) == MediaProgress(track: 3, seconds: 12.5, finished: true, updated: Date(timeIntervalSince1970: 100)))
        let old = try JSONDecoder().decode(MediaProgress.self, from: Data(#"{"track":1,"seconds":2,"finished":false}"#.utf8))
        #expect(old.updated == nil && old.track == 1)
    }
}

// MARK: - Linked media

@Suite("LinkedMedia")
struct LinkedMediaTests {
    @Test("Add, load and remove round-trip in the library's Media folder")
    func roundTrip() throws {
        let tmp = try TempDir()
        let library = try tmp.folder("Library")
        let song = try tmp.file("Music/Album/1.mp3")
        let film = try tmp.file("Movies/Film.mp4")
        let album = LinkedMediaEntry(kind: .audio, title: "Album", creator: "Mara", folder: song.deletingLastPathComponent().path, tracks: [song.path])
        let movie = LinkedMediaEntry(kind: .video, title: "Film", folder: nil, tracks: [film.path])
        #expect(try LinkedMedia.add([album, movie], to: library) == 2)
        #expect(FileManager.default.fileExists(atPath: library.appending(path: "Media/Linked Media.json").path))
        let loaded = LinkedMedia.load([library])
        #expect(loaded.map(\.id) == [album.id, movie.id])
        #expect(loaded.first?.creator == "Mara")
        // The same first file isn't linked twice.
        #expect(try LinkedMedia.add([LinkedMediaEntry(kind: .video, title: "Again", folder: nil, tracks: [film.path])], to: library) == 0)
        try LinkedMedia.remove(id: album.id, from: [library])
        #expect(LinkedMedia.load([library]).map(\.id) == [movie.id])
        #expect(FileManager.default.fileExists(atPath: song.path), "removing a link never touches the file")
    }

    @Test("Loading several libraries skips duplicate ids and damaged lists")
    func severalLibraries() throws {
        let tmp = try TempDir()
        let one = try tmp.folder("One"), two = try tmp.folder("Two"), broken = try tmp.folder("Broken")
        let entry = LinkedMediaEntry(kind: .video, title: "Film", folder: nil, tracks: ["/tmp/nowhere/film.mp4"])
        try LinkedMedia.add([entry], to: one)
        try LinkedMedia.add([entry], to: two)
        try tmp.file("Broken/Media/Linked Media.json", "{ not json")
        #expect(LinkedMedia.load([one, two, broken]).count == 1)
        #expect(LinkedMedia.load([tmp.url.appending(path: "Missing")]).isEmpty)
    }

    @Test("Items: present links play; missing files and folders say so")
    func items() throws {
        let tmp = try TempDir()
        let film = try tmp.file("Movies/Film.mp4")
        let albumFolder = try tmp.folder("Music/Album")
        try tmp.file("Music/Album/02 Second.mp3")
        try tmp.file("Music/Album/01 First.mp3")
        try tmp.file("Music/Album/cover.jpg")
        let entries = [
            LinkedMediaEntry(kind: .video, title: "Film", folder: nil, tracks: [film.path]),
            LinkedMediaEntry(kind: .audio, title: "Album", folder: albumFolder.path, tracks: [albumFolder.appending(path: "01 First.mp3").path]),
            LinkedMediaEntry(kind: .video, title: "Gone", folder: nil, tracks: [tmp.url.appending(path: "Movies/Gone.mp4").path]),
            LinkedMediaEntry(kind: .audio, title: "Gone Album", folder: tmp.url.appending(path: "Music/Gone").path,
                             tracks: [tmp.url.appending(path: "Music/Gone/1.mp3").path]),
        ]
        let items = LinkedMedia.items(entries)
        #expect(items.count == 4)
        #expect(items[0].unavailable == nil && items[0].catalogKey == "/@linked/\(entries[0].id)" && items[0].linkID == entries[0].id)
        #expect(items[1].tracks.map(\.lastPathComponent) == ["01 First.mp3", "02 Second.mp3"], "tracks added to the folder later are picked up, in order")
        #expect(items[1].cover?.lastPathComponent == "cover.jpg")
        #expect(items[2].unavailable == "its file" && items[2].unavailableBadge == "File missing")
        #expect(items[3].unavailable == "its folder" && items[3].unavailableBadge == "Folder missing")
    }

    @Test("Drive names come from /Volumes paths")
    func volumeName() {
        #expect(LinkedMedia.volumeName("/Volumes/My Drive/Movies/Film.mp4") == "My Drive")
        #expect(LinkedMedia.volumeName("/Users/me/Movies/Film.mp4") == nil)
        #expect(LinkedMedia.volumeName("/Volumes") == nil)
    }

    @Test("Relocate points a link at its new place, checking file versus folder")
    func relocate() throws {
        let tmp = try TempDir()
        let library = try tmp.folder("Library")
        let moved = try tmp.file("New/Film.mp4")
        let entry = LinkedMediaEntry(kind: .video, title: "Film", folder: nil, tracks: [tmp.url.appending(path: "Old/Film.mp4").path])
        try LinkedMedia.add([entry], to: library)
        #expect(throws: LinkedMedia.LocateError.self) { try LinkedMedia.relocate(id: entry.id, to: tmp.url.appending(path: "New"), in: [library]) }
        try LinkedMedia.relocate(id: entry.id, to: moved, in: [library])
        #expect(LinkedMedia.load([library]).first?.tracks == [moved.path])
        #expect(throws: LinkedMedia.LocateError.self) { try LinkedMedia.relocate(id: "no-such-id", to: moved, in: [library]) }
    }
}

// MARK: - Scanning and the details cache

@Suite("Media scan and details cache", .serialized)
struct MediaScanTests {
    @Test("Scanning finds films, albums, loose songs and books")
    func scan() throws {
        let tmp = try TempDir()
        let media = try tmp.folder("Media")
        try tmp.file("Media/Films/Tears_of_Steel (2012).mp4")
        try tmp.file("Media/Music/Artist/Album/02 - Two.mp3")
        try tmp.file("Media/Music/Artist/Album/01 - One.mp3")
        try tmp.file("Media/Music/Loose Song.mp3")
        try tmp.file("Media/Books/Manual.pdf")
        try tmp.file("Media/Films/._Tears_of_Steel (2012).mp4")
        try tmp.file("Media/Films/partial.mp4.part")
        try tmp.file("Media/.hidden/secret.mp4")
        let items = MediaLibrary.scan([media])
        #expect(items.map(\.title) == ["Album", "Loose Song", "Manual", "Tears of Steel (2012)"])
        let album = try #require(items.first { $0.title == "Album" })
        #expect(album.kind == .audio && album.tracks.map(\.lastPathComponent) == ["01 - One.mp3", "02 - Two.mp3"])
    }

    @Test("Prune drops details for files that are gone, but keeps drives that are away and old entries until a full scan")
    func prune() throws {
        _ = try TestSupport.testHome()
        let fm = FileManager.default
        let thumbs = MediaInfoStore.folder.appending(path: "thumbs", directoryHint: .isDirectory)
        try fm.createDirectory(at: thumbs, withIntermediateDirectories: true)
        func thumb(_ name: String) throws -> String {
            let url = thumbs.appending(path: name)
            try Data("jpg".utf8).write(to: url)
            return url.path
        }
        func info(source: String?, thumb: String?) -> MediaInfo {
            var i = MediaInfo(duration: 60, year: nil, genre: nil, added: Date(timeIntervalSince1970: 0), thumb: thumb)
            i.source = source
            return i
        }
        let keptThumb = try thumb("kept.jpg"), goneThumb = try thumb("gone.jpg"), sharedThumb = try thumb("shared.jpg")
        let seeded: [String: MediaInfo] = [
            "keep": info(source: "/tmp/okit-tests/kept.mp4", thumb: keptThumb),
            "gone": info(source: "/tmp/okit-tests/gone.mp4", thumb: goneThumb),
            "gone-shared": info(source: "/tmp/okit-tests/gone2.mp4", thumb: sharedThumb),
            "keep-shared": info(source: "/tmp/okit-tests/kept2.mp4", thumb: sharedThumb),
            "drive": info(source: "/Volumes/OKTestNoSuchDrive/film.mp4", thumb: nil),
            "old": info(source: nil, thumb: nil),
        ]
        // The details cache reads its file once, on first use; nothing else in the tests uses it before this.
        let file = MediaInfoStore.folder.appending(path: "info.json")
        try JSONEncoder().encode(seeded).write(to: file)
        func saved() throws -> Set<String> {
            Set(try JSONDecoder().decode([String: MediaInfo].self, from: Data(contentsOf: file)).keys)
        }
        MediaInfoStore.shared.prune(keeping: ["keep", "keep-shared"], complete: false)
        #expect(try saved() == ["keep", "keep-shared", "drive", "old"])
        #expect(!fm.fileExists(atPath: goneThumb), "a gone file's picture is deleted")
        #expect(fm.fileExists(atPath: sharedThumb), "a picture still used by another entry stays")
        #expect(fm.fileExists(atPath: keptThumb))
        MediaInfoStore.shared.prune(keeping: ["keep", "keep-shared"], complete: true)
        #expect(try saved() == ["keep", "keep-shared", "drive"], "after a complete scan, entries without a source go too")
    }

    @Test("Library-catalog subjects become friendly genres")
    func friendlyGenre() {
        #expect(MediaInfoStore.friendlyGenre(["Holmes, Sherlock (Fictitious character)--Fiction"]) == "Mystery")
        #expect(MediaInfoStore.friendlyGenre(["Buried treasure--Fiction"]) == "Adventure")
        #expect(MediaInfoStore.friendlyGenre(["Frankenstein's monster"]) == "Science Fiction & Horror")
        #expect(MediaInfoStore.friendlyGenre(["Something else"]) == "Classics")
        #expect(MediaInfoStore.friendlyGenre([]) == nil)
    }
}

@Suite struct HitPauseWatchdogTests {
    @Test func releasesAfterStillnessAndResumesOnMovement() {
        var w = HitPauseWatchdog()
        let t0 = Date()
        let paused = w.phase(moving: true, now: t0)
        #expect(paused)
        #expect(!w.shouldRelease(now: t0.addingTimeInterval(0.3)))
        // Offset keeps changing: never released.
        _ = w.offsetChanged(now: t0.addingTimeInterval(0.4))
        #expect(!w.shouldRelease(now: t0.addingTimeInterval(0.8)))
        // Phase never ends and the offset stands still.
        #expect(w.shouldRelease(now: t0.addingTimeInterval(0.95)))
        // Movement resumes while the phase is still moving: pause again.
        let resumed = w.offsetChanged(now: t0.addingTimeInterval(1.0))
        #expect(resumed)
        #expect(!w.shouldRelease(now: t0.addingTimeInterval(1.1)))
        // A real end clears it.
        let ended = w.phase(moving: false, now: t0.addingTimeInterval(1.2))
        #expect(!ended)
        #expect(!w.shouldRelease(now: t0.addingTimeInterval(9)))
    }
}
