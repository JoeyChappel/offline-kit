import SwiftUI

struct AskView: View {
    @Environment(KitNavigation.self) private var navigation
    @Environment(Library.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(AskModel.self) private var model
    @Environment(Household.self) private var household
    @State private var draft = ""
    @State private var showingKnowledge = false
    /// Speaking questions and hearing answers (hands-free mode).
    @State private var voice = VoiceAsk()
    /// What was typed before dictation started, so spoken words are added after it.
    @State private var dictationBase = ""
    /// True while the view keeps the newest question at the top; false once the reader scrolls.
    @State private var following = true
    /// Emergency Numbers, shown over Ask so an emergency never leaves this screen.
    @State private var showingNumbers = false
    /// True when the window is too narrow for the toolbar's words; its menus show icons only.
    @State private var compact = false
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
        if let alert = model.alert {
            EmergencyBanner(alert: alert, asked: !model.turns.isEmpty,
                            showNumbers: { showingNumbers = true }, done: { withAnimation { model.endEmergency() } })
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 6)
                .frame(maxWidth: 900)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 36) {
                    if model.turns.isEmpty && model.alert == nil {
                        WelcomeView { ask($0) }
                    }
                    if model.turns.isEmpty, model.alert != nil {
                        Text("Type or say what’s happening, in your own words. Short is fine.")
                            .font(.title2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    ForEach(model.turns) { turn in
                        TurnView(turn: turn, large: model.isFullEmergency).id(turn.id)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: Design.readableWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(Design.canvas)
            .scrollDismissesKeyboard(.interactively)
            // While an answer streams in, its question rises to the top and the text fills in below, so it can be
            // read from the start. The moment the reader scrolls, the view is theirs until they ask again.
            .onScrollPhaseChange { _, phase in
                if phase == .interacting || phase == .decelerating { following = false }
            }
            .onChange(of: model.turns.last?.answer) {
                if following, let id = model.turns.last?.id { proxy.scrollTo(id, anchor: .top) }
                if let turn = model.turns.last { voice.update(turn) }
            }
            .onChange(of: model.turns.last?.status) {
                if let turn = model.turns.last { voice.update(turn) }
            }
            .onChange(of: model.turns.count) {
                following = true
                if let id = model.turns.last?.id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
            }
        }
        .safeAreaInset(edge: .bottom) { composer }
        }
        .background(Design.canvas)
        .onGeometryChange(for: Bool.self) { $0.size.width < 760 } action: { compact = $0 }
        .environment(voice)
        .onAppear {
            voice.model = model
            voice.ask = { ask($0) }
        }
        .onDisappear { voice.end() }
        .onChange(of: voice.dictating) { _, dictating in
            if dictating { dictationBase = draft.isEmpty ? "" : draft + " " }
        }
        .onChange(of: voice.listener.transcript) { _, words in
            if voice.dictating { draft = dictationBase + words }
        }
        .animation(.spring(duration: 0.35), value: model.alert)
        .animation(.easeInOut(duration: 0.25), value: voice.isActive)
        .navigationTitle("Ask")
        .sheet(isPresented: $showingKnowledge) {
            NavigationStack {
                ScrollView { AskKnowledgeSection().padding(24) }
                    .background(Design.canvas)
                    .navigationTitle("What Ask Knows")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingKnowledge = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 620, minHeight: 640)
            #endif
        }
        .sheet(isPresented: $showingNumbers) {
            NavigationStack {
                ScrollView { EmergencyInfoSection().padding(24) }
                    .background(Design.canvas)
                    .navigationTitle("Emergency Numbers")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingNumbers = false } } }
            }
            #if os(macOS)
            .frame(minWidth: 600, idealWidth: 680, minHeight: 520, idealHeight: 720)
            #endif
        }
        .toolbar {
            if !model.isFullEmergency {
                ToolbarItem {
                    Button { withAnimation { model.startEmergency() } } label: {
                        Label("Emergency", systemImage: "exclamationmark.triangle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.red)
                    }
                    .help("Someone may be in danger: get the emergency numbers and short, step-by-step answers")
                }
            }
            ToolbarItem {
                Menu {
                    Picker("Asking as", selection: Binding(get: { household.data.activePersonID },
                                                           set: { household.data.activePersonID = $0 })) {
                        ForEach(household.data.people) { Text($0.name.isEmpty ? "Unnamed" : $0.name).tag(Optional($0.id)) }
                        Text("Someone else").tag(UUID?.none)
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Add People in Prepare…") { navigation.prepare(.people) }
                    Button("What Ask Knows…") { showingKnowledge = true }
                    if compact {
                        // A narrow window has no room for its own Answer with menu, so it lives here.
                        Divider()
                        Picker("Answer with", selection: $model.choice) {
                            ForEach(EngineChoice.allCases) { Text($0.label).tag($0) }
                        }
                    }
                } label: {
                    Label(household.activePerson.map { "Asking as \($0.name)" } ?? "Who’s asking?", systemImage: "person.crop.circle")
                        .labelStyle(ToolbarLabelStyle(compact: compact))
                }
                .help("Ask answers with this person’s health, skills and notes in mind")
            }
            if !compact {
                ToolbarItem {
                    Menu {
                        Picker("Answer with", selection: $model.choice) {
                            ForEach(EngineChoice.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label("Answer with: \(model.choice.label)", systemImage: "cpu")
                            .labelStyle(ToolbarLabelStyle(compact: compact))
                    }
                    .help("Answer with: \(model.choice.label). Automatic picks the best one available. Answers are made on \(model.contextDestination).")
                }
            }
            ToolbarItem {
                Button { model.clear(); focused = true } label: { Label("New Conversation", systemImage: "square.and.pencil") }
                    .disabled(model.turns.isEmpty)
                    .help("Start over")
            }
        }
        #if os(macOS)
        .onAppear { focused = true }   // on iPhone the keyboard would cover the welcome screen
        #endif
        .task { await model.refreshOllama() }
        #if DEBUG
        // Test hook: -startEmergency YES opens Ask with the emergency alert showing.
        .task {
            guard UserDefaults.standard.bool(forKey: "startEmergency") else { return }
            try? await Task.sleep(for: .seconds(2))
            model.startEmergency()
            // -showEmergencyNumbers YES then opens the Emergency Numbers sheet.
            if UserDefaults.standard.bool(forKey: "showEmergencyNumbers") {
                try? await Task.sleep(for: .seconds(1))
                showingNumbers = true
            }
        }
        // Test hook: -emergencyCheck YES runs the emergency-word samples and writes the results to asklog.txt.
        .task {
            guard UserDefaults.standard.bool(forKey: "emergencyCheck") else { return }
            let lines = EmergencyAlert.selfCheck()
            let failed = lines.filter { $0.hasPrefix("FAIL") }.count
            Self.log("EMERGENCY CHECK: \(lines.count - failed) of \(lines.count) as expected\n" + lines.joined(separator: "\n") + "\n")
        }
        // Test hook: -voiceTestFile <audio file> listens to that recording instead of the microphone, and
        // -voiceTestHandsFree YES runs it through hands-free mode (asks, reads the answer, logs to asklog.txt).
        .task {
            guard let path = UserDefaults.standard.string(forKey: "voiceTestFile") else { return }
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<200 where library.isLoading { try? await Task.sleep(for: .milliseconds(300)) }
            Self.log("voice test: \(library.books.count) books\n")
            let files = path.components(separatedBy: "|").map { URL(fileURLWithPath: $0) }
            voice.source = .file(files[0])
            voice.testFiles = Array(files.dropFirst())
            if UserDefaults.standard.bool(forKey: "voiceTestHandsFree") {
                voice.begin()
            } else {
                voice.micTapped { words in Self.log("DICTATED: \(words)\n"); draft = words }
            }
        }
        // Test hook: -autoAsk "first question || follow-up" asks each in turn once the library has loaded,
        // and prints every answer with its sources.
        .task(id: library.books.count) {
            if UserDefaults.standard.string(forKey: "autoAsk") != nil { Self.log("library: \(library.books.count) books, loading=\(library.isLoading)\n") }
            guard let script = UserDefaults.standard.string(forKey: "autoAsk"), !library.books.isEmpty,
                  model.turns.isEmpty else { return }
            for q in script.components(separatedBy: "||").map({ $0.trimmingCharacters(in: .whitespaces) }) where !q.isEmpty {
                model.ask(q, library: library, household: household)
                while model.isBusy { try? await Task.sleep(for: .milliseconds(300)) }
                if let t = model.turns.last {
                    Self.log("===== Q: \(t.question)\nalert: \(model.alert.map { ($0.detected ? "detected · " : "full · ") + $0.headline } ?? "none")\nsources: \(t.sources.map(\.ref.title).joined(separator: " | "))\nA: \(t.answer)\nnoted: \(t.noted.map(\.text))\n")
                }
            }
            Self.log("DONE\n")
        }
        #endif
    }

    #if DEBUG
    /// Appends to <test home>/asklog.txt, so test runs can be read while the app is open.
    private static func log(_ text: String) {
        guard let home = KitLocation.testHome else { return }
        let url = home.appending(path: "asklog.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
    #endif

    private var composer: some View {
        let empty = draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return VStack(spacing: 10) {
            if let scope = navigation.askScope {
                HStack {
                    Label("\(scope.area.title) / \(scope.title)", systemImage: "folder")
                        .font(.caption).foregroundStyle(Color.accentColor)
                    Spacer()
                    Button("Clear topic") { navigation.askScope = nil }.font(.caption)
                }
            }
            VoiceNotice()
            VStack(alignment: .leading, spacing: 4) {
                if voice.isActive {
                    VoiceStatusLine()
                        .padding(.top, 4)
                        .transition(.opacity)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    if voice.handsFree && voice.listener.isActive {
                        // Hands-free questions send themselves; the words show here as they're heard.
                        Text(voice.listener.transcript.isEmpty ? "Ask your question…" : voice.listener.transcript)
                            .foregroundStyle(voice.listener.transcript.isEmpty ? .secondary : .primary)
                            .lineLimit(1...6)
                            .truncationMode(.head)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        TextField(voice.listener.isActive ? "Listening…" : placeholder, text: $draft, axis: .vertical)
                            .disabled(noLibrary)
                            .textFieldStyle(.plain)
                            .lineLimit(1...6)
                            .focused($focused)
                            .onSubmit(send)
                            .padding(.vertical, 6)
                    }
                    HandsFreeToggle(labeled: model.isFullEmergency)
                        .disabled(noLibrary)
                    MicButton { words in
                        draft = dictationBase + words
                        focused = true
                    }
                    .disabled(noLibrary)
                    Button(action: model.isBusy ? model.stop : send) {
                        Label(model.isBusy ? "Stop" : "Send", systemImage: model.isBusy ? "stop.fill" : "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.isBusy && empty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(model.isBusy ? "Stop" : "Ask")
                }
            }
            .padding(.leading, 16).padding(.trailing, 7).padding(.vertical, 6)
            .background(Design.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(focused ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.35), lineWidth: focused ? 1.5 : 1))
            .shadow(color: .black.opacity(0.06), radius: 8, y: 2)

            if !model.isFullEmergency {
                Text("Answers come from your offline library where it covers the question, and anything else is labeled “Not from the library.” They can still be wrong. Check the sources for anything safety-critical."
                     + (model.usesHomeNetwork ? " Your questions go to \(model.contextDestination) to be answered." : " Your questions stay on this device."))
                    .font(.caption2)
                    .foregroundStyle(Design.muted)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: Design.readableWidth)
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    /// Nothing saved and nothing loading: there's nothing to ask about yet (an emergency can always ask).
    private var noLibrary: Bool { library.books.isEmpty && !library.isLoading && model.alert == nil }

    private var placeholder: String {
        if model.alert != nil { return "What’s happening?" }
        if library.isLoading && library.toOpen > 0 {
            return "Opening your library (\(library.opened) of \(library.toOpen)). You can type your question now…"
        }
        if library.books.isEmpty && !library.isLoading {
            return downloads.summary != nil ? "You can ask as soon as the first reference finishes downloading"
                                            : "Download some references first, then ask here"
        }
        return "Ask about first aid, repairs, food, anything…"
    }

    private func send() { ask(draft) }

    private func ask(_ question: String) {
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        model.ask(question, library: library, scope: navigation.askScope, household: household)
    }
}

// MARK: - Welcome

private struct Suggestion: Identifiable {
    let symbol: String
    let topic: String
    let text: String
    var id: String { text }
}

private struct WelcomeView: View {
    @Environment(Library.self) private var library
    @Environment(AskModel.self) private var model
    let onPick: (String) -> Void

    private let suggestions = [
        Suggestion(symbol: "drop", topic: "Water", text: "How do I purify water without power?"),
        Suggestion(symbol: "thermometer.sun", topic: "Health", text: "How do I keep cool in a heat wave without AC?"),
        Suggestion(symbol: "bolt", topic: "Home", text: "How do I reset a tripped GFCI outlet?"),
        Suggestion(symbol: "refrigerator", topic: "Food", text: "How long does food last in a fridge without power?"),
        Suggestion(symbol: "bandage", topic: "First aid", text: "How do I treat a deep cut?"),
        Suggestion(symbol: "car", topic: "Vehicles", text: "My car won't start and just clicks"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image("KitIcon").resizable().frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    Text("A LITTLE KNOWLEDGE. ALWAYS WITH YOU.")
                        .font(.caption.weight(.semibold)).tracking(1.1).foregroundStyle(Color.accentColor)
                }
                Text("Ask your offline library")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Trusted references, saved for the moments you need them. Browse by area or ask a question.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                FlowLayout(spacing: 6) {
                    Pill(text: model.usesHomeNetwork ? "Answers use home Wi-Fi" : "Works offline",
                         symbol: model.usesHomeNetwork ? "wifi" : "checkmark.shield", tint: .accentColor)
                    Pill(text: "\(library.books.count) \(library.books.count == 1 ? "reference" : "references")", symbol: "books.vertical")
                    Pill(text: "\(articleCount.compact) \(articleCount == 1 ? "article" : "articles")", symbol: "doc.text")
                    let engine = model.engineLabel(libraryFolders: library.folders)
                    Pill(text: engine.name, symbol: "cpu").help(engine.detail)
                }
                .padding(.top, 2)
            }

            if library.books.isEmpty && !library.isLoading {
                EmptyLibraryCard()
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Where would you like to start?").font(.headline).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10)], spacing: 10) {
                        ForEach(suggestions) { s in
                            Button { onPick(s.text) } label: { SuggestionCard(suggestion: s) }
                                .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.top, 12)
    }

    private var articleCount: Int { library.books.reduce(0) { $0 + Int($1.archive.articleCount) } }
}

private struct SuggestionCard: View {
    let suggestion: Suggestion
    @State private var hovering = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: suggestion.symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.topic.uppercased())
                    .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Text(suggestion.text)
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 14)
        .overlay(RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(hovering ? 0.6 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Turn

private struct TurnView: View {
    let turn: Turn
    var large = false
    @Environment(\.openArticle) private var openArticle
    @Environment(KitNavigation.self) private var navigation
    @Environment(Library.self) private var library
    @Environment(AskModel.self) private var model
    @Environment(Household.self) private var household
    @Environment(VoiceAsk.self) private var voice
    @State private var copied = false
    /// A web link in an answer, waiting for the person to confirm it (see answerText).
    @State private var pendingLink: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(turn.question)
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 14) {
                status
                if !turn.answer.isEmpty {
                    // Models sometimes bold the heading; normalize it so the split (and the page) stay clean.
                    let normalized = turn.answer
                        .replacingOccurrences(of: "**Not from the library:**", with: "Not from the library:")
                        .replacingOccurrences(of: "**Not from the library**:", with: "Not from the library:")
                        .replacingOccurrences(of: "**Not from the library**", with: "Not from the library:")
                    let sections = normalized.components(separatedBy: "Not from the library:")
                    if isUnsourced(sections[0]) {
                        // Nothing in it came from the library: all of it goes in the general-knowledge box.
                        notFromLibrary(sections.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                        .filter { !$0.isEmpty }.joined(separator: "\n\n"),
                                       note: "Your saved references didn’t cover this. This is general knowledge, not checked against them.")
                    } else {
                        if !sections[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            answerText(sections[0])
                        }
                        if sections.count > 1 {
                            notFromLibrary(sections.dropFirst().joined(separator: "Not from the library:"),
                                           note: "This part is general knowledge, not checked against your saved references.")
                        }
                    }
                }
                if let error = turn.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if turn.status == .done || turn.status == .failed || turn.status == .stopped {
                    footer
                }
            }
            .card(padding: 18)

            ForEach(turn.noted) { memory in
                HStack(spacing: 8) {
                    Image(systemName: "brain").foregroundStyle(Color.accentColor)
                    Text("Noted: \(memory.text)").font(.callout)
                    Spacer()
                    Button("Undo") { model.unnote(memory, household: household) }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .help("Ask will remember this. Undo, or edit it in Prepare › What Ask knows.")
            }

            if !turn.context.isEmpty && turn.status == .done {
                DisclosureGroup {
                    Text(turn.context).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("What Ask used about you and your kit", systemImage: "eye").font(.caption).foregroundStyle(.secondary)
                }
            }

            if !turn.sources.isEmpty && turn.status != .searching {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Sources").font(.headline).foregroundStyle(.secondary)
                    if let searched = turn.searchedFor {
                        Label("Searched for \u{201C}\(searched)\u{201D}", systemImage: "text.magnifyingglass")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("The first search found nothing close, so Ask corrected the spelling or used clearer words.")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], spacing: 8) {
                        ForEach(turn.sources) { source in
                            Button { open(source.ref) } label: {
                                SourceCard(source: source, book: library.book(source.ref.bookID))
                            }
                            .buttonStyle(.plain)
                            .help("Open \(SourceCard.title(source.ref.title))")
                            .accessibilityLabel("Source \(source.id): \(SourceCard.title(source.ref.title)), \(source.bookTitle)")
                        }
                    }
                }
            }
        }
    }

    private func notFromLibrary(_ text: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Not from the library", systemImage: "exclamationmark.bubble")
                .font(.headline).foregroundStyle(.orange)
            Text(note).font(.caption).foregroundStyle(.secondary)
            answerText(text)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// The main part of an answer cites nothing, or says the library had nothing: it mustn't look like a library answer.
    /// While an answer is still arriving, only the "couldn't find" sentence counts (citations may be on their way).
    private func isUnsourced(_ first: String) -> Bool {
        let text = first.replacingOccurrences(of: "’", with: "'").lowercased()
        if text.contains("couldn't find this in your offline library") || text.contains("could not find this in your offline library") {
            return true
        }
        guard turn.status == .done || turn.status == .stopped,
              !first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        // Questions about Offline Kit itself are answered from the description of the kit, with nothing to cite.
        if turn.sources.isEmpty && AskModel.isAboutKit(turn.question) { return false }
        return Self.citation.firstMatch(in: first, range: NSRange(first.startIndex..., in: first)) == nil
    }

    /// Library sources open in the reader; the built-in power-out guide opens in Prepare.
    private func openExternal(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }

    private func open(_ ref: ArticleRef) {
        if ref.bookID == PowerOutGuide.bookID { navigation.prepare(.powerOut) } else { openArticle(ref) }
    }

    private func answerText(_ text: String) -> some View {
        Text(Self.render(text)).font(large ? .title3 : .body).lineSpacing(3).textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "cite", let n = Int(url.host() ?? ""),
                   let source = turn.sources.first(where: { $0.id == n }) {
                    open(source.ref)
                    return .handled
                }
                // Answers are written by a model that has read archive text, so a link could have been planted to
                // carry details out. Web links open only after the person sees the full address; anything else is ignored.
                if url.scheme == "https" || url.scheme == "http" { pendingLink = url }
                return .handled
            })
            .confirmationDialog("Open this link in your browser?", isPresented: Binding(get: { pendingLink != nil }, set: { if !$0 { pendingLink = nil } }),
                                titleVisibility: .visible, presenting: pendingLink) { link in
                Button("Open Link") { openExternal(link) }
                Button("Cancel", role: .cancel) {}
            } message: { link in
                Text("It came from the answer, not from Offline Kit. Check that you recognize it:\n\(link.absoluteString)")
            }
    }

    @ViewBuilder private var status: some View {
        switch turn.status {
        case .searching:
            Label {
                Text(library.isLoading && library.toOpen > 0
                     ? "Opening your library (\(library.opened) of \(library.toOpen))… your answer comes right after."
                     : "Searching your library…")
            } icon: { ProgressView().controlSize(.small) }
                .foregroundStyle(.secondary)
        case .stopped:
            Label("Stopped by you. The answer is incomplete.", systemImage: "stop.circle")
                .foregroundStyle(.secondary)
        case .answering where turn.answer.isEmpty:
            Label { Text("Reading \(turn.sources.count) source\(turn.sources.count == 1 ? "" : "s")…") }
                icon: { ProgressView().controlSize(.small) }
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !turn.engine.isEmpty { Pill(text: turn.engine, symbol: "cpu").help(turn.engineDetail) }
            Pill(text: turn.runsOnDevice ? "Offline" : "Home Wi-Fi",
                 symbol: turn.runsOnDevice ? "checkmark.shield" : "wifi", tint: .accentColor)
            if let finished = turn.finished {
                Text(String(format: "%.1fs", finished.timeIntervalSince(turn.started)))
                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            }
            Spacer()
            if !turn.answer.isEmpty {
                let reading = voice.reader.turnID == turn.id && voice.reader.isSpeaking
                Button { voice.readAloud(turn) } label: {
                    Label(reading ? "Stop Reading" : "Read Aloud", systemImage: reading ? "stop.fill" : "speaker.wave.2")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                Button { copy(turn.answer) } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.top, 2)
    }

    private func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    static let citation = try! NSRegularExpression(pattern: "\\[(\\d{1,2})\\]")

    private static let citationGroup = try! NSRegularExpression(pattern: "\\[(\\d{1,2}(?:\\s*,\\s*\\d{1,2})+)\\]")

    /// Markdown with [n] turned into tappable cite:// links. "[1, 2]" becomes [1][2] first.
    /// "* " and "- " list markers at the start of a line, which inline Markdown would otherwise show as typed.
    private static let listMarker = try! NSRegularExpression(pattern: "(?m)^([ \\t]*)[*-][ \\t]+")

    static func render(_ text: String) -> AttributedString {
        let bulleted = listMarker.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1• ")
        var split = bulleted
        for match in citationGroup.matches(in: bulleted, range: NSRange(bulleted.startIndex..., in: bulleted)).reversed() {
            guard let whole = Range(match.range, in: split), let inner = Range(match.range(at: 1), in: split) else { continue }
            let numbers = split[inner].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            split.replaceSubrange(whole, with: numbers.map { "[\($0)]" }.joined())
        }
        let linked = citation.stringByReplacingMatches(
            in: split, range: NSRange(split.startIndex..., in: split), withTemplate: "[\\\\[$1\\\\]](cite://$1)")
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: linked, options: options)) ?? AttributedString(bulleted)
    }
}

private struct SourceCard: View {
    let source: Source
    let book: Book?
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(source.id)")
                .font(.caption.weight(.bold)).monospacedDigit()
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            VStack(alignment: .leading, spacing: 3) {
                Text(Self.title(source.ref.title))
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    if let book { BookIcon(book: book, size: 14) }
                    Text(book?.shortTitle ?? source.bookTitle).lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 11)
        .overlay(RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(hovering ? 0.6 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    /// "files/Water (7).pdf, page 16" → "Water (7), page 16": no folders or file extensions in a source's name.
    static func title(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"^(?:[^,]*/)?([^/,]+?)\.(?:pdf|epub|html?|txt|md)(?=,|$)"#, with: "$1",
                                 options: [.regularExpression, .caseInsensitive])
    }
}

/// Toolbar labels with words when there's room and icons only when the window is narrow.
struct ToolbarLabelStyle: LabelStyle {
    let compact: Bool
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if compact {
            Label(configuration).labelStyle(.iconOnly)
        } else {
            Label(configuration).labelStyle(.titleAndIcon)
        }
    }
}

/// Wraps children onto new lines, like tags.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
