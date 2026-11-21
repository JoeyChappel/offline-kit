import SwiftUI

/// Existing libraries open immediately. New kits get a short, skippable introduction.
struct FirstRunPresentation: ViewModifier {
    @Environment(Library.self) private var library
    @State private var checked = false
    @State private var presented = false

    func body(content: Content) -> some View {
        content
            .onChange(of: library.isLoading) {
                guard !library.isLoading, !checked else { return }
                checked = true
                presented = (library.books.isEmpty && KitSettings.shared.bool(forKey: "onboardingComplete") != true
                    && !UserDefaults.standard.bool(forKey: "skipOnboarding"))
                    || UserDefaults.standard.bool(forKey: "showOnboarding")   // launch with -showOnboarding YES
            }
            .onReceive(NotificationCenter.default.publisher(for: .showOnboarding)) { _ in presented = true }
            .task {
                // Don't wait on a slow scan (an external drive can sit behind a macOS permission prompt):
                // forced at launch shows right away; a new, still-empty kit shows after a few seconds.
                if UserDefaults.standard.bool(forKey: "showOnboarding") { checked = true; presented = true; return }
                try? await Task.sleep(for: .seconds(4))
                guard !checked, library.books.isEmpty, KitSettings.shared.bool(forKey: "onboardingComplete") != true,
                      !UserDefaults.standard.bool(forKey: "skipOnboarding") else { return }
                checked = true
                presented = true
            }
            .sheet(isPresented: $presented) { OnboardingView { presented = false } }
    }
}

struct OnboardingView: View {
    @Environment(KitNavigation.self) private var navigation
    @Environment(AskModel.self) private var model
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @State private var step = 0
    @State private var areas: Set<SubjectArea> = [.emergency, .health]
    @State private var locations: [SaveLocation] = []
    @State private var destination: SaveLocation?
    @State private var pickingFolder = false
    @State private var wantsModel = false
    @State private var pictures: PictureChoice = .full
    @State private var catalog: Catalog?
    @State private var catalogError: String?
    @State private var chosen: Set<String> = []          // pack names ticked in Review
    @State private var reviewedAreas: Set<SubjectArea> = []
    @State private var startedSummary: StartedSummary?
    let dismiss: () -> Void

    private let steps = 6
    /// Packs bigger than this (and all video packs) start unticked so a first download stays reasonable.
    private static let largePack: Int64 = 2_500_000_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Offline Kit").font(.headline)
                Spacer()
                Text(step < steps ? "\(step + 1) of \(steps)" : "Setup complete").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
            ProgressView(value: Double(min(step + 1, steps)), total: Double(steps)).padding(.horizontal, 24)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch step {
                    case 0: welcome
                    case 1: howItWorks
                    case 2: interests
                    case 3: storage
                    case 4: answers
                    case 5: review
                    default: started
                    }
                }.padding(24)
            }
            footer
        }
        .background(Design.canvas)
        .interactiveDismissDisabled(step == 0 || step == steps)
        #if os(macOS)
        // Flexible height: the steps scroll, so a smaller window still shows the whole sheet with its buttons.
        .frame(width: 640)
        .frame(minHeight: 480, idealHeight: 700)
        .fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let custom = SaveLocation(folder: url, name: url.lastPathComponent, symbol: "folder")
                if !locations.contains(custom) { locations.append(custom) }
                destination = custom
            }
        }
        #endif
        .task {
            await model.refreshOllama()
            locations = SaveLocation.available()
            destination = SaveLocation.preferred(locations)
            // Without Ollama or Apple Intelligence, the built-in model is the only way to get answers.
            wantsModel = (model.ollamaModels ?? []).isEmpty && !AppleEngine.isAvailable
                && LocalModels.installed(libraryFolders: library.folders).isEmpty
            let cache = (KitLocation.portableRoot ?? URL.cachesDirectory.appending(path: "OfflineKit"))
                .appending(path: ".kiwix-catalog.xml")
            do { catalog = try await Catalog.load(cache: cache) } catch { catalogError = error.localizedDescription }
            #if DEBUG
            // Test hook: -onboardingStep N opens at that step.
            let start = UserDefaults.standard.integer(forKey: "onboardingStep")
            if start > 0 { step = min(start, steps - 1); if step == steps - 1 { preselect() } }
            if start == steps {   // the confirmation screen, with sample numbers
                step = steps
                startedSummary = StartedSummary(items: 9, bytes: 7_490_000_000, place: "This Mac")
            }
            #endif
        }
    }

    // MARK: Steps

    @ViewBuilder private var welcome: some View {
        Image("KitIcon").resizable().frame(width: 88, height: 88)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        KitHeading(eyebrow: "A LITTLE KNOWLEDGE. ALWAYS WITH YOU.",
                   title: "Your family’s library, ready when the internet isn’t.",
                   subtitle: "Save trusted references. Find clear answers. Keep them close, wherever you are.")
        Pill(text: "No account. No cloud.", symbol: "checkmark.shield", tint: .accentColor)
        Text("Setup takes a couple of minutes. You’ll need the internet once, to download what you choose; after that everything works offline.")
            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var howItWorks: some View {
        KitHeading(eyebrow: "HOW IT WORKS", title: "Knowledge you can count on.", subtitle: "Three simple steps to a useful offline library.")
        explanation("Save trusted references", "Choose subjects and download them while you’re online. \(starterSize) A USB drive is handy for bigger collections.", "arrow.down.circle")
        explanation("Browse or ask", "Browse by area and topic, or ask in plain English.", "books.vertical")
        explanation("Check every source", "Numbered citations open the original saved article.", "checkmark.shield")
    }

    @ViewBuilder private var interests: some View {
        KitHeading(eyebrow: "BUILD YOUR KIT", title: "What matters to your family?",
                   subtitle: "Choose as many areas as you like. We’ve ticked two common starting points. You’ll see exactly what each includes, and its size, before anything downloads.")
        ForEach(SubjectArea.allCases) { item in
            let on = areas.contains(item)
            Button {
                if on { areas.remove(item) } else { areas.insert(item) }
            } label: {
                HStack(spacing: 12) {
                    KitSymbol(item.symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).foregroundStyle(.primary)
                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .imageScale(.large).foregroundStyle(Color.accentColor)
                }.card(padding: 9)
            }.buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
    }

    @ViewBuilder private var storage: some View {
        KitHeading(eyebrow: "WHERE TO KEEP IT", title: "Choose where your library lives.",
                   subtitle: "Libraries can be large. A USB drive works well, and Offline Kit can run straight from it on any Apple silicon Mac with macOS 26 or later.")
        ForEach(locations) { location in
            let on = destination == location
            Button { destination = location } label: {
                HStack(spacing: 12) {
                    KitSymbol(location.symbol)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(location.name).foregroundStyle(.primary)
                        Text("\(bytes(location.freeSpace)) free")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: on ? "largecircle.fill.circle" : "circle")
                        .imageScale(.large).foregroundStyle(Color.accentColor)
                }.card(padding: 12)
            }.buttonStyle(.plain)
            .accessibilityAddTraits(on ? .isSelected : [])
        }
        #if os(macOS)
        Button { pickingFolder = true } label: { Label("Choose a USB Drive or Folder…", systemImage: "folder.badge.plus") }
        #endif
        if let estimate = estimatedBytes {
            if let destination, destination.freeSpace < estimate + 1_000_000_000 {
                Label("Not enough room on \(destination.name): your choices need about \(bytes(estimate)). Choose a USB drive, or pick fewer items on the next screens.",
                      systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Text("Your choices need about \(bytes(estimate)) to start. You can add or remove items on the next screens.")
                    .foregroundStyle(.secondary)
            }
        }
        if let destination, destination.isFAT32 {
            Label("This drive can’t hold files over 4 GB, so some items won’t fit. Choose This Mac, or reformat the drive as exFAT in Disk Utility.",
                  systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder private var answers: some View {
        if AppleEngine.isAvailable {
            KitHeading(eyebrow: "ANSWERS ON THIS DEVICE", title: "You’re all set for answers.",
                       subtitle: "This \(deviceName)’s built-in Apple Intelligence will answer your questions from your saved library. Your questions never leave this \(deviceName). Nothing else is needed.")
        } else {
            KitHeading(eyebrow: "ANSWERS ON THIS DEVICE", title: "Choose how questions get answered.",
                       subtitle: "You can read everything you save without this. To ask questions in plain English, this \(deviceName) needs an answer model. It runs here, privately, with no internet.")
            explanation("Apple Intelligence", AppleEngine.availability, "sparkles")
        }
        let installed = !LocalModels.installed(libraryFolders: library.folders).isEmpty
        Toggle(isOn: $wantsModel) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppleEngine.isAvailable ? "Optional: Offline Kit answer model" : "Offline Kit answer model (recommended)").font(.headline)
                Text(installed ? "Already installed."
                     : AppleEngine.isAvailable
                        ? "\(bytes(LocalModels.recommended.size)) download. Gives fuller answers, and keeps working if this library moves to a USB drive used on a Mac without Apple Intelligence."
                        : "\(bytes(LocalModels.recommended.size)) download. Lets this \(deviceName) answer questions with no internet and no other software.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .disabled(installed)
        .card()
        #if os(macOS)
        DisclosureGroup("For advanced users: Ollama") { ollamaCard }
            .foregroundStyle(.secondary)
        #endif
    }

    #if os(macOS)
    /// Optional: Ollama runs a larger model (fuller answers). Offer to install it and fetch the model.
    @ViewBuilder private var ollamaCard: some View {
        let models = model.ollamaModels
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                KitSymbol("desktopcomputer")
                VStack(alignment: .leading, spacing: 5) {
                    Text("Ollama (optional)").font(.headline)
                    Text(ollamaDetail(models)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if models == nil {
                HStack {
                    Button("Get Ollama…") { NSWorkspace.shared.open(OllamaEngine.downloadPage) }
                    Button("Check Again") { Task { await model.refreshOllama() } }
                }
            } else {
                OllamaModelDownload()
            }
        }.card()
    }

    private func ollamaDetail(_ models: [String]?) -> String {
        guard let models else {
            return "Ollama is a separate free app that can run a larger answer model. Most people don’t need it. To use it, install it from ollama.com, open it, then click Check Again."
        }
        if models.contains(where: { $0.hasPrefix("gemma4") }) { return "Ready. Automatic will use the larger answer model." }
        return "Ollama is running. Download a larger answer model for it here; it stays on \(model.contextDestination)."
    }
    #endif

    /// "The suggested starter set is about 9.8 GB, plus 5.2 GB for the answer model." Real sizes once the
    /// download list has loaded; until then, the usual sizes of the default choices.
    private var starterSize: String {
        let modelSize = LocalModels.installed(libraryFolders: library.folders).isEmpty ? LocalModels.recommended.size : 0
        let model = modelSize > 0 ? ", plus about \(bytes(modelSize)) for the answer model" : ""
        if let catalog {
            var names = Set<String>()
            for area in areas { for pack in area.packs where !isInstalled(pack.name) { names.insert(pack.name) } }
            let total = names.compactMap { catalog.entry(for: $0, pictures: pictures) }
                .filter { $0.size <= Self.largePack && ContentFormat(archiveName: $0.name) != .video }
                .reduce(Int64(0)) { $0 + $1.size }
            if total > 0 { return "The suggested starter set is about \(bytes(total))\(model)." }
        }
        return "The suggested starter set is about 10 GB\(model)."
    }

    @ViewBuilder private var review: some View {
        KitHeading(eyebrow: "REVIEW", title: "Here’s what will download.",
                   subtitle: "Untick anything you don’t want. Videos and very large collections start unticked. You can add more anytime in Get Resources.")
        Picker("Include", selection: $pictures) {
            ForEach(PictureChoice.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        Text(pictures.explanation).font(.caption).foregroundStyle(.secondary)
        if let catalog {
            ForEach(SubjectArea.allCases.filter(areas.contains)) { area in
                VStack(alignment: .leading, spacing: 8) {
                    Label(area.title, systemImage: area.symbol).font(.headline)
                    ForEach(area.packs.filter { !isInstalled($0.name) }) { pack in
                        if let entry = catalog.entry(for: pack.name, pictures: pictures) {
                            Toggle(isOn: Binding(get: { chosen.contains(pack.name) },
                                                 set: { if $0 { chosen.insert(pack.name) } else { chosen.remove(pack.name) } })) {
                                HStack(alignment: .firstTextBaseline) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(pack.label)
                                        if !pack.note.isEmpty { Text(pack.note).font(.caption).foregroundStyle(.secondary) }
                                    }
                                    Spacer()
                                    Text(bytes(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                            #if os(macOS)
                            .toggleStyle(.checkbox)
                            #endif
                        }
                    }
                }.card(padding: 14)
            }
            if wantsModel {
                HStack {
                    Label("Offline Kit answer model", systemImage: "cpu")
                    Spacer()
                    Text(bytes(LocalModels.recommended.size)).monospacedDigit().foregroundStyle(.secondary)
                }.card(padding: 14)
            }
        } else if let catalogError {
            Label("Can’t reach the online download list right now. \(catalogError) You can choose resources later in Get Resources.",
                  systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
        } else {
            ProgressView("Loading what’s available…")
        }
    }

    @ViewBuilder private var started: some View {
        KitHeading(eyebrow: "DOWNLOADING", title: "Your library is on its way.",
                   subtitle: "Here’s what happens next.")
        if let summary = startedSummary {
            explanation("\(summary.items) item\(summary.items == 1 ? "" : "s") · \(bytes(summary.bytes))",
                        "Saving to \(summary.place). \(Self.timeEstimate(summary.bytes))", "arrow.down.circle")
        }
        explanation("Keep using Offline Kit", "Downloads continue in the background. Anything that finishes appears in Library right away.", "books.vertical")
        explanation("Check progress anytime", "Get Resources shows each download, with pause and resume.", "list.bullet.rectangle")
        explanation("Stay online and awake", "Keep this \(deviceName) connected and awake. If it sleeps or loses internet, downloads pick up where they left off.", "wifi")
    }

    /// "About 10 minutes on fast internet, up to 1 hour on slower connections."
    static func timeEstimate(_ total: Int64) -> String {
        func span(_ seconds: Double) -> String {
            let minutes = max(1, Int(seconds / 60))
            if minutes < 60 { return "\(minutes) minute\(minutes == 1 ? "" : "s")" }
            let hours = Double(minutes) / 60
            return hours < 1.5 ? "1 hour" : "\(Int(hours.rounded())) hours"
        }
        let fast = Double(total) / 25_000_000, slow = Double(total) / 1_250_000
        return "About \(span(fast)) on fast internet, \(span(slow)) or more on slow connections. Get Resources shows the time left."
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if step > 0 && step < steps {
                Button("Back") { step -= 1 }
                if step < steps { Button("Skip for now") { finish(start: false) }.buttonStyle(.borderless).help("Close setup. You can choose what to download anytime in Get Resources.") }
            }
            Spacer()
            if step == steps - 1 && catalog != nil {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(totalBytes == 0 ? "Nothing selected" : "\(bytes(totalBytes)) to download").font(.callout.weight(.medium))
                    if let destination {
                        if fits {
                            Text("\(bytes(destination.freeSpace)) free on \(destination.name) · Downloads continue in the background")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Needs \(bytes(totalBytes)); only \(bytes(destination.freeSpace)) free on \(destination.name). Untick some items or choose Text only.")
                                .font(.caption).foregroundStyle(.orange).multilineTextAlignment(.trailing)
                            Button("Use a USB Drive Instead…") { step = 3 }.font(.caption.weight(.semibold)).buttonStyle(.borderless).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            if step == steps {
                Button("Done") { navigation.selection = .library; dismiss() }
                    .buttonStyle(.bordered).controlSize(.large)
            }
            Button(primaryTitle) {
                if step == steps { navigation.getResources(nil); dismiss() }
                else if step == steps - 1 { finish(start: true) }
                else { advance() }
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled((step == 2 && areas.isEmpty) || (step == 3 && destination == nil)
                      || (step == steps - 1 && catalog != nil && (!fits || totalBytes == 0)))
        }.padding(24)
    }

    private var primaryTitle: String {
        switch step {
        case 0: "Get Started"
        case steps - 1: catalog == nil ? "Choose Later" : "Download"
        case steps: "Show Progress"
        default: "Continue"
        }
    }

    // MARK: Logic

    private var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    private func advance() {
        step += 1
        if step == steps - 1 { preselect() }
    }

    /// Tick the reasonably sized packs of any newly chosen area.
    private func preselect() {
        guard let catalog else { return }
        for area in areas where !reviewedAreas.contains(area) {
            reviewedAreas.insert(area)
            for pack in area.packs where !isInstalled(pack.name) {
                if let size = catalog.entry(for: pack.name, pictures: pictures)?.size, size <= Self.largePack,
                   ContentFormat(archiveName: pack.name) != .video {
                    chosen.insert(pack.name)
                }
            }
        }
    }

    /// Starter size for the chosen areas (the same picks the review step pre-ticks), plus the answer model if chosen.
    private var estimatedBytes: Int64? {
        guard let catalog else { return nil }
        var names = Set<String>()
        for area in areas { for pack in area.packs where !isInstalled(pack.name) { names.insert(pack.name) } }
        let packs = names.compactMap { catalog.entry(for: $0, pictures: pictures) }
            .filter { $0.size <= Self.largePack && ContentFormat(archiveName: $0.name) != .video }
        return packs.reduce(0) { $0 + $1.size } + (wantsModel ? LocalModels.recommended.size : 0)
    }

    private var entries: [CatalogEntry] {
        guard let catalog else { return [] }
        let names = Set(SubjectArea.allCases.filter(areas.contains).flatMap(\.packs).map(\.name)).intersection(chosen)
        return names.compactMap { catalog.entry(for: $0, pictures: pictures) }.sorted { $0.size < $1.size }
    }

    private var totalBytes: Int64 {
        entries.reduce(0) { $0 + $1.size } + (wantsModel && LocalModels.installed(libraryFolders: library.folders).isEmpty ? LocalModels.recommended.size : 0)
    }

    private var fits: Bool { (destination?.freeSpace ?? 0) > totalBytes + 1_000_000_000 }

    private func isInstalled(_ name: String) -> Bool { library.books.contains { $0.archive.name == name } }

    private func finish(start: Bool) {
        KitSettings.shared.set(true, forKey: "onboardingComplete")
        KitSettings.shared.set(pictures.rawValue, forKey: "pictures")
        if start, let destination, catalog != nil {
            // A folder the app doesn't scan by default becomes part of the library.
            let folder = destination.folder
            KitStorage.remember(folder)
            let scanned = library.folders.map { $0.standardizedFileURL.path }
            if !scanned.contains(folder.standardizedFileURL.path) {
                library.extraFolders.append(folder.path)
                Task { await library.reload() }
            }
            for entry in entries { downloads.enqueue(entry, to: folder) }
            if wantsModel, LocalModels.installed(libraryFolders: library.folders).isEmpty {
                downloads.enqueue(model: LocalModels.recommended, to: LocalModels.folder(forLibrary: folder))
            }
            navigation.getResources(nil)
            startedSummary = StartedSummary(items: entries.count + (wantsModel ? 1 : 0), bytes: totalBytes, place: destination.name)
            step = steps          // confirmation screen
            return
        } else if start {
            navigation.getResources(areas.first)
        }
        dismiss()
    }

    private func explanation(_ title: String, _ detail: String, _ symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            KitSymbol(symbol)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.card()
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

extension Notification.Name {
    /// Posted by Settings › Show Welcome Again.
    static let showOnboarding = Notification.Name("OfflineKit.showOnboarding")
    static let openGetResources = Notification.Name("OfflineKit.openGetResources")
    /// Posted by Settings › Copy Offline Kit to a Drive: opens Kit Care's Copy my kit.
    static let openKitCopy = Notification.Name("OfflineKit.openKitCopy")
}

/// Downloads Offline Kit's recommended larger model into Ollama, with progress. Used in setup and in Settings.
struct OllamaModelDownload: View {
    @Environment(AskModel.self) private var model
    @State private var pull: OllamaPull?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let pull {
                ProgressView(value: pull.fraction) { Text(pull.label).font(.caption) }
            } else if !(model.ollamaModels ?? []).contains(where: { $0.hasPrefix("gemma4") }) {
                Button("Download the larger model · \(ByteCountFormatter.string(fromByteCount: OllamaEngine.recommendedModelBytes, countStyle: .file))") { start() }
                    .help("Downloads \(OllamaEngine.recommendedModel) into Ollama. Needs the internet while it downloads.")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func start() {
        guard let host = URL(string: model.ollamaHost) else { return }
        error = nil
        pull = OllamaPull(fraction: 0, label: "Starting…")
        Task {
            do {
                try await OllamaEngine.pull(model: OllamaEngine.recommendedModel, host: host) { done, total, status in
                    Task { @MainActor in
                        pull = OllamaPull(fraction: total > 0 ? Double(done) / Double(total) : 0,
                                          label: total > 0 ? "\(Self.bytes(done)) of \(Self.bytes(total))" : status.capitalized)
                    }
                }
                pull = nil
                await model.refreshOllama()
            } catch {
                pull = nil
                self.error = "Couldn’t download the model: \(error.localizedDescription)"
            }
        }
    }

    private static func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

struct OllamaPull: Equatable {
    var fraction: Double
    var label: String
}

struct StartedSummary: Equatable {
    var items: Int
    var bytes: Int64
    var place: String
}
