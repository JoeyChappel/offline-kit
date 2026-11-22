import SwiftUI

/// Prepare › Saved guides: articles saved from the reader, with notes, and "Print the Binder".
struct SavedGuidesSection: View {
    @Environment(Household.self) private var household
    @Environment(Library.self) private var library
    @Environment(KitNavigation.self) private var navigation
    @Environment(\.openArticle) private var openArticle
    @State private var showBinder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Guides & binder").font(.title.bold())
                Text("Keep useful articles together. Make a paper backup when you’re ready.").font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    savedGuides.frame(minWidth: 420, maxWidth: .infinity)
                    paperBackup.frame(minWidth: 280, maxWidth: 350)
                }
                VStack(alignment: .leading, spacing: 18) { savedGuides; paperBackup }
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

    private var savedGuides: some View {
        @Bindable var household = household
        let guides = household.data.extra.savedGuides
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Saved guides").font(.title2.bold())
                Spacer(minLength: 0)
                Text("\(guides.count) \(guides.count == 1 ? "guide" : "guides")").font(.callout).foregroundStyle(.secondary)
            }
            if guides.isEmpty {
                ContentUnavailableView {
                    Label("Your useful articles, kept together", systemImage: "bookmark")
                } description: {
                    Text("Open an article in Library and choose Save Guide. Add your notes here and include guides in your printed binder.")
                } actions: {
                    Button("Browse Library", systemImage: "books.vertical") { navigation.selection = .library }
                        .buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity).card(padding: 18)
            }
            ForEach($household.data.extra.savedGuides) { $guide in
                let book = library.book(guide.ref.bookID)
                VStack(alignment: .leading, spacing: 10) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            guideIdentity(guide, book: book).frame(minWidth: 220)
                            Spacer(minLength: 8)
                            guideActions(guide, book: book)
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            guideIdentity(guide, book: book)
                            guideActions(guide, book: book)
                        }
                    }
                    TextField("Notes, like “Use this for the tornado shelter”", text: $guide.notes, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder)
                }
                .card(padding: 16)
            }
            Label("Saved guides stay in the order you choose.", systemImage: "list.bullet")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func guideIdentity(_ guide: SavedGuide, book: Book?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if let book { BookIcon(book: book, size: 38) } else { KitSymbol("bookmark.fill") }
            VStack(alignment: .leading, spacing: 2) {
                Text(guide.ref.title.isBlank ? "Untitled" : guide.ref.title).font(.headline)
                Text(book?.shortTitle ?? "\(guide.bookTitle) · archive not connected")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func guideActions(_ guide: SavedGuide, book: Book?) -> some View {
        HStack(spacing: 10) {
            Button("Open") { openArticle(guide.ref) }.buttonStyle(.bordered).disabled(book == nil)
            Menu {
                Button("Move Up") { move(guide.id, by: -1) }.disabled(household.data.extra.savedGuides.first?.id == guide.id)
                Button("Move Down") { move(guide.id, by: 1) }.disabled(household.data.extra.savedGuides.last?.id == guide.id)
                Divider()
                Button("Remove", role: .destructive) {
                    household.data.extra.savedGuides.removeAll { $0.id == guide.id }
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.button).buttonStyle(.borderless).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("More")
        }
    }

    private var paperBackup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "book").font(.largeTitle).foregroundStyle(.tint)
            Text("Your paper backup").font(.title2.bold())
            Text("One PDF with a cover and contents, your selected emergency information, the power-out guide, saved guides and supplies.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { showBinder = true } label: { Label("Print the Binder…", systemImage: "printer") }
                .buttonStyle(.borderedProminent)
            Text(household.data.extra.savedGuides.isEmpty ? "You can build a binder before saving any guides." : "Choose which sections to include before printing.")
                .font(.caption).foregroundStyle(.secondary)
            Label("Review household details before printing or sharing.", systemImage: "lock")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 20)
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

    private struct ContentsSection {
        let title: String
        let note: String
    }
    private var contents: [ContentsSection] {
        var list: [ContentsSection] = []
        if options.familyPlan { list.append(.init(title: "Family emergency plan", note: "Meeting places, shutoffs and medical cards")) }
        if options.emergencyInfo {
            list.append(.init(title: "Emergency numbers and radio", note: options.yourNumbers ? "Includes your own numbers (\(household.data.contacts.count))" : "Public numbers and radio information"))
        }
        if options.powerOut { list.append(.init(title: "Power-out guide", note: "Food, generator and water guidance with sources")) }
        if options.guides {
            for guide in household.data.extra.savedGuides {
                list.append(.init(title: guide.ref.title.isBlank ? "Untitled guide" : guide.ref.title,
                                  note: library.book(guide.ref.bookID) == nil ? "Archive not connected; noted in the binder" : "Saved guide"))
            }
        }
        if options.supplies { list.append(.init(title: "Supplies list", note: "\(household.data.extra.supplies.count) items")) }
        return list
    }
    private var includesPrivateInformation: Bool {
        options.familyPlan || (options.emergencyInfo && options.yourNumbers) || options.supplies
    }

    var body: some View {
        let extra = household.data.extra
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Build your paper backup.").font(.title.bold())
                        Text("Choose the sections to print or save together as one PDF.").font(.callout).foregroundStyle(.secondary)
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 20) {
                            choices.frame(minWidth: 370, maxWidth: .infinity)
                            selectedContents.frame(minWidth: 280, maxWidth: 360)
                        }
                        VStack(alignment: .leading, spacing: 20) { choices; selectedContents }
                    }
                }.padding(24).frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
            }
            .background(Design.canvas)
            .safeAreaInset(edge: .bottom) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 20) { contentsCount.frame(minWidth: 180); Spacer(); printActions }
                    VStack(alignment: .leading, spacing: 12) { contentsCount; printActions }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
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
        .frame(width: 900, height: 760)
        #endif
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Reference sections").font(.title2.bold())
                Toggle("Emergency numbers and radio", isOn: $options.emergencyInfo)
                Toggle("Include your own numbers (\(household.data.contacts.count))", isOn: $options.yourNumbers)
                    .disabled(!options.emergencyInfo || household.data.contacts.isEmpty).padding(.leading, 20)
                Divider()
                Toggle(isOn: $options.powerOut) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Power-out guide")
                        Text("Built-in guidance with its official sources.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Toggle("Saved guides (\(household.data.extra.savedGuides.count))", isOn: $options.guides)
                    .disabled(household.data.extra.savedGuides.isEmpty)
                Text("Save an article from Library to include it here. Guides print with their pictures when the archive has them.")
                    .font(.caption).foregroundStyle(.secondary)
            }.card(padding: 18)
            VStack(alignment: .leading, spacing: 16) {
                Text("Household sections").font(.title2.bold())
                Toggle(isOn: $options.familyPlan) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Family plan")
                        Text("Meeting places, shutoffs and medical cards.").font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(household.data.people.isEmpty)
                Divider()
                Toggle("Supplies list (\(household.data.extra.supplies.count))", isOn: $options.supplies)
                    .disabled(household.data.extra.supplies.isEmpty)
            }.card(padding: 18)
            let offline = household.data.extra.savedGuides.filter { library.book($0.ref.bookID) == nil }
            if options.guides && !offline.isEmpty {
                Label("\(offline.count) saved \(offline.count == 1 ? "guide’s archive isn’t" : "guides’ archives aren’t") connected. Connect the drive to print \(offline.count == 1 ? "it" : "them") in full.", systemImage: "externaldrive.badge.exclamationmark")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true).card(padding: 16)
            }
        }
    }

    private var selectedContents: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Selected contents").font(.title2.bold())
                Label("Cover and contents · Always included", systemImage: "doc.text").font(.callout)
                ForEach(Array(contents.enumerated()), id: \.offset) { index, section in
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        Text("\(index + 1)").font(.callout.bold()).foregroundStyle(.tint).frame(width: 24)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(section.title).font(.callout.weight(.semibold))
                            Text(section.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Text("Each section begins on a new page.").font(.caption).foregroundStyle(.secondary)
            }.card(padding: 18)
            if includesPrivateInformation {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Includes private household information", systemImage: "lock.fill").font(.headline).foregroundStyle(.orange)
                    Text("Printouts and PDFs aren’t encrypted. Store them privately and shred old copies.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.card(padding: 18)
            }
        }
    }
    private var contentsCount: some View {
        Text("\(contents.count) \(contents.count == 1 ? "section" : "sections"), plus cover and contents")
            .font(.callout.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
    }
    private var printActions: some View {
        PrintButtons(title: "Household emergency binder", filename: "Household emergency binder", pageNumbers: true,
                     printLabel: "Print Binder…") {
            await PrintDocuments.binder(household.data, options: options, library: library)
        }.disabled(contents.isEmpty)
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
