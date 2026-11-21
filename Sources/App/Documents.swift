import SwiftUI
import PDFKit
import UniformTypeIdentifiers

/// A PDF someone added: a manual, a book, a printed guide.
struct SavedDocument: Identifiable, Hashable {
    let url: URL
    var id: String { url.path }
    var title: String { MediaLibrary.prettyTitle(url.deletingPathExtension().lastPathComponent) }
    var size: Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
}

/// PDFs live in a "Documents" folder inside each library, so they travel with a drive.
enum DocumentShelf {
    @MainActor static func folders(library: Library) -> [URL] {
        #if os(macOS)
        var list = library.folders.map { $0.appending(path: "Documents", directoryHint: .isDirectory) }
        list.append(KitLocation.home.appending(path: "OfflineKit/Device Manuals", directoryHint: .isDirectory))
        return list
        #else
        return [importFolder]
        #endif
    }

    /// Where new PDFs are copied: beside the app in drive mode, else this Mac or the phone.
    /// In the library they chose for their kit (often a USB drive), so it all travels together.
    static var importFolder: URL { KitStorage.documents }

    nonisolated static func scan(_ roots: [URL]) -> [SavedDocument] {
        var seen = Set<String>()
        var docs: [SavedDocument] = []
        for root in roots {
            guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                                              options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in walker
            where url.pathExtension.lowercased() == "pdf" && !url.lastPathComponent.hasPrefix("._") {
                if seen.insert(url.standardizedFileURL.path).inserted { docs.append(SavedDocument(url: url)) }
            }
        }
        return docs.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    nonisolated static func importFiles(_ urls: [URL], to dest: URL) throws {
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let target = dest.appending(path: url.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: url, to: target) }
        }
    }
}

/// The "Your documents" section of Everything saved: list, add and open PDFs.
struct DocumentsSection: View {
    @Environment(Library.self) private var library
    @State private var documents: [SavedDocument] = []
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Section {
            ForEach(documents) { doc in
                NavigationLink { PDFReaderView(document: doc) } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(doc.title).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: doc.size, countStyle: .file))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } icon: { Image(systemName: "doc.richtext") }
                }
                .sendableMenu(doc.url, .document(doc))
            }
            Button { importing = true } label: {
                Label(documents.isEmpty ? "Add PDFs: manuals, books, printed guides…" : "Add PDFs…", systemImage: "plus.circle")
            }
            .buttonStyle(.borderless)
        } header: {
            Text("Your documents")
        } footer: {
            Text("PDFs are copied into your library, so they work offline and travel with a USB drive.")
        }
        // Rescans when the library folders change and whenever PDFs are added anywhere (here, a drop, Finder).
        .task(id: ReloadKey(folders: library.folders, changes: KitChanges.shared.documents)) { await reload() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf], allowsMultipleSelection: true) { result in
            guard let urls = try? result.get() else { return }
            let dest = DocumentShelf.importFolder
            library.adopt(dest.deletingLastPathComponent())
            Task {
                let failure = await Task.detached(priority: .userInitiated) { () -> String? in
                    do { try DocumentShelf.importFiles(urls, to: dest); return nil } catch { return error.localizedDescription }
                }.value
                // Whatever was copied before a failure still shows up.
                KitChanges.shared.documentsChanged()
                importError = failure
            }
        }
        .alert("Couldn't add PDFs", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: { Text(importError ?? "") }
    }

    private struct ReloadKey: Equatable { let folders: [URL]; let changes: Int }

    private func reload() async {
        let roots = DocumentShelf.folders(library: library)
        let found = await Task.detached(priority: .userInitiated) { DocumentShelf.scan(roots) }.value
        // A newer scan replaced this one (task(id:) cancels the old task): its list may be out of date.
        guard !Task.isCancelled else { return }
        documents = found
    }
}

struct PDFReaderView: View {
    let document: SavedDocument

    var body: some View {
        PDFKitView(url: document.url)
            .navigationTitle(document.title)
            #if os(macOS)
            .toolbar {
                ToolbarItem {
                    Button { NSWorkspace.shared.open(document.url) } label: { Label("Open in Preview", systemImage: "arrow.up.forward.app") }
                        .help("Open in Preview to print or mark up")
                }
            }
            #else
            .toolbar {
                ToolbarItem { ShareLink(item: document.url) }
            }
            #endif
    }
}

#if os(macOS)
private struct PDFKitView: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView { configured(PDFView()) }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
    private func configured(_ view: PDFView) -> PDFView {
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }
}
#else
private struct PDFKitView: UIViewRepresentable {
    let url: URL
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}
#endif
