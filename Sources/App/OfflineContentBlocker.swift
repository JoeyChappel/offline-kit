import WebKit

/// Offline readers (reference archives and EPUB books) never load anything from the internet: a tracking pixel,
/// web font or script in a page would tell its server what's being read, when, and from where. Links the person
/// taps are handled by each reader's navigation delegate.
///
/// The rules are compiled once (the app starts it at launch), and a reader's first page waits the moment it takes,
/// so not even the first page of a session can reach out.
@MainActor
enum OfflineContentBlocker {
    private static var list: WKContentRuleList?
    private static var compiled = false
    private static var waiting: [@MainActor (WKContentRuleList?) -> Void] = []

    /// One rule per scheme: WebKit's rule patterns don't support "|" (a single "(https?|wss?|ftp)" rule fails to compile).
    private static let rules: String = {
        let types = #"["image","style-sheet","script","font","raw","svg-document","media","ping","fetch","websocket","other"]"#
        let rules = ["^https?://", "^wss?://", "^ftp://"].map {
            #"{"trigger":{"url-filter":"\#($0)","resource-type":\#(types)},"action":{"type":"block"}}"#
        }
        return "[" + rules.joined(separator: ",") + "]"
    }()

    /// Starts compiling early, so readers don't wait at all.
    static func prepare() { withList { _ in } }

    /// Adds the blocker to the web view, then runs `load`. If the rules can't be compiled, pages still open.
    static func apply(to web: WKWebView, then load: @escaping @MainActor () -> Void) {
        withList { list in
            if let list { web.configuration.userContentController.add(list) }
            load()
        }
    }

    private static func withList(_ body: @escaping @MainActor (WKContentRuleList?) -> Void) {
        if compiled { body(list); return }
        waiting.append(body)
        guard waiting.count == 1 else { return }   // already compiling
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "offlinekit-offline-only",
                                                                encodedContentRuleList: rules) { compiledList, error in
            Task { @MainActor in
                if let error { print("Offline content rules didn't compile: \(error)") }
                list = compiledList
                compiled = true
                let callers = waiting
                waiting = []
                callers.forEach { $0(compiledList) }
            }
        }
    }
}
