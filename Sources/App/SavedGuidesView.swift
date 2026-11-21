import SwiftUI

/// Prepare › Saved guides: articles saved from the reader, with notes, and "Print the Binder".
struct SavedGuidesSection: View {
    @Environment(Household.self) private var household
    @Environment(Library.self) private var library
    @Environment(\.openArticle) private var openArticle
    @State private var showBinder = false

    var body: some View {
        @Bindable var household = household
        let guides = household.data.extra.savedGuides
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(symbol: "books.vertical", title: "Print the binder",
                        subtitle: "One printable PDF with a cover and contents, emergency numbers, the power-out guide, these guides and your supplies list. Paper still works when every device is dead.") {
                Button { showBinder = true } label: { Label("Print the Binder…", systemImage: "printer") }
                    .buttonStyle(.borderedProminent)
            }

            if guides.isEmpty {
                ContentUnavailableView {
                    Label("No saved guides yet", systemImage: "bookmark")
                } description: {
                    Text("Open an article in Library and choose Save Guide. Saved guides are listed here and go into the printed binder.")
                }
                .frame(maxWidth: .infinity).card(padding: 18)
            }

            ForEach($household.data.extra.savedGuides) { $guide in
                let book = library.book(guide.ref.bookID)
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        if let book { BookIcon(book: book, size: 38) } else { KitSymbol("bookmark.fill") }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(guide.ref.title.isBlank ? "Untitled" : guide.ref.title).font(.headline)
                            Text(book?.shortTitle ?? "\(guide.bookTitle) · archive not connected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button("Open") { openArticle(guide.ref) }
                            .buttonStyle(.bordered)
                            .disabled(book == nil)
                        Menu {
                            Button("Move Up") { move(guide.id, by: -1) }.disabled(guides.first?.id == guide.id)
                            Button("Move Down") { move(guide.id, by: 1) }.disabled(guides.last?.id == guide.id)
                            Divider()
                            Button("Remove", role: .destructive) {
                                household.data.extra.savedGuides.removeAll { $0.id == guide.id }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel("More")
                    }
                    TextField("Notes, like “Use this for the tornado shelter”", text: $guide.notes, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder)
                }
                .card(padding: 16)
            }
        }
        .sheet(isPresented: $showBinder) { BinderSheet() }
        #if DEBUG
        // Test hook: -openArticle "knots|bowline" opens the first title match in the first archive whose name has "knots".
        .task {
            guard let spec = UserDefaults.standard.string(forKey: "openArticle") else { return }
            let parts = spec.split(separator: "|").map(String.init)
            for _ in 0..<30 where library.books.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
            guard parts.count == 2, let book = library.books.first(where: { $0.archive.name.localizedCaseInsensitiveContains(parts[0]) }),
                  let hit = book.archive.suggest(parts[1], limit: 1).first else { return }
            openArticle(ArticleRef(bookID: book.id, path: hit.path, title: hit.title))
        }
        .task {
            var options = PrintDocuments.BinderOptions()
            options.familyPlan = UserDefaults.standard.bool(forKey: "binderPlan")
            options.supplies = !household.data.extra.supplies.isEmpty
            await PrintTestHook.run("binder", title: "Household emergency binder", pageNumbers: true) {
                await PrintDocuments.binder(household.data, options: options, library: library)
            }
        }
        #endif
    }

    private func move(_ id: String, by offset: Int) {
        var list = household.data.extra.savedGuides
        guard let index = list.firstIndex(where: { $0.id == id }), list.indices.contains(index + offset) else { return }
        list.swapAt(index, index + offset)
        household.data.extra.savedGuides = list
    }
}

/// Choose what goes in the binder, then print it or save it as one PDF.
struct BinderSheet: View {
    @Environment(Household.self) private var household
    @Environment(Library.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var options = PrintDocuments.BinderOptions()

    var body: some View {
        let extra = household.data.extra
        NavigationStack {
            Form {
                Section {
                    Toggle(isOn: $options.familyPlan) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Family plan")
                            Text("Meeting places, shutoffs and each person’s medical details.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(household.data.people.isEmpty)
                    if options.familyPlan {
                        Label(PrintDocuments.privateWarning, systemImage: "exclamationmark.lock.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Toggle("Emergency numbers and radio", isOn: $options.emergencyInfo)
                    if options.emergencyInfo {
                        Toggle("Include your own numbers (\(household.data.contacts.count))", isOn: $options.yourNumbers)
                            .disabled(household.data.contacts.isEmpty)
                    }
                    Toggle(isOn: $options.powerOut) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Power-out guide (food, generator, water)")
                            Text("Offline Kit’s built-in guide, with the official sources for each figure.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Saved guides (\(extra.savedGuides.count))", isOn: $options.guides)
                        .disabled(extra.savedGuides.isEmpty)
                    Toggle("Supplies list (\(extra.supplies.count))", isOn: $options.supplies)
                        .disabled(extra.supplies.isEmpty)
                } header: {
                    Text("Include")
                } footer: {
                    Text("Starts with a cover and contents. Each section begins on a new page. Guides print with their pictures when the archive has them; archives that aren’t connected are noted.")
                }
                let offline = extra.savedGuides.filter { library.book($0.ref.bookID) == nil }
                if options.guides && !offline.isEmpty {
                    Section {
                        Label("\(offline.count) saved \(offline.count == 1 ? "guide’s archive isn’t" : "guides’ archives aren’t") connected. Connect the drive to print \(offline.count == 1 ? "it" : "them") in full.",
                              systemImage: "externaldrive.badge.exclamationmark")
                            .font(.callout)
                    }
                }
                Section {
                    PrintButtons(title: "Household emergency binder", filename: "Household emergency binder", pageNumbers: true,
                                 printLabel: "Print Binder…") {
                        await PrintDocuments.binder(household.data, options: options, library: library)
                    }
                    .disabled(!(options.familyPlan || options.emergencyInfo || options.powerOut || options.guides || options.supplies))
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Print the Binder")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .onAppear {
                if extra.savedGuides.isEmpty { options.guides = false }
                if household.data.contacts.isEmpty { options.yourNumbers = false }
                if extra.supplies.isEmpty { options.supplies = false }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
    }
}

/// "Save Guide" in the article reader's toolbar. Saves whatever article is showing now.
struct SaveGuideButton: View {
    @Environment(Household.self) private var household
    @Environment(Library.self) private var library
    let ref: ArticleRef?

    var body: some View {
        let saved = ref.map { r in household.data.extra.savedGuides.contains { $0.id == r.id } } ?? false
        Button {
            if let ref { toggle(ref) }
        } label: {
            Label(saved ? "Saved" : "Save Guide", systemImage: saved ? "bookmark.fill" : "bookmark")
        }
        .disabled(ref == nil)
        .help(saved ? "Remove from Prepare › Saved guides" : "Save to Prepare › Saved guides and the printed binder")
        #if DEBUG
        // Test hook: -autoSaveGuide YES presses this button once the article has loaded.
        .task(id: ref?.id) {
            guard UserDefaults.standard.bool(forKey: "autoSaveGuide"), let ref, !ref.title.isEmpty else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, !household.data.extra.savedGuides.contains(where: { $0.id == ref.id }) else { return }
            toggle(ref)
        }
        #endif
    }

    private func toggle(_ ref: ArticleRef) {
        if household.data.extra.savedGuides.contains(where: { $0.id == ref.id }) {
            household.data.extra.savedGuides.removeAll { $0.id == ref.id }
        } else {
            household.data.extra.savedGuides.append(SavedGuide(ref: ref, bookTitle: library.book(ref.bookID)?.title ?? ""))
        }
    }
}
