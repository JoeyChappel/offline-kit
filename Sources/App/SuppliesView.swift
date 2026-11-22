import SwiftUI
import UserNotifications

/// Prepare › Supplies: what's on the shelf, where it is, and when it expires.
struct SuppliesSection: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all, soon, expired
        var id: String { rawValue }
        var label: String {
            switch self {
            case .all: "All"
            case .soon: "Expires soon"
            case .expired: "Expired"
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case expiry, name, category, location
        var id: String { rawValue }
        var label: String {
            switch self {
            case .expiry: "Expiry date"
            case .name: "Name"
            case .category: "Category"
            case .location: "Location"
            }
        }
    }

    @Environment(Household.self) private var household
    @Environment(KitNavigation.self) private var navigation
    @State private var filter: Filter = .all
    @State private var sort: Sort = .expiry
    @State private var category: SupplyCategory?
    @State private var search = ""
    @State private var editing: SupplyItem?
    @State private var alertNote: String?
    @State private var wide = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        @Bindable var household = household
        let all = household.data.extra.supplies
        let expired = all.filter { $0.status() == .expired }.count
        let soon = all.filter { $0.status() == .soon }.count

        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) { inventoryHeading; Spacer(); addButton }
                VStack(alignment: .leading, spacing: 12) { inventoryHeading; addButton }
            }
            Picker("Show", selection: $filter) {
                ForEach(Filter.allCases) { item in
                    Text("\(item.label) (\(item == .all ? all.count : item == .soon ? soon : expired))").tag(item)
                }
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 600)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    searchField.frame(minWidth: 230)
                    categoryMenu.fixedSize()
                    sortMenu.fixedSize()
                }
                VStack(alignment: .leading, spacing: 12) {
                    searchField
                    FlowLayout(spacing: 12) { categoryMenu; sortMenu }
                }
            }

            let items = visible(all)
            if all.isEmpty {
                ContentUnavailableView {
                    Label("No supplies yet", systemImage: "shippingbox")
                } description: {
                    Text("Add water, food, medicine and batteries with their expiry dates, and Offline Kit can remind you before they go bad.")
                } actions: {
                    // What the family ticked in the checklist can start the list; they fill in amounts and dates after.
                    let starters = Preparedness.supplyStarters(from: household.data.checklist)
                    if !starters.isEmpty {
                        Button("Start from my checklist (\(starters.count))", systemImage: "checklist") {
                            household.data.extra.supplies.append(contentsOf: starters)
                        }
                        .buttonStyle(.borderedProminent)
                        .help("Adds what you ticked in the Checklist. Then set each amount, place and expiry date.")
                    } else {
                        Button("Open Checklist", systemImage: "arrow.right") { navigation.prepare(.checklist) }
                    }
                }
                .frame(maxWidth: .infinity).card(padding: 18)
            } else if items.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("No supplies match these filters.").foregroundStyle(.secondary)
                    Button("Clear filters") { filter = .all; category = nil; search = "" }.buttonStyle(.borderless)
                }.frame(maxWidth: .infinity, alignment: .leading).card(padding: 18)
            } else {
                VStack(spacing: 0) {
                    if wide { tableHeading; Divider() }
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider() }
                        SupplyRow(item: item, columns: wide) { editing = item }
                    }
                }
                .card(padding: 6)
            }
            DisclosureGroup {
                alertsControls.padding(.top, 12)
            } label: {
                Label(household.data.extra.supplyAlerts.enabled
                      ? "Expiry reminders on · \(household.data.extra.supplyAlerts.leadDays) days before"
                      : "Expiry reminders are off", systemImage: "bell")
                    .font(.callout)
            }.card(padding: 16)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { checklistNote; Spacer(); checklistButton }
                VStack(alignment: .leading, spacing: 10) { checklistNote; checklistButton }
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 760 } action: { wide = $0 }
        .findShortcut($searchFocused)
        .sheet(item: $editing) { item in
            SupplyEditor(item: item, isNew: !all.contains { $0.id == item.id })
                .environment(household)
        }
        .task(id: alertSignature) { await SupplyAlerts.reschedule(household.data.extra) }
        #if DEBUG
        .onAppear { if let raw = UserDefaults.standard.string(forKey: "supplyFilter"), let f = Filter(rawValue: raw) { filter = f } }
        // Test hook: -openSupplyEditor YES opens Add Item (with -autoScan YES it also opens the scanner).
        .task {
            guard UserDefaults.standard.bool(forKey: "openSupplyEditor") else { return }
            try? await Task.sleep(for: .seconds(1))
            var item = SupplyItem()
            item.barcode = UserDefaults.standard.string(forKey: "testBarcode") ?? ""
            editing = item
        }
        #endif
    }

    private var inventoryHeading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Your supplies").font(.title.bold())
            Text("What you have, where it is, and when to replace it.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var addButton: some View {
        Button { editing = SupplyItem() } label: { Label("Add Item", systemImage: "plus") }
            .buttonStyle(.borderedProminent).controlSize(.large)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search supplies", text: $search).textFieldStyle(.plain).focused($searchFocused)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear supply search")
            }
        }.padding(10)
            .background(Design.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).stroke(Design.border) }
    }

    private var categoryMenu: some View {
        Menu {
            Picker("Category", selection: $category) {
                Text("All categories").tag(SupplyCategory?.none)
                ForEach(SupplyCategory.allCases) { Label($0.label, systemImage: $0.symbol).tag(Optional($0)) }
            }
        } label: { Text("Category: \(category?.label ?? "All")") }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) { ForEach(Sort.allCases) { Text($0.label).tag($0) } }
        } label: { Text("Sort: \(sort.label)") }
    }

    private var tableHeading: some View {
        HStack(spacing: 12) {
            Text("Item").frame(maxWidth: .infinity, alignment: .leading)
            Text("Amount").frame(width: 90, alignment: .leading)
            Text("Location").frame(width: 140, alignment: .leading)
            Text("Expiry").frame(width: 150, alignment: .leading)
            Color.clear.frame(width: 12, height: 1)
        }.font(.caption.weight(.medium)).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 10)
    }

    private var checklistNote: some View {
        Text("Checklist tracks what you need. Supplies tracks what you already have.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var checklistButton: some View {
        Button("Open Checklist", systemImage: "arrow.right") { navigation.prepare(.checklist) }.buttonStyle(.borderless)
    }

    /// Changes that affect reminders.
    private var alertSignature: String {
        let extra = household.data.extra
        return "\(extra.supplyAlerts.enabled)-\(extra.supplyAlerts.leadDays)-" +
            extra.supplies.map { "\($0.id)\($0.name)\($0.expires?.timeIntervalSince1970 ?? 0)\($0.category.rawValue)" }.joined()
    }

    @ViewBuilder private var alertsControls: some View {
        @Bindable var household = household
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { household.data.extra.supplyAlerts.enabled }, set: { on in
                Task {
                    if on, !(await SupplyAlerts.requestPermission()) {
                        alertNote = "Notifications are off for Offline Kit. Turn them on in System Settings › Notifications, then try again."
                        return
                    }
                    alertNote = nil
                    household.data.extra.supplyAlerts.enabled = on
                }
            })) {
                Label("Remind me before things expire", systemImage: "bell.badge")
            }
            if household.data.extra.supplyAlerts.enabled {
                Picker("First reminder", selection: $household.data.extra.supplyAlerts.leadDays) {
                    Text("1 week before").tag(7)
                    Text("2 weeks before").tag(14)
                    Text("30 days before").tag(30)
                    Text("60 days before").tag(60)
                }
                .fixedSize()
                Text("Another reminder comes on the day itself. Reminders for medicines don’t name the medicine, so it can’t show on a locked screen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let alertNote {
                Label(alertNote, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func visible(_ all: [SupplyItem]) -> [SupplyItem] {
        var items = all
        switch filter {
        case .all: break
        case .soon: items = items.filter { $0.status() == .soon }
        case .expired: items = items.filter { $0.status() == .expired }
        }
        if let category { items = items.filter { $0.category == category } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            items = items.filter { [$0.name, $0.location, $0.notes, $0.unit, $0.category.label].contains { $0.localizedCaseInsensitiveContains(q) } }
        }
        let byName: (SupplyItem, SupplyItem) -> Bool = { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        switch sort {
        case .expiry:
            items.sort { ($0.expires ?? .distantFuture, $0.name.lowercased()) < ($1.expires ?? .distantFuture, $1.name.lowercased()) }
        case .name: items.sort(by: byName)
        case .category: items.sort { $0.category == $1.category ? byName($0, $1) : SupplyCategory.allCases.firstIndex(of: $0.category)! < SupplyCategory.allCases.firstIndex(of: $1.category)! }
        case .location: items.sort { $0.location.lowercased() == $1.location.lowercased() ? byName($0, $1) : $0.location.localizedStandardCompare($1.location) == .orderedAscending }
        }
        return items
    }
}

private struct SupplyRow: View {
    let item: SupplyItem
    var columns = false
    let edit: () -> Void

    var body: some View {
        Button(action: edit) {
            HStack(spacing: 12) {
                Image(systemName: item.category.symbol)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                if columns {
                    Text(item.name.isBlank ? "Unnamed item" : item.name).font(.body.weight(.semibold))
                        .foregroundStyle(Design.ink).frame(maxWidth: .infinity, alignment: .leading)
                    Text(item.amount).font(.callout).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                    Text(item.location.isBlank ? "Not set" : item.location).font(.callout).foregroundStyle(.secondary)
                        .frame(width: 140, alignment: .leading)
                    ExpiryBadge(item: item).frame(width: 150, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.name.isBlank ? "Unnamed item" : item.name).font(.body.weight(.semibold)).foregroundStyle(Design.ink)
                        Text([item.amount, item.location].filter { !$0.isBlank }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        ExpiryBadge(item: item)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).frame(width: 12)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }
}

private struct ExpiryBadge: View {
    let item: SupplyItem
    var body: some View {
        let status = item.status()
        let tint: Color = switch status {
        case .expired: .red
        case .soon: .orange
        default: .secondary
        }
        Text(item.expiryText())
            .font(.caption.weight(status <= .soon ? .semibold : .regular))
            .foregroundStyle(tint)
            .multilineTextAlignment(.trailing)
    }
}

// MARK: - Editor

struct SupplyEditor: View {
    @Environment(Household.self) private var household
    @Environment(\.dismiss) private var dismiss
    @State var item: SupplyItem
    let isNew: Bool
    @State private var quantityText = ""
    @State private var scanning = false
    @State private var lookingUp = false
    @State private var lookupNote: String?
    @State private var foundOnline: ProductLookup.Product?
    @State private var confirmDelete = false

    init(item: SupplyItem, isNew: Bool) {
        _item = State(initialValue: item)
        self.isNew = isNew
        _quantityText = State(initialValue: item.quantity.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $item.name)
                    Picker("Category", selection: $item.category) {
                        ForEach(SupplyCategory.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                    }
                    LabeledContent("Amount") {
                        HStack {
                            TextField("Quantity", text: $quantityText, prompt: Text("1"))
                                .labelsHidden().frame(maxWidth: 70)
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            TextField("Unit", text: $item.unit, prompt: Text("cans, gallons…")).labelsHidden()
                        }
                        .multilineTextAlignment(.trailing)
                    }
                    TextField("Where it’s kept", text: $item.location, prompt: Text("Pantry, garage shelf…"))
                }
                Section("Expiry") {
                    Toggle("Has an expiry date", isOn: Binding(get: { item.expires != nil }, set: { on in
                        item.expires = on ? Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .year, value: 1, to: .now) ?? .now) : nil
                    }))
                    if let expires = item.expires {
                        DatePicker("Expires", selection: Binding(get: { expires }, set: { item.expires = Calendar.current.startOfDay(for: $0) }),
                                   displayedComponents: .date)
                    }
                }
                barcodeSection
                Section("Notes") {
                    TextField("Rotation reminders, lot numbers…", text: $item.notes, axis: .vertical).lineLimit(2...5)
                }
                if !isNew {
                    Section {
                        Button("Delete Item", role: .destructive) { confirmDelete = true }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "Add Item" : "Edit Item")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Add" : "Save", action: save).disabled(item.name.isBlank)
                }
            }
            .confirmationDialog("Delete \(item.name.isBlank ? "this item" : item.name)?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) {
                    household.data.extra.supplies.removeAll { $0.id == item.id }
                    dismiss()
                }
            }
            #if DEBUG
            .task {
                if !item.barcode.isEmpty { useBarcode(item.barcode) }
                #if os(iOS)
                if UserDefaults.standard.bool(forKey: "autoScan") { try? await Task.sleep(for: .seconds(1)); scanning = true }
                #endif
            }
            #endif
            #if os(iOS)
            .sheet(isPresented: $scanning) {
                BarcodeScanSheet { code in
                    scanning = false
                    useBarcode(code)
                }
            }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }

    @ViewBuilder private var barcodeSection: some View {
        Section {
            HStack {
                TextField("Barcode", text: $item.barcode)
                    #if os(iOS)
                    .keyboardType(.numberPad)
                    #endif
                    .onSubmit { useBarcode(item.barcode) }
                #if os(iOS)
                Button { scanning = true } label: { Label("Scan", systemImage: "barcode.viewfinder") }
                    .buttonStyle(.bordered)
                #endif
            }
            if let known = knownName, known != item.name {
                Button("Use “\(known)” (named before)") { item.name = known }
            }
            if ProductLookup.normalize(item.barcode) != nil {
                HStack {
                    Button { Task { await lookUp() } } label: { Label("Look Up Name Online", systemImage: "globe") }
                        .disabled(lookingUp)
                    if lookingUp { ProgressView().controlSize(.small) }
                }
            }
            if let foundOnline {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Name from Open Food Facts, under the Open Database License.")
                    if let url = foundOnline.pageURL { Link("View on openfoodfacts.org", destination: url) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            if let lookupNote {
                Text(lookupNote).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Barcode")
        } footer: {
            Text("Offline Kit remembers the name you give each barcode, so the next scan fills it in with no internet. “Look Up Name Online” sends only the barcode to Open Food Facts, and only when you tap it.")
        }
    }

    private var knownName: String? {
        guard let code = ProductLookup.normalize(item.barcode) ?? (item.barcode.isBlank ? nil : item.barcode) else { return nil }
        return household.data.extra.barcodeNames[code]
    }

    private func useBarcode(_ code: String) {
        item.barcode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        foundOnline = nil
        lookupNote = nil
        if item.name.isBlank, let known = knownName { item.name = known }
    }

    private func lookUp() async {
        lookingUp = true
        defer { lookingUp = false }
        lookupNote = nil
        do {
            let product = try await ProductLookup.lookUp(item.barcode)
            item.name = product.name
            foundOnline = product
        } catch {
            lookupNote = error.localizedDescription
        }
    }

    private func save() {
        item.name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Double(quantityText.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        item.quantity = max(0, parsed ?? item.quantity)
        var extra = household.data.extra
        if let index = extra.supplies.firstIndex(where: { $0.id == item.id }) { extra.supplies[index] = item }
        else { extra.supplies.append(item) }
        let code = ProductLookup.normalize(item.barcode) ?? item.barcode.trimmingCharacters(in: .whitespaces)
        if !code.isEmpty, !item.name.isEmpty { extra.barcodeNames[code] = item.name }
        household.data.extra = extra
        dismiss()
    }
}

// MARK: - Reminders

/// Local notifications before supplies expire. Scheduled on this device only; nothing leaves it.
enum SupplyAlerts {
    static let prefix = "supply-expiry-"
    /// iOS keeps at most 64 pending notifications per app; leave room for others.
    static let maximum = 50

    static func requestPermission() async -> Bool {
        guard !PowerOutAlerts.isTestRun else { return true }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .denied: return false
        default: return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func reschedule(_ records: HouseholdRecords, now: Date = .now) async {
        // Test runs (OFFLINEKIT_HOME) share the real app's bundle ID, so they leave its notifications alone.
        guard !PowerOutAlerts.isTestRun else { return }
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        guard records.supplyAlerts.enabled else { return }
        let settings = await center.notificationSettings()
        guard [.authorized, .provisional].contains(settings.authorizationStatus) else { return }

        var requests: [(Date, UNNotificationRequest)] = []
        let calendar = Calendar.current
        for item in records.supplies {
            guard let expires = item.expires else { continue }
            let early = calendar.date(byAdding: .day, value: -records.supplyAlerts.leadDays, to: expires)
            for (when, isDay) in [(early, false), (Optional(expires), true)] {
                guard let day = when, let fire = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day), fire > now else { continue }
                let content = UNMutableNotificationContent()
                let dateText = expires.formatted(.dateTime.month(.abbreviated).day())
                let what = item.category == .medicine ? "A medicine in your kit" : item.name
                content.title = isDay ? "Expires today" : "Expires soon"
                content.body = isDay ? "\(what) expires today. Open Prepare › Supplies to replace it."
                                     : "\(what) expires on \(dateText). Open Prepare › Supplies to plan a replacement."
                content.sound = .default
                let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
                let request = UNNotificationRequest(identifier: "\(prefix)\(item.id.uuidString)-\(isDay ? "day" : "early")",
                                                    content: content,
                                                    trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
                requests.append((fire, request))
            }
        }
        for (_, request) in requests.sorted(by: { $0.0 < $1.0 }).prefix(maximum) {
            try? await center.add(request)
        }
    }
}

extension View {
    /// A small red count after a label, hidden at zero (for the Supplies chip in Prepare).
    func badgeCount(_ count: Int) -> some View {
        HStack(spacing: 6) {
            self
            if count > 0 {
                Text("\(count)")
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.red, in: Capsule())
                    .accessibilityLabel("\(count) need attention")
            }
        }
    }
}
