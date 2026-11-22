import SwiftUI

#if os(macOS)

/// Run "Organize with AI" and review what it suggests. Nothing changes until a suggestion is approved;
/// anything edited here counts as the person's own value and is never replaced by a later run.
struct OrganizeSheet: View {
    var startScope: CatalogKind? = nil
    @Environment(Library.self) private var library
    @Environment(MediaLibrary.self) private var media
    @Environment(GameLibrary.self) private var games
    @Environment(AskModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var organizer = MediaOrganizer.shared
    @State private var catalog = KitCatalog.shared
    @State private var editing: String?
    @State private var draft: [CatalogDetails.Key: String] = [:]
    @State private var appeared = false
    /// Ticks changed in the review, by suggestion. Untouched fields use `isUsed`'s default:
    /// details from the file or a library article start ticked, the model's own guesses start unticked.
    @State private var choices: [String: [CatalogDetails.Key: Bool]] = [:]

    private func isUsed(_ suggestion: CatalogSuggestion, _ key: CatalogDetails.Key) -> Bool {
        if let choice = choices[suggestion.key]?[key] { return choice }
        return suggestion.proposed[key]?.source != .aiGuess
    }
    @State private var note: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where "accept AI guesses too" is waiting for the person to confirm: one section, or everything.
    private enum AcceptScope: Identifiable {
        case section(CatalogKind), everything
        var id: String { switch self { case .section(let k): k.rawValue; case .everything: "all" } }
        var kind: CatalogKind? { if case .section(let k) = self { k } else { nil } }
    }
    @State private var confirmAccept: AcceptScope?

    private var waiting: [CatalogSuggestion] {
        catalog.suggestions.values.filter { organizer.scope == nil || $0.kind == organizer.scope }
            .sorted { ($0.kind.rawValue, $0.title) < ($1.kind.rawValue, $1.title) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header.padding(.horizontal, 24).padding(.top, 24)
                    HStack {
                        Text("Review suggestions").font(.title2.bold())
                        Spacer()
                        Text("\(waiting.count) waiting").font(.callout).foregroundStyle(.secondary)
                    }.padding(.horizontal, 24)
                    if waiting.isEmpty {
                        ContentUnavailableView {
                            Label(organizer.isWorking ? "Working through your library…" : "Nothing waiting for review", systemImage: "sparkles")
                        } description: {
                            Text("Suggestions appear here as they’re ready. You choose which details to approve.")
                        }.frame(maxWidth: .infinity, minHeight: 180)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            let sections = CatalogKind.allCases.filter { kind in waiting.contains { $0.kind == kind } }
                            if sections.count > 1, organizer.scope == nil {
                                HStack {
                                    Text("\(sections.count) sections are waiting").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Button("Accept Everything…", systemImage: "checkmark.circle") { confirmAccept = .everything }
                                        .help("Applies every suggestion in every section, AI guesses included. You will be asked to confirm, and Undo takes it all back.")
                                        .accessibilityHint("Applies all suggestions, including AI guesses, after you confirm.")
                                }
                                .padding(.horizontal, 24).padding(.vertical, 10)
                                Divider()
                            }
                            ForEach(CatalogKind.allCases) { kind in
                                let list = waiting.filter { $0.kind == kind }
                                if !list.isEmpty {
                                    HStack {
                                        Text("\(kind.section) · \(list.count)").font(.headline)
                                        Spacer()
                                        Menu("Approve All in \(kind.section)") {
                                            Button("Approve Details From Files and Library") { approveAll(kind) }
                                            Button("Accept AI Guesses Too…") { confirmAccept = .section(kind) }
                                        } primaryAction: { approveAll(kind) }
                                            .fixedSize()
                                            .help("The main button applies details from your files and your offline library, and leaves AI guesses here for you to check item by item. The menu also offers to accept AI guesses too.")
                                    }
                                    .padding(.horizontal, 24).padding(.vertical, 10)
                                    .background(.bar)
                                    ForEach(list) { suggestion in
                                        VStack(spacing: 0) {
                                            card(suggestion).padding(.horizontal, 24).padding(.vertical, 6)
                                            Divider().padding(.leading, 24)
                                        }
                                        .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
                                    }
                                }
                            }
                        }
                        .animation(Motion.gentle(reduceMotion), value: waiting.map(\.key))
                    }
                }.padding(.bottom, 18)
            }
            activityStatus
            Divider()
            HStack {
                Text("Saved in “\(KitCatalog.fileName)” inside each library folder, so it travels with the drive. File names and folders are never changed.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let label = catalog.undoLabel {
                    Button("Undo Last Organize", systemImage: "arrow.uturn.backward") { catalog.undo(); note = nil; media.applyCatalog(library: library) }
                        .help("Undo: \(label)")
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
        }
        .confirmationDialog(acceptTitle, isPresented: Binding(get: { confirmAccept != nil }, set: { if !$0 { confirmAccept = nil } }), titleVisibility: .visible, presenting: confirmAccept) { scope in
            Button("Accept All, Guesses Included") { acceptEverything(scope) }
            Button("Cancel", role: .cancel) {}
        } message: { scope in
            let counts = catalog.guessCounts(kind: scope.kind)
            Text("\(counts.items) \(counts.items == 1 ? "item" : "items") will take \(counts.fields) AI \(counts.fields == 1 ? "guess" : "guesses"), which can be wrong for less-known titles. Details you typed yourself are never replaced, and an AI age rating on its own is never used. Undo Last Organize takes the whole batch back.")
        }
        // Fits the smallest window (520 points tall): the review list scrolls.
        .frame(minWidth: 680, idealWidth: 900, minHeight: 420, idealHeight: 760)
        .onAppear {
            catalog.reload(library)
            if !appeared, !organizer.isWorking { organizer.scope = startScope }
            appeared = true
            #if DEBUG
            if KitLocation.testHome != nil, UserDefaults.standard.bool(forKey: "organizeMedia"), !organizer.isWorking, organizer.state == .idle {
                if UserDefaults.standard.bool(forKey: "organizeAll") { organizer.scope = nil }
                if let raw = UserDefaults.standard.string(forKey: "organizeScope") { organizer.scope = CatalogKind(rawValue: raw) }
                if UserDefaults.standard.bool(forKey: "organizeRedo") { organizer.redo = true }
                Task {
                    while library.isLoading || media.items.isEmpty { try? await Task.sleep(for: .milliseconds(300)) }
                    organizer.start(library: library, media: media, games: games, model: model)
                    while organizer.isWorking { try? await Task.sleep(for: .milliseconds(300)) }
                    if let home = KitLocation.testHome, let data = try? JSONEncoder.catalog.encode(Array(catalog.suggestions.values)) {
                        try? data.write(to: home.appending(path: "debug-organize.json"))
                    }
                    if let home = KitLocation.testHome {
                        try? "\(organizer.done) of \(organizer.total) · \(organizer.engineName ?? "no model") · \(organizer.message ?? "")".write(to: home.appending(path: "debug-organize.txt"), atomically: true, encoding: .utf8)
                    }
                }
            }
            #endif
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Organize with AI").font(.title.bold())
                Text("Suggest details. Review them before they change your collection.").font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    setupCard.frame(minWidth: 300, maxWidth: .infinity)
                    provenanceCard.frame(minWidth: 280, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 18) { setupCard; provenanceCard }
            }

        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose what to organize").font(.headline)
            Picker("Section", selection: $organizer.scope) {
                Text("Everything").tag(CatalogKind?.none)
                ForEach(CatalogKind.allCases) { Text($0.section).tag(Optional($0)) }
            }.disabled(organizer.isWorking)
            Toggle("Look again at items already organized", isOn: $organizer.redo).toggleStyle(.checkbox).disabled(organizer.isWorking)
            Text("Genre, studio or author, year, series, age ratings and descriptions.").font(.caption).foregroundStyle(.secondary)
            if !organizer.isWorking {
                HStack { Spacer(minLength: 0); runControls }
            }

        }.card(padding: 16)
    }

    @ViewBuilder private var runControls: some View {
        switch organizer.state {
        case .running:
            Button("Pause", systemImage: "pause.fill") { organizer.pause() }
            Button("Stop", systemImage: "stop.fill") { organizer.stop() }
        case .paused:
            Button("Resume", systemImage: "play.fill") { organizer.resume() }.buttonStyle(.borderedProminent)
            Button("Stop", systemImage: "stop.fill") { organizer.stop() }
        case .idle, .finished:
            Button("Start", systemImage: "sparkles") { organizer.start(library: library, media: media, games: games, model: model) }
                .buttonStyle(.borderedProminent)
        }
    }


    @ViewBuilder private var activityStatus: some View {
        if organizer.isWorking || organizer.message != nil || note != nil || catalog.saveError != nil {
            VStack(alignment: .leading, spacing: 10) {
                if organizer.isWorking {
                    HStack(spacing: 16) {
                        ProgressView(value: Double(organizer.done), total: Double(max(organizer.total, 1))) {
                            Text(organizer.state == .paused ? "Paused at \(organizer.done) of \(organizer.total)" : "Looking at \(organizer.current)… (\(organizer.done) of \(organizer.total))")
                                .lineLimit(1)
                        }
                        runControls
                    }
                }
                if let message = organizer.message { Text(message).font(.callout).foregroundStyle(.secondary) }
                if let note { Label(note, systemImage: "sparkles").font(.callout).foregroundStyle(.orange) }
                if let error = catalog.saveError { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout) }
            }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
        }
    }

    private var provenanceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Where details come from").font(.headline)
            provenance("Your files", note: "Existing details come first.", symbol: "doc")
            provenance("Offline library", note: "Checked against articles when available.", symbol: "book.closed")
            provenance("AI guess", note: "Model guesses start unchecked for review.", symbol: "sparkles")
            Text("AI age ratings are not used.").font(.caption).foregroundStyle(.secondary)
            let archives = organizer.grounding ?? {
                let names = library.books.filter { $0.archive.name.lowercased().hasPrefix("wikipedia") }.map(\.title)
                return names.isEmpty ? nil : names.joined(separator: ", ")
            }()
            Label(archives.map { "Checking details against \($0) in your library." }
                  ?? "Details come from your files, plus AI guesses you can check. Add Wikipedia in Get Resources to check them against real articles.",
                  systemImage: "books.vertical").font(.caption).foregroundStyle(.secondary)
        }.card(padding: 16)
    }

    private func provenance(_ title: String, note: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(title == "AI guess" ? Color.orange : Color.accentColor).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.callout.weight(.semibold)); Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func card(_ suggestion: CatalogSuggestion) -> some View {
        let current = catalog.details[suggestion.key]
        let isEditing = editing == suggestion.key
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(suggestion.title).font(.headline)
                if let article = suggestion.article {
                    Label("Checked against “\(article)”", systemImage: "book.closed").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isEditing {
                    Button("Cancel") { editing = nil }
                    Button("Save & Approve") { saveEdits(suggestion) }.buttonStyle(.borderedProminent)
                } else {
                    let ticked = shown(suggestion).filter { isUsed(suggestion, $0) }
                    Button("Skip") { withAnimation(Motion.gentle(reduceMotion)) { catalog.skip(suggestion.key) }; note = nil }
                    Button("Edit") { startEditing(suggestion) }
                    Button(ticked.count == shown(suggestion).count ? "Approve" : "Approve \(ticked.count) of \(shown(suggestion).count)") {
                        approve(suggestion.key, only: Set(ticked))
                    }
                    .buttonStyle(.borderedProminent).disabled(ticked.isEmpty)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(CatalogDetails.Key.allCases) { key in
                    if let field = suggestion.proposed[key].flatMap({ KitCatalog.applies(key, $0) ? $0 : nil }) ?? (isEditing ? CatalogField(value: "", source: .user) : nil) {
                        GridRow {
                            if isEditing {
                                Color.clear.frame(width: 1, height: 1)
                            } else {
                                // Untick a detail to leave it out when approving.
                                Toggle("Use \(key.label(for: suggestion.kind))", isOn: Binding(
                                    get: { isUsed(suggestion, key) },
                                    set: { choices[suggestion.key, default: [:]][key] = $0 }))
                                    .toggleStyle(.checkbox).labelsHidden()
                            }
                            Text(key.label(for: suggestion.kind)).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            if isEditing {
                                TextField(key.label(for: suggestion.kind), text: Binding(get: { draft[key] ?? field.value }, set: { draft[key] = $0 }),
                                          axis: key == .summary ? .vertical : .horizontal)
                                    .textFieldStyle(.roundedBorder)
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    if let old = current?[key]?.value, old != field.value, !old.isEmpty {
                                        Text(old).strikethrough().foregroundStyle(.secondary).font(.callout)
                                    }
                                    Text(field.value).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            if !isEditing { SourceBadge(field: field) } else { Color.clear.frame(width: 1, height: 1) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private func startEditing(_ suggestion: CatalogSuggestion) {
        draft = [:]
        for key in CatalogDetails.Key.allCases { draft[key] = suggestion.proposed[key]?.value ?? "" }
        editing = suggestion.key
    }

    /// Approves the suggestion, with each changed field saved as the person's own value.
    private func saveEdits(_ suggestion: CatalogSuggestion) {
        var edited = suggestion.proposed
        let owner = catalog.owner(suggestion.key) ?? KitStorage.primaryLibrary
        var userKeys: [CatalogDetails.Key: String] = [:]
        for key in CatalogDetails.Key.allCases {
            let value = (draft[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value != (suggestion.proposed[key]?.value ?? "") { userKeys[key] = value; edited[key] = nil }
        }
        catalog.approve(suggestion.key, edited: edited)
        for (key, value) in userKeys { catalog.setByUser(suggestion.key, field: key, value: value, owner: owner, undoable: false) }   // part of the approve, one Undo
        editing = nil
        note = nil
        media.applyCatalog(library: library)
    }

    /// The details a suggestion shows (an AI age rating is never used, so it isn't shown).
    private func shown(_ suggestion: CatalogSuggestion) -> [CatalogDetails.Key] {
        CatalogDetails.Key.allCases.filter { key in suggestion.proposed[key].map { KitCatalog.applies(key, $0) } ?? false }
    }

    private func approve(_ key: String, only: Set<CatalogDetails.Key>) {
        withAnimation(Motion.gentle(reduceMotion)) { catalog.approve(key, only: only) }
        choices[key] = nil
        note = nil
        media.applyCatalog(library: library)
    }

    private var acceptTitle: String {
        switch confirmAccept {
        case .section(let kind): "Accept everything in \(kind.section)?"
        default: "Accept everything?"
        }
    }

    private func acceptEverything(_ scope: AcceptScope) {
        withAnimation(Motion.gentle(reduceMotion)) { _ = catalog.approveAll(kind: scope.kind, includingGuesses: true) }
        note = "Everything was accepted, AI guesses included. Undo Last Organize takes it all back."
        media.applyCatalog(library: library)
    }

    private func approveAll(_ kind: CatalogKind) {
        let waiting = withAnimation(Motion.gentle(reduceMotion)) { catalog.approveAll(kind: kind) }
        note = waiting == 0 ? nil
            : "Details from your files and library were applied. \(waiting) \(waiting == 1 ? "item has" : "items have") AI guesses left to check: approve \(waiting == 1 ? "it" : "each one") below if they look right."
        media.applyCatalog(library: library)
    }
}

/// Where a detail came from: the file, a named library article, an AI guess or the person's own edit.
struct SourceBadge: View {
    let field: CatalogField
    var body: some View {
        let (symbol, tint): (String, Color) = switch field.source {
        case .file: ("doc", .secondary)
        case .library: ("book.closed", .accentColor)
        case .aiGuess: ("sparkles", .orange)
        case .user: ("person", .secondary)
        }
        Label(field.label, systemImage: symbol)
            .font(.caption2.weight(.semibold)).lineLimit(1)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(tint)
            .background(tint.opacity(0.12), in: Capsule())
            .help(field.source == .aiGuess ? "The model’s own knowledge. It may be wrong for less-known titles; edit it if so." : field.label)
    }
}
#endif
