import SwiftUI

/// Where downloads can go: the kit beside the app (drive mode), this Mac, or a connected drive.
struct SaveLocation: Identifiable, Hashable {
    let folder: URL
    let name: String
    let symbol: String
    var id: String { folder.path }

    var freeSpace: Int64 {
        #if DEBUG
        if let gb = ProcessInfo.processInfo.environment["OFFLINEKIT_FAKE_FREE_GB"].flatMap(Double.init) { return Int64(gb * 1e9) }
        #endif
        // On a new Mac the library folder (and maybe its parent) doesn't exist yet: measure the nearest folder that does.
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return max(values?.volumeAvailableCapacityForImportantUsage ?? 0, Int64(values?.volumeAvailableCapacity ?? 0))
    }

    /// FAT32 can't hold files over 4 GB (many archives are bigger).
    var isFAT32: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_FAKE_FAT32"] != nil { return true }
        #endif
        #if os(macOS)
        var fs = statfs()
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.path) && probe.path != "/" { probe.deleteLastPathComponent() }
        guard statfs(probe.path, &fs) == 0 else { return false }
        return withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == "msdos"
        #else
        return false
        #endif
    }

    static func available() -> [SaveLocation] {
        var list: [SaveLocation] = []
        #if os(macOS)
        if let portable = KitLocation.portableLibrary {
            list.append(SaveLocation(folder: portable, name: "\(KitLocation.portableVolumeName ?? "This drive") (with the app)",
                                     symbol: "externaldrive.fill"))
        }
        list.append(SaveLocation(folder: KitLocation.home.appending(path: "OfflineKit/Library"),
                                 name: "This Mac", symbol: "laptopcomputer"))
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsReadOnlyKey, .volumeLocalizedNameKey, .volumeIsBrowsableKey]
        for volume in (KitLocation.scansVolumes ? FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) : nil) ?? [] {
            guard let v = try? volume.resourceValues(forKeys: keys), v.volumeIsInternal == false,
                  v.volumeIsReadOnly != true, v.volumeIsBrowsable != false else { continue }
            // Leave Time Machine backup disks alone, and skip drives with no room.
            // Time Machine disks refuse ordinary apps ("Operation not permitted"), so require a readable, writable root.
            guard (try? FileManager.default.contentsOfDirectory(atPath: volume.path)) != nil,
                  FileManager.default.isWritableFile(atPath: volume.path) else { continue }
            let markers = ["Backups.backupdb", ".timemachine", ".com.apple.timemachine.supported", ".com.apple.TMCheckpoint"]
            if markers.contains(where: { FileManager.default.fileExists(atPath: volume.appending(path: $0).path) }) { continue }
            let free = (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0
            if free < 1_000_000_000 { continue }
            let folder = volume.appending(path: "OfflineKit/Library")
            if list.contains(where: { $0.folder.standardizedFileURL == folder.standardizedFileURL }) { continue }
            list.append(SaveLocation(folder: folder, name: v.volumeLocalizedName ?? volume.lastPathComponent, symbol: "externaldrive"))
        }
        #else
        list.append(SaveLocation(folder: URL.documentsDirectory, name: "This device", symbol: "iphone"))
        #endif
        return list
    }

    /// Drive mode first, then a drive that already holds a kit, then this Mac.
    static func preferred(_ list: [SaveLocation]) -> SaveLocation? {
        if KitLocation.isPortable { return list.first }
        // The place they chose before, if it's still here.
        if let chosen = KitStorage.chosen?.standardizedFileURL.path,
           let match = list.first(where: { $0.folder.standardizedFileURL.path == chosen }) { return match }
        return list.first { $0.symbol == "externaldrive" && FileManager.default.fileExists(atPath: $0.folder.path) } ?? list.first
    }
}

struct GetResourcesView: View {
    @Environment(KitNavigation.self) private var navigation
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads

    @State private var catalog: Catalog?
    @State private var loadError: String?
    @State private var pictures: PictureChoice = PictureChoice(rawValue: KitSettings.shared.string(forKey: "pictures") ?? "") ?? .full
    @State private var locations: [SaveLocation] = []
    @State private var destination: SaveLocation?
    @State private var area: SubjectArea?
    @State private var showingEncyclopedia = false
    @State private var reviewing = false
    @State private var format: ContentFormat?

    // Ticked choices live in KitNavigation, so they survive a look at another section.
    private var selected: Set<String> {
        get { navigation.resourceSelection }
        nonmutating set { navigation.resourceSelection = newValue }
    }
    private var encyclopedia: String? {
        get { navigation.resourceEncyclopedia }
        nonmutating set { navigation.resourceEncyclopedia = newValue }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                #if os(iOS)
                FromMacCard()   // Send to iPhone: download what the Mac picked, over home Wi-Fi
                #endif
                if !downloads.jobs.isEmpty {
                    DownloadProgressPanel(showsOpenButton: false)
                    DownloadsCard()
                }
                if let catalog {
                    FormatChips(selection: $format, formats: [.reference, .books, .video, .maps, .interactive])
                    if format != nil {
                        // A format filter shows every matching pack, across all areas.
                        if format == .reference { encyclopediaCard(catalog) }
                        ForEach(Interests.all) { interest in
                            if interest.packs.contains(where: matches) { interestCard(interest, catalog: catalog) }
                        }
                        if format == .maps { mapRegions(catalog) }
                    } else if showingEncyclopedia {
                        breadcrumb
                        encyclopediaCard(catalog)
                    } else if let area {
                        breadcrumb
                        interestCard(Interest(id: area.id, title: area.title, subtitle: area.subtitle,
                                              symbol: area.symbol, packs: area.packs), catalog: catalog)
                        if area == .world { mapRegions(catalog) }
                        Text("Resources shared by more than one area are downloaded once.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        if !selected.isEmpty && library.books.isEmpty {
                            Label("We’ve picked a small starter set of essentials. Change anything before you download.",
                                  systemImage: "sparkles").font(.callout).foregroundStyle(.secondary)
                        }
                        Text("Browse by area").font(.headline)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                            ForEach(SubjectArea.allCases) { item in
                                Button { area = item } label: {
                                    SubjectAreaCard(area: item, detail: selectedCount(item))
                                }.buttonStyle(.plain)
                            }
                        }
                        Button { showingEncyclopedia = true } label: {
                            HStack(spacing: 14) {
                                KitSymbol("book.closed")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("General encyclopedia").font(.headline)
                                    Text("Wikipedia across all subjects. Choose one edition, or none.")
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.card(padding: 18).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        ModelPackCard(destination: destination?.folder)
                    }
                    Text("Content comes from the Kiwix online library. Licenses vary by archive. Wikipedia and many Q&A archives use CC BY-SA. Check each archive for its license.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let loadError {
                    ContentUnavailableView {
                        Label("Can’t reach the online download list", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Downloading needs an internet connection. \(loadError)")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                    .card()
                } else {
                    ProgressView("Loading the download list…").frame(maxWidth: .infinity).padding(40)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Design.canvas)
        .safeAreaInset(edge: .bottom) { if catalog != nil { footer } }
        .sheet(isPresented: $reviewing) { review }
        .onAppear {
            area = navigation.resourceArea
            #if DEBUG
            // Test hook: -getFormat maps opens the Get screen filtered to one format.
            if let raw = UserDefaults.standard.string(forKey: "getFormat") { format = ContentFormat(rawValue: raw) }
            #endif
        }
        .onChange(of: navigation.resourceArea) { area = navigation.resourceArea; showingEncyclopedia = false }
        .navigationTitle("Get Resources")
        .task { await load() }
        .onChange(of: pictures) { KitSettings.shared.set(pictures.rawValue, forKey: "pictures") }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 20) {
            KitHeading(eyebrow: "BUILD YOUR LIBRARY", title: "Choose what to keep offline.",
                       subtitle: "Choose an area, then tick the references you want. Downloading needs internet; after that, everything works offline.")
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { locationMenu; sizePicker }
                VStack(alignment: .leading, spacing: 12) { locationMenu; sizePicker }
            }
            #if os(macOS)
            HStack(spacing: 10) {
                Text("Already have movies, music, audiobooks or games on this Mac?").font(.callout).foregroundStyle(.secondary)
                FindMyMediaButton().buttonStyle(.bordered)
            }
            #endif
        }
    }

    private var locationMenu: some View {
        Menu {
            ForEach(locations) { location in
                Button {
                    destination = location
                    // Downloads and anything added later (games, movies, PDFs) go to the same place.
                    KitStorage.remember(location.folder)
                } label: {
                    Label("\(location.name) · \(bytes(location.freeSpace)) free", systemImage: location.symbol)
                }
            }
        } label: {
            Label("Save to \(destination?.name ?? "…")", systemImage: destination?.symbol ?? "folder")
        }
    }

    private var sizePicker: some View {
        Picker("Include", selection: $pictures) {
            ForEach(PictureChoice.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.segmented)
        .help(pictures.explanation + " Each reference uses the closest version available.")
    }

    private var breadcrumb: some View {
        HStack(spacing: 8) {
            Button("All areas") { area = nil; showingEncyclopedia = false }.buttonStyle(.borderless)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
            Text(showingEncyclopedia ? "General encyclopedia" : area?.title ?? "")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    /// "3 selected" under an area's card (the card already shows the area's description), or nothing.
    private func selectedCount(_ area: SubjectArea) -> String? {
        var count = area.packs.filter { selected.contains($0.name) }.count
        if area == .world { count += selected.filter { $0.hasPrefix("maps_") }.count }
        return count > 0 ? "\(count) selected" : nil
    }

    // MARK: Cards

    private func encyclopediaCard(_ catalog: Catalog) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "book.closed", title: "General encyclopedia",
                       subtitle: "Pick one, or none. These include celebrities and sports. For science only, choose None and pick references in Science & learning.")
            Divider()
            EncyclopediaRow(label: "None", note: "Only the subjects you pick below.", size: nil,
                            isOn: encyclopedia == nil, status: nil) { encyclopedia = nil }
            ForEach(Interests.encyclopedia) { pack in
                let entry = catalog.entry(for: pack.name, pictures: pictures)
                EncyclopediaRow(label: pack.label, note: pack.note, size: entry?.size,
                                isOn: encyclopedia == pack.name, status: status(pack.name)) {
                    encyclopedia = pack.name
                }
                .disabled(entry == nil)
            }
        }
        .card(padding: 18)
    }

    private func interestCard(_ interest: Interest, catalog: Catalog) -> some View {
        let available = interest.packs.filter { catalog.entry(for: $0.name, pictures: pictures) != nil && !isInstalled($0.name) }
        let chosen = available.filter { selected.contains($0.name) }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                CardHeader(symbol: interest.symbol, title: interest.title, subtitle: interest.subtitle)
                Spacer()
                if !available.isEmpty {
                    Button(chosen.count == available.count ? "Clear" : "Select All") {
                        if chosen.count == available.count {
                            available.forEach { selected.remove($0.name) }
                        } else {
                            available.forEach { selected.insert($0.name) }
                        }
                    }
                    .buttonStyle(.borderless)
                }
            }
            Divider()
            ForEach(interest.packs.filter(matches)) { pack in
                let entry = catalog.entry(for: pack.name, pictures: pictures)
                PackRow(pack: pack, entry: entry, isOn: selected.contains(pack.name), status: status(pack.name)) {
                    if selected.contains(pack.name) { selected.remove(pack.name) } else { selected.insert(pack.name) }
                }
            }
        }
        .card(padding: 18)
    }

    private func mapRegions(_ catalog: Catalog) -> some View {
        MapRegionsCard(catalog: catalog, selected: Bindable(navigation).resourceSelection, status: status)
    }

    // MARK: Footer

    private var footer: some View {
        let items = chosenEntries
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let free = spaceLeft
        let fits = total < free - (1 << 30)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { footerSummary(items: items, total: total, free: free, fits: fits); Spacer(); reviewButton(items: items, fits: fits) }
            VStack(alignment: .leading, spacing: 12) { footerSummary(items: items, total: total, free: free, fits: fits); reviewButton(items: items, fits: fits) }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: 860).frame(maxWidth: .infinity).background(.bar)
    }

    private func footerSummary(items: [CatalogEntry], total: Int64, free: Int64, fits: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(items.isEmpty ? "Nothing selected" : "\(items.count) \(items.count == 1 ? "item" : "items") · \(bytes(total))").font(.headline)
                .help("Items that appear in more than one area are counted once.")
            if items.count > 0 && SubjectArea.allCases.reduce(0, { sum, area in sum + area.packs.filter { selected.contains($0.name) }.count }) > items.count {
                Text("Some items appear in more than one area; they download once.").font(.caption).foregroundStyle(.secondary)
            }
            if let destination {
                Text("\(bytes(free)) free on \(destination.name)" + (!fits && !items.isEmpty ? " · Not enough space" : ""))
                    .font(.caption).foregroundStyle(!fits && !items.isEmpty ? Color.orange : .secondary)
            }
        }
    }

    private func reviewButton(items: [CatalogEntry], fits: Bool) -> some View {
        Button("Review selection", systemImage: "checklist") { reviewing = true }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(items.isEmpty || !fits || destination == nil)
    }

    private var review: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    KitHeading(eyebrow: "A QUICK CHECK", title: "Review your kit.",
                               subtitle: "\(chosenEntries.count) resources · \(pictures.label) · \(destination?.name ?? "Choose a location")")
                    ForEach(chosenEntries) { entry in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.title)
                                Text(entry.editionLabel).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(bytes(entry.size)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    let total = chosenEntries.reduce(Int64(0)) { $0 + $1.size }
                    Text("\(bytes(total)) needed · \(bytes(spaceLeft)) free").font(.headline)
                    Text("Downloading needs an internet connection. Time depends on the connection and archive size. Your saved references work offline.")
                        .foregroundStyle(.secondary)
                    Button("Download", systemImage: "arrow.down.circle") { startDownloads() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(chosenEntries.isEmpty || destination == nil || total >= spaceLeft - (1 << 30))
                }.padding(24)
            }
            .background(Design.canvas)
            .navigationTitle("Review selection")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Keep Choosing") { reviewing = false } } }
        }
        #if os(macOS)
        .frame(width: 600, height: 580)
        #endif
    }

    /// Free space on the chosen drive after what queued, running and paused downloads still have to write there.
    private var spaceLeft: Int64 {
        guard let destination else { return 0 }
        return max(0, destination.freeSpace - downloads.bytesStillNeeded(on: destination.folder))
    }

    private func startDownloads() {
        guard let destination else { return }
        let items = chosenEntries
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        guard !items.isEmpty, total < spaceLeft - (1 << 30) else { return }
        for entry in items { downloads.enqueue(entry, to: destination.folder) }
        selected.removeAll()
        encyclopedia = nil
        reviewing = false
    }

    // MARK: Logic

    private var chosenEntries: [CatalogEntry] {
        guard let catalog else { return [] }
        var names = selected
        if let encyclopedia { names.insert(encyclopedia) }
        return names.filter { !isInstalled($0) && downloads.job(named: $0) == nil }
            .compactMap { catalog.entry(for: $0, pictures: pictures) }
            .sorted { $0.size < $1.size }   // small ones finish first
    }

    private func matches(_ pack: Pack) -> Bool {
        format.map { ContentFormat(archiveName: pack.name) == $0 } ?? true
    }

    private func isInstalled(_ name: String) -> Bool {
        library.books.contains { $0.archive.name == name || $0.archive.name.hasPrefix(name + "_") }
    }

    private func status(_ name: String) -> PackStatus? {
        if isInstalled(name) { return .installed }
        if let job = downloads.job(named: name) { return .downloading(job.fraction, job.state == .paused) }
        return nil
    }

    private func load() async {
        loadError = nil
        locations = SaveLocation.available()
        if destination == nil || !locations.contains(where: { $0 == destination }) { destination = SaveLocation.preferred(locations) }
        let cache = (KitLocation.portableRoot ?? URL.cachesDirectory.appending(path: "OfflineKit"))
            .appending(path: ".kiwix-catalog.xml")
        do {
            catalog = try await Catalog.load(cache: cache)
            if !navigation.resourcesPreselected && library.books.isEmpty {
                // A new kit starts with the emergency essentials ticked.
                for interest in Interests.all where interest.startsSelected { interest.packs.forEach { selected.insert($0.name) } }
            }
            navigation.resourcesPreselected = true
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func bytes(_ n: Int64) -> String { ByteCountFormatter.string(fromByteCount: n, countStyle: .file) }
}

enum PackStatus: Equatable { case installed, downloading(Double, Bool) }

private struct CardHeader: View {
    let symbol: String
    let title: String
    let subtitle: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct PackRow: View {
    let pack: Pack
    let entry: CatalogEntry?
    let isOn: Bool
    let status: PackStatus?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: icon)
                    .foregroundStyle(status == .installed ? Color.secondary : (isOn ? Color.accentColor : Color.secondary))
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pack.label).foregroundStyle(entry == nil ? .secondary : .primary)
                    if !pack.note.isEmpty {
                        Text(pack.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 12)
                trailing
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(entry == nil || status != nil)
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch status {
        case .installed: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case nil: isOn ? "checkmark.square.fill" : "square"
        }
    }

    @ViewBuilder private var trailing: some View {
        switch status {
        case .installed:
            Pill(text: "Installed", symbol: "checkmark", tint: .accentColor)
        case .downloading(let fraction, let paused):
            Pill(text: paused ? "Paused" : "\(Int(fraction * 100))%", symbol: "arrow.down", tint: .accentColor)
        case nil:
            if let entry {
                Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("Not available").font(.caption).foregroundStyle(.tertiary)
            }
        }
    }
}

private struct EncyclopediaRow: View {
    let label: String
    let note: String
    let size: Int64?
    let isOn: Bool
    let status: PackStatus?
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: status == .installed ? "checkmark.circle.fill" : (isOn ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(isOn || status == .installed ? Color.accentColor : Color.secondary)
                    .imageScale(.large)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                    if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 12)
                if status == .installed {
                    Pill(text: "Installed", symbol: "checkmark", tint: .accentColor)
                } else if case .downloading(let f, let paused) = status {
                    Pill(text: paused ? "Paused" : "\(Int(f * 100))%", symbol: "arrow.down", tint: .accentColor)
                } else if let size {
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status != nil)
        .padding(.vertical, 2)
    }
}

/// Live downloads with pause, resume and cancel.
struct DownloadsCard: View {
    @Environment(DownloadManager.self) private var downloads
    @State private var confirmCancel: DownloadJob?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Downloads").font(.headline)
                Spacer()
                if downloads.jobs.contains(where: { $0.state == .paused }) {
                    Button("Resume All") { downloads.resumeAll() }.buttonStyle(.borderless)
                }
                if downloads.jobs.contains(where: \.isFinished) {
                    Button("Clear Finished") { downloads.clearFinished() }.buttonStyle(.borderless)
                }
            }
            ForEach(downloads.jobs) { job in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(job.title).lineLimit(1)
                        Spacer()
                        controls(job)
                    }
                    if !job.isFinished {
                        ProgressView(value: job.fraction)
                            .tint(job.state == .verifying ? .blue : .accentColor)
                    }
                    Text(job.detail)
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(isFailed(job) ? Color.orange : Color.secondary)
                }
                if job.id != downloads.jobs.last?.id { Divider() }
            }
            Text("Downloads resume where they left off if the app quits, the Mac sleeps or the drive is unplugged.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .card(padding: 18)
        .confirmationDialog("Cancel this download?", isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }), presenting: confirmCancel) { job in
            Button("Cancel Download and Delete Partial File", role: .destructive) { downloads.cancel(job); confirmCancel = nil }
            Button("Keep Downloading", role: .cancel) { confirmCancel = nil }
        } message: { job in
            Text("\(job.title) will need to start over.")
        }
    }

    @ViewBuilder private func controls(_ job: DownloadJob) -> some View {
        HStack(spacing: 10) {
            if job.isFinished {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
            } else {
                if job.state == .paused || isFailed(job) {
                    Button { downloads.resume(job) } label: { Image(systemName: isFailed(job) ? "arrow.clockwise" : "play.fill") }
                        .help(isFailed(job) ? "Retry" : "Resume")
                } else if job.isActive {
                    Button { downloads.pause(job) } label: { Image(systemName: "pause.fill") }.help("Pause")
                }
                Button { confirmCancel = job } label: { Image(systemName: "xmark") }.help("Cancel")
            }
        }
        .buttonStyle(.borderless)
    }

    private func isFailed(_ job: DownloadJob) -> Bool {
        if case .failed = job.state { return true } else { return false }
    }
}

/// A row of filter chips: All, Reference, Books, Video...
struct FormatChips: View {
    @Binding var selection: ContentFormat?
    var formats: [ContentFormat] = ContentFormat.allCases

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(nil, "All", "square.grid.2x2")
                ForEach(formats) { chip($0, $0.label, $0.symbol) }
            }
        }
    }

    private func chip(_ format: ContentFormat?, _ label: String, _ symbol: String) -> some View {
        let on = selection == format
        return Button { selection = format } label: {
            Label(label, systemImage: symbol)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
