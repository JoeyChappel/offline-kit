import Foundation

#if DEBUG
/// Made-up test data for screenshots and checks. Only runs in a test home (OFFLINEKIT_HOME) with an empty store,
/// so it can never touch real household details.
enum HouseholdSamples {
    @MainActor static func seedIfAsked(_ household: Household) {
        guard KitLocation.testHome != nil, UserDefaults.standard.bool(forKey: "seedHousehold"),
              household.data.people.isEmpty, household.data.records == nil else { return }
        var data = household.data
        let alex = Person(name: "Alex Sample", age: .adult, health: "Seasonal allergies")
        let jordan = Person(name: "Jordan Sample", age: .adult)
        let riley = Person(name: "Riley Sample", age: .child)
        data.people = [alex, jordan, riley]
        data.activePersonID = alex.id
        data.home.meetingPlace = "Big oak tree at the corner of Elm St and 3rd Ave"
        data.home.outOfAreaContact = "Aunt Pat Example (Springfield)"
        data.contacts = [LocalContact(name: "Neighbor Sam Test", detail: "555-0142")]

        var extra = HouseholdRecords()
        extra.plan.meetingOutOfArea = "Central Library, 100 Example Ave, Springfield"
        extra.plan.outOfAreaPhone = "555-0199"
        extra.plan.waterShutoff = "Basement, north wall behind the water heater. Turn handle clockwise."
        extra.plan.gasShutoff = "Meter on the east side of the house. Wrench hangs in the garage."
        extra.plan.electricShutoff = "Garage panel, main breaker at top."
        extra.plan.shutoffNotes = "Flashlight on the hook by the garage door."

        var a = MedicalCard(id: alex.id)
        a.birthDate = "1985-04-12"
        a.bloodType = "O+"
        a.allergies = "Penicillin"
        a.conditions = "Asthma"
        a.medications = [Medication(name: "Albuterol inhaler", dose: "2 puffs", schedule: "as needed"),
                         Medication(name: "Exampleprazole", dose: "20 mg", schedule: "every morning")]
        a.doctors = [PhoneContact(name: "Dr. Morgan Test", role: "Family doctor", phone: "555-0110")]
        a.pharmacy = PhoneContact(name: "Corner Pharmacy, Main St", phone: "555-0120")
        a.insurance.provider = "Sample Health Plan"
        a.insurance.memberID = "XZ0000001"
        a.insurance.groupNumber = "G-1234"
        a.insurance.phone = "555-0130"
        a.emergencyContacts = [PhoneContact(name: "Jordan Sample", role: "Spouse", phone: "555-0101"),
                               PhoneContact(name: "Aunt Pat Example", role: "Aunt", phone: "555-0199")]
        var j = MedicalCard(id: jordan.id)
        j.birthDate = "1987-09-30"
        j.bloodType = "A−"
        j.allergies = "None known"
        j.emergencyContacts = [PhoneContact(name: "Alex Sample", role: "Spouse", phone: "555-0100")]
        var r = MedicalCard(id: riley.id)
        r.birthDate = "2016-02-08"
        r.allergies = "Peanuts (carries EpiPen)"
        r.medications = [Medication(name: "Epinephrine auto-injector", dose: "0.15 mg", schedule: "for a severe reaction")]
        r.doctors = [PhoneContact(name: "Dr. Casey Example", role: "Pediatrician", phone: "555-0111")]
        r.emergencyContacts = a.emergencyContacts
        // -seedOverfull YES: Alex's card has far more than fits, to check the wallet card's too-full warning.
        if UserDefaults.standard.bool(forKey: "seedOverfull") {
            a.medications += (1...16).map { Medication(name: "Sample medicine number \($0)", dose: "\($0 * 5) mg", schedule: "twice a day with food") }
            a.conditions = "Asthma, type 2 diabetes, high blood pressure, sample condition with a long description"
        }
        extra.cards = [a, j, r]

        let today = Calendar.current.startOfDay(for: .now)
        func day(_ offset: Int) -> Date { Calendar.current.date(byAdding: .day, value: offset, to: today)! }
        func item(_ name: String, _ cat: SupplyCategory, _ qty: Double, _ unit: String, _ loc: String, _ exp: Int?) -> SupplyItem {
            var s = SupplyItem(name: name, category: cat)
            s.quantity = qty; s.unit = unit; s.location = loc; s.expires = exp.map(day)
            return s
        }
        extra.supplies = [
            item("Bottled water", .water, 12, "gallons", "Basement shelf", 400),
            item("Canned black beans", .food, 8, "cans", "Pantry", 20),
            item("Granola bars", .food, 2, "boxes", "Go-bag", -5),
            item("Ibuprofen 200 mg", .medicine, 1, "bottle", "Bathroom cabinet", 12),
            item("AA batteries", .batteries, 24, "", "Junk drawer", 900),
            item("Gasoline", .fuel, 5, "gallons", "Shed", 150),
            item("First aid kit", .firstAid, 1, "", "Hall closet", nil),
        ]
        extra.barcodeNames = ["0123456789012": "Canned black beans"]
        // -seedNoSupplies YES: an empty Supplies list. -tickChecklist water,food: those checklist items are ticked.
        if UserDefaults.standard.bool(forKey: "seedNoSupplies") { extra.supplies = [] }
        // -seedSupplies N: N made-up supplies instead (for timing a long list).
        if let count = Int(UserDefaults.standard.string(forKey: "seedSupplies") ?? "") {
            let categories: [SupplyCategory] = [.water, .food, .medicine, .batteries, .fuel, .firstAid]
            extra.supplies = (0..<count).map { n in
                item("Sample supply \(n + 1)", categories[n % categories.count], Double(n % 12 + 1), n % 2 == 0 ? "cans" : "boxes",
                     ["Pantry", "Basement shelf", "Go-bag", "Garage"][n % 4], n % 7 == 0 ? nil : (n * 37) % 700 - 30)
            }
        }
        let ticked = (UserDefaults.standard.string(forKey: "tickChecklist") ?? "").split(separator: ",").map(String.init)
        for index in data.checklist.indices where ticked.contains(data.checklist[index].id) { data.checklist[index].have = true }
        data.records = extra
        household.data = data
    }
}
#else
enum HouseholdSamples {
    @MainActor static func seedIfAsked(_ household: Household) {}
}
#endif
