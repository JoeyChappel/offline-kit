import Foundation

// Family plan, supplies and saved guides. All of it lives inside HouseholdData, so it's sealed in the same
// encrypted, device-only file as the rest of the household (see PrivateStore).
//
// Why supplies are in the encrypted store and not a plain file in the library: a supply list includes medicine
// names, and where the fuel, cash and medicine are kept. That's worth protecting, and one store means one
// "Erase All Personal Details" button covers everything. The cost is that supplies don't travel with a kit drive
// or show up over Wi-Fi sharing, which is the point.
//
// Backward compatibility: HouseholdData holds these as one optional value, so household files saved before this
// existed still open. Every type here decodes missing keys as defaults, so later fields can be added safely.

/// Everything added for the family plan, supplies and saved guides.
struct HouseholdRecords: Codable, Hashable {
    var plan = FamilyPlan()
    var cards: [MedicalCard] = []
    var supplies: [SupplyItem] = []
    /// Barcodes the household has named before, so a second scan fills the name in with no internet.
    var barcodeNames: [String: String] = [:]
    var supplyAlerts = SupplyAlertSettings()
    var savedGuides: [SavedGuide] = []

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        plan = (try? c.decodeIfPresent(FamilyPlan.self, forKey: .plan)) ?? FamilyPlan()
        cards = (try? c.decodeIfPresent([MedicalCard].self, forKey: .cards)) ?? []
        supplies = (try? c.decodeIfPresent([SupplyItem].self, forKey: .supplies)) ?? []
        barcodeNames = (try? c.decodeIfPresent([String: String].self, forKey: .barcodeNames)) ?? [:]
        supplyAlerts = (try? c.decodeIfPresent(SupplyAlertSettings.self, forKey: .supplyAlerts)) ?? SupplyAlertSettings()
        savedGuides = (try? c.decodeIfPresent([SavedGuide].self, forKey: .savedGuides)) ?? []
    }
}

extension HouseholdData {
    /// The records, created empty the first time they're used.
    var extra: HouseholdRecords {
        get { records ?? HouseholdRecords() }
        set { records = newValue }
    }

    /// The person's medical card, or an empty one.
    func card(for person: Person) -> MedicalCard {
        extra.cards.first { $0.id == person.id } ?? MedicalCard(id: person.id)
    }
}

// MARK: - Family plan

/// Whole-household details. The near-home meeting place and out-of-area contact name are `Home.meetingPlace`
/// and `Home.outOfAreaContact`, so Ask and the Home tab keep seeing the same values.
struct FamilyPlan: Codable, Hashable {
    var meetingOutOfArea = ""
    var outOfAreaPhone = ""
    var waterShutoff = ""
    var gasShutoff = ""
    var electricShutoff = ""
    var shutoffNotes = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meetingOutOfArea = c.string(.meetingOutOfArea)
        outOfAreaPhone = c.string(.outOfAreaPhone)
        waterShutoff = c.string(.waterShutoff)
        gasShutoff = c.string(.gasShutoff)
        electricShutoff = c.string(.electricShutoff)
        shutoffNotes = c.string(.shutoffNotes)
    }
}

/// One person's medical and contact card. `id` is the matching `Person.id`.
struct MedicalCard: Codable, Hashable, Identifiable {
    var id: UUID
    /// "1984-03-12". Kept as text so it never shifts a day with time zones.
    var birthDate = ""
    var bloodType = ""
    var medications: [Medication] = []
    var allergies = ""
    var conditions = ""
    var doctors: [PhoneContact] = []
    var pharmacy = PhoneContact()
    var insurance = Insurance()
    var emergencyContacts: [PhoneContact] = []

    init(id: UUID) { self.id = id }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        birthDate = c.string(.birthDate)
        bloodType = c.string(.bloodType)
        medications = (try? c.decodeIfPresent([Medication].self, forKey: .medications)) ?? []
        allergies = c.string(.allergies)
        conditions = c.string(.conditions)
        doctors = (try? c.decodeIfPresent([PhoneContact].self, forKey: .doctors)) ?? []
        pharmacy = (try? c.decodeIfPresent(PhoneContact.self, forKey: .pharmacy)) ?? PhoneContact()
        insurance = (try? c.decodeIfPresent(Insurance.self, forKey: .insurance)) ?? Insurance()
        emergencyContacts = (try? c.decodeIfPresent([PhoneContact].self, forKey: .emergencyContacts)) ?? []
    }

    static let bloodTypes = ["A+", "A−", "B+", "B−", "AB+", "AB−", "O+", "O−"]

    var birthDateValue: Date? { MedicalCard.dayFormatter.date(from: birthDate) }

    /// "Mar 12, 1984 (age 42)"
    var birthDateText: String {
        guard let date = birthDateValue else { return "" }
        let years = Calendar.current.dateComponents([.year], from: date, to: .now).year ?? 0
        return date.formatted(.dateTime.month(.abbreviated).day().year()) + " (age \(years))"
    }

    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var isEmpty: Bool {
        birthDate.isEmpty && bloodType.isEmpty && medications.isEmpty && allergies.isBlank && conditions.isBlank
            && doctors.isEmpty && pharmacy.isEmpty && insurance.isEmpty && emergencyContacts.isEmpty
    }
}

struct Medication: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = ""
    var dose = ""
    var schedule = ""

    init(name: String = "", dose: String = "", schedule: String = "") {
        self.name = name; self.dose = dose; self.schedule = schedule
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = c.string(.name)
        dose = c.string(.dose)
        schedule = c.string(.schedule)
    }

    /// "Lisinopril 10 mg, once a day"
    var line: String {
        let rest = [dose, schedule].filter { !$0.isBlank }.joined(separator: ", ")
        return rest.isEmpty ? name : "\(name) \(rest)"
    }
}

/// A doctor, pharmacy or emergency contact.
struct PhoneContact: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = ""
    /// "Mother", "Pediatrician", "Cardiologist"…
    var role = ""
    var phone = ""

    init(name: String = "", role: String = "", phone: String = "") {
        self.name = name; self.role = role; self.phone = phone
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = c.string(.name)
        role = c.string(.role)
        phone = c.string(.phone)
    }

    var isEmpty: Bool { name.isBlank && phone.isBlank }

    /// "Dr. Ana Ruiz (Pediatrician)"
    var label: String { role.isBlank ? name : (name.isBlank ? role : "\(name) (\(role))") }
}

struct Insurance: Codable, Hashable {
    var provider = ""
    var memberID = ""
    var groupNumber = ""
    var phone = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        provider = c.string(.provider)
        memberID = c.string(.memberID)
        groupNumber = c.string(.groupNumber)
        phone = c.string(.phone)
    }

    var isEmpty: Bool { provider.isBlank && memberID.isBlank && groupNumber.isBlank && phone.isBlank }
}

// MARK: - Supplies

enum SupplyCategory: String, Codable, CaseIterable, Identifiable {
    case water, food, medicine, batteries, fuel, firstAid, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .water: "Water"
        case .food: "Food"
        case .medicine: "Medicine"
        case .batteries: "Batteries"
        case .fuel: "Fuel"
        case .firstAid: "First aid"
        case .other: "Other"
        }
    }
    var symbol: String {
        switch self {
        case .water: "drop.fill"
        case .food: "fork.knife"
        case .medicine: "pills.fill"
        case .batteries: "battery.75percent"
        case .fuel: "fuelpump.fill"
        case .firstAid: "cross.case.fill"
        case .other: "shippingbox.fill"
        }
    }
}

struct SupplyItem: Codable, Hashable, Identifiable {
    var id = UUID()
    var name = ""
    var category = SupplyCategory.other
    var quantity: Double = 1
    var unit = ""
    var location = ""
    /// Start of the day it expires, or nil when it doesn't.
    var expires: Date?
    var notes = ""
    var barcode = ""
    var added = Date()

    init(name: String = "", category: SupplyCategory = .other) {
        self.name = name; self.category = category
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = c.string(.name)
        category = (try? c.decodeIfPresent(SupplyCategory.self, forKey: .category)) ?? .other
        quantity = (try? c.decodeIfPresent(Double.self, forKey: .quantity)) ?? 1
        unit = c.string(.unit)
        location = c.string(.location)
        expires = try? c.decodeIfPresent(Date.self, forKey: .expires)
        notes = c.string(.notes)
        barcode = c.string(.barcode)
        added = (try? c.decodeIfPresent(Date.self, forKey: .added)) ?? Date()
    }

    enum Status: Int, Comparable {
        case expired, soon, fine, noDate
        static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
    }

    /// Days counted as "expires soon".
    static let soonDays = 30

    func status(now: Date = .now) -> Status {
        guard let expires else { return .noDate }
        let today = Calendar.current.startOfDay(for: now)
        if expires < today { return .expired }
        let soon = Calendar.current.date(byAdding: .day, value: SupplyItem.soonDays, to: today) ?? today
        return expires <= soon ? .soon : .fine
    }

    /// "12 cans", "1.5 gallons", "3"
    var amount: String {
        let number = quantity.formatted(.number.precision(.fractionLength(0...2)))
        return unit.isBlank ? number : "\(number) \(unit)"
    }

    /// "Expired Nov 2", "Expires today", "Expires in 5 days", "Expires Mar 2027"
    func expiryText(now: Date = .now) -> String {
        guard let expires else { return "No expiry date" }
        let today = Calendar.current.startOfDay(for: now)
        let days = Calendar.current.dateComponents([.day], from: today, to: expires).day ?? 0
        if days < 0 { return "Expired " + expires.formatted(.dateTime.month(.abbreviated).day().year()) }
        if days == 0 { return "Expires today" }
        if days == 1 { return "Expires tomorrow" }
        if days <= SupplyItem.soonDays { return "Expires in \(days) days" }
        return "Expires " + expires.formatted(.dateTime.month(.abbreviated).day().year())
    }
}

struct SupplyAlertSettings: Codable, Hashable {
    var enabled = false
    /// How many days ahead the first reminder comes. A second one comes on the day itself.
    var leadDays = 14

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        leadDays = (try? c.decodeIfPresent(Int.self, forKey: .leadDays)) ?? 14
    }
}

extension HouseholdRecords {
    /// Items that are expired or expire within 30 days, for badges.
    func suppliesNeedingAttention(now: Date = .now) -> Int {
        supplies.filter { $0.status(now: now) <= .soon }.count
    }
}

// MARK: - Saved guides

/// A reference article saved for quick access and for the printed binder.
struct SavedGuide: Codable, Hashable, Identifiable {
    var ref: ArticleRef
    /// The archive's title when it was saved, shown when its drive isn't connected.
    var bookTitle = ""
    var notes = ""
    var saved = Date()
    var id: String { ref.id }

    init(ref: ArticleRef, bookTitle: String) {
        self.ref = ref; self.bookTitle = bookTitle
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ref = try c.decode(ArticleRef.self, forKey: .ref)
        bookTitle = c.string(.bookTitle)
        notes = c.string(.notes)
        saved = (try? c.decodeIfPresent(Date.self, forKey: .saved)) ?? Date()
    }
}

// MARK: - Helpers

extension KeyedDecodingContainer {
    /// A string that's missing or the wrong type reads as empty.
    func string(_ key: Key) -> String { ((try? decodeIfPresent(String.self, forKey: key)) ?? nil) ?? "" }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
