import SwiftUI

/// Prepare › Calculators: water disinfection, generator load, solar and battery sizing, unit conversions.
/// Each shows its formula and assumptions, and any safety figure carries its official source.
enum Calculator: String, CaseIterable, Identifiable {
    case water, generator, solar, units
    var id: String { rawValue }
    var label: String {
        switch self {
        case .water: "Water disinfection"
        case .generator: "Generator load"
        case .solar: "Solar and battery"
        case .units: "Unit conversions"
        }
    }
    var symbol: String {
        switch self {
        case .water: "drop"
        case .generator: "bolt.fill"
        case .solar: "sun.max"
        case .units: "arrow.left.arrow.right"
        }
    }
}

struct CalculatorsSection: View {
    @Binding var selection: Calculator
    /// Opens Power out, for its generator safety section.
    let openPowerOut: () -> Void

    @State private var wide = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Calculators").font(.title.bold())
                Text("Choose a tool, then work with its inputs and results.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                if wide { toolList.frame(width: 230) }
                VStack(alignment: .leading, spacing: 16) {
                    if !wide {
                        Picker("Tool", selection: $selection) {
                            ForEach(Calculator.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        }.pickerStyle(.menu)
                    }
                    calculator
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onGeometryChange(for: Bool.self) { $0.size.width >= 900 } action: { wide = $0 }
        #if DEBUG
        // Test hook: -calculator generator opens that calculator.
        .task { if let raw = UserDefaults.standard.string(forKey: "calculator"), let c = Calculator(rawValue: raw) { selection = c } }
        #endif
    }

    private var toolList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Tools").font(.headline).padding(.bottom, 4)
            ForEach(Calculator.allCases) { tool in
                let on = tool == selection
                Button { selection = tool } label: {
                    Label(tool.label, systemImage: tool.symbol).font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        .foregroundStyle(on ? Color.white : Design.ink)
                        .background(on ? Color.accentColor : Design.canvas, in: RoundedRectangle(cornerRadius: 9))
                        .overlay { RoundedRectangle(cornerRadius: 9).stroke(on ? Color.clear : Design.border) }
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }.card(padding: 14)
    }

    @ViewBuilder private var calculator: some View {
        switch selection {
        case .water: WaterCalculator()
        case .generator: GeneratorCalculator(openPowerOut: openPowerOut)
        case .solar: SolarCalculator()
        case .units: UnitsCalculator()
        }
    }

}

// MARK: - Shared pieces

/// The capsule row used for Prepare's tabs, for any list of choices.
struct ChipRow<Item: Hashable & Identifiable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: KeyPath<Item, String>
    let symbol: KeyPath<Item, String>

    var body: some View {
        // Wraps onto a second line rather than scrolling, so no choice is ever cut off at narrow widths.
        FlowLayout(spacing: 8) {
            ForEach(items) { item in
                let on = item == selection
                Button { selection = item } label: {
                    Label(item[keyPath: label], systemImage: item[keyPath: symbol])
                        .font(.callout.weight(.semibold))
                        .fixedSize()
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .foregroundStyle(on ? Color.white : Design.ink)
                        .background(on ? Color.accentColor : Design.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(Design.border, lineWidth: on ? 0 : 0.5))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}

/// A number field that updates its value on every keystroke. `TextField(value:format:)` only commits on
/// Return or focus loss on macOS, which made the calculators look frozen while typing.
/// The text stays as typed while editing; it is rewritten only when the value changes from elsewhere.
struct LiveNumberField: View {
    let prompt: String
    @Binding var value: Double?
    var digits: ClosedRange<Int> = 0...3
    var allowNegative = false
    @State private var text = ""
    @State private var started = false

    private var format: FloatingPointFormatStyle<Double> { .number.precision(.fractionLength(digits)) }

    var body: some View {
        TextField(prompt, text: $text)
            .onAppear {
                guard !started else { return }
                started = true
                text = value.map { format.format($0) } ?? ""
            }
            .onChange(of: text) {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { if value != nil { value = nil }; return }
                // Locale-aware, so "1,5" works where the decimal separator is a comma. Half-typed text is ignored.
                guard let parsed = try? format.parseStrategy.parse(trimmed), parsed.isFinite else { return }
                let clean = allowNegative ? parsed : abs(parsed)
                if value != clean { value = clean }
            }
            .onChange(of: value) {
                // Changed from elsewhere (a reset, a saved value): show it. Skip when it already matches the text.
                let shown = text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try? format.parseStrategy.parse(text.trimmingCharacters(in: .whitespaces))
                if shown != value { text = value.map { format.format($0) } ?? "" }
            }
    }
}

/// A labeled number box. Empty or invalid text reads as nil.
struct NumberInput: View {
    let label: String
    @Binding var value: Double?
    var unit: String = ""
    var prompt: String = ""
    var width: CGFloat = 110
    /// Amounts, watts and hours can't be negative; temperatures can.
    var allowNegative = false

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            Spacer(minLength: 8)
            LiveNumberField(prompt: prompt, value: $value, digits: 0...3, allowNegative: allowNegative)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
            if !unit.isEmpty {
                Text(unit).foregroundStyle(.secondary).frame(minWidth: 34, alignment: .leading)
            }
        }
    }
}

/// The big answer at the top of a calculator.
struct ResultLine: View {
    let value: String
    let caption: String
    var tint: Color = .accentColor
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(tint)
                .contentTransition(.numericText())
            Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "How it's worked out": the formula, what it assumes, and where any safety figure came from.
struct FormulaNote: View {
    let formula: [String]
    let assumptions: [String]
    var sources: [SafetySource] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How it’s worked out").font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(formula, id: \.self) { line in
                    Text(line).font(.system(.callout, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            if !assumptions.isEmpty {
                Text("Assumptions").font(.subheadline.weight(.semibold))
                BulletList(items: assumptions)
            }
            if !sources.isEmpty { SourceList(sources: sources) }
        }
        .font(.callout)
    }
}

struct BulletList: View {
    let items: [String]
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    Text(item).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Where a safety figure came from and when it was checked. Links open in the browser when online.
struct SourceList: View {
    let sources: [SafetySource]
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sources) { source in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "checkmark.seal").foregroundStyle(Color.accentColor).imageScale(.small)
                    if let url = source.link {
                        Link("\(source.publisher): \(source.title)", destination: url)
                    } else {
                        Text("\(source.publisher): \(source.title)")
                    }
                }
                .font(.caption)
            }
            Text("Checked \(SafetySources.checkedOn). Links need internet.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Calculator inputs kept in settings, like the generator's appliance list, so switching tabs or quitting doesn't lose them.
enum CalculatorMemory {
    static func load<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let json = KitSettings.shared.string(forKey: key), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        KitSettings.shared.set(String(decoding: data, as: UTF8.self), forKey: key)
    }
}

private func formatted(_ value: Double, digits: Int = 0) -> String {
    value.formatted(.number.precision(.fractionLength(0...digits)))
}

// MARK: - Water disinfection

private struct WaterInput: Codable, Equatable {
    var amount: Double? = 1
    var liters = false
    var cloudy = false
    var strengthID = WaterDisinfection.strengths[0].id
    static let key = "calculatorWater"
}

private struct WaterCalculator: View {
    @State private var input = CalculatorMemory.load(WaterInput.key, as: WaterInput.self) ?? WaterInput()

    private var strength: WaterDisinfection.Strength {
        WaterDisinfection.strengths.first { $0.id == input.strengthID } ?? WaterDisinfection.strengths[0]
    }

    var body: some View {
        let liters = input.liters, cloudy = input.cloudy, amount = max(0, input.amount ?? 0)
        let perUnit = liters ? strength.dropsPerLiter : strength.dropsPerGallon
        let drops = amount * perUnit * (cloudy ? 2 : 1)
        SectionCard(symbol: "drop", title: "Disinfect water with bleach",
                    subtitle: "For when you can’t boil it (a rolling boil for at least 1 minute). Use plain, unscented household bleach.") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    NumberInput(label: "Water", value: $input.amount)
                    Picker("Unit", selection: $input.liters) {
                        Text("gallons").tag(false)
                        Text("liters").tag(true)
                    }
                    .labelsHidden().fixedSize()
                }
                Picker("The water is", selection: $input.cloudy) {
                    Text("Clear").tag(false)
                    Text("Cloudy, colored or very cold").tag(true)
                }
                .pickerStyle(.segmented)
                Picker("Bleach strength on the label", selection: $input.strengthID) {
                    ForEach(WaterDisinfection.strengths) { Text($0.label).tag($0.id) }
                }
            }
            Divider()
            // For EPA's own rows (2, 4 and 8 gallons) show EPA's measure: its teaspoon figures come out lower than
            // 8 drops a gallon, and the result shouldn't disagree with the table printed below it.
            let row = liters ? nil : WaterDisinfection.tableRows.first { $0.water == "\(formatted(amount, digits: 2)) gallons" }
            let measure = row.map { strength.id == "6" ? $0.six : $0.eight }
            ResultLine(value: measure.map { cloudy ? "2 × \($0)" : $0 } ?? "\(formatted(drops.rounded(.up))) drops",
                       caption: "of \(strength.percent) bleach for \(formatted(amount, digits: 2)) \(unitName(amount)) of \(cloudy ? "cloudy, colored or very cold" : "clear") water"
                        + (measure != nil ? ", from EPA’s table. " : ". ") + WaterDisinfection.afterAdding)
            if liters && strength.dropsPerGallon / strength.dropsPerLiter < 3.785 {
                Label("EPA rounds its liter figure up, so liters get a little more bleach than the gallon figure works out to. Both are EPA’s own numbers.",
                      systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if cloudy {
                Label(WaterDisinfection.cloudyFirst, systemImage: "line.3.horizontal.decrease")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Label(WaterDisinfection.warning, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            Divider()
            FormulaNote(
                formula: [
                    "drops = amount × \(formatted(perUnit, digits: 2)) drops per \(liters ? "liter" : "gallon")"
                        + (cloudy ? " × 2 (cloudy, colored or cold)" : ""),
                    "rounded up to a whole drop",
                ],
                assumptions: WaterDisinfection.assumptions,
                sources: [SafetySources.epaBleach])
            EPABleachTable()
        }
        .onChange(of: input) { CalculatorMemory.save(input, WaterInput.key) }
    }
}

extension WaterCalculator {
    fileprivate func unitName(_ n: Double) -> String {
        n == 1 ? (input.liters ? "liter" : "gallon") : (input.liters ? "liters" : "gallons")
    }
}

// MARK: - Generator load

private struct GeneratorRating: Codable, Equatable {
    static let key = "calculatorGenerator"
    var running: Double?
    var surge: Double?
}

private struct GeneratorCalculator: View {
    let openPowerOut: () -> Void
    @State private var store = ApplianceStore()
    @State private var rating = CalculatorMemory.load(GeneratorRating.key, as: GeneratorRating.self) ?? GeneratorRating()
    private var running: Double? { rating.running }
    private var surge: Double? { rating.surge }
    @State private var newName = ""

    var body: some View {
        let picked = store.items.filter(\.on)
        let totalRunning = picked.reduce(0) { $0 + $1.running * Double($1.count) }
        let biggestExtra = picked.map(\.extra).max() ?? 0
        let peak = totalRunning + biggestExtra
        VStack(alignment: .leading, spacing: 16) {
            SectionCard(symbol: "bolt.fill", title: "What can my generator run?",
                        subtitle: "Pick what you’ll plug in. Wattages are typical; check your appliance’s label and change them to match.") {
                NumberInput(label: "Generator running (rated) watts", value: $rating.running, unit: "W", prompt: "On its label")
                NumberInput(label: "Generator starting (surge) watts", value: $rating.surge, unit: "W", prompt: "On its label")
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) { safetyLine; Spacer(minLength: 0); safetyButton }
                    VStack(alignment: .leading, spacing: 6) { safetyLine; safetyButton }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    ResultLine(value: "\(formatted(totalRunning)) W running",
                               caption: "Peak while the biggest motor starts: \(formatted(peak)) W.")
                    if let running, running > 0 {
                        let share = totalRunning / running
                        ProgressView(value: min(share, 1)).tint(share > 1 ? .red : .accentColor)
                        // No surge figure: count it as the running watts, so the words and the color always agree.
                        let surgeCap = (surge ?? 0) > 0 ? surge! : running
                        Text(verdict(running: running, surge: surge, total: totalRunning, peak: peak))
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(totalRunning > running || peak > surgeCap ? Color.red : Design.ink)
                    } else {
                        Text("Enter your generator’s watts to compare.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }

            SectionCard(symbol: "powerplug", title: "Appliances", subtitle: "Running watts keep it going. Extra to start is the short surge on top of that when a motor kicks on.") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("").gridColumnAlignment(.leading)
                        Text("Running W").font(.caption).foregroundStyle(.secondary)
                        Text("Extra to start W").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach($store.items) { $item in
                        GridRow {
                            HStack(spacing: 8) {
                                Button { item.on.toggle() } label: {
                                    Image(systemName: item.on ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(item.on ? Color.accentColor : .secondary).imageScale(.large)
                                }
                                .buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).lineLimit(2)
                                    if item.on {
                                        Stepper("× \(item.count)", value: $item.count, in: 1...20).font(.caption).fixedSize()
                                    }
                                }
                                if item.custom {
                                    Button(role: .destructive) { store.items.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }
                                        .buttonStyle(.borderless).help("Remove")
                                }
                            }
                            wattField($item.running)
                            wattField($item.extra)
                        }
                    }
                }
                HStack {
                    TextField("Add an appliance", text: $newName).textFieldStyle(.roundedBorder).onSubmit(add)
                    Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Text("Typical; check your appliance’s label.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Wattages") { store.reset() }.buttonStyle(.borderless).font(.caption)
                }
                Divider()
                FormulaNote(
                    formula: [
                        "running = Σ (running W × how many)",
                        "peak = running + the largest extra-to-start",
                    ],
                    assumptions: [
                        "Start the appliance with the biggest surge first, then add the rest one at a time, so only one motor starts at once.",
                        "Generator ratings come from its label or manual. Running (rated) watts is what it can supply continuously.",
                        "Appliances without a surge (heaters, lights, electronics) have no extra to start.",
                        "The wattages here are typical values from \(ApplianceWatts.sourceName). Your appliance’s label or manual is the real number.",
                    ],
                    sources: ApplianceWatts.sources)
            }
        }
        .onChange(of: store.items) { store.save() }
        .onChange(of: rating) { CalculatorMemory.save(rating, GeneratorRating.key) }
    }

    private func verdict(running: Double, surge: Double?, total: Double, peak: Double) -> String {
        if total > running { return "Too much: \(formatted(total - running)) W over what it can run. Unplug something." }
        let known = (surge ?? 0) > 0
        let cap = known ? surge! : running
        if peak > cap {
            return known ? "Running load fits, but starting the biggest motor needs \(formatted(peak - cap)) W more surge than it has."
                         : "Running load fits, but starting the biggest motor needs \(formatted(peak - cap)) W more than its running watts. Enter its surge watts from the label to check."
        }
        return "Fits: \(formatted(total / running * 100))% of its running watts."
    }

    /// CDC: generators go outside, far from the house's openings.
    private var safetyLine: some View {
        Label("Run it outside, more than 20 feet from the house’s windows, doors and vents. Never in a garage, even with the door open.",
              systemImage: "exclamationmark.triangle.fill")
            .font(.callout.weight(.medium)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
    }

    private var safetyButton: some View {
        Button("Generator Safety", action: openPowerOut).buttonStyle(.bordered).fixedSize()
            .help("Power out › Generator safety and carbon monoxide (CDC, CPSC)")
    }

    private func wattField(_ value: Binding<Double>) -> some View {
        // Watts can't be negative, and the field updates as you type.
        LiveNumberField(prompt: "W", value: Binding<Double?>(get: { value.wrappedValue },
                                                             set: { value.wrappedValue = max(0, $0 ?? 0) }),
                        digits: 0...0)
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 82)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.items.append(Appliance(id: UUID().uuidString, name: name, running: 0, extra: 0, on: true, custom: true))
        newName = ""
    }
}

struct Appliance: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var running: Double
    var extra: Double
    var on = false
    var count = 1
    var custom = false
}

/// The appliance list with the user's edits, kept in settings.
@MainActor @Observable
final class ApplianceStore {
    private static let key = "generatorAppliances"
    var items: [Appliance]

    init() {
        if let json = KitSettings.shared.string(forKey: Self.key), let data = json.data(using: .utf8),
           let saved = try? JSONDecoder().decode([Appliance].self, from: data) {
            // Keep the user's edits; pick up any typical appliances added in a later version.
            let known = Set(saved.map(\.id))
            items = saved + ApplianceWatts.defaults.filter { !known.contains($0.id) }
        } else {
            items = ApplianceWatts.defaults
        }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        KitSettings.shared.set(String(decoding: data, as: UTF8.self), forKey: Self.key)
    }

    func reset() {
        let custom = items.filter(\.custom)
        items = ApplianceWatts.defaults + custom
    }
}

// MARK: - Solar and battery

private struct SolarInput: Codable, Equatable {
    var loads: [SolarLoad] = [SolarLoad(name: "Refrigerator"), SolarLoad(name: "Lights"), SolarLoad(name: "Phones")]
    var typedDaily: Double? = nil
    var days: Double? = 1
    var usable: Double? = nil
    var volts: Double = 12
    var sunHours: Double? = nil
    var losses: Double? = SolarDefaults.systemLossesPercent
    static let key = "calculatorSolar"
}

private struct SolarCalculator: View {
    @State private var input = CalculatorMemory.load(SolarInput.key, as: SolarInput.self) ?? SolarInput()

    var body: some View {
        let loads = input.loads, volts = input.volts, sunHours = input.sunHours, usable = input.usable
        let fromLoads = loads.reduce(0) { $0 + max(0, $1.watts ?? 0) * max(0, $1.hours ?? 0) }
        let daily = input.typedDaily ?? fromLoads
        let usableOK = usable.map { $0 > 0 && $0 <= 100 } ?? true
        let usableFraction = min(1, max(0.01, (usable ?? 100) / 100))
        let batteryWh = daily * (input.days ?? 1) / usableFraction
        let batteryAh = batteryWh / volts
        let derate = max(0.01, 1 - min(99, input.losses ?? 0) / 100)
        let panelW = (sunHours ?? 0) > 0 ? daily / ((sunHours ?? 1) * derate) : 0

        VStack(alignment: .leading, spacing: 16) {
            SectionCard(symbol: "list.bullet", title: "How much power you use a day",
                        subtitle: "Add what you’d run and for how long, or type a daily total. Watts are on each device’s label.") {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Device").font(.caption).foregroundStyle(.secondary)
                        Text("Watts").font(.caption).foregroundStyle(.secondary)
                        Text("Hours a day").font(.caption).foregroundStyle(.secondary)
                        Text("")
                    }
                    ForEach($input.loads) { $load in
                        GridRow {
                            TextField("Device", text: $load.name).textFieldStyle(.roundedBorder)
                            smallField($load.watts, "W")
                            smallField($load.hours, "h")
                            Button(role: .destructive) { input.loads.removeAll { $0.id == load.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Remove")
                        }
                    }
                }
                Button { input.loads.append(SolarLoad(name: "")) } label: { Label("Add a Device", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Text("From the list: \(formatted(fromLoads)) Wh a day").font(.callout).foregroundStyle(.secondary)
                NumberInput(label: "Or type a daily total", value: $input.typedDaily, unit: "Wh", prompt: "Optional")
            }

            SectionCard(symbol: "sun.max", title: "Battery and panels you need") {
                NumberInput(label: "Days of backup without sun", value: $input.days, unit: "days")
                NumberInput(label: "Share of the battery you’ll use", value: $input.usable, unit: "%", prompt: "Datasheet")
                if !usableOK {
                    Label("Enter a share between 1% and 100%. At 0% the battery gives nothing.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                } else if usable == nil {
                    Label("Blank counts as 100%, which many batteries shouldn’t be drained to. Check the datasheet’s depth of discharge.",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Battery voltage")
                    Spacer()
                    Picker("Battery voltage", selection: $input.volts) {
                        ForEach([12.0, 24.0, 48.0], id: \.self) { Text("\(Int($0)) V").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                NumberInput(label: "Peak sun hours a day", value: $input.sunHours, unit: "h", prompt: "Your area")
                NumberInput(label: "System losses", value: $input.losses, unit: "%")
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 28) { batteryResult(batteryWh, batteryAh, ok: usableOK); panelResult(panelW) }
                    VStack(alignment: .leading, spacing: 12) { batteryResult(batteryWh, batteryAh, ok: usableOK); panelResult(panelW) }
                }
                Divider()
                FormulaNote(
                    formula: [
                        "daily Wh = Σ (watts × hours a day)",
                        "battery Wh = daily Wh × days ÷ share you’ll use",
                        "battery Ah = battery Wh ÷ battery volts",
                        "panel W = daily Wh ÷ (sun hours × (1 − losses))",
                    ],
                    assumptions: SolarDefaults.assumptions,
                    sources: SolarDefaults.sources)
            }
        }
        .onChange(of: input) { CalculatorMemory.save(input, SolarInput.key) }
    }

    private func batteryResult(_ wh: Double, _ ah: Double, ok: Bool) -> some View {
        ResultLine(value: ok ? "\(formatted(wh)) Wh" : "–", caption: ok ? "Battery: about \(formatted(ah)) Ah at \(Int(input.volts)) V" : "Battery: enter the share you’ll use")
    }

    private func panelResult(_ w: Double) -> some View {
        ResultLine(value: (input.sunHours ?? 0) > 0 ? "\(formatted(w)) W" : "–", caption: "Solar panels to refill it each day")
    }

    private func smallField(_ value: Binding<Double?>, _ prompt: String) -> some View {
        LiveNumberField(prompt: prompt, value: value, digits: 0...2)
            .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing).frame(width: 70)
            #if os(iOS)
            .keyboardType(.decimalPad)
            #endif
    }
}

private struct SolarLoad: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var watts: Double? = nil
    var hours: Double? = nil
}

// MARK: - Unit conversions

private enum UnitKind: String, CaseIterable, Identifiable {
    case volume, weight, temperature, length, fuel
    var id: String { rawValue }
    var label: String {
        switch self {
        case .volume: "Volume"
        case .weight: "Weight"
        case .temperature: "Temperature"
        case .length: "Length"
        case .fuel: "Fuel and run time"
        }
    }
    var symbol: String {
        switch self {
        case .volume: "drop"
        case .weight: "scalemass"
        case .temperature: "thermometer.medium"
        case .length: "ruler"
        case .fuel: "fuelpump"
        }
    }
    var units: [(String, Dimension)] {
        switch self {
        case .volume: [("gallons (US)", UnitVolume.gallons), ("quarts (US)", UnitVolume.quarts), ("pints (US)", UnitVolume.pints),
                       ("fluid ounces (US)", UnitVolume.fluidOunces),
                       ("tablespoons", UnitVolume.tablespoons), ("teaspoons", UnitVolume.teaspoons),
                       ("liters", UnitVolume.liters), ("milliliters", UnitVolume.milliliters)]
        case .weight: [("pounds", UnitMass.pounds), ("ounces", UnitMass.ounces), ("kilograms", UnitMass.kilograms), ("grams", UnitMass.grams)]
        case .temperature: [("°F", UnitTemperature.fahrenheit), ("°C", UnitTemperature.celsius)]
        case .length: [("inches", UnitLength.inches), ("feet", UnitLength.feet), ("yards", UnitLength.yards), ("miles", UnitLength.miles),
                       ("millimeters", UnitLength.millimeters), ("centimeters", UnitLength.centimeters),
                       ("meters", UnitLength.meters), ("kilometers", UnitLength.kilometers)]
        case .fuel: []
        }
    }
}

private struct UnitsCalculator: View {
    @State private var kind: UnitKind = .volume
    @State private var amount: Double? = 1
    @State private var from = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Unit conversions").font(.title2.bold())
            Picker("Convert", selection: $kind) {
                ForEach(UnitKind.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
            }.pickerStyle(.menu)
            if kind == .fuel {
                FuelCalculator()
            } else {
                converter
            }
        }
        .onChange(of: kind) {
            from = 0
            // The amount is shared across kinds: -40 as °F must not become negative gallons.
            if kind != .temperature, let a = amount, a < 0 { amount = 0 }
        }
    }

    private var converter: some View {
        let units = kind.units
        let source = units[min(from, units.count - 1)]
        let value = Measurement(value: amount ?? 0, unit: source.1)
        return VStack(alignment: .leading, spacing: 16) {
            SectionCard(symbol: kind.symbol, title: "Amount to convert") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { amountInput.frame(minWidth: 220); fromPicker.frame(minWidth: 160) }
                    VStack(alignment: .leading, spacing: 12) { amountInput; fromPicker }
                }
            }
            SectionCard(symbol: "equal", title: "Equivalent amounts") {
                ForEach(units.indices, id: \.self) { i in
                    if i != from {
                        HStack {
                            Text(units[i].0).foregroundStyle(.secondary)
                            Spacer()
                            Text(value.converted(to: units[i].1).value.formatted(.number.precision(.significantDigits(1...6))))
                                .font(.body.weight(.semibold).monospacedDigit()).textSelection(.enabled)
                        }
                    }
                }
            }
            FormulaNote(formula: formula, assumptions: assumptions).card(padding: 18)
        }
    }

    private var amountInput: some View {
        NumberInput(label: "Amount", value: $amount, width: 130, allowNegative: kind == .temperature)
    }
    private var fromPicker: some View {
        Picker("From", selection: $from) {
            ForEach(kind.units.indices, id: \.self) { Text(kind.units[$0].0).tag($0) }
        }.pickerStyle(.menu)
    }

    private var formula: [String] {
        switch kind {
        case .temperature: ["°C = (°F − 32) × 5 ⁄ 9", "°F = °C × 9 ⁄ 5 + 32"]
        case .volume: ["1 US gallon = 4 quarts = 128 US fluid ounces = 3.785411784 liters"]
        case .weight: ["1 pound = 16 ounces = 0.45359237 kilograms"]
        case .length: ["1 inch = 2.54 centimeters", "1 mile = 5,280 feet"]
        case .fuel: []
        }
    }

    private var assumptions: [String] {
        switch kind {
        case .volume: ["US customary units, not UK (imperial) gallons or pints."]
        case .weight: ["Avoirdupois pounds and ounces (everyday weight), not troy or fluid ounces."]
        default: ["Exact definitions, worked out by the system’s unit converter."]
        }
    }
}

private struct FuelInput: Codable, Equatable {
    var fuel: Double? = nil
    var perHour: Double? = nil
    var hoursPerDay: Double? = nil
    var wantHours: Double? = nil
    static let key = "calculatorFuel"
}

private struct FuelCalculator: View {
    @State private var input = CalculatorMemory.load(FuelInput.key, as: FuelInput.self) ?? FuelInput()

    var body: some View {
        let fuel = input.fuel, perHour = input.perHour, hoursPerDay = input.hoursPerDay, wantHours = input.wantHours
        let runHours = (fuel ?? 0) > 0 && (perHour ?? 0) > 0 ? (fuel ?? 0) / (perHour ?? 1) : nil
        SectionCard(symbol: "fuelpump", title: "How long will my fuel last?",
                    subtitle: "Fuel use per hour is in your generator’s manual, usually at a few different loads. Use the one closest to what you’ll run.") {
            NumberInput(label: "Fuel on hand", value: $input.fuel, unit: "gal", prompt: "Gallons")
            NumberInput(label: "Generator uses", value: $input.perHour, unit: "gal/h", prompt: "From manual")
            NumberInput(label: "Hours you’ll run it a day", value: $input.hoursPerDay, unit: "h", prompt: "Optional")
            Divider()
            if let runHours {
                ResultLine(value: "\(formatted(runHours, digits: 1)) hours of running",
                           caption: (hoursPerDay ?? 0) > 0
                            ? "About \(formatted(runHours / (hoursPerDay ?? 1), digits: 1)) days at \(formatted(hoursPerDay ?? 0, digits: 1)) hours a day."
                            : "Add hours a day to see how many days that is.")
            } else {
                Text("Enter your fuel and your generator’s fuel use.").font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            NumberInput(label: "Hours you want to run", value: $input.wantHours, unit: "h", prompt: "Optional")
            if let wantHours, wantHours > 0, let perHour, perHour > 0 {
                Text("You’ll need about \(formatted(wantHours * perHour, digits: 1)) gallons (\(formatted(wantHours * perHour * 3.785411784, digits: 1)) liters).")
                    .font(.callout.weight(.semibold))
            }
            Divider()
            FormulaNote(
                formula: ["hours = fuel ÷ fuel use per hour", "days = hours ÷ hours a day", "fuel needed = hours × fuel use per hour"],
                assumptions: [
                    "Fuel use changes with load: more plugged in burns more. Use the manual’s figure for your load.",
                    "Turn the generator off and let it cool before refueling.",
                ],
                sources: [SafetySources.generatorRefuel])
        }
        .onChange(of: input) { CalculatorMemory.save(input, FuelInput.key) }
    }
}

/// Extensions for the typical list.
extension ApplianceWatts {
    static var defaults: [Appliance] {
        typical.map { Appliance(id: $0.id, name: $0.name, running: $0.running, extra: $0.extra) }
    }
}

/// EPA's bleach table, as published.
private struct EPABleachTable: View {
    var body: some View {
        DisclosureGroup("EPA’s table") {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    Text("Water").font(.caption.weight(.semibold))
                    Text("6% bleach").font(.caption.weight(.semibold))
                    Text("8.25% bleach").font(.caption.weight(.semibold))
                }
                ForEach(WaterDisinfection.tableRows, id: \.water) { row in
                    GridRow { Text(row.water); Text(row.six); Text(row.eight) }.font(.callout)
                }
            }
            .padding(.top, 6)
        }
        .font(.callout)
    }
}
