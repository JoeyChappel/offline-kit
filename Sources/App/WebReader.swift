import SwiftUI
import WebKit

/// Serves `zim://<archive-uuid>/<path>` straight out of the archive, so article
/// HTML, images and relative links all work with no server and no network.
final class ZimSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "zim"

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let host = url.host(),
              let archive = ArchiveRegistry.shared.archive(host) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        var path = url.path(percentEncoded: false)
        if path.hasPrefix("/") { path.removeFirst() }
        // A byte-range request (a video starting or seeking) reads only those bytes out of the archive, not the whole
        // entry again for every seek.
        if let rangeHeader = task.request.value(forHTTPHeaderField: "Range"),
           let info = archive.info(atPath: path),
           let range = ByteRange(header: rangeHeader, total: Int(info.totalSize)) {
            // An open-ended request ("bytes=0-") would otherwise read the rest of a movie in one go; players accept less.
            let openEnded = rangeHeader.hasSuffix("-")
            let upper = openEnded ? min(range.upper, range.lower + ZimSchemeHandler.openEndedLimit - 1) : range.upper
            if let body = archive.data(atPath: info.path, offset: UInt(range.lower), length: UInt(upper - range.lower + 1)) {
                let headers = ["Content-Type": Self.contentType(info.mimeType), "Content-Length": "\(body.count)", "Accept-Ranges": "bytes",
                               "Content-Range": "bytes \(range.lower)-\(range.lower + body.count - 1)/\(info.totalSize)"]
                task.didReceive(HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!)
                task.didReceive(body)
                task.didFinish()
                return
            }
        }
        guard let content = archive.content(atPath: path) else {
            let page = "<html><body style='font:16px -apple-system;padding:2em'>This page isn't in the offline archive.</body></html>"
            let data = Data(page.utf8)
            task.didReceive(URLResponse(url: url, mimeType: "text/html", expectedContentLength: data.count, textEncodingName: "utf-8"))
            task.didReceive(data)
            task.didFinish()
            return
        }
        let contentType = Self.contentType(content.mimeType)
        let total = content.data.count
        // Video and audio players ask for byte ranges; answer with 206 so videos in TED/Khan archives play and seek.
        if let range = ByteRange(header: task.request.value(forHTTPHeaderField: "Range"), total: total) {
            let body = content.data.subdata(in: range.lower..<(range.upper + 1))
            let headers = ["Content-Type": contentType, "Content-Length": "\(body.count)", "Accept-Ranges": "bytes",
                           "Content-Range": "bytes \(range.lower)-\(range.upper)/\(total)"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 206, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(body)
        } else {
            let headers = ["Content-Type": contentType, "Content-Length": "\(total)", "Accept-Ranges": "bytes"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(content.data)
        }
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}

    /// The most one open-ended range request is answered with.
    static let openEndedLimit = 16 * 1024 * 1024

    /// "text/html" becomes "text/html; charset=utf-8"; binary types are left as they are.
    private static func contentType(_ mimeType: String) -> String {
        let mime = mimeType.components(separatedBy: ";").first ?? mimeType
        let isText = mime.hasPrefix("text/") || mime.contains("javascript") || mime.contains("json")
        return isText ? "\(mime); charset=utf-8" : mime
    }
}

/// "bytes=100-199", "bytes=100-" or "bytes=-500" resolved against a length.
struct ByteRange {
    let lower: Int
    let upper: Int

    init?(header: String?, total: Int) {
        guard let header, header.hasPrefix("bytes="), total > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 {
            lower = max(0, total - suffix); upper = total - 1
        } else if let start = Int(parts[0]), start < total {
            lower = start
            upper = min(total - 1, Int(parts[1]) ?? total - 1)
            guard upper >= lower else { return nil }
        } else {
            return nil
        }
    }
}

struct ReaderNotice: Equatable, Identifiable {
    let id = UUID()
    let message: String
    /// Set when the link can be opened outside the app (a website, an email address).
    let url: URL?
}

/// Observable state for one reader so toolbars can drive the web view.
@MainActor @Observable
final class ReaderState {
    var title = ""
    var canGoBack = false
    var canGoForward = false
    /// The article showing now, after following links (for Save Guide).
    var current: ArticleRef?
    /// A plain-language note about a link that can't open offline.
    var notice: ReaderNotice?
    fileprivate weak var webView: WKWebView?

    func back() { webView?.goBack() }
    func forward() { webView?.goForward() }
    func load(_ ref: ArticleRef) { webView?.load(URLRequest(url: ref.url)) }
}

#if os(macOS)
typealias PlatformViewRepresentable = NSViewRepresentable
#else
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct ArticleWebView: PlatformViewRepresentable {
    let ref: ArticleRef
    let state: ReaderState

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    private func make(_ context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(ZimSchemeHandler(), forURLScheme: ZimSchemeHandler.scheme)
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        state.webView = web
        // Archive pages are read offline: nothing on them may load from the internet (tracking pixels, scripts),
        // which would tell a server what's being read. Links the person taps still work.
        context.coordinator.loaded = ref.id
        let url = ref.url
        OfflineContentBlocker.apply(to: web) { web.load(URLRequest(url: url)) }
        return web
    }

    private func update(_ web: WKWebView, _ context: Context) {
        if context.coordinator.loaded != ref.id {
            context.coordinator.loaded = ref.id
            web.load(URLRequest(url: ref.url))
        }
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { make(context) }
    func updateNSView(_ web: WKWebView, context: Context) { update(web, context) }
    #else
    func makeUIView(context: Context) -> WKWebView { make(context) }
    func updateUIView(_ web: WKWebView, context: Context) { update(web, context) }
    #endif

    final class Coordinator: NSObject, WKNavigationDelegate {
        let state: ReaderState
        var loaded = ""
        init(state: ReaderState) { self.state = state }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == ZimSchemeHandler.scheme || scheme == "about" || scheme == "data" || scheme == "blob" { return .allow }
            // Never hand odd links (javascript:, file:, app links) to the system: macOS answers with a bare "-50" error.
            // Web links get a clear note in the reader, with the choice to open the browser.
            guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame != false || action.targetFrame == nil else {
                return .cancel
            }
            await MainActor.run {
                switch scheme {
                case "http", "https":
                    state.notice = ReaderNotice(message: "This link goes to \(url.host() ?? "a website"). Websites need the internet; this article doesn’t.", url: url)
                case "mailto", "tel", "sms":
                    state.notice = ReaderNotice(message: "This link starts an email, call or text, which needs a connection.", url: url)
                case "javascript", "":
                    break   // page menus and buttons that only work on the live site: ignore quietly
                default:
                    state.notice = ReaderNotice(message: "This link only works on the original website, not in the offline copy.", url: nil)
                }
            }
            return .cancel
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                state.title = webView.title ?? ""
                state.canGoBack = webView.canGoBack
                state.canGoForward = webView.canGoForward
                if let url = webView.url, url.scheme == ZimSchemeHandler.scheme, let host = url.host() {
                    var path = url.path(percentEncoded: false)
                    if path.hasPrefix("/") { path.removeFirst() }
                    state.current = ArticleRef(bookID: host, path: path, title: webView.title ?? "")
                }
            }
        }
    }
}

/// An article with back/forward controls. Used in its own window on Mac and a sheet on iPhone.
struct ReaderView: View {
    @Environment(Library.self) private var library
    let ref: ArticleRef
    @State private var state = ReaderState()

    var body: some View {
        ArticleWebView(ref: ref, state: state)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 12) {
                    Label(library.book(ref.bookID)?.shortTitle ?? "Saved archive", systemImage: "book.closed")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("External links need internet").foregroundStyle(.secondary)
                }
                .font(.caption).padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
            }
            .overlay(alignment: .bottom) {
                if let notice = state.notice {
                    LinkNoticeView(notice: notice) { state.notice = nil }
                        .padding(16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: notice.id) {
                            // Notes without an action fade on their own.
                            guard notice.url == nil else { return }
                            try? await Task.sleep(for: .seconds(5))
                            if state.notice?.id == notice.id { state.notice = nil }
                        }
                }
            }
            .animation(.spring(duration: 0.3), value: state.notice)
            .overlay {
                if !library.isLoading && library.book(ref.bookID) == nil {
                    ContentUnavailableView("This archive isn’t connected", systemImage: "externaldrive.badge.exclamationmark",
                                           description: Text("Reconnect its drive to keep reading this article."))
                        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Design.canvas)
                }
            }
            .navigationTitle(state.title.isEmpty ? ref.title : state.title)
            .toolbar {
                ToolbarItemGroup(placement: .navigation) {
                    Button { state.back() } label: { Label("Back", systemImage: "chevron.left") }
                        .disabled(!state.canGoBack)
                    Button { state.forward() } label: { Label("Forward", systemImage: "chevron.right") }
                        .disabled(!state.canGoForward)
                }
                ToolbarItem(placement: .primaryAction) { SaveGuideButton(ref: state.current ?? ref) }
            }
    }
}

/// Explains, in plain words, a link that can't open in the offline reader.
private struct LinkNoticeView: View {
    let notice: ReaderNotice
    let dismiss: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: notice.url == nil ? "link.badge.plus" : "globe")
                .font(.title3).foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 10) {
                Text(notice.message).font(.callout)
                if let url = notice.url {
                    HStack(spacing: 10) {
                        Button(url.scheme?.hasPrefix("http") == true ? "Open in Browser" : "Open") {
                            openURL(url)
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Stay Here", action: dismiss).buttonStyle(.bordered)
                    }
                }
            }
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss")
        }
        .padding(16)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Design.border, lineWidth: 0.5))
    }
}
