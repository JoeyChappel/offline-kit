import SwiftUI

/// One screen in Prepare. Kept as one flat list so deep links (`navigation.prepare(.info)`, `-prepareTab people`)
/// keep working; `group` places each in the Plan · Supplies · Tools control.
enum PrepareTab: String, CaseIterable, Identifiable {
    case checklist, powerOut, supplies, people, plan, calculators, home, guides, info, privacy
    var id: String { rawValue }
    var label: String {
        switch self {
        case .checklist: "Checklist"
        case .powerOut: "Power out"
        case .calculators: "Calculators"
        case .supplies: "Supplies"
        case .people: "People"
        case .plan: "Family plan"
        case .guides: "Guides & binder"
        case .home: "Home"
        case .info: "Emergency numbers"
        case .privacy: "What Ask knows"
        }
    }
    var symbol: String {
        switch self {
        case .checklist: "checklist"
        case .powerOut: "bolt.slash"
        case .calculators: "function"
        case .supplies: "shippingbox"
        case .people: "person.2"
        case .plan: "person.text.rectangle"
        case .guides: "bookmark"
        case .home: "house"
        case .info: "phone.badge.waveform"
        case .privacy: "lock.shield"
        }
    }

    /// Where it sits in the control. What Ask knows has no group: it opens from "Privacy & Ask…".
    var group: PrepareGroup? {
        switch self {
        case .plan, .people, .home, .info: .plan
        case .checklist, .supplies: .supplies
        case .powerOut, .calculators, .guides: .tools
        case .privacy: nil
        }
    }

    /// Needs the drive's passphrase when it's locked. Power out, calculators and the public emergency numbers never do.
    var isPrivate: Bool {
        switch self {
        case .powerOut, .calculators, .info: false
        default: true
        }
    }
}

/// Prepare's three top-level groups, each with at most four screens.
enum PrepareGroup: String, CaseIterable, Identifiable {
    case plan, supplies, tools
    var id: String { rawValue }
    var label: String {
        switch self {
        case .plan: "Plan"
        case .supplies: "Supplies"
        case .tools: "Tools"
        }
    }
    var tabs: [PrepareTab] { PrepareTab.allCases.filter { $0.group == self }.sorted { order($0) < order($1) } }
    private func order(_ tab: PrepareTab) -> Int {
        [PrepareTab.plan, .people, .home, .info, .checklist, .supplies, .powerOut, .calculators, .guides].firstIndex(of: tab) ?? 99
    }
}

/// Household, supplies and skills, so Ask can give answers that fit. Private: see `PrivateStore.whereText`.
struct PrepareView: View {
    @Environment(KitNavigation.self) private var navigation
    @Environment(Household.self) private var household
    /// Opens on Power out while the power is out; on a locked drive, on something that works without the passphrase.
    @State private var tab: PrepareTab = PrepareView.startTab
    /// The screen each group shows when it's picked again.
    @State private var lastInGroup: [PrepareGroup: PrepareTab] = [:]
    /// Where "Done" goes from What Ask knows.
    @State private var beforePrivacy: PrepareTab = .checklist
    @State private var calculator: Calculator = KitSettings.shared.string(forKey: "lastCalculator").flatMap(Calculator.init(rawValue:)) ?? .water
    /// A person whose Family plan card People asked to open.
    @State private var focusPerson: UUID?
    @State private var power = PowerOut.shared
    @State private var showingSupplyPrivacy = false

    private static var startTab: PrepareTab {
        if PowerOut.shared.isActive { return .powerOut }
        // Back to the screen that was open last time, unless it needs details that are locked.
        let saved = KitSettings.shared.string(forKey: "lastPrepareTab").flatMap(PrepareTab.init(rawValue:))
        if let saved, saved != .privacy, !(saved.isPrivate && PrivateStore.isLocked) { return saved }
        return PrivateStore.isLocked ? .info : .checklist
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !Self.compactForTests {
                        if tab == .supplies {
                            DisclosureGroup(isExpanded: $showingSupplyPrivacy) {
                                PrivacyNote { open(.privacy) }.padding(.top, 8)
                            } label: {
                                Label("Private supply inventory", systemImage: "lock.fill").font(.callout).foregroundStyle(.secondary)
                            }
                        } else if tab == .people || tab == .home || tab == .calculators {
                            PrivacyNote { open(.privacy) }
                        } else {
                            KitHeading(eyebrow: "PREPARE", title: "Get ready before you need it.",
                                       subtitle: "Tell Offline Kit about your household and supplies so Ask can give answers that fit you.")
                            PrivacyNote { open(.privacy) }
                        }
                    }
                    PowerOutBanner(onPowerOut: tab == .powerOut) { open(.powerOut) }
                    picker
                    content
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
                .frame(maxWidth: [.supplies, .people, .home, .calculators].contains(tab) ? 1100 : 860, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: focusPerson) {
                guard let id = focusPerson else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    withAnimation { proxy.scrollTo(id, anchor: .top) }
                }
            }
        }
        .defaultScrollAnchor(Self.scrollToBottomForTests ? .bottom : .top)
        .background(Design.canvas)
        .navigationTitle("Prepare")
        .onAppear(perform: follow)
        .onChange(of: navigation.prepareTab) { follow() }
        .onChange(of: tab) {
            if let group = tab.group { lastInGroup[group] = tab }
            if tab != .privacy { KitSettings.shared.set(tab.rawValue, forKey: "lastPrepareTab") }
        }
        .onChange(of: calculator) { KitSettings.shared.set(calculator.rawValue, forKey: "lastCalculator") }
        #if DEBUG
        // Test hook: -prepareTab people opens that tab.
        .task { if let raw = UserDefaults.standard.string(forKey: "prepareTab"), let t = PrepareTab(rawValue: raw) { open(t) } }
        // Test hook: -seedHousehold YES fills an empty test store (OFFLINEKIT_HOME only) with made-up people.
        .task { await household.ensureLoaded(); HouseholdSamples.seedIfAsked(household) }
        #if os(macOS)
        // Test hook: -prepareWindowWidth 820 sizes the window (820 is its minimum), for checking the layout at that width.
        .task {
            let d = UserDefaults.standard
            try? await Task.sleep(for: .milliseconds(600))
            if let width = d.string(forKey: "prepareWindowWidth").flatMap(Double.init), let window = Self.testWindow {
                var frame = window.frame
                frame.size.width = width
                frame.size.height = d.string(forKey: "prepareWindowHeight").flatMap(Double.init) ?? 900
                window.setFrame(frame, display: true)
            }
            // Test hook: -prepareSnapshot /path/name [-prepareSnapshotTabs plan,people] saves /path/name-<tab>.png of the
            // window for each tab (works with the display asleep, unlike screencapture).
            guard let base = d.string(forKey: "prepareSnapshot") else { return }
            let tabs = (d.string(forKey: "prepareSnapshotTabs") ?? tab.rawValue).split(separator: ",")
                .compactMap { PrepareTab(rawValue: String($0)) }
            try? await Task.sleep(for: .seconds(2))
            for item in tabs {
                open(item)
                try? await Task.sleep(for: .milliseconds(1500))
                Self.snapshot(to: "\(base)-\(item.rawValue).png")
            }
            if d.bool(forKey: "prepareSnapshotQuit") { NSApp.terminate(nil) }
        }
        #endif
        #endif
    }

    #if DEBUG && os(macOS)
    private static var testWindow: NSWindow? {
        NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 500 }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    private static func snapshot(to path: String) {
        guard let view = testWindow?.contentView?.superview ?? testWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
    #endif

    // MARK: Plan · Supplies · Tools

    private var picker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Section", selection: Binding<PrepareGroup?>(
                get: { tab.group },
                set: { group in if let group { open(lastInGroup[group] ?? group.tabs[0]) } })) {
                ForEach(PrepareGroup.allCases) { group in
                    Text(segmentLabel(group)).tag(Optional(group))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if let group = tab.group {
                FlowLayout(spacing: 8) {
                    ForEach(group.tabs) { item in chip(item) }
                }
            } else {
                HStack {
                    Label(tab.label, systemImage: tab.symbol).font(.title3.bold())
                    Spacer()
                    Button("Done") { open(beforePrivacy) }.keyboardShortcut(.cancelAction)
                }
            }
        }
    }

    private func segmentLabel(_ group: PrepareGroup) -> String {
        if group == .tools && power.isActive { return "Tools · Power out" }
        let count = group == .supplies ? household.data.extra.suppliesNeedingAttention() : 0
        return count > 0 ? "\(group.label) (\(count))" : group.label
    }

    private func chip(_ item: PrepareTab) -> some View {
        let on = tab == item
        return Button { open(item) } label: {
            Label(item.label, systemImage: item.symbol)
                .badgeCount(item == .supplies ? household.data.extra.suppliesNeedingAttention() : 0)
                .overlay(alignment: .topTrailing) {
                    if item == .powerOut && power.isActive {
                        Circle().fill(Color.red).frame(width: 8, height: 8).offset(x: 9, y: -5)
                            .accessibilityLabel("Power-out mode is on")
                    }
                }
                .font(.callout.weight(.semibold))
                .fixedSize()
                .padding(.horizontal, 14).padding(.vertical, 8)
                .foregroundStyle(on ? Color.white : Design.ink)
                .background(on ? Color.accentColor : Design.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(Design.border, lineWidth: on ? 0 : 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        if household.isLocked && tab.isPrivate {
            if household.unlockPrompting {
                Label("Enter the passphrase in the window that’s open to see this.", systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.secondary).card(padding: 18)
            } else {
                UnlockPrivateDetails(notNow: { open(power.isActive ? .powerOut : .info) }).card(padding: 18)
            }
        } else {
            switch tab {
            case .checklist: ChecklistSection()
            case .powerOut: PowerOutSection { calculator = .water; open(.calculators) }
            case .calculators: CalculatorsSection(selection: $calculator) { open(.powerOut) }
            case .supplies: SuppliesSection()
            case .people: PeopleSection { id in focusPerson = id; open(.plan) }
            case .plan: FamilyPlanSection(focus: $focusPerson) { open(.people) }
            case .guides: SavedGuidesSection()
            case .home: HomeSection { open(.plan) }
            case .info: EmergencyInfoSection()
            case .privacy: AskKnowledgeSection()
            }
        }
    }

    private func open(_ next: PrepareTab) {
        if next == .privacy && tab != .privacy { beforePrivacy = tab }
        tab = next
    }

    /// Test hook: -compactPrepare YES hides the heading so screenshots reach the content without scrolling.
    private static var compactForTests: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "compactPrepare")
        #else
        false
        #endif
    }

    /// Test hook: -scrollPrepareToBottom YES starts scrolled to the end of the tab.
    private static var scrollToBottomForTests: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "scrollPrepareToBottom")
        #else
        false
        #endif
    }

    private func follow() {
        if let next = navigation.prepareTab { open(next); navigation.prepareTab = nil }
    }
}

/// "Power out · 5 h 0 min", above every Prepare screen while power-out mode is on.
struct PowerOutBanner: View {
    @State private var power = PowerOut.shared
    /// Already showing Power out: no "Open" arrow.
    var onPowerOut = false
    let open: () -> Void

    var body: some View {
        if let start = power.start {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let text = "Power out · \(PowerOutSection.duration(context.date.timeIntervalSince(start)))"
                if onPowerOut {
                    bar(text)
                } else {
                    Button(action: open) { bar(text) }
                        .buttonStyle(.plain)
                        .help("Open Power out")
                }
            }
        }
    }

    private func bar(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "bolt.slash.fill")
            Text(text).font(.headline).monospacedDigit()
            Spacer(minLength: 8)
            if !onPowerOut {
                Text("Fridge, freezer and steps").font(.callout).lineLimit(1)
                Image(systemName: "chevron.right").font(.callout.weight(.semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.red, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct PrivacyNote: View {
    @Environment(Household.self) private var household
    @Environment(AskModel.self) private var model
    var openPrivacy: (() -> Void)? = nil

    var body: some View {
        let _ = household.storeChanges
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) { note; Spacer(minLength: 0); button }
            VStack(alignment: .leading, spacing: 8) { note; button }
        }
    }

    private var note: some View {
        Label {
            Text(Self.text(passphrase: PrivateStore.usesPassphrase, homeNetwork: model.usesHomeNetwork))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.fill").foregroundStyle(Color.accentColor)
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: 560, alignment: .leading)
    }

    @ViewBuilder private var button: some View {
        if let openPrivacy {
            Button("Privacy & Ask…", action: openPrivacy).buttonStyle(.bordered).fixedSize()
        }
    }

    static func text(passphrase: Bool, homeNetwork: Bool) -> String {
        let place = PrivateStore.whereText
        let first = passphrase ? "\(place), so it opens on your other Macs. Never shared over Wi-Fi."
                               : "\(place). It’s encrypted, never saved to a kit drive and never shared over Wi-Fi."
        return first + " " + askDestination(homeNetwork: homeNetwork)
    }

    /// Where Ask's copy of these details goes. Usually nowhere; with an Ollama on another computer, that computer.
    static func askDestination(homeNetwork: Bool) -> String {
        homeNetwork ? "When you ask a question, the details Ask uses are sent only to the Ollama computer you chose on your home network."
                    : "Never sent anywhere."
    }
}

struct SectionCard<Content: View>: View {
    let symbol: String
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                KitSymbol(symbol)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
        }
        .card(padding: 18)
    }
}

// MARK: - Checklist

private struct ChecklistSection: View {
    @Environment(Household.self) private var household
    @State private var newItem: [String: String] = [:]
    /// A checklist item being added to Supplies, in the same editor as Add Item.
    @State private var addingSupply: SupplyItem?

    var body: some View {
        @Bindable var household = household
        let items = household.data.checklist
        let have = items.filter(\.have).count
        let categories = Preparedness.categories + Array(Set(items.map(\.category))).filter { !Preparedness.categories.contains($0) }.sorted()

        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text("You have \(have) of \(items.count)").font(.title3.bold())
                ProgressView(value: Double(have), total: Double(max(items.count, 1)))
                Text("Tick what you already have. Ask uses this to work with your supplies and point out what’s missing when it matters. Based on Ready.gov’s basic emergency kit.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                SourceList(sources: [SafetySources.readyKit])
            }
            .card(padding: 18)

            let suggestions = Preparedness.suggestions(for: household.data)
            if !suggestions.isEmpty {
                SectionCard(symbol: "sparkles", title: "Suggested for your household",
                            subtitle: "Based on the people, pets and home you’ve described.") {
                    ForEach(suggestions, id: \.self) { text in
                        HStack {
                            Text(text)
                            Spacer()
                            Button("Add") {
                                household.data.checklist.append(ChecklistItem(id: UUID().uuidString, title: text,
                                                                              category: "For your household", custom: true))
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            ForEach(categories, id: \.self) { category in
                VStack(alignment: .leading, spacing: 6) {
                    Text(category).font(.headline)
                    ForEach($household.data.checklist) { $item in
                        if item.category == category {
                            HStack(spacing: 10) {
                                Toggle(isOn: $item.have) {
                                    Text(item.title).foregroundStyle(item.have ? .secondary : .primary)
                                }
                                .toggleStyle(SquareCheckStyle())
                                if item.have, let starter = Self.offer(for: item, in: household.data) {
                                    Button("Add to Supplies…", systemImage: "shippingbox") { addingSupply = starter }
                                        .buttonStyle(.borderless).font(.callout)
                                        .help("Record how much you have and when it expires")
                                        .accessibilityLabel("Add \(item.title) to Supplies")
                                }
                                if item.custom {
                                    Button(role: .destructive) {
                                        household.data.checklist.removeAll { $0.id == item.id }
                                    } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                                    .help("Remove this item")
                                }
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    HStack {
                        TextField("Add your own item", text: Binding(get: { newItem[category] ?? "" }, set: { newItem[category] = $0 }))
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { add(to: category) }
                        Button("Add") { add(to: category) }
                            .disabled((newItem[category] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 4)
                }
                .card(padding: 18)
            }
        }
        .sheet(item: $addingSupply) { starter in
            SupplyEditor(item: starter, isNew: true).environment(household)
        }
    }

    /// Water and food, once ticked, with nothing in Supplies for them yet: the offer to record the amount and expiry date.
    private static func offer(for item: ChecklistItem, in data: HouseholdData) -> SupplyItem? {
        guard item.id == "water" || item.id == "food", let supply = Preparedness.supply(for: item),
              !data.extra.supplies.contains(where: { $0.category == supply.category }) else { return nil }
        return supply
    }

    private func add(to category: String) {
        let text = (newItem[category] ?? "").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        household.data.checklist.append(ChecklistItem(id: UUID().uuidString, title: text, category: category, custom: true))
        newItem[category] = ""
    }
}

// MARK: - People

private struct PeopleSection: View {
    @Environment(Household.self) private var household
    /// Opens this person's card in Family plan.
    let openCard: (UUID) -> Void
    @State private var viewedPerson: UUID?
    @State private var editingPerson: UUID?
    @State private var wide = false

    var body: some View {
        @Bindable var household = household
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { heading; Spacer(); addButton }
                VStack(alignment: .leading, spacing: 12) { heading; addButton }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { askingAs; askingNote }
                VStack(alignment: .leading, spacing: 8) { askingAs; askingNote }
            }
            if household.data.people.isEmpty {
                ContentUnavailableView("Add your household", systemImage: "person.2",
                                       description: Text("Keep each person’s skills and notes here. Their health details live in Family plan."))
                    .frame(maxWidth: .infinity).card(padding: 18)
            } else if wide {
                HStack(alignment: .top, spacing: 18) {
                    roster.frame(width: 240)
                    profile(viewedPerson ?? household.data.people.first?.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let viewedPerson {
                Button("All people", systemImage: "chevron.left") { self.viewedPerson = nil }.buttonStyle(.borderless)
                profile(viewedPerson)
            } else {
                roster
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { wide = $0 }
        .onChange(of: household.data.people.map(\.id)) {
            if let viewedPerson, !household.data.people.contains(where: { $0.id == viewedPerson }) { self.viewedPerson = nil }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("People").font(.title.bold())
            Text("A household list, with the details Ask can use.").font(.callout).foregroundStyle(.secondary)
        }
    }
    private var addButton: some View {
        Button {
            let person = Person(name: "")
            household.data.people.append(person)
            if household.data.activePersonID == nil { household.data.activePersonID = person.id }
            viewedPerson = person.id
            editingPerson = person.id
        } label: { Label("Add a person", systemImage: "person.badge.plus") }
            .buttonStyle(.borderedProminent)
    }
    private var askingAs: some View {
        @Bindable var household = household
        return Picker("Asking as", selection: $household.data.activePersonID) {
            Text("Not set").tag(UUID?.none)
            ForEach(household.data.people) { Text($0.name.isBlank ? "Unnamed" : $0.name).tag(Optional($0.id)) }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var askingNote: some View {
        Text("Sets who Ask answers for. Viewing a profile below doesn’t change this.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var roster: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Household · \(household.data.people.count)").font(.headline)
            ForEach(household.data.people) { person in
                let selected = (viewedPerson ?? (wide ? household.data.people.first?.id : nil)) == person.id
                Button { viewedPerson = person.id } label: {
                    HStack(spacing: 12) {
                        Text(initials(person.name)).font(.callout.weight(.semibold))
                            .frame(width: 38, height: 38)
                            .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.name.isBlank ? "Unnamed" : person.name).font(.callout.weight(.semibold))
                            Text(person.age.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if !wide { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                    }.padding(10).contentShape(Rectangle())
                        .background(selected ? Color.accentColor.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor.opacity(0.5) : .clear) }
                }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            }
        }.card(padding: 14)
    }
    @ViewBuilder private func profile(_ id: UUID?) -> some View {
        if let id, let person = household.data.people.first(where: { $0.id == id }) {
            PersonCard(person: personBinding(person), card: household.data.card(for: person),
                       initiallyEditing: editingPerson == id, finishedEditing: { editingPerson = nil }, openCard: { openCard(id) }) {
                household.removePerson(id)
            }.id(id)
        }
    }
    private func personBinding(_ person: Person) -> Binding<Person> {
        Binding(get: { household.data.people.first { $0.id == person.id } ?? person }, set: { updated in
            if let index = household.data.people.firstIndex(where: { $0.id == person.id }) { household.data.people[index] = updated }
        })
    }
    private func initials(_ name: String) -> String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

private struct PersonCard: View {
    @Binding var person: Person
    let card: MedicalCard
    let initiallyEditing: Bool
    let finishedEditing: () -> Void
    let openCard: () -> Void
    let onDelete: () -> Void
    @State private var editing = false
    @State private var newSkill = ""
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { identity.frame(minWidth: 180); Spacer(minLength: 0); personActions }
                VStack(alignment: .leading, spacing: 12) { identity; personActions }
            }
            medicalLink
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Skills").font(.subheadline.weight(.semibold))
                Text("Ask gives more hands-on detail for things this person knows how to do.")
                    .font(.caption).foregroundStyle(.secondary)
                if editing {
                    FlowLayout(spacing: 6) {
                        ForEach(Preparedness.skills + person.skills.filter { !Preparedness.skills.contains($0) }, id: \.self) { skill in
                            let on = person.skills.contains(skill)
                            Button {
                                if on { person.skills.removeAll { $0 == skill } } else { person.skills.append(skill) }
                            } label: {
                                Label(skill, systemImage: on ? "checkmark" : "plus")
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .foregroundStyle(on ? Color.white : Design.ink)
                                    .background(on ? Color.accentColor : Color.secondary.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        TextField("Add another skill", text: $newSkill).textFieldStyle(.roundedBorder).onSubmit(addSkill)
                        Button("Add", action: addSkill).disabled(newSkill.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    if person.skills.isEmpty {
                        Text("No skills selected.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(person.skills, id: \.self) { skill in Pill(text: skill, symbol: "checkmark", tint: .accentColor) }
                        }
                    }
                    Button("Choose skills…") { editing = true }.buttonStyle(.bordered)
                }
            }
            Divider()
            if editing {
                field("Anything else Ask should know", "For example: uses a wheelchair, speaks Spanish, works night shifts", text: $person.notes)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Anything else Ask should know").font(.subheadline.weight(.semibold))
                    Text(person.notes.isBlank ? "No notes added." : person.notes).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(person.notes.isBlank ? "Add notes…" : "Edit notes…") { editing = true }.buttonStyle(.bordered)
                }
            }
        }
        .card(padding: 18)
        .onAppear { editing = initiallyEditing }
        .confirmationDialog("Remove \(person.name.isEmpty ? "this person" : person.name)?", isPresented: $confirmDelete) {
            Button("Remove", role: .destructive, action: onDelete)
        } message: {
            Text("Their details, their Family plan medical card and anything Ask noted about them are deleted.")
        }
    }

    @ViewBuilder private var identity: some View {
        if editing {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Name", text: $person.name).font(.title3.bold()).textFieldStyle(.roundedBorder)
                Picker("Age", selection: $person.age) { ForEach(Person.Age.allCases) { Text($0.label).tag($0) } }
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text(person.name.isBlank ? "Unnamed" : person.name).font(.title2.bold())
                Text(person.age.label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            }
        }
    }
    private var personActions: some View {
        HStack(spacing: 10) {
            Button(editing ? "Done" : "Edit person", systemImage: editing ? "checkmark" : "pencil") {
                editing.toggle()
                if !editing { finishedEditing() }
            }.buttonStyle(.bordered)
            Menu {
                Button("Remove person…", role: .destructive) { confirmDelete = true }
            } label: { Image(systemName: "ellipsis") }.accessibilityLabel("More person actions")
        }
    }

    /// Health lives on the person's Family plan card, so it's typed in one place and printed from there.
    private var medicalLink: some View {
        let meds = card.medications.filter { !$0.name.isBlank }.count
        let bits = [card.allergies.isBlank ? nil : "Allergies: \(card.allergies)",
                    card.conditions.isBlank ? nil : "Conditions: \(card.conditions)",
                    meds == 0 ? nil : "\(meds) \(meds == 1 ? "medicine" : "medicines")",
                    person.health.isBlank ? nil : "Notes: \(person.health)"].compactMap { $0 }
        return VStack(alignment: .leading, spacing: 4) {
            Text("Health").font(.subheadline.weight(.semibold))
            Text(bits.isEmpty ? "Allergies, conditions and medicines go on this person’s Family plan card. Ask uses them too."
                              : bits.joined(separator: " · "))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button { openCard() } label: { Label("Open Medical Card in Family Plan", systemImage: "person.text.rectangle") }
                .buttonStyle(.bordered)
        }
    }

    private func addSkill() {
        let skill = newSkill.trimmingCharacters(in: .whitespaces)
        guard !skill.isEmpty, !person.skills.contains(skill) else { return }
        person.skills.append(skill)
        newSkill = ""
    }

    private func field(_ label: String, _ prompt: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.semibold))
            TextField(prompt, text: text, axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
        }
    }
}

// MARK: - Home

private struct HomeSection: View {
    @Environment(Household.self) private var household
    let openPlan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Your home").font(.title.bold())
                Text("Details that help Ask tailor practical answers to your setup.").font(.callout).foregroundStyle(.secondary)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    homeFields.frame(minWidth: 350, maxWidth: .infinity)
                    familyPlanSummary.frame(minWidth: 280, maxWidth: 360)
                }
                VStack(alignment: .leading, spacing: 18) { homeFields; familyPlanSummary }
            }
        }
    }

    private var homeFields: some View {
        @Bindable var household = household
        return VStack(alignment: .leading, spacing: 16) {
            SectionCard(symbol: "house", title: "Location & home") {
                row("Where you live", "City and state, like Springfield, Illinois", $household.data.home.area)
                row("Type of home", "House, apartment, mobile home…", $household.data.home.type)
            }
            SectionCard(symbol: "drop", title: "Utilities & backup") {
                row("Water", "City water, private well…", $household.data.home.water)
                row("Heat", "Natural gas, electric, propane, wood stove…", $household.data.home.heat)
                row("Backup power", "None, portable generator, solar and battery…", $household.data.home.power)
            }
            SectionCard(symbol: "pawprint", title: "Pets & notes") {
                row("Pets", "Two dogs, one cat…", $household.data.home.pets)
                row("Notes", "Anything else about your home", $household.data.home.notes)
            }
        }
    }

    private var familyPlanSummary: some View {
        SectionCard(symbol: "figure.2.and.child.holdinghands", title: "From your Family plan") {
            planSummary("Near home", value: household.data.home.meetingPlace, symbol: "mappin")
            Divider()
            planSummary("Out of area", value: household.data.extra.plan.meetingOutOfArea, symbol: "mappin.and.ellipse")
            Divider()
            planSummary("Contact", value: household.data.home.outOfAreaContact, symbol: "person")
            Button { openPlan() } label: { Label("Open Family plan", systemImage: "arrow.right") }.buttonStyle(.bordered)
            Text("Edit meeting places and contacts there so they stay consistent on printed plans.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func planSummary(_ title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(value.isBlank ? "Not set yet" : value).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(.vertical, 3)
    }

    private func row(_ label: String, _ prompt: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.semibold))
            TextField(prompt, text: text, axis: .vertical).lineLimit(1...3).textFieldStyle(.roundedBorder)
        }
    }


}

// MARK: - Emergency info

struct EmergencyInfoSection: View {
    @Environment(Household.self) private var household
    @State private var name = ""
    @State private var detail = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(EmergencyInfo.groups) { group in
                SectionCard(symbol: group.symbol, title: group.title, subtitle: group.intro) {
                    ForEach(group.entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.title).font(.body.weight(.semibold))
                                if !entry.note.isEmpty {
                                    Text(entry.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer(minLength: 12)
                            #if os(iOS)
                            if let dial = entry.dial, let url = URL(string: "tel:\(dial)") {
                                Link(destination: url) { Label(entry.value, systemImage: "phone.fill") }
                                    .font(.body.weight(.semibold).monospacedDigit())
                            } else {
                                Text(entry.value).font(.body.weight(.semibold).monospacedDigit()).textSelection(.enabled)
                            }
                            #else
                            Text(entry.value).font(.body.weight(.semibold).monospacedDigit()).textSelection(.enabled)
                            #endif
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            Label(EmergencyInfo.radioNote, systemImage: "radio")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .card(padding: 16)
            Label(EmergencyInfo.sourceNote, systemImage: "checkmark.seal")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            SectionCard(symbol: "person.crop.rectangle.stack", title: "Your numbers",
                        subtitle: "Your doctor, pharmacy, utility companies, neighbors, local radio station. \(PrivateStore.whereText).") {
                if household.isLocked {
                    UnlockPrivateDetails(compact: true)
                } else {
                    yourNumbers
                }
            }
        }
    }

    @ViewBuilder private var yourNumbers: some View {
        ForEach(household.data.contacts) { contact in
            HStack {
                Text(contact.name).font(.body.weight(.semibold))
                Spacer()
                Text(contact.detail).monospacedDigit().textSelection(.enabled)
                Button(role: .destructive) { household.data.contacts.removeAll { $0.id == contact.id } } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless).help("Remove")
            }
        }
        ViewThatFits(in: .horizontal) {
            HStack { nameField; detailField; addButton }
            VStack(alignment: .leading) { nameField; detailField; addButton }
        }
    }

    private var nameField: some View { TextField("Name, like Dr. Patel", text: $name).textFieldStyle(.roundedBorder) }
    private var detailField: some View { TextField("Number or frequency", text: $detail).textFieldStyle(.roundedBorder) }
    private var addButton: some View {
        Button("Add") {
            household.data.contacts.append(LocalContact(name: name.trimmingCharacters(in: .whitespaces),
                                                        detail: detail.trimmingCharacters(in: .whitespaces)))
            name = ""; detail = ""
        }
        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || detail.trimmingCharacters(in: .whitespaces).isEmpty)
    }
}

extension EmergencyInfo {
    /// Where the fixed numbers came from (see the note at the top of EmergencyInfo.swift).
    static let sourceNote = "Checked against SAMHSA, CDC, FEMA and National Weather Service pages in November 2026. NOAA Weather Radio channels and range: National Weather Service."
}

// MARK: - What Ask knows

struct AskKnowledgeSection: View {
    @Environment(Household.self) private var household
    @Environment(Library.self) private var library
    @Environment(AskModel.self) private var model
    @State private var newMemory = ""
    @State private var memoryOwner: UUID?
    @State private var confirmErase = false
    @State private var confirmClearHistory = false

    var body: some View {
        if household.isLocked {
            UnlockPrivateDetails().card(padding: 18)
        } else {
            details
        }
    }

    @ViewBuilder private var details: some View {
        @Bindable var household = household
        let _ = household.storeChanges
        let p = household.data.privacy
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(symbol: "slider.horizontal.3", title: "What Ask can use",
                        subtitle: "Turn any of these off at any time. Off means Ask doesn’t see it.") {
                Toggle("Personalize answers", isOn: $household.data.privacy.personalize).font(.body.weight(.semibold))
                Group {
                    Toggle("Household, people, health, skills and shut-off locations", isOn: $household.data.privacy.useHousehold)
                    Toggle("Supplies checklist and what you have in stock", isOn: $household.data.privacy.useChecklist)
                    Toggle("Things Ask has noted", isOn: $household.data.privacy.useMemories)
                    Toggle("Note new facts from questions", isOn: $household.data.privacy.learnMemories)
                }
                .disabled(!p.personalize)
                Toggle("Keep a history of questions and answers", isOn: $household.data.privacy.keepHistory)
            }

            SectionCard(symbol: "eye", title: "Exactly what Ask sees",
                        subtitle: "This text goes with each question you ask on this device, for the person shown. " + (model.usesHomeNetwork ? PrivacyNote.askDestination(homeNetwork: true) : "It never leaves this device.") + " The small on-device model gets a shorter version. Questions from other devices over Wi-Fi never include it.") {
                let text = AskContext.build(household.data, kit: AskModel.kitSummary(library), limit: 4_000)
                Text(text.isEmpty ? "Nothing yet." : text)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            SectionCard(symbol: "brain", title: "Things Ask has noted",
                        subtitle: "Facts you mentioned in questions or added here. Edit or delete any of them.") {
                if household.data.memories.isEmpty {
                    Text("Nothing noted yet.").font(.callout).foregroundStyle(.secondary)
                }
                ForEach($household.data.memories) { $memory in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(household.person(memory.personID)?.name ?? "Household")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                        TextField("Fact", text: $memory.text, axis: .vertical).textFieldStyle(.plain)
                        Button(role: .destructive) { household.forget(memory.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete")
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Picker("About", selection: $memoryOwner) {
                        Text("Household").tag(UUID?.none)
                        ForEach(household.data.people) { Text($0.name.isEmpty ? "Unnamed" : $0.name).tag(Optional($0.id)) }
                    }
                    .labelsHidden().fixedSize()
                    TextField("Add a fact, like “Sam carries an EpiPen”", text: $newMemory).textFieldStyle(.roundedBorder)
                        .onSubmit(addMemory)
                    Button("Add", action: addMemory).disabled(newMemory.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            SectionCard(symbol: "clock.arrow.circlepath", title: "Question history",
                        subtitle: "\(household.data.history.count) saved. \(PrivateStore.whereText).") {
                ForEach(household.data.history.suffix(30).reversed()) { item in
                    DisclosureGroup {
                        Text(item.answer).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Delete", role: .destructive) { household.data.history.removeAll { $0.id == item.id } }
                            .buttonStyle(.borderless).font(.caption)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.question).font(.callout.weight(.medium)).lineLimit(2)
                            Text("\(household.person(item.personID)?.name ?? "Someone") · \(item.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if !household.data.history.isEmpty {
                    Button("Clear History…", role: .destructive) { confirmClearHistory = true }
                        .confirmationDialog("Clear all question history?", isPresented: $confirmClearHistory) {
                            Button("Clear History", role: .destructive) { household.data.history.removeAll() }
                        }
                }
            }

            PassphraseCard()

            VStack(alignment: .leading, spacing: 8) {
                Button(PrivateStore.usesPassphrase ? "Erase This Drive’s Personal Details…" : "Erase All Personal Details…",
                       role: .destructive) { confirmErase = true }
                Text(eraseText)
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .confirmationDialog(PrivateStore.usesPassphrase ? "Erase this drive’s personal details for every Mac?" : "Erase all personal details?",
                                isPresented: $confirmErase) {
                Button("Erase Everything", role: .destructive) {
                    household.eraseEverything()
                    Task { await SupplyAlerts.reschedule(HouseholdRecords()) }   // cancels any expiry reminders
                }
            } message: {
                Text(PrivateStore.usesPassphrase
                     ? "Every Mac that uses this drive loses them. This can’t be undone. Copies of the drive made earlier still hold their own encrypted copy."
                     : "This can’t be undone.")
            }
            if let error = household.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
    }

    private var eraseText: String {
        let what = "people, home, checklist, family plan, supplies, saved guides, noted facts, your numbers and history"
        if PrivateStore.usesPassphrase {
            return "Deletes this drive’s \(what), and its passphrase file, for every Mac that uses this drive. This can’t be undone. What stays: the library, settings, anything you printed or saved as a PDF, earlier copies of the drive, and any separate details this Mac keeps for itself."
        }
        return "Deletes \(what), and the key that protects them. This can’t be undone. The library, settings and anything you printed or saved as a PDF stay."
    }

    private func addMemory() {
        _ = household.remember(newMemory, about: memoryOwner, learned: false)
        newMemory = ""
    }
}
