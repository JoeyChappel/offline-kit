import Foundation
import Testing
import CoreGraphics

/// Automatic artwork (AutoArtwork, MovieArtwork, GeneratedCovers, GameTitleCards): the rules, on synthetic pictures.
@Suite("Artwork title matching")
struct ArtworkTitleMatchTests {
    @Test func ignoresCaseArticlesPunctuationAndYear() {
        #expect(TitleMatch.matches("LIGHTHOUSE KEEPER", title: "The Lighthouse Keeper (2021)"))
        #expect(TitleMatch.matches("the lighthouse-keeper!", title: "The Lighthouse Keeper"))
        #expect(TitleMatch.words("The Lord of the Rings: Return (2003)") == ["lord", "of", "rings", "return"])
        #expect(TitleMatch.matches("AMELIE", title: "Amélie"))
        #expect(TitleMatch.matches("TOM AND JERRY", title: "Tom & Jerry"))
    }

    @Test func forgivesSmallReadingMistakes() {
        #expect(TitleMatch.matches("TEARS 0F STEEL", title: "Tears of Steel"))
        #expect(TitleMatch.matches("TEARSOFSTEEL", title: "Tears of Steel (2012)"))
        #expect(TitleMatch.matches("THE LIGHTHOUSE\nKEEPER", title: "The Lighthouse Keeper"))
        #expect(TitleMatch.matches("A FILM BY SOMEONE  NIGHT TRAIN", title: "Night Train (1999)"))
    }

    @Test func rejectsOtherText() {
        #expect(!TitleMatch.matches("NORTHWIND PICTURES presents", title: "Night Train"))
        #expect(!TitleMatch.matches("HARBOR LIGHTS", title: "Night Train"))
        #expect(!TitleMatch.matches("", title: "Night Train"))
        #expect(!TitleMatch.matches("LIGHTHOUSE", title: "The Lighthouse Keeper"))   // half the title isn't the title
        #expect(TitleMatch.score("anything", title: "The") == 0)                     // nothing left after articles
        // Two-letter words must be read exactly.
        #expect(!TitleMatch.matches("UB", title: "Up"))
    }

    @Test func prefersBigCentredWords() {
        let big = [TextLine(text: "NIGHT TRAIN", box: CGRect(x: 0.2, y: 0.42, width: 0.6, height: 0.16))]
        let small = [TextLine(text: "NIGHT TRAIN", box: CGRect(x: 0.02, y: 0.02, width: 0.2, height: 0.03))]
        #expect(FrameText.titleScore(big, title: "Night Train") > FrameText.titleScore(small, title: "Night Train"))
        #expect(FrameText.titleScore(big, title: "Night Train") > 0.9)
    }
}

/// Synthetic grey pictures for the frame checks.
enum SyntheticFrame {
    static func make(width: Int = 320, height: Int = 180, _ value: (Int, Int) -> UInt8) -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height { for x in 0..<width { pixels[y * width + x] = value(x, y) } }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
    /// Sharp shapes and fine texture, full range: a frame worth showing.
    static var busy: CGImage {
        make { x, y in
            var h = UInt32(truncatingIfNeeded: x &* 73856093) ^ UInt32(truncatingIfNeeded: y &* 19349663)
            h = (h ^ (h >> 13)) &* 0x5bd1e995
            let blocks = ((x / 20) + (y / 20)) % 2 == 0 ? 200 : 40
            return UInt8(clamping: blocks + Int(h % 50) - 25)
        }
    }
}

@Suite("Artwork frame checks")
struct ArtworkFrameTests {
    func stats(_ image: CGImage) throws -> FrameStats { try #require(FrameStats.measure(image)) }

    @Test func blackFrameIsRejected() throws {
        let s = try stats(SyntheticFrame.make { _, _ in 4 })
        #expect(FrameCheck.rejection(s) == .black)
        #expect(FrameCheck.isBlank(s))
    }

    @Test func flatFrameIsRejected() throws {
        let s = try stats(SyntheticFrame.make { _, _ in 128 })
        #expect(FrameCheck.rejection(s) == .flat)
        #expect(FrameCheck.isBlank(s))
    }

    @Test func fadedFrameIsRejected() throws {
        // Sharp pattern, but only a sliver of contrast: a frame mid-fade, or washed out.
        let s = try stats(SyntheticFrame.make { x, y in ((x / 6) + (y / 6)) % 2 == 0 ? 140 : 180 })
        #expect(FrameCheck.rejection(s) == .faded)
    }

    @Test func blurryFrameIsRejected() throws {
        // A smooth sweep from dark to light: plenty of contrast, no edges at all.
        let s = try stats(SyntheticFrame.make { x, _ in UInt8(30 + x * 190 / 320) })
        #expect(FrameCheck.rejection(s) == .blurry)
    }

    @Test func busyFrameIsKept() throws {
        let s = try stats(SyntheticFrame.busy)
        #expect(FrameCheck.rejection(s) == nil)
        #expect(!FrameCheck.isBlank(s))
        #expect(s.sharpness > 100)
    }

    @Test func titleCardOnBlackIsNotBlankButIsNotAScene() throws {
        // White block letters on black: blank for neither pass, but the best-frame pass still wants a scene.
        let s = try stats(SyntheticFrame.make { x, y in (x > 100 && x < 220 && y > 70 && y < 110 && (x / 8) % 2 == 0) ? 240 : 6 })
        #expect(!FrameCheck.isBlank(s))
        #expect(FrameCheck.rejection(s) == .black)
    }

    @Test func creditsLookLikeCredits() {
        let crawl = (0..<8).map { CGRect(x: 0.3, y: 0.1 + Double($0) * 0.1, width: 0.4, height: 0.03) }
        #expect(FrameCheck.looksLikeCredits(crawl))
        let title = [CGRect(x: 0.2, y: 0.45, width: 0.6, height: 0.14)]
        #expect(!FrameCheck.looksLikeCredits(title))
        let subtitle = [CGRect(x: 0.2, y: 0.05, width: 0.6, height: 0.04), CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.04)]
        #expect(!FrameCheck.looksLikeCredits(subtitle))
    }
}

@Suite("Game title screens")
struct GameTitleScreenTests {
    @Test func publisherSplashesAreSplashes() {
        #expect(GameTitleCards.isSplash(["LICENSED BY", "NINTENDO"], title: "Sky Rider"))
        #expect(GameTitleCards.isSplash(["HUDSON SOFT", "PRESENTS"], title: "Sky Rider"))
        #expect(GameTitleCards.isSplash(["© 1990 KONAMI"], title: "Sky Rider"))
        #expect(GameTitleCards.isSplash(["(C) 1991 CAPCOM CO., LTD.", "LICENSED BY NINTENDO"], title: "Sky Rider"))
    }

    @Test func titleScreensAreNotSplashes() {
        #expect(!GameTitleCards.isSplash(["SKY RIDER", "PRESS START", "(C) 2026 TEST SOFT"], title: "Sky Rider"))
        // The logo didn't read, but "PUSH START" says it's the title screen.
        #expect(!GameTitleCards.isSplash(["PUSH START", "© 1989 NINTENDO"], title: "Something Else"))
        #expect(!GameTitleCards.isSplash([], title: "Sky Rider"))
        // Lots of other words: a story screen or a menu, not a publisher's card.
        #expect(!GameTitleCards.isSplash(["THE KINGDOM WAS QUIET UNTIL THE NIGHT THE DRAGON CAME DOWN FROM THE MOUNTAIN"], title: "X"))
    }

    func shot(_ seconds: Double, _ image: CGImage, _ text: [String]) -> GameTitleCards.ShotInfo {
        GameTitleCards.ShotInfo(seconds: seconds, stats: FrameStats.measure(image), text: text)
    }

    @Test func picksTheTitleOverSplashAndBlack() {
        let black = SyntheticFrame.make { _, _ in 0 }
        let splash = SyntheticFrame.busy
        let titled = SyntheticFrame.make { x, y in (x / 8 + y / 8) % 3 == 0 ? 230 : 10 }
        let shots = [shot(1, black, []), shot(2, splash, ["LICENSED BY", "NINTENDO"]), shot(3, titled, ["SKY RIDER", "PRESS START"]),
                     shot(4, splash, [])]
        #expect(GameTitleCards.choose(shots, title: "Sky Rider") == 2)
    }

    @Test func withoutTheTitlePicksTheMostDetailedNonSplash() {
        let plain = SyntheticFrame.make { x, y in (x / 40 + y / 40) % 2 == 0 ? 200 : 30 }
        let busy = SyntheticFrame.busy
        let shots = [shot(1, busy, ["LICENSED BY", "NINTENDO"]), shot(2, plain, []), shot(3, busy, [])]
        #expect(GameTitleCards.choose(shots, title: "Sky Rider") == 2)
        #expect(GameTitleCards.choose([shot(1, SyntheticFrame.make { _, _ in 0 }, [])], title: "Sky Rider") == nil)
    }
}

@Suite("Artwork precedence and keys")
struct ArtworkRuleTests {
    @Test func userBeatsSidecarBeatsEmbeddedBeatsGenerated() {
        var c: [ArtworkSource: String] = [.custom: "user", .sidecar: "folder", .embedded: "tag", .still: "still", .generated: "gen", .automatic: "auto"]
        #expect(ArtworkRules.pick(c)?.source == .custom)
        c[.custom] = nil
        #expect(ArtworkRules.pick(c)?.path == "folder")
        c[.sidecar] = nil
        #expect(ArtworkRules.pick(c)?.source == .embedded)
        c[.embedded] = nil
        #expect(ArtworkRules.pick(c)?.source == .still)
        c[.still] = nil
        #expect(ArtworkRules.pick(c)?.source == .generated)
        c[.generated] = nil
        #expect(ArtworkRules.pick(c)?.source == .automatic)
        #expect(ArtworkRules.pick([:]) == nil)
    }

    @Test func generatedArtOnlyFillsGaps() {
        // A cover of the item's own (custom or sidecar) means nothing is made.
        #expect(!ArtworkRules.wantsGenerated(kind: .video, hasCover: true, thumb: "auto.jpg", art: nil, isPDF: false))
        #expect(!ArtworkRules.wantsGenerated(kind: .audio, hasCover: true, thumb: nil, art: nil, isPDF: false))
        // Embedded art (a thumb read from the files) wins for music and books; a video's thumb is only the automatic frame.
        #expect(!ArtworkRules.wantsGenerated(kind: .audio, hasCover: false, thumb: "tag.jpg", art: nil, isPDF: false))
        #expect(!ArtworkRules.wantsGenerated(kind: .book, hasCover: false, thumb: "epub-cover.jpg", art: nil, isPDF: false))
        #expect(ArtworkRules.wantsGenerated(kind: .video, hasCover: false, thumb: "auto.jpg", art: nil, isPDF: false))
        #expect(ArtworkRules.wantsGenerated(kind: .audio, hasCover: false, thumb: nil, art: nil, isPDF: false))
        #expect(ArtworkRules.wantsGenerated(kind: .book, hasCover: false, thumb: nil, art: nil, isPDF: false))
        // PDFs keep their first page; each file is done once.
        #expect(!ArtworkRules.wantsGenerated(kind: .book, hasCover: false, thumb: nil, art: nil, isPDF: true))
        #expect(!ArtworkRules.wantsGenerated(kind: .video, hasCover: false, thumb: "gen.jpg", art: "titleCard", isPDF: false))
        #expect(!ArtworkRules.wantsGenerated(kind: .video, hasCover: false, thumb: "auto.jpg", art: "none", isPDF: false))
    }

    @Test func thumbKeepsStillsAndEmbeddedArt() {
        #expect(ArtworkRules.thumb(kind: .video, current: "auto.jpg", currentArt: nil, still: nil, generated: "gen.jpg") == "gen.jpg")
        #expect(ArtworkRules.thumb(kind: .video, current: "auto.jpg", currentArt: nil, still: "still.jpg", generated: "gen.jpg") == "still.jpg")
        #expect(ArtworkRules.thumb(kind: .audio, current: "tag.jpg", currentArt: nil, still: nil, generated: "gen.jpg") == "tag.jpg")
        #expect(ArtworkRules.thumb(kind: .audio, current: nil, currentArt: nil, still: nil, generated: "gen.jpg") == "gen.jpg")
        #expect(ArtworkRules.thumb(kind: .book, current: "old-gen.jpg", currentArt: "cover", still: nil, generated: "gen.jpg") == "gen.jpg")
        // Games: a played game's last frame beats its title screen.
        #expect(ArtworkRules.gamePicture(played: "last.png", generated: "title.png") == "last.png")
        #expect(ArtworkRules.gamePicture(played: nil, generated: "title.png") == "title.png")
        #expect(ArtworkRules.gamePicture(played: nil, generated: nil) == nil)
    }

    @Test func keysFollowPathSizeDateAndKind() throws {
        let base = ArtworkRules.key(path: "/a/Movie.mp4", size: 100, modified: 1000, kind: "movie")
        #expect(base == ArtworkRules.key(path: "/a/Movie.mp4", size: 100, modified: 1000, kind: "movie"))
        #expect(base.count == 24)
        #expect(base != ArtworkRules.key(path: "/b/Movie.mp4", size: 100, modified: 1000, kind: "movie"))
        #expect(base != ArtworkRules.key(path: "/a/Movie.mp4", size: 101, modified: 1000, kind: "movie"))
        #expect(base != ArtworkRules.key(path: "/a/Movie.mp4", size: 100, modified: 1001, kind: "movie"))
        #expect(base != ArtworkRules.key(path: "/a/Movie.mp4", size: 100, modified: 1000, kind: "game"))

        let dir = try TempDir()
        let file = try dir.file("Song.mp3", "one")
        let first = try #require(ArtworkRules.key(for: file, kind: "cover"))
        #expect(ArtworkRules.key(for: file, kind: "cover") == first)
        try Data("changed".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: file.path)
        #expect(ArtworkRules.key(for: file, kind: "cover") != first)
        #expect(ArtworkRules.key(for: dir.url.appending(path: "missing.mp3"), kind: "cover") == nil)
    }

    @Test func generatedFilesShareARecordName() {
        #expect(MediaInfoStore.generatedBase("/c/thumbs/gen-ab12.jpg") == "/c/thumbs/gen-ab12")
        #expect(MediaInfoStore.generatedBase("/c/thumbs/gen-ab12-p3.jpg") == "/c/thumbs/gen-ab12")
        #expect(MediaInfoStore.generatedBase("/c/thumbs/ab12.jpg") == nil)
    }

    @Test func restsOnBatteryLowPowerAndBusyTimes() {
        var c = ArtworkConditions()
        #expect(c.pause() == nil)
        c.battery = 0.4; c.pluggedIn = false
        #expect(c.pause() == .battery)
        c.pluggedIn = true
        #expect(c.pause() == nil)
        c.pluggedIn = false; c.battery = 0.6
        #expect(c.pause() == nil)
        c.battery = nil   // a desktop Mac
        #expect(c.pause() == nil)
        c.lowPower = true
        #expect(c.pause() == .lowPower)
        c.lowPower = false; c.thermal = .serious
        #expect(c.pause() == .hot)
        c.thermal = .nominal; c.asking = true
        #expect(c.pause() == .asking)
        c.asking = false; c.playing = true
        #expect(c.pause() == .playing)
        c.game = true
        #expect(c.pause() == .game)
        c.userPaused = true
        #expect(c.pause() == .user)
    }
}

@Suite("Generated covers")
struct GeneratedCoverTests {
    @Test func drawsSquareAlbumsAndTallBooks() throws {
        let album = try #require(GeneratedCovers.draw(.init(title: "Songs from the Lighthouse", byline: "The Harbor Band",
                                                             genre: "Folk", shape: .square, label: "ALBUM")))
        #expect(album.width == 900 && album.height == 900)
        let book = try #require(GeneratedCovers.draw(.init(title: "A Very Long Title That Has To Wrap Over Several Lines To Fit",
                                                            byline: "Some Author", genre: nil, shape: .book, label: "BOOK")))
        #expect(book.width == 640 && book.height == 960)
        // Not a flat swatch: the type and texture are there.
        let s = try #require(FrameStats.measure(album))
        #expect(s.deviation > 0.05)
    }

    @Test func tintFollowsGenreAndIsSteady() {
        #expect(GeneratedCovers.tint(genre: "Jazz", title: "A") == GeneratedCovers.tint(genre: "Blues", title: "B"))
        #expect(GeneratedCovers.tint(genre: "Jazz", title: "A") != GeneratedCovers.tint(genre: "Rock", title: "A"))
        #expect(GeneratedCovers.tint(genre: nil, title: "Same") == GeneratedCovers.tint(genre: nil, title: "Same"))
    }
}

/// End to end with the real NES emulator (fceumm, from Vendor/Cores) and Tools/Tests/make-test-nes.py's title-screen
/// ROM: "LICENSED BY NINTENDO" for 2 seconds, then the "SKY RIDER" title screen. Proves the splash is skipped, the
/// title picked, and that no save is read or written.
@Suite("Game title capture", .serialized)
struct GameTitleCaptureTests {
    static var corePath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Vendor/Cores/fceumm_libretro.xcframework/macos-arm64/fceumm_libretro.framework/fceumm_libretro").path
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: GameTitleCaptureTests.corePath)))
    func capturesSkipsTheSplashAndPicksTheTitle() throws {
        let dir = try TempDir()
        let games = try dir.folder("Games")
        let rom = games.appending(path: "Sky Rider.nes")
        try FileManager.default.copyItem(at: try TestSupport.fixture("Sky Rider.nes"), to: rom)
        let game = Game(url: rom, system: .nes)
        let gate = GameArtworkGate()
        #expect(gate.beginCapture())
        let started = Date()
        let outcome = GameTitleCards.capture(game, corePath: Self.corePath, gate: gate)
        let elapsed = Date().timeIntervalSince(started)
        gate.endCapture()
        guard case .frames(let shots) = outcome else { Issue.record("no frames: \(outcome)"); return }
        #expect(shots.count == GameTitleCards.capturePoints.count)
        #expect(elapsed < GameTitleCards.wallLimit)
        let reading = Date()
        let infos = shots.map { shot in
            GameTitleCards.ShotInfo(seconds: shot.seconds, stats: FrameStats.measure(shot.image, width: 160),
                                    text: FrameText.read(GameTitleCards.upscaled(shot.image) ?? shot.image, accurate: true).map(\.text))
        }
        print("Title capture: \(String(format: "%.3f", elapsed)) s emulation, \(String(format: "%.2f", Date().timeIntervalSince(reading))) s reading; text per point: \(infos.map { "\($0.seconds)s=\($0.text)" })")
        let splashAt1 = infos.first { $0.seconds == 1 }
        #expect(splashAt1.map { GameTitleCards.isSplash($0.text, title: game.title) } == true)
        let index = try #require(GameTitleCards.choose(infos, title: game.title))
        #expect(infos[index].seconds >= 3)
        #expect(TitleMatch.matches(infos[index].text.joined(separator: " "), title: "Sky Rider"))
        // Nothing was written beside the games: no Saves folder, no battery save, no state.
        #expect(!FileManager.default.fileExists(atPath: game.savesFolder.path))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: GameTitleCaptureTests.corePath)))
    func stopsAtOnceWhenAGameStarts() throws {
        let dir = try TempDir()
        let rom = try dir.folder("Games").appending(path: "Sky Rider.nes")
        try FileManager.default.copyItem(at: try TestSupport.fixture("Sky Rider.nes"), to: rom)
        let gate = GameArtworkGate()
        #expect(gate.beginCapture())
        #expect(!gate.beginCapture())   // one capture at a time
        let finished = DispatchSemaphore(value: 0)
        let box = OutcomeBox()
        Thread.detachNewThread {
            box.outcome = GameTitleCards.capture(Game(url: rom, system: .nes), corePath: Self.corePath, gate: gate,
                                                 points: [600], wallLimit: 30)   // would run for a while
            gate.endCapture()
            finished.signal()
        }
        Thread.sleep(forTimeInterval: 0.05)
        let asked = Date()
        gate.gameWillStart()   // what GameSession.start does
        #expect(Date().timeIntervalSince(asked) < 1)
        #expect(!gate.isCapturing)
        #expect(finished.wait(timeout: .now() + 2) == .success)
        if case .aborted = box.outcome {} else { Issue.record("expected an aborted capture, got \(String(describing: box.outcome))") }
        // The core is gone: a game could load its own now.
        let core = try? RetroCore(libraryPath: Self.corePath, options: nil, systemDirectory: dir.url.path, saveDirectory: dir.url.path)
        #expect(core != nil)
    }

    final class OutcomeBox: @unchecked Sendable { var outcome: GameTitleCards.Outcome? }
}

/// Timing on real-looking movies: set OKIT_TEST_MOVIES to a folder made by Tools/Tests/make-test-movies.swift
/// (TEST_RUNNER_OKIT_TEST_MOVIES=<folder> Tools/Tests/run-tests.sh). Skipped otherwise.
@Suite("Movie artwork on test movies", .serialized)
struct MovieArtworkTimingTests {
    static let folder = ProcessInfo.processInfo.environment["OKIT_TEST_MOVIES"]

    func analyze(_ name: String, title: String) async throws -> (MovieArtwork.Analysis, Double) {
        let url = URL(fileURLWithPath: try #require(Self.folder)).appending(path: name)
        let started = Date()
        let analysis = try #require(await MovieArtwork.analyze(url, title: title))
        let elapsed = Date().timeIntervalSince(started)
        print("Movie artwork: \(name): \(analysis.art) at \(analysis.times.first ?? -1) s, \(String(format: "%.2f", elapsed)) s")
        return (analysis, elapsed)
    }

    @Test(.enabled(if: MovieArtworkTimingTests.folder != nil))
    func findsTheTitleCard() async throws {
        let (a, _) = try await analyze("The Lighthouse Keeper (2021).mp4", title: "The Lighthouse Keeper")
        #expect(a.art == .titleCard)
        #expect((3.0...9.0).contains(a.times[0]))
        #expect(a.times.count > 1)   // alternatives for "Pick Another Frame"
    }

    @Test(.enabled(if: MovieArtworkTimingTests.folder != nil))
    func skipsTheStudioCardForTheTitle() async throws {
        let (a, _) = try await analyze("Night Train (1999).mp4", title: "Night Train")
        #expect(a.art == .titleCard)
        #expect((70.0...76.0).contains(a.times[0]))
    }

    @Test(.enabled(if: MovieArtworkTimingTests.folder != nil))
    func picksAGoodFrameWithoutATitleCard() async throws {
        let (a, _) = try await analyze("Harbor Lights.mp4", title: "Harbor Lights")
        #expect(a.art == .frame)
        #expect((0.08 * 120 - 2...0.7 * 120 + 2).contains(a.times[0]))
    }
}
