# Offline Kit: developer notes

## Updated native design

Library now opens with seven subject areas. Drill into an area and topic to find real articles in the saved archives, or switch to All archives to browse a collection directly. Topic searches prefer dedicated references and show the source on every result. Ask about this topic carries its area into retrieval. Get Resources uses the same area labels, preserves selection between areas, and shows a review sheet with actual editions, sizes and free space before downloading.

Games now has system collections, Favorites, Saved Places, recent games and game detail pages. Resume loads a saved emulator state; Play starts the game normally without deleting its save. Favorites and recent-play metadata live in Games/Saves beside each game, so they travel with the drive.

The Compass icon is applied to both app targets as PNG asset-catalog icons.

Focused model checks: `python3 Tools/Tests/verify-models.py`. These verify taxonomy coverage, offline topic search, relevance and deduplication, game metadata persistence and compatibility with existing game-window references.

Ask questions with no internet and get answers grounded in your offline Kiwix library (Wikipedia, WikiMed, iFixit, Stack Exchange), with numbered citations you can click to read the source article.

## How it works

1. **Search:** libzim full-text search across every `.zim` archive. It searches each two-word phrase of the question, then the whole question, then the most specific words, and reranks by title and phrase matches.
2. **Read:** it pulls the most relevant paragraphs from the top articles, sized to the model's context.
3. **Answer:** a local model answers from those passages only, citing `[1]`, `[2]`. If the library doesn't cover the question it says so, and anything from general knowledge is labeled "Not from the library".
4. **Reader:** articles render straight from the archive through a `zim://` scheme handler, with no server.

| | Mac | iPhone / iPad |
|---|---|---|
| Archives | `~/OfflineKit/Library`, any `/Volumes/*/OfflineKit/Library`, plus folders added in Settings | App's Documents (Files app or Finder file sharing, or the + button) |
| AI (Automatic) | Ollama if running (Gemma 4 12B, ~14K chars of sources), else Apple on-device | Apple on-device; or Ollama on the Mac over home Wi-Fi (set the address in Settings) |

Apple's on-device model runs offline but needs Apple Intelligence turned on (and its model downloaded) while you're still online. iPhone 15 Pro or newer, iOS 26+.

## Get Resources (picker and downloader)

- **Pick by interest:** Emergency essentials, Survival and preparedness (Army publications, Military Medicine, Ready.gov, CD3WD, prepper videos, Survivor Library), Health, Home and repair, Food and outdoors, Science, History and travel, Learning, Sports and entertainment (off by default), and Maps. A separate one-choice "General encyclopedia" list (None, Best of, Top 1M, All, Simple English) is labeled as including pop culture, so "science only" means None plus Science.
- **Size:** With pictures, Text only or Summaries. Each pack uses the closest size Kiwix publishes.
- **Catalog:** the live Kiwix OPDS feed (`library.kiwix.org/catalog/v2`), cached beside the kit so sizes still show offline. Curated pack names are in `Sources/Core/Catalog.swift`.
- **Downloader** (`Sources/Core/Downloader.swift`): reads the `.meta4` mirror list and fetches 8 MB chunks from up to 10 connections across mirrors. Each chunk is checked against the metalink's SHA-1 piece hashes before it's written. A slow mirror's last chunks get re-requested elsewhere. Progress is saved to `name.zim.okdl` beside `name.zim.part`, and the whole file is checked against SHA-256 before it's renamed into place. It refuses FAT32 drives for files over 4 GB and checks free space first.
- **Tested:** a 21 MB pack, and a 573 MB pack stopped two-thirds of the way through then resumed; both match Kiwix's SHA-256.

## Games

Built-in emulators play Game Boy, Game Boy Color, Game Boy Advance (mGBA, MPL 2.0) and NES (FCEUmm, GPLv2 or later) files the user adds. No games ship in the app; the test library holds four openly licensed homebrew games (Tobu Tobu Girl, Apotris, Thwaite, Concentration Room), each under its own open license; they aren't part of this repository.

- **Cores:** `Vendor/Cores/*.xcframework`, dynamic frameworks for macOS, iOS and the simulator, embedded but not linked and loaded with `dlopen` (both export the same `retro_*` symbols). Rebuild scripts and source commits are in `Vendor/Cores/README.md`.
- **Bridge:** `Sources/Bridge/RetroCore` is a minimal libretro frontend that handles video in RGB565, XRGB8888 and 0RGB1555, an audio ring buffer, joypad input, save states and battery saves.
- **Player:** `Sources/App/GameSession.swift` runs the core on its own thread at the console's frame rate, plays sound through AVAudioEngine and keeps audio delay under 0.2 seconds. `GamesView.swift` holds the shelf and the player:
  - Mac: keyboard (arrows, X/Z, Q/W, Return, Space) and ⌘S/⌘L/⌘P.
  - iPhone: touch D-pad and buttons.
  - Both: Bluetooth controllers through GameController.
- **Saves:** `Games/Saves/` beside the games (battery saves `.srm`, one save-state slot `.state`, a `.png` of the last frame as tile art), so progress travels with the drive.
- **Tested:** all four games on the Mac and the NES and GBA games in the iPhone simulator. All ran at about 60 fps with sound, and button presses reached the games. Not tested on a real iPhone or with a physical controller.
- **Licensing:** FCEUmm's source headers say GPLv2 "or any later version" (509 files checked), so it's compatible with the app's GPLv3. mGBA's MPL 2.0 is also compatible.
- **Debug hooks:** `-autoPlay /path/game.gba -gameSnapshot /tmp/prefix` opens a game and saves two frames plus stats.

## Watch & Listen and format filters

- `Sources/Core/ContentFormat.swift` labels packs and archives by format. Get Resources shows filter chips; the Library sidebar has a Show menu.
- New pack groups in `Catalog.swift`: Books to read (Gutenberg by shelf) and Watch and learn (TED-Ed, TED Kids, TED by topic, CrashCourse, Khan Academy).
- `Sources/App/MediaLibrary.swift` and `WatchListenView.swift` scan each library's `Media` folder (and the old `~/OfflineKit/Kids`). Videos (MP4, M4V, MOV) are single items; a folder of audio files (MP3, M4A, M4B and others) is an audiobook with chapters. Progress is saved in the kit settings (on the drive in drive mode). AVKit plays video; a custom audio player handles chapters, skip, speed and background audio on iPhone. MKV and AVI aren't supported by Apple's player.
- LibriVox picks: 12 public-domain children's audiobooks, downloaded chapter by chapter (64 kbps MP3 from archive.org via the LibriVox API) into `Media/Audiobooks/<title>/`, with a `.complete` marker.
- The reader (`zim://`) and Wi-Fi sharing answer byte-range requests, so videos inside archives (TED packs are WebM) can play and seek.
- **Tested:** the TED grammar pack loads; a talk's video answers full and range requests (206 with Content-Range). *The Tale of Peter Rabbit and Others* downloaded through the app (18 chapters, 76 MB) and appeared as an 18-chapter audiobook. A spoken test audiobook was scanned as 2 chapters. **Not tested:** tapping play in the audio or video player, resume after relaunch, actual WebM playback in the reader, the iPhone layout of Watch & Listen.
- **Debug hooks:** `-startSection media|games|resources|share`, `-getAudiobook <LibriVox id>`.

## Find my media and Organize with AI (Mac)

- **Find my media** (`Sources/App/FindMedia.swift`): looks through Music, Movies, Downloads, Documents, Desktop, drives under `/Volumes` and chosen folders. Skips app bundles and other packages (the Photos library), `~/Library`, system folders, the Trash, the kit's own folders and iCloud files that aren't downloaded. Groups results by album, audiobook, series and type, with cover art from folder art, embedded artwork or EPUB covers. Marks items already in the kit (same path, or same size and checksum: whole-file SHA-256 up to 256 MB, size plus three 4 MB samples above that). FairPlay `.m4p` files and protected `.m4v` files are listed under "Won't play here" and never added.
- **Asking**: "my Beatles albums" goes to the Ask model (Ollama or the built-in engine) for search words and kinds, is matched against folder names and tags, then the model picks which of the closest 40 really match. Without a model it matches by keywords.
- **Adding**: Keep where it is (a link in `Media/Linked Media.json` in the library, shown as unavailable while its drive is unplugged), Copy, or Move (copy, verify size and SHA-256, then the original goes to the Trash, only after a confirmation listing every file). Copy and move share `KitTransfer` with drag-and-drop import. Games are always copied so their saves live with the kit.
- **Organize with AI** (`MediaOrganizer.swift`, `OrganizeView.swift`, `KitCatalog.swift`): fills in genre, sub-genre, studio/publisher/author, year, series and order, an age rating (G, PG, Teen, Mature) and a one-line description. Trust order per field: the file's own tags (ID3/MP4, EPUB creator, Calibre or EPUB 3 *series*-type collections, Game Boy cartridge names), then a Wikipedia archive in the kit (title lookup plus Ask's read-only `Retriever`; a value is labeled as from the article only if the article text contains it), then the model's knowledge, labeled "AI guess". EPUB `dc:date` is treated as the edition date, not first publication. Everything waits on a review screen (approve, edit, skip, or approve all in a section). Approved details live in `Kit Catalog.json` in each library folder; a person's edits are saved as theirs and never replaced by a re-run. Files are never renamed or moved.
- **Where it shows**: genre tiles and rows, series rows in order, "More from <studio or author>" rows and detail-page details in Watch & Listen; genre and publisher groups in Play; `/api/media` adds `subgenre`, `studio`, `series`, `seriesOrder`, `ageRating`, `summary` and `aiGuess` (no field renamed); the Apple TV shows the description.
- **Game checksums:** libretro-database is CC BY-SA 4.0 and its game data comes from No-Intro and other groups whose terms the repo doesn't state, so a trimmed copy isn't bundled. Games use the cartridge name and the model instead, labeled as such.
- **macOS privacy prompts** (the Developer ID build isn't sandboxed, so these come from macOS privacy controls): the first read of Desktop, Documents, Downloads, a removable drive or a network share makes macOS ask. `Sources/Mac/Info.plist` has `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription` and `NSNetworkVolumesUsageDescription` for that dialog's wording. Find my media explains the prompt before scanning (and marks each place "macOS asks first"), tells people to choose Allow while it scans, and if access was turned off, names the place and points to System Settings › Privacy & Security › Files and Folders. Music and Movies folders don't prompt. A library on a USB drive already caused the removable-volume prompt at launch; its wording now covers that too.
- **Debug hooks (test home only):** `-findMedia "<request>"` (scan everything listed, ask, write `debug-find.json`; `open` just opens the sheet), `-findMediaAdd keep|copy|move`, `-organizeMedia YES` with `-organizeScope video|music|audiobook|book|game` and `-organizeRedo YES`, `-organizeOpen YES`, `-organizeApproveAll YES`; `OFFLINEKIT_ORGANIZE_NO_GROUNDING=1` turns grounding off for comparisons.

## Share on Wi-Fi (Mac)

Sidebar › Share on Wi-Fi turns the Mac into a small web server for phones, tablets and PCs on the home network. They open the address (or scan the QR code) in a browser and get Ask (answered by the Mac's model, streamed, with citations) and the Library (browse every archive, search titles, read articles with a "Back to Offline Kit" bar). Nothing needs installing on them and no internet is needed.

- **Code:**
  - `Sources/Mac/WebServer.swift`: HTTP/1.1 on Network.framework, Bonjour `_http._tcp`, first free port from 8080 to 8099. It checks each port with a real bind first; 8080 is often taken.
  - `ShareController.swift`: routes, PIN and Ask streaming.
  - `ShareView.swift`: the screen.
  - `WebApp.swift` and `WebAppScript.swift`: the page. The script builds the page with DOM methods, never by parsing HTML.
- **Routes:**
  - `/` (page)
  - `GET /api/status`, `/api/books`, `/api/search?q=&book=&mode=title|text`
  - `POST /api/login` (PIN) and `/api/ask` (server-sent events: engine, sources, answer, done or error)
  - `/book/<id>` (home page)
  - `/content/<id>/<path>` (archive files; redirects keep relative links right)
- **Safety:**
  - Off by default.
  - Read-only.
  - Accepts only private, link-local or loopback addresses.
  - An optional PIN stored as an HttpOnly cookie, with a delay after wrong attempts.
  - One question at a time (others get a "try again" message).
  - Requests over 256 KB are refused.
- **Tested:**
  - Every route with curl, including the PIN flow (no PIN gives 401 or a redirect, the wrong PIN gives 401, the right PIN sets the cookie).
  - A streamed Ask answer from Gemma 4 citing WikiMed and Wikipedia.
  - Article CSS and images.
  - The page in iPhone simulator Safari over the LAN address.
  - Not yet tested from a separate physical phone. The Mac's firewall prompt (if the firewall is on) hasn't been seen yet.
- **Debug hooks:** `-shareOnLaunch YES` starts sharing without changing the saved setting, and `-sharePIN 1234` sets a PIN for that run.
- **Connected Devices** (`ShareDevices.swift`, `ShareDevicesView.swift`, `NeighborTable.swift`; Share › Connected Devices…, ⇧⌘J): every client gets an HttpOnly `okdev` cookie and is told apart by MAC (neighbor tables), cookie, sign-in token, then IP + client kind. Blocking and "Ask before new devices connect" are checked in `ShareDevices.admit`, right after the Host check on both ports; refusals are 403 with `{"error": "blocked"|"waiting"}`, which the iPhone and Apple TV apps show (and poll while waiting). Approvals and the ask-first choice live in this Mac's own settings; a drive's settings can only add blocks or turn asking on. Debug hooks (test home): `-openDevices YES`, `-shareAskFirst YES`, `-devicesSelect <text>`, `-shareDeviceActions "20:block:Edge,30:signout:iPhone,40:allow:Android"`, `-neighborCheck YES` (logs neighbor counts and a digest to compare with `arp -an`/`ndp -an`).

## Drive mode

When the app runs from an external drive (`/Volumes/...`), the folder holding it is the kit: `Library/` beside the app is scanned first and is the default download location, and settings live in `Offline Kit Settings.plist` beside it instead of the Mac's preferences. Settings › Drive mode › "Put Offline Kit on a Drive" copies the app to `<drive>/OfflineKit/`. `OFFLINEKIT_ROOT=/path` forces drive mode for testing.

## Build

Requirements: Xcode 27, XcodeGen (`brew install xcodegen`).

```bash
xcodegen generate
```

```bash
xcodebuild -project OfflineKit.xcodeproj -scheme OfflineKit-macOS -derivedDataPath build build
```

```bash
open "build/Build/Products/Debug/Offline Kit.app"
```

For iPhone, open `OfflineKit.xcodeproj`, pick the `OfflineKit-iOS` scheme, set your Team under Signing & Capabilities, and run on your phone.

`okit` is a command-line test harness that uses the same core:

```bash
build/Build/Products/Debug/okit --sources-only "signs of heat stroke in a child"
```

```bash
build/Build/Products/Debug/okit --engine apple "how do I reset a tripped GFCI outlet"
```

```bash
build/Build/Products/Debug/okit --catalog
```

```bash
build/Build/Products/Debug/okit --download zimgit-water_en /tmp/okit-test
```

Debug builds accept `-autoAsk "question"` at launch to ask automatically (used for simulator testing).

### Ask benchmarks and checks (okit)

Run them on a Debug `okit` with `OFFLINEKIT_HOME=<test home>` (a folder with `OfflineKit/Library` holding the archives and `Models`; symlinked files need an old modification time, e.g. `touch -h -t 202611010000`, or they count as still downloading) and `OFFLINEKIT_NO_OLLAMA=1`. `OFFLINEKIT_GREEDY=1` makes answers repeatable, `OFFLINEKIT_NO_INDEX=1` searches with libzim instead of the answer index, `OFFLINEKIT_TRACE=1` prints where a question's time goes.

- `--ask-bench Tools/Tests/ask-conversations.txt [--wait 5] [--gap 3] [--out r.json] [--sources-only]`: Ask end to end in a fresh process, as a person uses it: first word per turn, prompt and reused tokens, memory. It also scores each turn: the share of its top three sources on the expected topic (each question's `=> word|word; word` in the file), valid citations, "not in your library" said when it should be (`=> none`), and answers that repeat the instructions. `--sources-only` runs Ask's source search per turn without answering, for retrieval changes.
- `--followup-check Tools/Tests/ask-conversations.txt`: each conversation's second answer with and without the saved conversation state; greedy answers must be identical.
- `--bench Tools/Tests/ask-bench-questions.txt [--ttfw]`: retrieval time and source size per question, two passes; `--ttfw` adds time to first word.
- `--llama-bench <questions.txt> [--tokens 128]`: the built-in model's prompt and generation speed and memory.
- `--search-cold "query" […]`: each archive's first libzim search against later ones.
- `--index-build <file.zim> [--seconds 60]`: the app's answer-index builder on one archive: articles a second and CPU.
- `--index-bench <file.zim> [--limit N] [--depth full|leads] [--questions q.txt]`: index build and query timings.
- `--html-check <file.zim> [--articles N]`: the byte scanner against the regular expressions it replaced, article by article, with timings. `OFFLINEKIT_HTML_LIST=1` lists every differing article, `OFFLINEKIT_HTML_ONLY=<path>` checks one.

Test archives, no downloads: `Tools/Tests/make-tiny-zim.py` writes `Tests/Fixtures/tiny.zim` (six articles, the unit tests' fixture; `--index` writes `tiny-indexed.zim` with a full-text index), and `Tools/Tests/make-test-zim/make-test-zim.py <folder>` writes `practical.zim` (about 300 health, repair and food articles) and `encyclopedia.zim` (about 20,000 short articles), or with `--big N` a Wikipedia-sized archive for index scale tests.

## First-run smoke test

```bash
Tools/Tests/first-run-smoke.sh [--drop] [--keep] [--no-build]
```

Walks a brand-new user through setup with no internet: builds the Debug app, writes test archives, starts `Tools/Tests/first-run-server.py` (a fake Kiwix catalog, metalinks with real SHA-256 and piece hashes, and Range downloads on a free 127.0.0.1 port), then launches the app in a fresh `OFFLINEKIT_HOME`. Run 1 presses through the setup screens (`-onboardingScript`), downloads, and waits for the answer index; run 2 reopens the app and asks a question (`-autoAsk`). It checks sizes, checksums, no leftover partial files, an index per archive and a cited source, then cleans up. `--drop` throttles the server and stops it mid-download to check recovery; `--keep` leaves the screenshots (`shots/`, one PNG per window per time in `-snapshotAt`), logs and test home in a folder it prints. Needs a logged-in desktop session (the app opens windows). Takes about 3 minutes with the build.

- **Test server override:** `OFFLINEKIT_TEST_SERVER=http://127.0.0.1:<port>` points the catalog and downloads at the local server. It works only in Debug builds, only with `OFFLINEKIT_HOME` set, and only for 127.0.0.1 (`LocalTestServer` in `Catalog.swift`); a Release build ignores it.
- **Setup hook:** `-onboardingScript "next,next,areas:emergency+health,pictures:noPictures,model:off,back,wait:3,download,progress,done"` presses the buttons (`-onboardingGap` seconds apart, default 2). `-onboardingStep N` opens at a step.

## Unit tests

```bash
Tools/Tests/run-tests.sh
```

Regenerates the project, builds the `OfflineKitTests` scheme into `$TMPDIR/OfflineKitTests-DerivedData` with `CODE_SIGNING_ALLOWED=NO` and runs it (about 45 seconds cold, under 5 seconds of tests). Extra arguments go to `xcodebuild`, e.g. `-only-testing:OfflineKitTests/WebServerTests`.

- **Setup:** a macOS unit-test bundle using Swift Testing, not hosted: it compiles `Sources/Bridge`, `Core`, `App` and `Mac` (all but `OfflineKitMacApp.swift`) plus `Tools/okit/LegacyHTMLText.swift` itself, so tests reach internal types without launching the app, its windows, sharing or update checks. Tests live in `Tests/OfflineKitTests`; `Tests/Fixtures/tiny.zim` (six articles, 37 KB) comes from `Tools/Tests/make-tiny-zim.py`.
- **Isolation:** each run gets a fresh `OFFLINEKIT_HOME` under `/tmp` (the scheme's default is `/tmp/OfflineKitTests-home`), so settings, caches, indexes and test keys stay out of `~/OfflineKit`, this Mac's preferences and the Keychain; tests that need it fail if it's missing. Test files go in folders under `/tmp` that are removed afterwards. The HTTP and WebSocket tests run the real `WebServer` on a free loopback port.
- **Known issues:** real bugs a test found are kept as `withKnownIssue` with a one-line reason; they show as known issues, not failures. Remove the wrapper once the bug is fixed.

## Layout

- `Sources/Bridge`: Objective-C++ wrapper over libzim (`ZimArchive`)
- `Sources/Core`: library scanning, retrieval and ranking, AI engines (Apple Foundation Models, Ollama), ask flow
- `Sources/App`: shared SwiftUI (Ask, library browser, article reader, settings)
- `Sources/Mac`, `Sources/iOS`: platform app shells
- `Vendor/CoreKiwix.xcframework`: libkiwix 14.2.1 + libzim prebuilt by Kiwix (GPLv3)

## Licensing

Offline Kit is GPLv3 (see `LICENSE`); `THIRD-PARTY-NOTICES.md` lists every bundled component, and `Resources/Licenses` holds the license texts the app carries. Downloaded content keeps its own license: Wikipedia and Stack Exchange are CC BY-SA, and other archives vary, so check each one's terms before redistributing it.

## Known gaps

- Short questions ("treat a burn") can pull loosely related Q&A alongside the right article. The model mostly ignores them, but the sources list shows them.
- Follow-ups carry the conversation's topic words by rule (`AskModel.searchQuery`); a follow-up that changes the subject in a few words ("what about chicken?" after rice) still carries the old subject at half weight.
- No bundled model for iPhones without Apple Intelligence (next step: MLX or llama.cpp with a ~3B model).
- Documents vault and kids' media aren't in the app yet.
- iPhone downloads only run while the app is open (no background transfer yet).
