import SwiftUI

@main
struct OfflineKitMacApp: App {
    @State private var library = Library()
    @State private var model = AskModel()
    @State private var downloads = DownloadManager()
    @State private var games = GameLibrary()
    @State private var media = MediaLibrary()
    @State private var audiobooks = AudiobookDownloads()
    @State private var share = ShareController()
    @State private var household = Household()
    @State private var nowPlaying = NowPlaying()
    @State private var starterFilms = StarterFilms()

    init() {
        // Release the built-in AI model while the app is still fully alive.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            // Household saves are debounced; write any edit still waiting so quitting right after a change keeps it.
            MainActor.assumeIsolated { Household.shared?.flushPendingSave() }
            LlamaRuntime.shared.shutdown()
        }
    }

    /// Startup work belongs to the launch, not to a window: a second main window (or one reopened from the Dock)
    /// must not re-attach sharing, restart downloads the user paused, or add duplicate observers.
    @MainActor private static var didStartUp = false

    /// Watches every library folder, plus the older Kids and Device Manuals folders, for changes made outside the app.
    private func watchLibrary() {
        #if DEBUG
        // Test hook: -noWatch YES turns off watching, to check that adds refresh the screen on their own.
        if UserDefaults.standard.bool(forKey: "noWatch") { return }
        #endif
        LibraryWatcher.shared.watch(libraries: library.folders,
                                    media: [KitLocation.home.appending(path: "OfflineKit/Kids", directoryHint: .isDirectory)],
                                    documents: [KitLocation.home.appending(path: "OfflineKit/Device Manuals", directoryHint: .isDirectory)])
    }

    /// Rescans the shelves whose folders changed. Each library coalesces overlapping requests (see ScanGate).
    private func rescan(_ shelves: Set<LibraryWatcher.Shelf>) async {
        if shelves.contains(.documents) { KitChanges.shared.documentsChanged() }
        if shelves.contains(.models) { KitChanges.shared.modelsChanged() }
        if shelves.contains(.references) {
            await library.reload()
            recheckRecentArchives()
        }
        if shelves.contains(.media) { await media.reload(library: library) }
        if shelves.contains(.games) { await games.reload(library: library) }
        // A library folder created by this change (a first import, a new drive) is watched from now on.
        watchLibrary()
    }

    /// The library waits two minutes before opening an archive that was just written (it may still be copying).
    /// One that arrived through Finder or `cp` gets one more look once that wait is over, not a rescan loop.
    private func recheckRecentArchives() {
        let fm = FileManager.default
        let ready = library.skipped.filter { $0.reason == "Still downloading" && !fm.fileExists(atPath: $0.url.path + ".aria2") }
            .compactMap { (try? $0.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }
            .map { $0.addingTimeInterval(125) }.max()
        guard let ready, ready.timeIntervalSinceNow < 300 else { return }
        Task {
            try? await Task.sleep(for: .seconds(max(1, ready.timeIntervalSinceNow)))
            await library.reload()
        }
    }

    #if DEBUG
    /// Test hook: -hangLog YES logs "HANG <ms>" whenever the main thread can't answer for over 100 ms,
    /// to find what makes the window stop responding.
    @MainActor private static func hangWatchForTesting() {
        guard UserDefaults.standard.bool(forKey: "hangLog") else { return }
        Thread.detachNewThread {
            while true {
                let sent = Date()
                let answered = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { answered.signal() }
                answered.wait()
                let ms = Date().timeIntervalSince(sent) * 1000
                if ms > 100 { NSLog("HANG %.0f ms", ms) }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
    }

    /// Test hook: -snapshot <folder> draws every visible window (with its toolbar, and any sheet as its own picture)
    /// to PNGs at the seconds listed in -snapshotAt "5,20" (default 6). -snapshotSize 1200x820 sizes the main window
    /// first. For checking layouts when the screen can't be recorded (a locked or sleeping display).
    @MainActor private static func snapshotsForTesting() {
        let defaults = UserDefaults.standard
        guard let folder = defaults.string(forKey: "snapshot") else { return }
        let times = (defaults.string(forKey: "snapshotAt") ?? "6").split(separator: ",").compactMap { Double($0) }
        let size = defaults.string(forKey: "snapshotSize")?.split(separator: "x").compactMap { Double($0) }
        Task { @MainActor in
            if let size, size.count == 2, let main = NSApp.windows.first(where: { $0.isVisible && !$0.isSheet && $0.frame.width > 500 }) {
                main.setFrame(NSRect(x: main.frame.minX, y: max(40, main.frame.maxY - size[1]), width: size[0], height: size[1]), display: true)
            }
            var elapsed = 0.0
            for time in times.sorted() {
                try? await Task.sleep(for: .seconds(max(0, time - elapsed)))
                elapsed = time
                for (index, window) in NSApp.windows.enumerated() where window.isVisible && window.contentView != nil {
                    guard let view = window.contentView?.superview ?? window.contentView, view.bounds.width > 100,
                          let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                    view.cacheDisplay(in: view.bounds, to: rep)
                    let name = "\(Int(time))s-\(index)-\(window.isSheet ? "sheet" : window.title.isEmpty ? "window" : window.title).png"
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: folder).appending(path: name.replacingOccurrences(of: "/", with: "-")))
                }
            }
        }
    }
    #endif

    var body: some Scene {
        WindowGroup("Offline Kit", id: "main") {
            RootView()
                .frame(minWidth: 820, minHeight: 520)
                .task {
                    guard !Self.didStartUp else { return }
                    Self.didStartUp = true
                    // Opened straight from the disk image: offer to move into Applications first.
                    AppMover.offerMoveIfNeeded()
                    // Downloads can be archives, maps, answer models or media: show whichever it was.
                    downloads.onInstalled = {
                        KitChanges.shared.modelsChanged()
                        Task { await library.reload(); await media.reload(library: library); watchLibrary() }
                    }
                    share.attach(library: library, model: model, media: media)
                    await library.reload()
                    // First launch: copy the bundled classic books into the kit.
                    if await StarterBooks.installIfNeeded() { await media.reload(library: library) }
                    LibraryWatcher.shared.onChange = { shelves in Task { await rescan(shelves) } }
                    watchLibrary()
                    downloads.restore(from: library.folders)
                    downloads.resumeOwn()
                    AppUpdater.shared.startAutomaticChecks()
                    #if DEBUG
                    Self.hangWatchForTesting()
                    Self.snapshotsForTesting()
                    if UserDefaults.standard.bool(forKey: "sampleDownloads") {
                        downloads.insertSamples(folder: KitLocation.home.appending(path: "OfflineKit/Library"))
                    }
                    #endif
                }
                // A drive can hold a whole kit, and linked media lives on drives too: rescan every shelf.
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
                    Task { await rescan([.references, .media, .games, .documents, .models]) }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willUnmountNotification)) { note in
                    // Let go of the drive's folders before it goes, so watching never holds up ejecting it.
                    if let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL { LibraryWatcher.shared.stop(volume: volume) }
                }
                .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
                    Task { await rescan([.references, .media, .games, .documents, .models]) }
                }
                .onChange(of: library.extraFolders) { watchLibrary() }
        }
        // Big enough on first launch for the welcome sheet (640 × 700) to fit inside the window.
        .defaultSize(width: 1100, height: 780)
        .environment(library)
        .environment(model)
        .environment(downloads)
        .environment(games)
        .environment(media)
        .environment(audiobooks)
        .environment(share)
        .environment(household)
        .environment(nowPlaying)
        .environment(starterFilms)
        .commands {
            // One main window: File › New Window would only make a second copy of the same library.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await AppUpdater.shared.check(userInitiated: true) } }
            }
            // Play/pause from the menu bar (⌘.), for when Space is busy typing.
            CommandMenu("Controls") {
                Button(nowPlaying.playback?.isPlaying == true ? "Pause" : "Play") { nowPlaying.playback?.toggle() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(nowPlaying.playback == nil)
            }
        }

        WindowGroup("Game", for: GameRef.self) { $ref in
            if let game = ref?.game {
                PlayerView(game: game, resumeSavedState: ref?.resume ?? false).frame(minWidth: 480, minHeight: 360)
            }
        }
        .defaultSize(width: 720, height: 560)
        // Don't bring a game back (with its sound) when the app launches.
        .restorationBehavior(.disabled)

        WindowGroup("Article", for: ArticleRef.self) { $ref in
            if let ref {
                ReaderView(ref: ref).frame(minWidth: 640, minHeight: 480)
            }
        }
        .environment(library)
        .environment(household)
        .defaultSize(width: 900, height: 760)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView()
        }
        .environment(library)
        .environment(model)
        .environment(downloads)
    }
}
