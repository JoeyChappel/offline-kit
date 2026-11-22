import SwiftUI

/// Prepare › Family plan: each person's medical card and the household's meeting places and shutoffs,
/// printable as wallet cards and a one-page plan. It's the one place medical details and meeting places are edited;
/// People keeps names, ages and skills, and links here.
struct FamilyPlanSection: View {
    @Environment(Household.self) private var household
    @State private var expanded: Set<UUID> = []
    @State private var editingPlan = false
    /// A person to open and scroll to (from People).
    @Binding var focus: UUID?
    let openPeople: () -> Void

    var body: some View {
        @Bindable var household = household
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) { planHeading; Spacer(); planActions }
                VStack(alignment: .leading, spacing: 12) { planHeading; planActions }
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    meetingPlaces.frame(minWidth: 380, maxWidth: .infinity)
                    contactDetails.frame(minWidth: 250, maxWidth: .infinity)
                }
                VStack(alignment: .leading, spacing: 16) { meetingPlaces; contactDetails }
            }
            utilityShutoffs
            Label(PrintDocuments.privateWarning, systemImage: "exclamationmark.lock.fill")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if household.data.people.isEmpty {
                Text("Add the people in your household in People to print cards.").font(.caption).foregroundStyle(.secondary)
            }

            ForEach(household.data.people) { person in
                PersonPlanCard(person: person, card: cardBinding(for: person),
                               expanded: Binding(get: { expanded.contains(person.id) },
                                                 set: { if $0 { expanded.insert(person.id) } else { expanded.remove(person.id) } }))
                    .id(person.id)
            }
            HStack(spacing: 10) {
                Button { openPeople() } label: {
                    Label(household.data.people.isEmpty ? "Add People…" : "Add or Remove People…", systemImage: "person.2")
                }
                .buttonStyle(.bordered)
                Text("Names and ages are set in People.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: openFocus)
        .onChange(of: focus) { openFocus() }
        #if DEBUG
        .task { await PrintTestHook.run("wallet", title: "Wallet cards") { PrintDocuments.walletCards(household.data) } }
        .task { await PrintTestHook.run("plan", title: "Family emergency plan") { PrintDocuments.familyPlan(household.data) } }
        .onAppear { if UserDefaults.standard.bool(forKey: "expandCards") { expanded = Set(household.data.people.map(\.id)) } }
        #endif
    }

    private func openFocus() {
        guard let id = focus else { return }
        expanded.insert(id)
        Task { try? await Task.sleep(for: .seconds(1)); if focus == id { focus = nil } }
    }

    private var planHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Family plan").font(.title2.bold())
            Text("Where to meet. Who to call. What to know.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var planActions: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(editingPlan ? "Done" : "Edit plan", systemImage: editingPlan ? "checkmark" : "pencil") {
                withAnimation(.snappy) { editingPlan.toggle() }
            }.buttonStyle(.borderedProminent)
            PrintButtons(title: "Family emergency plan", filename: "Family emergency plan", printLabel: "Print full plan…",
                         menuPresentation: true,
                         additionalDocument: .init(title: "Wallet cards", filename: "Wallet cards", printLabel: "Print wallet cards…", pdfLabel: "Save wallet cards as PDF…", enabled: !household.data.people.isEmpty, makeHTML: { PrintDocuments.walletCards(household.data) })) {
                PrintDocuments.familyPlan(household.data)
            }
        }
    }

    private var meetingPlaces: some View {
        @Bindable var household = household
        return SectionCard(symbol: "mappin.and.ellipse", title: "Meeting places", subtitle: nil) {
            if editingPlan {
                PlanField("Near home", "A neighbor’s porch, the mailbox at the corner…", $household.data.home.meetingPlace)
                PlanField("Out of the area", "A relative’s house, a library in the next town…", $household.data.extra.plan.meetingOutOfArea)
            } else {
                planDetail("Near home", value: household.data.home.meetingPlace, placeholder: "Add a meeting place near home…", symbol: "mappin")
                Divider()
                planDetail("Out of the area", value: household.data.extra.plan.meetingOutOfArea, placeholder: "Add an out-of-area meeting place…", symbol: "mappin.and.ellipse")
            }
        }
    }

    private var contactDetails: some View {
        @Bindable var household = household
        return SectionCard(symbol: "person.crop.circle", title: "Out-of-area contact", subtitle: "Someone far away everyone checks in with.") {
            if editingPlan {
                PlanField("Contact", "Name and location", $household.data.home.outOfAreaContact)
                PlanField("Their phone", "Number", $household.data.extra.plan.outOfAreaPhone, phone: true)
            } else {
                planDetail("Contact", value: household.data.home.outOfAreaContact, placeholder: "Add a contact…", symbol: "person")
                planDetail("Phone", value: household.data.extra.plan.outOfAreaPhone, placeholder: "Add their phone…", symbol: "phone")
            }
        }
    }

    private var utilityShutoffs: some View {
        @Bindable var household = household
        return SectionCard(symbol: "wrench.and.screwdriver", title: "Utility shutoffs", subtitle: nil) {
            if editingPlan {
                PlanField("Water", "Where the main valve is and how to turn it", $household.data.extra.plan.waterShutoff)
                PlanField("Gas", "Meter location, tool needed", $household.data.extra.plan.gasShutoff)
                PlanField("Electricity", "Breaker panel location, main breaker", $household.data.extra.plan.electricShutoff)
                PlanField("Notes", "Where the wrench is kept, anything else", $household.data.extra.plan.shutoffNotes)
            } else {
                planDetail("Water", value: household.data.extra.plan.waterShutoff, placeholder: "Add location…", symbol: "drop")
                Divider()
                planDetail("Gas", value: household.data.extra.plan.gasShutoff, placeholder: "Add location…", symbol: "flame")
                Divider()
                planDetail("Electricity", value: household.data.extra.plan.electricShutoff, placeholder: "Add location…", symbol: "bolt")
                if !household.data.extra.plan.shutoffNotes.isBlank {
                    Divider()
                    planDetail("Notes", value: household.data.extra.plan.shutoffNotes, placeholder: "Add notes…", symbol: "note.text")
                }
            }
        }
    }

    private func planDetail(_ title: String, value: String, placeholder: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.tint).frame(width: 24).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                if value.isBlank {
                    Button(placeholder) { editingPlan = true }.buttonStyle(.borderless)
                } else {
                    Text(value).font(.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if !value.isBlank {
                Button("Edit") { editingPlan = true }.buttonStyle(.borderless).font(.callout)
                    .accessibilityLabel("Edit \(title.lowercased())")
            }
        }.padding(.vertical, 4)
    }

    /// Reads and writes the person's card, adding it the first time something is entered.
    private func cardBinding(for person: Person) -> Binding<MedicalCard> {
        Binding {
            household.data.card(for: person)
        } set: { card in
            var extra = household.data.extra
            if let index = extra.cards.firstIndex(where: { $0.id == person.id }) { extra.cards[index] = card }
            else { extra.cards.append(card) }
            household.data.extra = extra
        }
    }
}

private struct PersonPlanCard: View {
    let person: Person
    @Binding var card: MedicalCard
    @Binding var expanded: Bool
    @Environment(Household.self) private var household

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { withAnimation(.snappy) { expanded.toggle() } } label: {
                HStack(alignment: .top, spacing: 12) {
                    KitSymbol("person.text.rectangle")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(person.name.isBlank ? "Unnamed" : person.name).font(.headline)
                        Text(summary).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Hides the details" : "Shows the details")

            if expanded { editor }
        }
        .card(padding: 18)
    }

    private var summary: String {
        var bits: [String] = []
        if !card.birthDateText.isEmpty { bits.append("Born " + card.birthDateText) }
        if !card.bloodType.isEmpty { bits.append("Blood " + card.bloodType) }
        if !card.allergies.isBlank { bits.append("Allergies: " + card.allergies) }
        let meds = card.medications.filter { !$0.name.isBlank }.count
        if meds > 0 { bits.append("\(meds) \(meds == 1 ? "medicine" : "medicines")") }
        if card.emergencyContacts.contains(where: { !$0.isEmpty }) { bits.append("emergency contacts set") }
        #if os(macOS)
        let hint = "Nothing filled in yet. Click to add details."
        #else
        let hint = "Nothing filled in yet. Tap to add details."
        #endif
        return bits.isEmpty ? hint : bits.joined(separator: " · ")
    }

    @ViewBuilder private var editor: some View {
        @Bindable var household = household
        if let index = household.data.people.firstIndex(where: { $0.id == person.id }) {
            PlanField("Name", "Name", $household.data.people[index].name)
        }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) { birthDate; bloodType }
            VStack(alignment: .leading, spacing: 12) { birthDate; bloodType }
        }
        PlanField("Allergies", "Medicines, foods, insect stings… or “None known”", $card.allergies, lines: 3)
        PlanField("Medical conditions", "Diabetes, asthma, pacemaker…", $card.conditions, lines: 3)
        if let index = household.data.people.firstIndex(where: { $0.id == person.id }) {
            // Once People › Health. Kept as its own field so nothing typed there is lost; Ask sees it, cards don't print it.
            PlanField("Other health notes for Ask", "Anything else about their health Ask should know", $household.data.people[index].health, lines: 3)
        }

        GroupHeader("Medicines", "Name, dose and when it’s taken.")
        ForEach($card.medications) { $med in
            ViewThatFits(in: .horizontal) {
                HStack { medFields($med); remove { card.medications.removeAll { $0.id == med.id } } }
                VStack(alignment: .leading) { medFields($med); remove { card.medications.removeAll { $0.id == med.id } } }
            }
        }
        AddButton("Add Medicine") { card.medications.append(Medication()) }

        GroupHeader("Doctors", nil)
        ForEach($card.doctors) { $doc in
            ContactRow(contact: $doc, rolePrompt: "Specialty") { card.doctors.removeAll { $0.id == doc.id } }
        }
        AddButton("Add Doctor") { card.doctors.append(PhoneContact()) }

        GroupHeader("Pharmacy", nil)
        ViewThatFits(in: .horizontal) {
            HStack { pharmacyName; pharmacyPhone }
            VStack(alignment: .leading) { pharmacyName; pharmacyPhone }
        }

        GroupHeader("Insurance", "Optional.")
        ViewThatFits(in: .horizontal) {
            HStack { insuranceFields }
            VStack(alignment: .leading) { insuranceFields }
        }

        GroupHeader("Emergency contacts", "The first three go on the wallet card.")
        ForEach($card.emergencyContacts) { $contact in
            ContactRow(contact: $contact, rolePrompt: "Relationship") { card.emergencyContacts.removeAll { $0.id == contact.id } }
        }
        AddButton("Add Contact") { card.emergencyContacts.append(PhoneContact()) }
    }

    private var birthDate: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Birth date").font(.subheadline.weight(.semibold))
            if let date = card.birthDateValue {
                HStack {
                    DatePicker("Birth date", selection: Binding(get: { date }, set: { card.birthDate = MedicalCard.dayFormatter.string(from: $0) }),
                               in: ...Date.now, displayedComponents: .date)
                        .labelsHidden()
                    Button("Clear") { card.birthDate = "" }.buttonStyle(.borderless).font(.callout)
                }
            } else {
                Button("Add Birth Date") {
                    let start = Calendar.current.date(byAdding: .year, value: -30, to: .now) ?? .now
                    card.birthDate = MedicalCard.dayFormatter.string(from: start)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private var bloodType: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Blood type").font(.subheadline.weight(.semibold))
            Picker("Blood type", selection: $card.bloodType) {
                Text("Not known").tag("")
                ForEach(MedicalCard.bloodTypes, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize()
        }
    }

    @ViewBuilder private func medFields(_ med: Binding<Medication>) -> some View {
        TextField("Medicine", text: med.name).textFieldStyle(.roundedBorder)
        TextField("Dose, like 10 mg", text: med.dose).textFieldStyle(.roundedBorder)
        TextField("When, like every morning", text: med.schedule).textFieldStyle(.roundedBorder)
    }

    private var pharmacyName: some View {
        TextField("Pharmacy name and location", text: $card.pharmacy.name).textFieldStyle(.roundedBorder)
    }
    private var pharmacyPhone: some View {
        PhoneField(text: $card.pharmacy.phone).frame(maxWidth: 200)
    }

    @ViewBuilder private var insuranceFields: some View {
        TextField("Provider", text: $card.insurance.provider).textFieldStyle(.roundedBorder)
        TextField("Member ID", text: $card.insurance.memberID).textFieldStyle(.roundedBorder)
        TextField("Group number", text: $card.insurance.groupNumber).textFieldStyle(.roundedBorder)
        PhoneField(text: $card.insurance.phone)
    }

    private func remove(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) { Image(systemName: "trash") }
            .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove")
    }
}

private struct ContactRow: View {
    @Binding var contact: PhoneContact
    let rolePrompt: String
    let onDelete: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack { fields; delete }
            VStack(alignment: .leading) { fields; delete }
        }
    }

    @ViewBuilder private var fields: some View {
        TextField("Name", text: $contact.name).textFieldStyle(.roundedBorder)
        TextField(rolePrompt, text: $contact.role).textFieldStyle(.roundedBorder).frame(maxWidth: 180)
        PhoneField(text: $contact.phone).frame(maxWidth: 180)
    }

    private var delete: some View {
        Button(role: .destructive, action: onDelete) { Image(systemName: "trash") }
            .buttonStyle(.borderless).help("Remove").accessibilityLabel("Remove")
    }
}

private struct PhoneField: View {
    @Binding var text: String
    var body: some View {
        TextField("Phone", text: $text)
            .textFieldStyle(.roundedBorder)
            #if os(iOS)
            .keyboardType(.phonePad)
            .textContentType(.telephoneNumber)
            #endif
    }
}

private struct GroupHeader: View {
    let title: String
    let detail: String?
    init(_ title: String, _ detail: String?) { self.title = title; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.top, 6)
    }
}

private struct AddButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Label(title, systemImage: "plus") }.buttonStyle(.bordered)
    }
}

/// A labeled text field used across the plan.
struct PlanField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var lines = 2
    var phone = false

    init(_ label: String, _ prompt: String, _ text: Binding<String>, lines: Int = 2, phone: Bool = false) {
        self.label = label; self.prompt = prompt; self._text = text; self.lines = lines; self.phone = phone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.subheadline.weight(.semibold))
            if phone {
                PhoneField(text: $text)
            } else {
                TextField(prompt, text: $text, axis: .vertical).lineLimit(1...lines).textFieldStyle(.roundedBorder)
            }
        }
    }
}
