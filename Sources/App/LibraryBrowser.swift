import SwiftUI
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class KitNavigation {
    var selection: SidebarItem? = .library {
        // Moving to another section forgets the area Get Resources was opened on, so the sidebar's
        // Get Resources always starts at All areas. `getResources(_:)` sets the area after the move.
        didSet { if selection != oldValue { resourceArea = nil } }
    }
    var askScope: SubjectTopic?
    var resourceArea: SubjectArea?
    var prepareTab: PrepareTab?
    /// What's ticked in Get Resources, kept while people look around the rest of the app.
    var resourceSelection: Set<String> = []
    var resourceEncyclopedia: String?
    /// The starter essentials were ticked once for a new kit; don't tick them again after someone clears them.
    var resourcesPreselected = false
    /// Set by Settings › Copy Offline Kit to a Drive: Kit Care opens Copy my kit when it appears.
    var wantsKitCopy = false

    func prepare(_ tab: PrepareTab) {
        prepareTab = tab
        selection = .prepare
    }

    func getResources(_ area: SubjectArea? = nil) {
        selection = .resources
        resourceArea = area
    }

    func ask(about topic: SubjectTopic) {
        askScope = topic
        selection = .ask
    }
}

private enum LibraryRoute: Hashable {
    case area(SubjectArea), topic(SubjectTopic), archives
}

struct LibraryBrowser: View {
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(KitNavigation.self) private var navigation
    @State private var path: [LibraryRoute]
    @State private var query = ""
    @State private var importing = false
    @State private var importError: String?
    /// The file being copied in by Add Downloaded Files, with progress.
    @State private var copying: ImportProgress?

    struct ImportProgress: Equatable {
        var name: String
        var index: Int
        var count: Int
        var done: Int64
        var total: Int64
        var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }
    }

    init(area: SubjectArea? = nil, archives: Bool = false) {
        _path = State(initialValue: archives ? [.archives] : area.map { [.area($0)] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    KitHeading(eyebrow: "YOUR REFERENCE SHELF", title: "What would you like to find?",
                               subtitle: "Start with an area. Narrow it down to a topic, then open a guide.")
                    if let summary = downloads.summary, !summary.isComplete || library.books.isEmpty {
                        DownloadProgressPanel { navigation.getResources() }
                    } else if library.books.isEmpty && !library.isLoading {
                        EmptyLibraryCard()
                    }
                    HStack {
                        Text("Browse by area").font(.headline)
                        Spacer()
                        NavigationLink("View by file", value: LibraryRoute.archives).font(.callout)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(filteredAreas) { area in
                            NavigationLink(value: LibraryRoute.area(area)) {
                                SubjectAreaCard(area: area, detail: library.books.isEmpty
                                                ? (downloads.summary?.isRunning == true ? "Downloading…" : "Nothing saved yet") : nil)
                            }.buttonStyle(.plain)
                        }
                    }
                    if let copying {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Adding \(copying.name)…", systemImage: "square.and.arrow.down")
                                .font(.headline)
                            ProgressView(value: copying.fraction)
                            Text("\(kitBytes(copying.done)) of \(kitBytes(copying.total))"
                                 + (copying.count > 1 ? " · file \(copying.index) of \(copying.count)" : ""))
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                        .card(padding: 16)
                    }
                    if filteredAreas.isEmpty {
                        ContentUnavailableView {
                            Label("No areas match \u{201C}\(query)\u{201D}", systemImage: "magnifyingglass")
                        } description: {
                            Text("This filters the list of areas. To search inside your saved references, ask a question.")
                        } actions: {
                            Button("Ask Instead", systemImage: "bubble.left") {
                                navigation.selection = .ask
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Design.canvas)
            .navigationTitle("Library")
            .refreshable { await library.reload() }
            .searchable(text: $query, prompt: "Filter areas and topics")
            .toolbar {
                ToolbarItem {
                    Button("Add Downloaded Files…", systemImage: "plus") { importing = true }
                        .disabled(copying != nil)
                        .help("Add .zim reference files you already downloaded (for example from kiwix.org). They’re copied into your library.")
                }
            }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .area(let area): SubjectAreaView(area: area)
                case .topic(let topic): SubjectTopicView(topic: topic)
                case .archives: ArchiveListView()
                }
            }
        }
        .onChange(of: path) {
            guard path.isEmpty else { return }
            switch navigation.selection {
            case .area, .archives: navigation.selection = .library
            default: break
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "zim") ?? .data], allowsMultipleSelection: true) { result in
            Task { await importArchives(result) }
        }
        .alert("Add Downloaded Files", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    /// Copies picked .zim files into the library folder new downloads go to, showing progress (they can be many
    /// gigabytes) and saying afterwards what was skipped or couldn't be copied.
    private func importArchives(_ result: Result<[URL], Error>) async {
        let urls: [URL]
        do { urls = try result.get() } catch { importError = error.localizedDescription; return }
        let folder = KitStorage.primaryLibrary
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            importError = "Couldn’t open the library folder \(folder.path): \(error.localizedDescription)"
            return
        }
        var added: [String] = [], skipped: [String] = [], failed: [String] = []
        for (i, url) in urls.enumerated() {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let name = url.lastPathComponent
            let destination = folder.appending(path: name)
            if FileManager.default.fileExists(atPath: destination.path) {
                skipped.append("\(name) (already in your library)")
                continue
            }
            if url.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path {
                skipped.append("\(name) (already in your library)")
                continue
            }
            let total = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? 0
            copying = ImportProgress(name: name, index: i + 1, count: urls.count, done: 0, total: total)
            do {
                try await Self.copy(url, to: destination) { done in
                    Task { @MainActor in copying?.done = done }
                }
                try? FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: destination.path)
                added.append(name)
            } catch {
                try? FileManager.default.removeItem(at: destination)   // never leave half a file in the library
                failed.append("\(name): \(error.localizedDescription)")
            }
        }
        copying = nil
        if !added.isEmpty {
            // The chosen library folder is normally scanned already; make sure the files show up if it isn't.
            if !library.folders.contains(where: { $0.standardizedFileURL.path == folder.standardizedFileURL.path }) {
                library.extraFolders.append(folder.path)
            }
            await library.reload()
        }
        var lines: [String] = []
        if !skipped.isEmpty { lines.append("Skipped: " + skipped.joined(separator: ", ") + ".") }
        if !failed.isEmpty { lines.append("Couldn’t copy: " + failed.joined(separator: "; ") + ".") }
        if !lines.isEmpty {
            if !added.isEmpty { lines.insert("Added \(added.count) \(added.count == 1 ? "file" : "files").", at: 0) }
            importError = lines.joined(separator: "\n\n")
        }
    }

    /// Copies in 8 MB pieces off the main thread, reporting bytes copied.
    private nonisolated static func copy(_ source: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fm = FileManager.default
            guard fm.createFile(atPath: destination.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: destination.path])
            }
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            var done: Int64 = 0
            var lastReport = Date.distantPast
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 8 << 20), !chunk.isEmpty else { break }
                try output.write(contentsOf: chunk)
                done += Int64(chunk.count)
                if Date().timeIntervalSince(lastReport) > 0.2 { progress(done); lastReport = Date() }
            }
            try output.synchronize()
            progress(done)
        }.value
    }

    private var filteredAreas: [SubjectArea] {
        SubjectArea.allCases.filter { area in
            query.isEmpty || (area.title + " " + area.subtitle + " " + area.topics.map(\.title).joined(separator: " "))
                .localizedCaseInsensitiveContains(query)
        }
    }
}

struct SubjectAreaCard: View {
    let area: SubjectArea
    var detail: String? = nil
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            KitSymbol(area.symbol)
            VStack(alignment: .leading, spacing: 7) {
                Text(area.title).font(.headline).foregroundStyle(Design.ink)
                Text(area.subtitle).font(.callout).foregroundStyle(Design.muted)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
        .card(padding: 18)
        .overlay(RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
            .strokeBorder(hovering ? Color.accentColor.opacity(0.6) : .clear))
        .contentShape(RoundedRectangle(cornerRadius: Design.corner))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct SubjectAreaView: View {
    @Environment(Library.self) private var library
    @Environment(KitNavigation.self) private var navigation
    let area: SubjectArea

    var body: some View {
        List {
            Section {
                KitHeading(eyebrow: "LIBRARY / \(area.title.uppercased())", title: area.title,
                           subtitle: "Choose a topic to narrow your library.")
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
            }
            Section("Topics in this area") {
                ForEach(area.topics) { topic in
                    NavigationLink(value: LibraryRoute.topic(topic)) {
                        HStack(spacing: 14) {
                            KitSymbol(topic.title == "Electrical" ? "bolt" : area.symbol)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(topic.title).font(.headline)
                                Text(topic.detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 7)
                    }
                }
            }
            if !hasArchives {
                Section {
                    Label("No references in this area are saved yet.", systemImage: "books.vertical")
                        .foregroundStyle(.secondary)
                    Button("Get resources for this area") { navigation.getResources(area) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.canvas)
        .navigationTitle(area.title)
    }

    private var hasArchives: Bool { library.books.contains { area.contains(archiveName: $0.archive.name) } }
}

private struct SubjectTopicView: View {
    @Environment(Library.self) private var library
    @Environment(KitNavigation.self) private var navigation
    @Environment(\.openArticle) private var openArticle
    let topic: SubjectTopic
    @State private var query = ""
    @State private var articles: [SubjectArticle] = []
    @State private var searching = true

    private var searchIdentity: String { query + "|" + library.books.map(\.id).sorted().joined(separator: ",") }

    var body: some View {
        List {
            Section {
                KitHeading(eyebrow: topic.area.title.uppercased(), title: topic.title,
                           subtitle: "Choose a saved guide. Each one shows where it comes from.")
                    .padding(.vertical, 12)
                    .listRowBackground(Color.clear)
            }
            Section("Guides & references") {
                if searching {
                    ProgressView("Searching your saved articles…").padding(.vertical, 20)
                } else if articles.isEmpty {
                    ContentUnavailableView {
                        Label("No saved guides found", systemImage: "doc.text.magnifyingglass")
                    } description: {
                        Text("Try another search, browse an archive, or add references in this area.")
                    } actions: {
                        NavigationLink("Browse archives", value: LibraryRoute.archives)
                        Button("Get Resources") { navigation.getResources(topic.area) }
                    }
                } else {
                    ForEach(articles) { article in
                        Button { openArticle(article.ref) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "doc.text").foregroundStyle(.tint).padding(.top, 3)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(article.ref.title).font(.headline).foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading)
                                    Text(article.archiveTitle).font(.caption).foregroundStyle(.secondary)
                                    if !article.snippet.isEmpty {
                                        Text(article.snippet).font(.callout).foregroundStyle(.secondary)
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                    }
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.forward").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 9).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(article.ref.title), \(article.archiveTitle). Open saved article.")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.canvas)
        .navigationTitle(topic.title)
        .searchable(text: $query, prompt: "Search within \(topic.title.lowercased())")
        .safeAreaInset(edge: .bottom) {
            HStack {
                Pill(text: "Saved offline", symbol: "checkmark.shield", tint: .accentColor)
                Spacer()
                Button("Ask about this topic", systemImage: "bubble.left") { navigation.ask(about: topic) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!library.books.contains { topic.area.contains(archiveName: $0.archive.name) })
            }.padding().background(.bar)
        }
        .task(id: searchIdentity) {
            searching = true
            do { try await Task.sleep(for: .milliseconds(query.isEmpty ? 0 : 250)) } catch { return }
            let books = library.books, input = query
            let worker = Task.detached(priority: .userInitiated) {
                SubjectSearch.articles(topic: topic, query: input, books: books)
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            articles = result
            searching = false
        }
    }
}

struct ArchiveListView: View {
    @Environment(Library.self) private var library
    @State private var format: ContentFormat?

    /// Formats present in the library, for the filter chips.
    private var presentFormats: [ContentFormat] {
        let present = Set(library.books.map { ContentFormat(archiveName: $0.archive.name) })
        return ContentFormat.allCases.filter(present.contains)
    }

    var body: some View {
        List {
            if library.books.isEmpty && !library.isLoading {
                EmptyLibraryCard()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if presentFormats.count > 1 {
                FormatChips(selection: $format, formats: presentFormats)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            ForEach(BookKind.allCases, id: \.self) { kind in
                let books = library.books.filter { book in book.kind == kind && (format.map { ContentFormat(archiveName: book.archive.name) == $0 } ?? true) }
                if !books.isEmpty {
                    Section(kind.title) {
                        ForEach(books) { book in
                            NavigationLink { BookView(book: book) } label: { BookRow(book: book) }
                                .sendableMenu(book.url, .archive(book))
                        }
                    }
                }
            }
            if format == nil || format == .books {
                DocumentsSection()
                FindMoreCard(title: "Where to find more to read",
                             intro: "Free PDFs you can download once and keep. Add them with Add PDFs.",
                             links: FindMore.documents,
                             footnote: "For device manuals, download the PDF from the maker’s support website. These links open in your browser and need internet.")
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if !library.skipped.isEmpty {
                Section("Not ready yet") {
                    ForEach(library.skipped, id: \.url) { item in
                        Label {
                            VStack(alignment: .leading) {
                                Text(RootView.prettyName(item.url))
                                Text(item.reason).font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "arrow.down.circle.dotted") }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Design.canvas)
        .navigationTitle("All downloads")
        // Archive rows have an icon and two lines; at the default minimum row height a Mac List clipped them.
        .environment(\.defaultMinListRowHeight, 44)
    }
}

struct EmptyLibraryCard: View {
    @Environment(KitNavigation.self) private var navigation
    @Environment(DownloadManager.self) private var downloads
    var body: some View {
        if downloads.summary != nil {
            DownloadProgressPanel { navigation.getResources() }
        } else {
            nothingSaved
        }
    }

    private var nothingSaved: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nothing saved yet", systemImage: "books.vertical").font(.headline)
            Text("Choose a few trusted references to download. They stay on this device and work without the internet.")
                .foregroundStyle(.secondary)
            Button("Get Resources", systemImage: "arrow.down.circle") { navigation.getResources() }
                .buttonStyle(.borderedProminent)
        }.card(padding: 20)
    }
}
