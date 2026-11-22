import SwiftUI
import WebKit
import PDFKit

/// Reading looks, saved per device.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case light, sepia, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var background: String { switch self { case .light: "#ffffff"; case .sepia: "#f4ecd8"; case .dark: "#141615" } }
    var text: String { switch self { case .light: "#1c1f1d"; case .sepia: "#4b3a2a"; case .dark: "#e4e8e5" } }
    var link: String { switch self { case .light, .sepia: "#2E7F60"; case .dark: "#5FC398" } }
}

/// Opens an EPUB or PDF from Watch & Listen › Books and remembers the place.
struct BookReaderView: View {
    let item: MediaItem
    var body: some View {
        if item.tracks[0].pathExtension.lowercased() == "pdf" {
            PDFBookView(item: item)
        } else {
            EPUBReaderView(item: item)
        }
    }
}

// MARK: - EPUB

/// Serves files from inside the EPUB to the web view at epub-book://local/<path in the zip>.
final class EPUBSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "epub-book"
    let zip: ZipReader
    init(zip: ZipReader) { self.zip = zip }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        var path = url.path(percentEncoded: false)
        if path.hasPrefix("/") { path.removeFirst() }
        guard let data = zip.data(path) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime: String = switch ext {
        case "xhtml", "xht": "application/xhtml+xml"
        case "html", "htm": "text/html"
        case "css": "text/css"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "otf", "ttf", "woff", "woff2": "font/\(ext)"
        default: "application/octet-stream"
        }
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                    textEncodingName: mime.hasPrefix("text") || mime.contains("xml") ? "utf-8" : nil))
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Runs the last thing it was given a moment after the calls stop, or right away on `flush()`.
/// Page turns and scrolling come in bursts; only where they ended up needs saving.
@MainActor
final class DebouncedAction {
    private var task: Task<Void, Never>?
    private var action: (@MainActor () -> Void)?

    func schedule(after seconds: Double = 0.8, _ action: @escaping @MainActor () -> Void) {
        self.action = action
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func cancel() { task?.cancel(); task = nil; action = nil }

    func flush() {
        task?.cancel()
        task = nil
        let pending = action
        action = nil
        pending?()
    }
}

@MainActor @Observable
final class EPUBReaderModel {
    nonisolated static let defaultTextScale = 1.1
    let item: MediaItem
    private(set) var book: EPUBBook?
    private(set) var zip: ZipReader?
    private(set) var chapter = 0
    var fraction: Double = 0
    /// Where to scroll after a chapter loads (0…1).
    var pendingScroll: Double = 0
    /// True once the saved place has been applied. The web view isn't created before then, so its first load is the right chapter.
    private(set) var ready = false
    var theme: ReaderTheme { didSet { KitSettings.shared.set(theme.rawValue, forKey: "readerTheme") } }
    var textScale: Double { didSet { KitSettings.shared.set(String(textScale), forKey: "readerTextScale") } }
    @ObservationIgnored weak var media: MediaLibrary?
    @ObservationIgnored private let saver = DebouncedAction()

    init(item: MediaItem) {
        self.item = item
        theme = ReaderTheme(rawValue: KitSettings.shared.string(forKey: "readerTheme") ?? "") ?? .light
        textScale = Double(KitSettings.shared.string(forKey: "readerTextScale") ?? "") ?? Self.defaultTextScale
        if let (book, zip) = EPUBBook.open(item.tracks[0]) { self.book = book; self.zip = zip }
    }

    var chapterURL: URL? {
        guard let book, book.chapters.indices.contains(chapter) else { return nil }
        let encoded = book.chapters[chapter].path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? book.chapters[chapter].path
        return URL(string: "\(EPUBSchemeHandler.scheme)://local/\(encoded)")
    }

    func start(media: MediaLibrary) {
        self.media = media
        defer { ready = true }
        guard let book, !ready else { return }
        let saved = media.progress[item.progressKey]
        if let saved, !saved.finished {
            chapter = min(max(0, saved.track), book.chapters.count - 1)
            pendingScroll = min(max(0, saved.seconds), 1)
        }
    }

    /// Where the reader was before a jump from Contents or a link, so one tap goes back. Fades after a while.
    private(set) var returnPlace: (chapter: Int, scroll: Double)?
    @ObservationIgnored private var returnTask: Task<Void, Never>?

    /// Jumps to a chapter. `remember` keeps the place left behind for "Back to where you were"; the Previous and Next
    /// buttons don't, since they can undo each other.
    func go(to index: Int, at scroll: Double = 0, remember: Bool = false) {
        guard let book, book.chapters.indices.contains(index) else { return }
        returnTask?.cancel()
        returnPlace = nil
        if remember, index != chapter {
            returnPlace = (chapter, fraction)
            returnTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                if !Task.isCancelled { self?.returnPlace = nil }
            }
        }
        chapter = index
        pendingScroll = scroll
        fraction = scroll
        save()
    }

    /// Saves the chapter and how far down it they are. Reaching the end of the last chapter marks the book read.
    /// Scrolling reports many times a second, so the save waits for it to settle (and happens at once when the book closes).
    func save() { saver.schedule { [weak self] in self?.saveNow() } }

    func saveNow() {
        saver.cancel()
        guard let media, book != nil else { return }
        // Reading the last real chapter to its end counts, and so does reaching a license page after it.
        let last = lastReadableChapter
        let done = chapter > last || (chapter == last && fraction > 0.95)
        media.saveProgress(MediaProgress(track: chapter, seconds: done ? 0 : fraction, finished: done), for: item)
    }

    /// The last chapter that is the book itself. Project Gutenberg files and others end with a license or copyright
    /// page that nobody reads, so finishing the story is what counts as finishing the book.
    var lastReadableChapter: Int {
        guard let book else { return 0 }
        var index = book.chapters.count - 1
        while index > 0, Self.isBackMatter(book.chapters[index].title) { index -= 1 }
        return index
    }

    nonisolated static func isBackMatter(_ title: String) -> Bool {
        let text = title.lowercased()
        return ["license", "licence", "gutenberg", "colophon", "copyright", "transcriber", "terms of use"].contains { text.contains($0) }
    }

    var css: String {
        """
        html { font-size: \(Int(textScale * 100))% !important; -webkit-text-size-adjust: none; }
        html, body { background: \(theme.background) !important; color: \(theme.text) !important; }
        body { max-width: 38em; margin: 0 auto !important; padding: 2.2em 1.4em 4em !important;
               line-height: 1.6 !important; font-family: "New York", "Iowan Old Style", Georgia, serif; }
        a { color: \(theme.link) !important; }
        img, svg { max-width: 100% !important; height: auto !important; }
        """
    }
}

private struct EPUBReaderView: View {
    @Environment(MediaLibrary.self) private var media
    @State private var model: EPUBReaderModel
    @State private var showingAppearance = false
    @State private var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(item: MediaItem) { _model = State(initialValue: EPUBReaderModel(item: item)) }

    var body: some View {
        Group {
            if let book = model.book, let zip = model.zip {
                VStack(spacing: 0) {
                    Group { if model.ready { EPUBWebView(model: model, zip: zip) } else { Color.clear } }
                        .overlay(alignment: .bottom) { backToPlace }
                        .animation(Motion.gentle(reduceMotion), value: model.returnPlace != nil)
                    bottomBar(book)
                }
                .background(Color(hex: model.theme.background))
            } else {
                ContentUnavailableView("This book can’t be opened", systemImage: "book.closed",
                                       description: Text("The EPUB file may be damaged or protected with DRM. Books bought from stores are usually locked to their own apps."))
            }
        }
        .navigationTitle(model.book?.title ?? MediaCatalog.displayTitle(model.item.title))
        #if os(macOS)
        .navigationSubtitle(model.book?.author ?? "")
        #endif
        .onGeometryChange(for: Bool.self) { $0.size.width < 500 } action: { compact = $0 }
        .toolbar {
            ToolbarItemGroup {
                if let book = model.book {
                    Menu {
                        ForEach(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
                            Button { model.go(to: index, remember: true) } label: {
                                if index == model.chapter { Label(chapter.title, systemImage: "checkmark") } else { Text(chapter.title) }
                            }
                        }
                    } label: { Label("Contents", systemImage: "list.bullet").labelStyle(.titleAndIcon) }
                    .help("Book contents")
                }
                Button { showingAppearance.toggle() } label: { Text("Aa").font(.system(.body, design: .serif, weight: .semibold)) }
                    .accessibilityLabel("Reading appearance")
                    .help("Text size and page color")
                    .popover(isPresented: $showingAppearance, arrowEdge: .bottom) { appearance }

            }
        }
        .onAppear { model.start(media: media) }
        .onDisappear { model.saveNow() }
        // Keep text-size shortcuts available while the appearance popover is closed.
        .background {
            Group {
                Button("Smaller Text", action: smallerText).keyboardShortcut("-", modifiers: .command)
                Button("Larger Text", action: largerText).keyboardShortcut("+", modifiers: .command)
                Button("Larger Text", action: largerText).keyboardShortcut("=", modifiers: .command)
                Button("Reset Text Size", action: resetText).keyboardShortcut("0", modifiers: .command)
            }.opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
    }

    /// After a jump from Contents or a link: one tap returns to the page the reader was on.
    @ViewBuilder private var backToPlace: some View {
        if let place = model.returnPlace {
            Button { model.go(to: place.chapter, at: place.scroll) } label: {
                Label("Back to where you were", systemImage: "arrow.uturn.backward").font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .buttonStyle(.plain)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5))
            .padding(.bottom, 14)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func smallerText() { model.textScale = max(0.8, model.textScale - 0.1) }
    private func largerText() { model.textScale = min(2.2, model.textScale + 0.1) }
    private func resetText() { model.textScale = EPUBReaderModel.defaultTextScale }

    private var appearance: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Reading appearance").font(.headline)
            Divider()
            Text("Text size").font(.subheadline.weight(.semibold))
            HStack(spacing: 16) {
                Button("A−", action: smallerText).disabled(model.textScale <= 0.8).accessibilityLabel("Smaller text")
                Spacer(minLength: 0)
                Text("\(Int((model.textScale * 100).rounded()))%").font(.callout).monospacedDigit()
                Spacer(minLength: 0)
                Button("A+", action: largerText).disabled(model.textScale >= 2.2).accessibilityLabel("Larger text")
            }.buttonStyle(.bordered)
            Button("Reset to \(Int((EPUBReaderModel.defaultTextScale * 100).rounded()))%", action: resetText)
                .buttonStyle(.borderless).font(.callout).frame(maxWidth: .infinity)
                .disabled(abs(model.textScale - EPUBReaderModel.defaultTextScale) < 0.01)
                .help("Reset text size (⌘0)")
            Divider()
            Text("Page color").font(.subheadline.weight(.semibold))
            HStack(spacing: 14) {
                ForEach(ReaderTheme.allCases) { theme in
                    Button { model.theme = theme } label: {
                        VStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 10).fill(Color(hex: theme.background))
                                .frame(height: 45)
                                .overlay { RoundedRectangle(cornerRadius: 10).stroke(model.theme == theme ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: model.theme == theme ? 2 : 1) }
                                .overlay { if model.theme == theme { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).font(.headline) } }
                            Text(theme.label).font(.callout)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("\(theme.label) page color")
                        .accessibilityAddTraits(model.theme == theme ? .isSelected : [])
                }
            }
        }.padding(18).frame(width: 280)
    }

    private func bottomBar(_ book: EPUBBook) -> some View {
        HStack(spacing: 14) {
            Button { model.go(to: model.chapter - 1) } label: {
                if compact { Image(systemName: "chevron.left") } else { Label("Previous", systemImage: "chevron.left") }
            }
                .accessibilityLabel("Previous section")
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .help("Previous section (⌘←)")
                .disabled(model.chapter == 0)
            VStack(spacing: 4) {
                Text(book.chapters[model.chapter].title).font(.callout.weight(.medium)).lineLimit(1)
                ProgressView(value: (Double(model.chapter) + model.fraction) / Double(book.chapters.count))
                    .frame(maxWidth: 460)
                    .accessibilityLabel("Section progress")
                    .accessibilityValue("Section \(model.chapter + 1) of \(book.chapters.count)")
                    .help("Progress treats each section equally; sections can have different lengths.")
                Text("Section \(model.chapter + 1) of \(book.chapters.count)").font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            Button { model.go(to: model.chapter + 1) } label: {
                if compact { Image(systemName: "chevron.right") } else { Label("Next", systemImage: "chevron.right") }
            }
                .accessibilityLabel("Next section")
                .labelStyle(.titleAndIcon)
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .help("Next section (⌘→)")
                .disabled(model.chapter + 1 >= book.chapters.count)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(.bar)
    }
}

private struct EPUBWebView: PlatformViewRepresentable {
    let model: EPUBReaderModel
    let zip: ZipReader

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    private func make(_ context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(EPUBSchemeHandler(zip: zip), forURLScheme: EPUBSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        // Reports how far down the chapter the reader is.
        let report = """
        (function(){ let t; window.addEventListener('scroll', function(){ clearTimeout(t); t = setTimeout(function(){
          var h = document.documentElement.scrollHeight - window.innerHeight;
          window.webkit.messageHandlers.progress.postMessage(h > 0 ? window.scrollY / h : 1); }, 250); }); })();
        """
        config.userContentController.addUserScript(WKUserScript(source: report, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController.add(context.coordinator, name: "progress")
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        #if os(macOS)
        web.setValue(false, forKey: "drawsBackground")
        #else
        web.isOpaque = false
        #endif
        context.coordinator.web = web
        // Books are read offline: images, fonts or scripts in a book never load from the internet.
        let coordinator = context.coordinator
        OfflineContentBlocker.apply(to: web) { coordinator.ready = true; coordinator.load() }
        return web
    }

    private func update(_ web: WKWebView, _ context: Context) { context.coordinator.sync() }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, context) }
    #else
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, context) }
    #endif

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: EPUBReaderModel
        weak var web: WKWebView?
        private var loadedChapter = -1
        private var appliedCSS = ""
        /// True from the start of a chapter load until it finishes. Scroll reports in that window belong to the old page.
        private var loading = false

        init(model: EPUBReaderModel) { self.model = model }

        func load() {
            guard let web, let url = model.chapterURL else { return }
            loadedChapter = model.chapter
            loading = true
            web.load(URLRequest(url: url))
        }

        /// Follows chapter changes from the bar and menu, and restyles when the theme or text size changes.
        /// False until the offline blocker is in place; nothing loads before then.
        var ready = false

        func sync() {
            guard ready else { return }
            if model.chapter != loadedChapter { load() } else if model.css != appliedCSS { applyStyle() }
        }

        private func applyStyle() {
            appliedCSS = model.css
            let css = model.css.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`")
            web?.evaluateJavaScript("""
            (function(){ var s = document.getElementById('ok-reader'); if (!s) { s = document.createElement('style'); s.id = 'ok-reader';
              (document.head || document.documentElement).appendChild(s); } s.textContent = `\(css)`; })();
            """)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyStyle()
            loading = false
            let target = model.pendingScroll
            model.pendingScroll = 0
            if target > 0 {
                webView.evaluateJavaScript("window.scrollTo(0, (document.documentElement.scrollHeight - window.innerHeight) * \(target));")
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { loading = false }

        /// The same chapter file, ignoring any #section a link added.
        static func samePage(_ a: URL?, _ b: URL?) -> Bool {
            guard let a, let b else { return false }
            return a.path(percentEncoded: false) == b.path(percentEncoded: false)
        }

        /// Links inside the book move between chapters; anything else stays put.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            guard url.scheme == EPUBSchemeHandler.scheme else { return .cancel }
            if action.navigationType == .linkActivated, let book = model.book {
                var path = url.path(percentEncoded: false)
                if path.hasPrefix("/") { path.removeFirst() }
                if let index = book.chapters.firstIndex(where: { $0.path == path }), index != model.chapter {
                    model.go(to: index, remember: true)
                    return .cancel
                }
            }
            return .allow
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let value = message.body as? Double, !loading,
                  Self.samePage(message.frameInfo.request.url, model.chapterURL) else { return }
            model.fraction = min(max(value, 0), 1)
            model.save()
        }
    }
}

extension Color {
    /// "#rrggbb"
    init(hex: String) {
        let v = UInt64(hex.dropFirst(), radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

// MARK: - PDF books

/// The open PDF: its page, and zoom controls for the toolbar.
@MainActor @Observable
private final class PDFReaderState {
    var page = 0
    var count = 0
    @ObservationIgnored weak var view: PDFView?
    func zoomIn() { view?.zoomIn(nil) }
    func zoomOut() { view?.zoomOut(nil) }
    func fit() { view?.autoScales = true }
}

private struct PDFBookView: View {
    let item: MediaItem
    @Environment(MediaLibrary.self) private var media
    @State private var document: PDFDocument?
    @State private var loaded = false
    @State private var state = PDFReaderState()
    @State private var saver = DebouncedAction()
    var body: some View {
        Group {
            if let document {
                PDFBookKitView(document: document, startPage: media.progress[item.progressKey].map { $0.finished ? 0 : $0.track } ?? 0, state: state) { page, count in
                    // Flipping through pages saves where it stops, not every page on the way.
                    saver.schedule { media.saveProgress(MediaProgress(track: page, seconds: 0, finished: page >= count - 1 && count > 1), for: item) }
                }
                .overlay(alignment: .bottom) {
                    if state.count > 0 {
                        Text("Page \(state.page + 1) of \(state.count)")
                            .font(.callout.weight(.medium)).monospacedDigit()
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 14)
                            .allowsHitTesting(false)
                    }
                }
            } else if loaded {
                ContentUnavailableView("This PDF can’t be opened", systemImage: "doc.questionmark",
                                       description: Text("The file may be damaged, still copying, or locked with a password. Try opening it in Preview, or add the file again."))
            } else {
                ProgressView()
            }
        }
        .navigationTitle(MediaCatalog.displayTitle(item.title))
        .toolbar {
            if document != nil {
                ToolbarItemGroup {
                    Button { state.zoomOut() } label: { Label("Zoom Out", systemImage: "minus.magnifyingglass") }
                        .keyboardShortcut("-", modifiers: .command).help("Zoom out (⌘−)")
                    Button { state.fit() } label: { Label("Fit to Window", systemImage: "arrow.up.left.and.down.right.magnifyingglass") }
                        .keyboardShortcut("0", modifiers: .command).help("Fit the page to the window (⌘0)")
                    Button { state.zoomIn() } label: { Label("Zoom In", systemImage: "plus.magnifyingglass") }
                        .keyboardShortcut("+", modifiers: .command).help("Zoom in (⌘+)")
                }
            }
        }
        .background {
            Button("Zoom In") { state.zoomIn() }
                .keyboardShortcut("=", modifiers: .command).opacity(0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .onDisappear { saver.flush() }
        .task(id: item.id) {
            let url = item.tracks[0]
            // Read off the main thread: a big PDF takes a moment to open.
            let opened = await Task.detached(priority: .userInitiated) { () -> PDFDocument? in
                guard let doc = PDFDocument(url: url), doc.pageCount > 0, !doc.isLocked else { return nil }
                return doc
            }.value
            document = opened
            loaded = true
        }
    }
}

private struct PDFBookKitView: PlatformViewRepresentable {
    let document: PDFDocument
    let startPage: Int
    let state: PDFReaderState
    let onPage: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPage: onPage, state: state) }

    private func make(_ context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = document
        let start = min(startPage, max(0, document.pageCount - 1))
        if let page = document.page(at: start) { view.go(to: page) }
        state.view = view
        let count = document.pageCount, state = state
        DispatchQueue.main.async { state.count = count; state.page = start }
        context.coordinator.observe(view)
        return view
    }

    #if os(macOS)
    func makeNSView(context: Context) -> PDFView { make(context) }
    func updateNSView(_ view: PDFView, context: Context) {}
    #else
    func makeUIView(context: Context) -> PDFView { make(context) }
    func updateUIView(_ view: PDFView, context: Context) {}
    #endif

    final class Coordinator: NSObject {
        let onPage: (Int, Int) -> Void
        let state: PDFReaderState
        private var token: NSObjectProtocol?
        init(onPage: @escaping (Int, Int) -> Void, state: PDFReaderState) { self.onPage = onPage; self.state = state }
        func observe(_ view: PDFView) {
            token = NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, let doc = view.document, let page = view.currentPage else { return }
                    let index = doc.index(for: page)
                    self.state.page = index
                    self.state.count = doc.pageCount
                    self.onPage(index, doc.pageCount)
                }
            }
        }
        deinit { if let token { NotificationCenter.default.removeObserver(token) } }
    }
}
