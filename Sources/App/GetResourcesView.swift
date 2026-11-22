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

    /// `freeSpace`, remembered for a few seconds. Get Resources asks on every redraw (each download progress tick),
    /// and reading it touches the disk. `refreshFreeSpace()` drops it, for example when a download finishes.
    var cachedFreeSpace: Int64 {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_FAKE_FREE_GB"] != nil { return freeSpace }
        #endif
        let now = Date()
        if let hit = Self.freeSpaceLock.withLock({ Self.freeSpaceValues[folder.path] }), now.timeIntervalSince(hit.at) < 5 { return hit.bytes }
        let bytes = freeSpace
        Self.freeSpaceLock.withLock { Self.freeSpaceValues[folder.path] = (bytes, now) }
        return bytes
    }

    private static let freeSpaceLock = NSLock()
    nonisolated(unsafe) private static var freeSpaceValues: [String: (bytes: Int64, at: Date)] = [:]

    static func refreshFreeSpace() { freeSpaceLock.withLock { freeSpaceValues.removeAll() } }

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
    @FocusState private var searchFocused: Bool
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
    @State private var query = ""
    /// `query` once the typing pauses: the results are worked out from this one, not on every keystroke.
    @State private var appliedQuery = ""

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
        GeometryReader { geometry in
            let wide = geometry.size.width >= 1000
            HStack(alignment: .top, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        header
                        if !wide { destinationControls }
                        resourceContent
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 24)
                    .frame(maxWidth: wide ? 1100 : 860, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                if wide, catalog != nil {
                    ScrollView { selectionInspector.padding(20) }
                        .frame(width: 320)
                        .background(Design.surface)
                        .overlay(alignment: .leading) { Rectangle().fill(Design.border).frame(width: 1) }
                }
            }
            .safeAreaInset(edge: .bottom) { if !wide && catalog != nil { footer } }
        }
        .background(Design.canvas)
        .findShortcut($searchFocused)
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
        .task {
            await load()
            #if DEBUG
            // Test hook: -resourcesType "text" types it into the search one letter every 80 ms (-resourcesTypeMs) once the
            // list has loaded ("<" deletes one), logging main-thread CPU per five letters, then scrolls (macOS) and ends with "CYCLE done".
            guard let text = UserDefaults.standard.string(forKey: "resourcesType") else { return }
            for _ in 0..<100 where catalog == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(3))
            StallProbe.start()
            StallProbe.report("before typing")
            for (index, letter) in text.enumerated() {
                if letter == "<" { if !query.isEmpty { query.removeLast() } } else { query.append(letter) }
                try? await Task.sleep(for: .milliseconds(Int(UserDefaults.standard.string(forKey: "resourcesTypeMs") ?? "") ?? 80))
                if index % 5 == 4 { StallProbe.report("search5") }
            }
            query = ""
            try? await Task.sleep(for: .milliseconds(300))
            StallProbe.report("cleared")
            #if os(macOS)
            await ProfileScroller.scrollMainContent()
            StallProbe.report("scroll")
            #endif
            NSLog("CYCLE done")
            #endif
        }
        .onChange(of: pictures) { KitSettings.shared.set(pictures.rawValue, forKey: "pictures") }
        // Search waits for a pause in the typing (each search rebuilds every matching row); clearing it shows all at once.
        .task(id: query) {
            guard query != appliedQuery else { return }
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            appliedQuery = query
        }
    }

    private var resourceContent: some View {
        // Lazy: a search can match a hundred packs in a dozen cards, and only the cards on screen need building.
        LazyVStack(alignment: .leading, spacing: 22) {
                #if os(iOS)
                FromMacCard()   // Send to iPhone: download what the Mac picked, over home Wi-Fi
                #endif
                if !downloads.jobs.isEmpty {
                    DownloadsCard()
                }
                if let catalog {
                    resourceSearch
                    FormatChips(selection: $format, formats: [.reference, .books, .video, .maps, .interactive])
                    if format != nil || !searchText.isEmpty {
                        // A format filter shows every matching pack, across all areas.
                        if (format == nil || format == .reference) && (searchText.isEmpty || Interests.encyclopedia.contains(where: matches)) { encyclopediaCard(catalog) }
                        ForEach(Interests.all) { interest in
                            if interest.packs.contains(where: matches) { interestCard(interest, catalog: catalog) }
                        }
                        if searchText.isEmpty && format == .maps { mapRegions(catalog) }
                        let maps = matchingMaps(catalog)
                        if !searchText.isEmpty && !maps.isEmpty { mapSearchResults(maps) }
                        if !searchText.isEmpty && maps.isEmpty && !Interests.all.contains(where: { $0.packs.contains(where: matches) }) && !Interests.encyclopedia.contains(where: matches) {
                            ContentUnavailableView.search(text: searchText)
                        }
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
                                }.buttonStyle(.plain).hoverLift(1.02)
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
                        }.buttonStyle(.plain).hoverLift(1.01)
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
                    // Shaped like the area grid that appears once the list arrives.
                    VStack(alignment: .leading, spacing: 14) {
                        SkeletonBlock(width: 130, height: 16, corner: 5)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                            ForEach(0..<6, id: \.self) { _ in SkeletonBlock(height: 84, corner: 16) }
                        }
                        SkeletonBlock(height: 72, corner: 16)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Loading the download list")
                }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("BUILD YOUR LIBRARY").font(.caption.weight(.bold)).tracking(1.4).foregroundStyle(.tint)
            Text("Choose what to keep offline.").font(.title.bold())
            Text("Browse an area and choose the references you want.")
                .font(.callout).foregroundStyle(.secondary)
            #if os(macOS)
            FindMyMediaButton().buttonStyle(.bordered)
                .help("Add movies, music, audiobooks and games already on this Mac.")
            #endif
        }
    }

    private var resourceSearch: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search resources", text: $query).textFieldStyle(.plain).focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear resource search")
            }
        }
        .padding(10)
        .background(Design.surface, in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(Design.border) }
    }

    private var destinationControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            locationMenu
            sizePicker
        }
    }

    private var selectionInspector: some View {
        let items = chosenEntries
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let free = spaceLeft
        let fits = total < free - (1 << 30)
        return VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Your selection").font(.title2.bold())
                Spacer()
                Text("\(items.count)").font(.callout.bold()).foregroundStyle(.tint)
            }
            if items.isEmpty {
                Text("Choose resources from any area to build your kit.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(SubjectArea.allCases) { item in
                    let count = item.packs.filter { pack in items.contains { $0.name == pack.name } }.count + (item == .world ? items.filter { $0.name.hasPrefix("maps_") }.count : 0)
                    if count > 0 {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item.symbol).foregroundStyle(.tint).frame(width: 22)
                            Text(item.title).font(.callout)
                            Spacer(minLength: 4)
                            Text("\(count)").font(.callout).monospacedDigit()
                        }
                    }
                }
                if encyclopedia != nil { Label("General encyclopedia", systemImage: "book.closed").font(.callout) }
                Text("Shared resources download once. The total includes only new downloads.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Storage destination").font(.subheadline.weight(.semibold))
                locationMenu.controlSize(.large)
                Text("\(bytes(free)) available").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Reference detail").font(.subheadline.weight(.semibold))
                Picker("Reference detail", selection: $pictures) {
                    ForEach(PictureChoice.allCases) { Text($0.label).tag($0) }
                }.labelsHidden().pickerStyle(.menu)
                Text(pictures.explanation).font(.caption).foregroundStyle(.secondary)
                Label("Uses the closest available edition.", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Selected download").font(.subheadline.weight(.semibold))
                Text(bytes(total)).font(.largeTitle.bold()).monospacedDigit()
                if !fits && !items.isEmpty { Text("Not enough space at this destination.").foregroundStyle(.orange).font(.callout) }
            }
            reviewButton(items: items, fits: fits).frame(maxWidth: .infinity)
            Text("Nothing downloads until you confirm.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var locationMenu: some View {
        Menu {
            ForEach(locations) { location in
                Button {
                    destination = location
                    // Downloads and anything added later (games, movies, PDFs) go to the same place.
                    KitStorage.remember(location.folder)
                } label: {
                    Label("\(location.name) · \(bytes(location.cachedFreeSpace)) free", systemImage: location.symbol)
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
            EncyclopediaRow(name: nil, label: "None", note: "Only the subjects you pick below.", size: nil,
                            isOn: encyclopedia == nil, installed: false) { encyclopedia = nil }
            ForEach(Interests.encyclopedia.filter { searchText.isEmpty || matches($0) }) { pack in
                let entry = catalog.entry(for: pack.name, pictures: pictures)
                EncyclopediaRow(name: pack.name, label: pack.label, note: pack.note, size: entry?.size,
                                isOn: encyclopedia == pack.name, installed: isInstalled(pack.name)) {
                    encyclopedia = pack.name
                }
                .disabled(entry == nil)
            }
        }
        .card(padding: 18)
    }

    private func interestCard(_ interest: Interest, catalog: Catalog) -> some View {
        let available = interest.packs.filter(matches).filter { catalog.entry(for: $0.name, pictures: pictures) != nil && !isInstalled($0.name) }
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
                PackRow(pack: pack, entry: entry, isOn: selected.contains(pack.name), installed: isInstalled(pack.name)) {
                    if selected.contains(pack.name) { selected.remove(pack.name) } else { selected.insert(pack.name) }
                }
            }
        }
        .card(padding: 18)
    }

    private func mapRegions(_ catalog: Catalog) -> some View {
        // `status` runs inside the card's own body, so only the card redraws on a progress tick.
        MapRegionsCard(catalog: catalog, selected: Bindable(navigation).resourceSelection, status: status)
    }

    private func matchingMaps(_ catalog: Catalog) -> [CatalogEntry] {
        guard !searchText.isEmpty, format == nil || format == .maps else { return [] }
        return MapRegions.entries(in: catalog).filter {
            ($0.title + " map maps").localizedCaseInsensitiveContains(searchText)
        }
    }

    private func mapSearchResults(_ maps: [CatalogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "map", title: "Maps", subtitle: "Street maps to browse offline.")
            Divider()
            ForEach(maps) { entry in
                PackRow(pack: Pack(name: entry.name, label: entry.title), entry: entry,
                        isOn: selected.contains(entry.name), installed: isInstalled(entry.name)) {
                    if selected.contains(entry.name) { selected.remove(entry.name) } else { selected.insert(entry.name) }
                }
            }
            Text("Maps come from OpenStreetMap through the Kiwix library. © OpenStreetMap contributors.")
                .font(.caption).foregroundStyle(.secondary)
        }.card(padding: 18)
    }

    // MARK: Footer

    private func reviewButton(items: [CatalogEntry], fits: Bool) -> some View {
        Button("Review selection", systemImage: "checklist") { reviewing = true }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(items.isEmpty || !fits || destination == nil)
    }

    private var footer: some View {
        ResourcesFooter(items: chosenEntries, destination: destination, selected: selected, reviewing: $reviewing)
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
    private var spaceLeft: Int64 { ResourcesFooter.spaceLeft(destination, downloads) }

    private func startDownloads() {
        guard let destination else { return }
        SaveLocation.refreshFreeSpace()   // the check that matters reads the disk fresh
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

    private var searchText: String { appliedQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func matches(_ pack: Pack) -> Bool {
        let matchesFormat = format.map { ContentFormat(archiveName: pack.name) == $0 } ?? true
        return matchesFormat && (searchText.isEmpty || (pack.label + " " + pack.note + " " + pack.name).localizedCaseInsensitiveContains(searchText))
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
        SaveLocation.refreshFreeSpace()
        locations = SaveLocation.available()
        if destination == nil || !locations.contains(where: { $0 == destination }) { destination = SaveLocation.preferred(locations) }
        let cache = KitRefresh.catalogCache
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

/// The bar under the list: what's ticked, how big it is and whether it fits. It reads download progress and free space
/// itself, so those changing every moment redraw only this bar, not the whole Get Resources screen.
private struct ResourcesFooter: View {
    @Environment(DownloadManager.self) private var downloads
    let items: [CatalogEntry]
    let destination: SaveLocation?
    let selected: Set<String>
    @Binding var reviewing: Bool
    /// Bumped when a download starts or ends, so the free space is read fresh and shown.
    @State private var spaceRevision = 0

    /// Free space on the chosen drive after what queued, running and paused downloads still have to write there.
    static func spaceLeft(_ destination: SaveLocation?, _ downloads: DownloadManager) -> Int64 {
        guard let destination else { return 0 }
        return max(0, destination.cachedFreeSpace - downloads.bytesStillNeeded(on: destination.folder))
    }

    var body: some View {
        let _ = spaceRevision
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        let free = Self.spaceLeft(destination, downloads)
        let fits = total < free - (1 << 30)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) { summary(total: total, free: free, fits: fits); Spacer(); reviewButton(fits: fits) }
            VStack(alignment: .leading, spacing: 12) { summary(total: total, free: free, fits: fits); reviewButton(fits: fits) }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .frame(maxWidth: 860).frame(maxWidth: .infinity).background(.bar)
        .onChange(of: downloads.activeCount) { SaveLocation.refreshFreeSpace(); spaceRevision += 1 }
    }

    private func summary(total: Int64, free: Int64, fits: Bool) -> some View {
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

    private func reviewButton(fits: Bool) -> some View {
        Button("Review selection", systemImage: "checklist") { reviewing = true }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(items.isEmpty || !fits || destination == nil)
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
    @Environment(DownloadManager.self) private var downloads
    let pack: Pack
    let entry: CatalogEntry?
    let isOn: Bool
    let installed: Bool
    let toggle: () -> Void

    /// Read here, not by the screen, so a progress tick redraws this row and not the whole list.
    private var status: PackStatus? {
        if installed { return .installed }
        return downloads.job(named: pack.name).map { .downloading($0.fraction, $0.state == .paused) }
    }

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
    @Environment(DownloadManager.self) private var downloads
    let name: String?
    let label: String
    let note: String
    let size: Int64?
    let isOn: Bool
    let installed: Bool
    let pick: () -> Void

    private var status: PackStatus? {
        if installed { return .installed }
        return name.flatMap { downloads.job(named: $0) }.map { .downloading($0.fraction, $0.state == .paused) }
    }

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

/// Live download queue. Finished rows are history; clearing them never removes installed files.
struct DownloadsCard: View {
    @Environment(DownloadManager.self) private var downloads
    @State private var confirmCancel: DownloadJob?
    @State private var showingFinished = false

    private var active: [DownloadJob] { downloads.jobs.filter(\.isActive) }
    private var waiting: [DownloadJob] { downloads.jobs.filter { $0.state == .queued } }
    private var interrupted: [DownloadJob] { downloads.jobs.filter { $0.state == .paused || isFailed($0) } }
    private var finished: [DownloadJob] { downloads.jobs.filter(\.isFinished) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Downloads").font(.title2.bold())
                Spacer(minLength: 0)
                if downloads.hasFailed {
                    Button("Retry All", systemImage: "arrow.clockwise") { downloads.retryAll() }.buttonStyle(.bordered)
                } else if downloads.jobs.contains(where: { $0.state == .paused }) {
                    Button("Resume All") { downloads.resumeAll() }.buttonStyle(.bordered)
                }
            }
            Text("Installed files are ready to use while the rest download.").font(.callout).foregroundStyle(.secondary)
            if let summary = downloads.summary {
                VStack(alignment: .leading, spacing: 10) {
                    FlowLayout(spacing: 10) {
                        Text("\(finished.count) installed").font(.callout.weight(.semibold))
                        if !active.isEmpty { Text("\(active.count) active").font(.callout) }
                        if !waiting.isEmpty { Text("\(waiting.count) waiting").font(.callout) }
                        if !interrupted.isEmpty { Text("\(interrupted.count) paused or needing attention").font(.callout).foregroundStyle(.orange) }
                    }
                    HStack(spacing: 12) {
                        ProgressView(value: summary.fraction)
                        Text("\(Int(summary.fraction * 100))%").font(.callout.weight(.semibold)).monospacedDigit()
                    }
                    Text(summary.detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                .card(padding: 16)
            }
            ForEach(active) { job in
                VStack(alignment: .leading, spacing: 12) {
                    Label(job.state == .verifying ? "Checking the file" : job.state == .preparing ? "Preparing download" : "Downloading now",
                          systemImage: job.state == .verifying ? "checkmark.shield" : "arrow.down.circle.fill")
                        .font(.headline)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) { activeDetails(job).frame(minWidth: 240); Spacer(minLength: 0); controls(job) }
                        VStack(alignment: .leading, spacing: 12) { activeDetails(job); controls(job) }
                    }
                }.card(padding: 18)
            }
            if !interrupted.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Paused & needs attention · \(interrupted.count)", systemImage: "pause.circle").font(.headline)
                    ForEach(interrupted) { job in
                        VStack(alignment: .leading, spacing: 7) {
                            ViewThatFits(in: .horizontal) {
                                HStack(alignment: .top, spacing: 16) { Text(job.title).frame(minWidth: 220, alignment: .leading); Spacer(); controls(job) }
                                VStack(alignment: .leading, spacing: 8) { Text(job.title); controls(job) }
                            }
                            Text(job.detail).font(.caption).monospacedDigit().foregroundStyle(isFailed(job) ? Color.orange : Color.secondary)
                        }
                        if job.id != interrupted.last?.id { Divider() }
                    }
                }.card(padding: 18)
            }
            if !waiting.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Waiting · \(waiting.count)").font(.headline)
                    ForEach(waiting) { job in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(job.title)
                                Text(job.detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            cancelMenu(job)
                        }
                        if job.id != waiting.last?.id { Divider() }
                    }
                }.card(padding: 18)
            }
            if !finished.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) { finishedDisclosure.frame(minWidth: 300); clearFinishedButton }
                        VStack(alignment: .leading, spacing: 12) { finishedDisclosure; clearFinishedButton }
                    }
                    Text("Clearing finished entries keeps installed files in your library.").font(.caption).foregroundStyle(.secondary)
                }.card(padding: 18)
            }
            #if os(macOS)
            let device = "this Mac"
            #else
            let device = "this device"
            #endif
            Text("Keep \(device) online and awake. Interrupted downloads resume where they left off after the app quits, the device sleeps or a drive is reconnected.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("Cancel this download?", isPresented: Binding(get: { confirmCancel != nil }, set: { if !$0 { confirmCancel = nil } }), presenting: confirmCancel) { job in
            Button("Cancel Download and Delete Partial File", role: .destructive) { downloads.cancel(job); confirmCancel = nil }
            Button("Keep Downloading", role: .cancel) { confirmCancel = nil }
        } message: { job in
            Text("\(job.title) will need to start over.")
        }
    }

    private var clearFinishedButton: some View {
        Button("Clear Finished") { downloads.clearFinished() }.buttonStyle(.bordered)
    }

    private var finishedDisclosure: some View {
        DisclosureGroup("Installed · \(finished.count)", isExpanded: $showingFinished) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(finished) { job in
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                        Text(job.title)
                        Spacer(minLength: 8)
                        Text(kitBytes(job.total)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                    if job.id != finished.last?.id { Divider() }
                }
            }.padding(.top, 10)
        }.font(.callout.weight(.medium))
    }

    private func activeDetails(_ job: DownloadJob) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(job.title).font(.body.weight(.medium))
            if job.state == .preparing {
                ProgressView().controlSize(.small)
            } else {
                ProgressView(value: job.fraction).tint(job.state == .verifying ? .blue : .accentColor)
                    .accessibilityLabel("\(job.title) progress")
            }
            Text(job.detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func controls(_ job: DownloadJob) -> some View {
        HStack(spacing: 10) {
            if job.state == .paused || isFailed(job) {
                Button(isFailed(job) ? "Retry" : "Resume", systemImage: isFailed(job) ? "arrow.clockwise" : "play.fill") { downloads.resume(job) }
                    .buttonStyle(.bordered)
            } else if job.isActive {
                Button("Pause", systemImage: "pause.fill") { downloads.pause(job) }.buttonStyle(.bordered)
            }
            cancelMenu(job)
        }
    }

    private func cancelMenu(_ job: DownloadJob) -> some View {
        Menu {
            Button("Cancel Download…", role: .destructive) { confirmCancel = job }
        } label: { Label("More", systemImage: "ellipsis") }
            .help("More actions for \(job.title)")
            .accessibilityLabel("More actions for \(job.title)")
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
