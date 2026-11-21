import SwiftUI
import WebKit
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

/// Lays out an HTML page off screen, then prints it or saves it as a PDF.
///
/// Private details only ever live in memory here: the web view uses a non-persistent data store, and the only
/// file written is the PDF the person picks a place for. Images in saved guides load through `zim://`.
@MainActor
final class HTMLPrintJob: NSObject, WKNavigationDelegate {
    let title: String
    /// Page numbers at the bottom of each page (the binder).
    let pageNumbers: Bool
    private let webView: WKWebView
    private var loading: CheckedContinuation<Void, Never>?
    #if os(macOS)
    private var window: NSWindow?
    private var printed: CheckedContinuation<Bool, Never>?
    #endif
    /// Jobs stay alive until they finish.
    private static var running: Set<HTMLPrintJob> = []

    static let pageSize = CGSize(width: 612, height: 792)   // US Letter, in points
    static let margin: CGFloat = 36

    init(title: String, pageNumbers: Bool = false) {
        self.title = title
        self.pageNumbers = pageNumbers
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ZimSchemeHandler(), forURLScheme: ZimSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        // Pages are styled at 90 CSS px per printed inch inside a 7.5 in wrapper (see PrintDocuments): the Mac print path
        // prints a CSS px as 0.8 pt, and the iPhone formatter scales the 675 px wrapper to the 540 pt printable width.
        let width = (HTMLPrintJob.pageSize.width - HTMLPrintJob.margin * 2) / 0.8
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 900), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    /// Loads the page and waits for its images. Returns what the page's fit script reported, like the names of
    /// people whose wallet cards are still too full.
    @discardableResult
    func load(_ html: String) async -> [String] {
        Self.running.insert(self)
        #if os(macOS)
        // Printing a web view needs it in a window. This one sits off screen and is never shown.
        let window = NSWindow(contentRect: CGRect(x: -20_000, y: -20_000, width: webView.frame.width, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.window = window
        #endif
        await withCheckedContinuation { continuation in
            loading = continuation
            webView.loadHTMLString(html, baseURL: URL(string: "zim://print/"))
        }
        let wait = """
        await Promise.all(Array.from(document.images).map(img => img.complete ? null :
            new Promise(done => { img.onload = done; img.onerror = done; setTimeout(done, 8000) })));
        if (window.fitToPage) { return window.fitToPage() || []; }
        return []
        """
        let report = (try? await webView.callAsyncJavaScript(wait, contentWorld: .page)) as? [String] ?? []
        // Printing straight after layout sometimes caught WebKit before it had painted, giving blank pages.
        try? await Task.sleep(for: .milliseconds(500))
        return report
    }

    enum PrintError: LocalizedError {
        case noWindow
        var errorDescription: String? {
            "Printing couldn’t start because Offline Kit has no window open to show it in. Open the main window and try again."
        }
    }

    func finish() {
        #if os(macOS)
        window?.contentView = nil
        window = nil
        #endif
        Self.running.remove(self)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in loading?.resume(); loading = nil }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in loading?.resume(); loading = nil }
    }

    nonisolated func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The page is built in memory; nothing it contains may reach out to the network.
        let scheme = action.request.url?.scheme?.lowercased() ?? ""
        return ["zim", "about", "data"].contains(scheme) ? .allow : .cancel
    }

    #if os(macOS)
    /// Shows the print panel (where "PDF › Save as PDF" also lives), or saves straight to `url` with no panel.
    /// Returns false when it was cancelled or didn't finish; throws when it couldn't start at all.
    func run(saveTo url: URL? = nil) async throws -> Bool {
        let info = NSPrintInfo()
        info.paperSize = HTMLPrintJob.pageSize
        info.topMargin = HTMLPrintJob.margin
        info.bottomMargin = HTMLPrintJob.margin
        info.leftMargin = HTMLPrintJob.margin
        info.rightMargin = HTMLPrintJob.margin
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = pageNumbers
        if let url {
            info.jobDisposition = .save
            info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        }
        let operation = webView.printOperation(with: info)
        operation.jobTitle = title
        operation.showsPrintPanel = url == nil
        operation.showsProgressPanel = url == nil
        // Without a frame, WebKit's print view comes out as blank pages.
        operation.view?.frame = webView.bounds
        guard let host = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else { throw PrintError.noWindow }
        return await withCheckedContinuation { continuation in
            printed = continuation
            operation.runModal(for: host, delegate: self, didRun: #selector(printOperationDidRun(_:success:contextInfo:)),
                               contextInfo: nil)
        }
    }

    @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printed?.resume(returning: success)
        printed = nil
    }
    #else
    /// Paginates the page into PDF data, in memory.
    func pdfData() -> Data {
        let renderer = FooterPageRenderer(title: pageNumbers ? title : nil)
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = CGRect(origin: .zero, size: HTMLPrintJob.pageSize)
        renderer.setValue(paper, forKey: "paperRect")
        // The web formatter keeps its own ~9 pt inset inside the printable area; widen by that so content gets the full
        // 7.5 in and wallet cards print at true size (measured: 6.52 in wide without this, 6.75 in with it).
        let inset = HTMLPrintJob.margin - 9
        renderer.setValue(paper.insetBy(dx: inset, dy: inset), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, [kCGPDFContextTitle as String: title])
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }
    #endif
}

#if os(iOS)
/// Adds "Title · page 3 of 12" under each page.
private final class FooterPageRenderer: UIPrintPageRenderer {
    let title: String?
    init(title: String?) {
        self.title = title
        super.init()
        footerHeight = title == nil ? 0 : 24
    }

    override func drawFooterForPage(at index: Int, in rect: CGRect) {
        guard let title else { return }
        let text = "\(title) · page \(index + 1) of \(numberOfPages)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8), .foregroundColor: UIColor.darkGray]
        let size = text.size(withAttributes: attrs)
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.maxY - size.height - 4), withAttributes: attrs)
    }
}
#endif

/// A PDF made in memory, for "Save PDF" on iPhone.
struct PDFFile: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// "Print…" and "Save as PDF…" for a page built on demand.
struct PrintButtons: View {
    let title: String
    let filename: String
    var pageNumbers = false
    var printLabel = "Print…"
    let makeHTML: @MainActor () async -> String
    @State private var working = false
    @State private var failed: String?
    /// The PDF just saved, for "Saved to … (Show in Finder)".
    @State private var saved: URL?
    /// Cards that are still too full: asked about before printing.
    @State private var tooFull: [String] = []
    @State private var tooFullAnswer: CheckedContinuation<Bool, Never>?
    #if os(iOS)
    @State private var exportFile: PDFFile?
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Button { Task { await print() } } label: { Label(printLabel, systemImage: "printer") }
                    .buttonStyle(.borderedProminent)
                Button { Task { await savePDF() } } label: { Label("Save as PDF…", systemImage: "doc.richtext") }
                    .buttonStyle(.bordered)
                if working { ProgressView().controlSize(.small) }
            }
            if let saved {
                HStack(spacing: 6) {
                    Label("Saved to \(saved.deletingLastPathComponent().lastPathComponent) as “\(saved.lastPathComponent)”.",
                          systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    #if os(macOS)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                        .buttonStyle(.link)
                    #endif
                }
                .font(.callout)
            }
        }
        .disabled(working)
        .alert("Couldn’t print", isPresented: Binding(get: { failed != nil }, set: { if !$0 { failed = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failed ?? "") }
        .alert(tooFull.count == 1 ? "A card is too full" : "Some cards are too full",
               isPresented: Binding(get: { !tooFull.isEmpty }, set: { if !$0 { answerTooFull(false) } })) {
            Button("Cancel", role: .cancel) { answerTooFull(false) }
            Button("Print Anyway") { answerTooFull(true) }
        } message: {
            Text(PrintDocuments.tooFullMessage(tooFull) + " The end of the text would be cut off.")
        }
        #if os(iOS)
        .fileExporter(isPresented: Binding(get: { exportFile != nil }, set: { if !$0 { exportFile = nil } }),
                      document: exportFile, contentType: .pdf, defaultFilename: filename) { result in
            exportFile = nil
            if case .success(let url) = result { saved = url }
        }
        #endif
    }

    /// Lays the page out. Nil when the person chose not to go ahead with cards that are too full.
    private func makeJob() async -> HTMLPrintJob? {
        working = true
        saved = nil
        let job = HTMLPrintJob(title: title, pageNumbers: pageNumbers)
        let full = await job.load(await makeHTML())
        if !full.isEmpty {
            let goAhead = await withCheckedContinuation { continuation in
                tooFullAnswer = continuation
                tooFull = full
            }
            if !goAhead { job.finish(); working = false; return nil }
        }
        return job
    }

    private func answerTooFull(_ goAhead: Bool) {
        tooFull = []
        tooFullAnswer?.resume(returning: goAhead)
        tooFullAnswer = nil
    }

    private func print() async {
        guard let job = await makeJob() else { return }
        defer { job.finish(); working = false }
        #if os(macOS)
        do { _ = try await job.run() } catch { failed = error.localizedDescription }
        #else
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo.printInfo()
        info.jobName = title
        info.outputType = .general
        controller.printInfo = info
        controller.printingItem = job.pdfData()
        controller.present(animated: true) { _, _, error in
            if let error { failed = "Printing couldn’t start: \(error.localizedDescription)" }
        }
        #endif
    }

    private func savePDF() async {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = filename + ".pdf"
        panel.canCreateDirectories = true
        panel.message = "This PDF isn’t encrypted. Anyone who can open the file can read it, so save it somewhere private."
        guard await panel.begin() == .OK, let url = panel.url else { return }
        guard let job = await makeJob() else { return }
        defer { job.finish(); working = false }
        do {
            if try await job.run(saveTo: url), FileManager.default.fileExists(atPath: url.path) { saved = url }
            else { failed = "The PDF couldn’t be saved there." }
        } catch {
            failed = error.localizedDescription
        }
        #else
        guard let job = await makeJob() else { return }
        defer { job.finish(); working = false }
        exportFile = PDFFile(data: job.pdfData())
        #endif
    }
}

#if DEBUG
/// Test hook: -printTest <name> -printOut /path/file.pdf saves a printout with no panels.
@MainActor enum PrintTestHook {
    static func run(_ name: String, title: String, pageNumbers: Bool = false, html: @MainActor () async -> String) async {
        guard UserDefaults.standard.string(forKey: "printTest") == name,
              let out = UserDefaults.standard.string(forKey: "printOut") else { return }
        try? await Task.sleep(for: .seconds(2))
        let job = HTMLPrintJob(title: title, pageNumbers: pageNumbers)
        let page = await html()
        try? page.write(toFile: out + ".html", atomically: true, encoding: .utf8)
        let report = await job.load(page)
        // The fit script's report (for wallet cards: whose card is still too full), for checks.
        try? report.joined(separator: "\n").write(toFile: out + ".report.txt", atomically: true, encoding: .utf8)
        #if os(macOS)
        _ = try? await job.run(saveTo: URL(fileURLWithPath: out))
        #else
        try? job.pdfData().write(to: URL(fileURLWithPath: out))
        #endif
        job.finish()
    }
}
#endif
