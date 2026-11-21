import Foundation
import Observation

// MARK: - What's stored (encrypted: on this device, or on the kit drive with a passphrase; see PrivateStore)

struct Person: Codable, Identifiable, Hashable {
    enum Age: String, Codable, CaseIterable, Identifiable {
        case infant, child, teen, adult, older
        var id: String { rawValue }
        var label: String {
            switch self {
            case .infant: "Baby (under 2)"
            case .child: "Child"
            case .teen: "Teen"
            case .adult: "Adult"
            case .older: "Older adult"
            }
        }
    }

    var id = UUID()
    var name: String
    var age: Age = .adult
    /// Other health notes, free text. Edited in Family plan beside the medical card (once the People tab's
    /// "Health" field, so older households keep what they typed here).
    var health = ""
    var skills: [String] = []
    /// Anything else Ask should know about this person.
    var notes = ""
}

struct Home: Codable, Hashable {
    var area = ""            // "Springfield, Illinois"
    var type = ""            // House, apartment…
    var water = ""           // City water, well…
    var heat = ""            // Gas, electric, wood…
    var power = ""           // Generator, solar…
    var pets = ""
    var meetingPlace = ""
    var outOfAreaContact = ""
    var notes = ""
}

struct ChecklistItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var category: String
    var have = false
    var custom = false
}

struct Memory: Codable, Identifiable, Hashable {
    var id = UUID()
    /// nil = about the whole household.
    var personID: UUID?
    var text: String
    var created = Date()
    /// True when Ask noted it from a question, false when typed in by hand.
    var learned = false
}

struct LoggedExchange: Codable, Identifiable, Hashable {
    var id = UUID()
    var personID: UUID?
    var date = Date()
    var question: String
    var answer: String
    var sources: [String] = []
}

struct LocalContact: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var detail: String      // phone number, radio frequency, address…
}

/// What Ask is allowed to use. Each part can be turned off on its own.
struct AskPrivacy: Codable, Hashable {
    var personalize = true
    var useHousehold = true
    var useChecklist = true
    var useMemories = true
    var learnMemories = true
    var keepHistory = true
}

struct HouseholdData: Codable {
    var people: [Person] = []
    var activePersonID: UUID?
    var home = Home()
    var checklist: [ChecklistItem] = Preparedness.defaultItems
    var memories: [Memory] = []
    var history: [LoggedExchange] = []
    var contacts: [LocalContact] = []
    var privacy = AskPrivacy()
    /// Family plan, supplies and saved guides (HouseholdRecords.swift). Optional so older files still open;
    /// use `extra` to read and change it.
    var records: HouseholdRecords?
}

// MARK: - Store

@MainActor @Observable
final class Household {
    var data: HouseholdData { didSet { scheduleSave() } }
    private(set) var saveError: String?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    /// True from an edit until its debounced write lands, so quitting can tell there is something to flush.
    @ObservationIgnored private var hasPendingSave = false
    /// The live store, for the quit handler (which runs outside any view).
    @ObservationIgnored static weak var shared: Household?

    /// The details are on a drive protected by a passphrase this Mac doesn't know yet. Nothing is saved until it's entered,
    /// so the drive's details can't be overwritten by an empty household.
    private(set) var isLocked = false
    /// Bumped when the passphrase setting changes, so views re-read PrivateStore.
    private(set) var storeChanges = 0
    /// True while the launch sheet asks for the passphrase, so Prepare doesn't show a second form under it.
    var unlockPrompting = false
    /// While the passphrase is being turned on, the store is moving: changes stay in memory and are written once
    /// it's done, so nothing typed during the slow key derivation lands in a file that's about to be deleted.
    @ObservationIgnored private var savesPaused = false
    @ObservationIgnored private var changedWhilePaused = false

    init() {
        let locked = PrivateStore.isLocked
        var loaded = (locked ? nil : PrivateStore.load(HouseholdData.self)) ?? HouseholdData()
        Preparedness.addMissingDefaults(to: &loaded.checklist)
        data = loaded
        Household.shared = self
        isLocked = locked
    }

    // MARK: Passphrase (Mac, running from a drive; see PrivateStore)

    /// Opens a passphrase-protected drive's details. The key derivation takes a moment, so it runs off the main thread.
    func unlock(passphrase: String, remember: Bool) async throws {
        try await Task.detached(priority: .userInitiated) { try PrivateStore.unlock(passphrase, remember: remember) }.value
        reload()
    }

    func setPassphrase(_ passphrase: String) async throws {
        try flush()
        savesPaused = true
        changedWhilePaused = false
        do {
            try await Task.detached(priority: .userInitiated) { try PrivateStore.enablePassphrase(passphrase) }.value
        } catch {
            resumeSaves()
            throw error
        }
        let edited = data
        let changed = changedWhilePaused
        reload()
        if changed { data = edited }   // keep what was typed meanwhile; scheduleSave sees savesPaused and waits
        savesPaused = false
        changedWhilePaused = false
        if changed { try flush() }
    }

    /// Checks the current passphrase, then protects the details with a new one.
    func changePassphrase(current: String, to passphrase: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try PrivateStore.changePassphrase(from: current, to: passphrase)
        }.value
        storeChanges += 1
    }

    private func resumeSaves() {
        savesPaused = false
        if changedWhilePaused { changedWhilePaused = false; scheduleSave() }
    }

    func removePassphrase() throws {
        try flush()
        try PrivateStore.removePassphrase()
        reload()
    }

    /// Locks the drive's details on this Mac right away.
    func forgetPassphraseOnThisMac() {
        PrivateStore.forgetOnThisMac()
        reload()
    }

    /// Writes any pending change now.
    private func flush() throws {
        guard !isLocked else { throw PrivateStore.PassphraseError.locked }
        saveTask?.cancel()
        hasPendingSave = false
        try PrivateStore.save(data)
    }

    /// Writes an edit that is still inside the 400 ms debounce, synchronously. Called as the app quits.
    func flushPendingSave() {
        guard hasPendingSave, !isLocked, !savesPaused else { return }
        saveTask?.cancel()
        hasPendingSave = false
        try? PrivateStore.save(data)
    }

    private func reload() {
        saveTask?.cancel()
        hasPendingSave = false
        isLocked = PrivateStore.isLocked
        var loaded = (isLocked ? nil : PrivateStore.load(HouseholdData.self)) ?? HouseholdData()
        Preparedness.addMissingDefaults(to: &loaded.checklist)
        data = loaded
        saveTask?.cancel()   // the assignment above isn't a change worth writing back
        storeChanges += 1
    }

    var activePerson: Person? { data.people.first { $0.id == data.activePersonID } }

    func person(_ id: UUID?) -> Person? { data.people.first { $0.id == id } }

    /// Removes a person with everything kept about them: their medical card and anything Ask noted.
    func removePerson(_ id: UUID) {
        var next = data
        next.people.removeAll { $0.id == id }
        next.memories.removeAll { $0.personID == id }
        if next.records != nil { next.extra.cards.removeAll { $0.id == id } }
        if next.activePersonID == id { next.activePersonID = nil }
        data = next
    }

    // MARK: Memories and history

    func remember(_ text: String, about personID: UUID?, learned: Bool) -> Memory? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty,
              !data.memories.contains(where: { $0.text.caseInsensitiveCompare(clean) == .orderedSame }) else { return nil }
        let memory = Memory(personID: personID, text: clean, learned: learned)
        data.memories.append(memory)
        return memory
    }

    func forget(_ id: UUID) { data.memories.removeAll { $0.id == id } }

    func log(question: String, answer: String, sources: [String]) {
        guard data.privacy.keepHistory, !answer.isEmpty else { return }
        data.history.append(LoggedExchange(personID: data.activePersonID, question: question,
                                           answer: String(answer.prefix(4000)), sources: sources))
        if data.history.count > 500 { data.history.removeFirst(data.history.count - 500) }
    }

    /// Wipes every personal detail and the encryption key, then starts fresh.
    func eraseEverything() {
        saveTask?.cancel()
        let wasOnDrive = PrivateStore.usesPassphrase
        PrivateStore.erase()
        // Erasing a drive's details turns its passphrase off; this Mac's own details (if any) are what's left.
        if wasOnDrive { reload(); return }
        data = HouseholdData()
        storeChanges += 1
    }

    private func scheduleSave() {
        saveTask?.cancel()
        guard !isLocked else { return }
        if savesPaused { changedWhilePaused = true; return }
        let snapshot = data
        hasPendingSave = true
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.hasPendingSave = false
            do { try PrivateStore.save(snapshot); self?.saveError = nil }
            catch { self?.saveError = "Couldn’t save your private details: \(error.localizedDescription)" }
        }
    }
}

// MARK: - Checklist and skills

enum Preparedness {
    /// Based on Ready.gov's basic emergency supply kit, plus a few common additions.
    static let defaultItems: [ChecklistItem] = {
        let groups: [(String, [(String, String)])] = [
            ("Water", [("water", "Water: about a gallon per person per day, for several days"),
                       ("purify", "Water filter or purification tablets")]),
            ("Food", [("food", "Food that won’t spoil, for several days"),
                      ("opener", "Manual can opener")]),
            ("Power and light", [("flashlight", "Flashlight"),
                                 ("batteries", "Extra batteries"),
                                 ("powerbank", "Phone chargers and a backup battery"),
                                 ("generator", "Generator or solar power station")]),
            ("Communication", [("radio", "Battery or hand-crank radio with NOAA Weather Radio"),
                               ("whistle", "Whistle to signal for help"),
                               ("phonelist", "Printed list of family phone numbers"),
                               ("maps", "Paper maps of your area")]),
            ("First aid and health", [("firstaid", "First aid kit"),
                                      ("meds", "A week of prescription medicines"),
                                      ("glasses", "Spare glasses or contact lens supplies"),
                                      ("masks", "Dust masks"),
                                      ("sanitizer", "Hand sanitizer and wet wipes")]),
            ("Tools and safety", [("wrench", "Wrench or pliers to turn off gas and water"),
                                  ("extinguisher", "Fire extinguisher"),
                                  ("matches", "Matches in a waterproof container"),
                                  ("sheeting", "Plastic sheeting and duct tape"),
                                  ("detectors", "Working smoke and carbon monoxide alarms")]),
            ("Documents and money", [("documents", "Copies of IDs, insurance and bank records"),
                                     ("cash", "Cash in small bills")]),
            ("Shelter and warmth", [("blankets", "Sleeping bag or warm blanket for each person"),
                                    ("clothes", "Change of clothes and sturdy shoes")]),
            ("Sanitation", [("bags", "Garbage bags and plastic ties"),
                            ("toiletries", "Toilet paper and personal hygiene items"),
                            ("bleach", "Unscented household bleach")]),
        ]
        return groups.flatMap { category, items in
            items.map { ChecklistItem(id: $0.0, title: $0.1, category: category) }
        }
    }()

    static var categories: [String] {
        var seen = Set<String>()
        return defaultItems.map(\.category).filter { seen.insert($0).inserted }
    }

    /// Keeps saved checklists current when new default items are added in an update.
    static func addMissingDefaults(to items: inout [ChecklistItem]) {
        let ids = Set(items.map(\.id))
        items.append(contentsOf: defaultItems.filter { !ids.contains($0.id) })
    }

    /// Extra suggestions that depend on who's in the household.
    static func suggestions(for data: HouseholdData) -> [String] {
        var list: [String] = []
        if data.people.contains(where: { $0.age == .infant }) { list.append("Formula, bottles, diapers and wipes for the baby") }
        if data.people.contains(where: { $0.age == .child }) { list.append("Books, games or comfort items for the kids") }
        if data.people.contains(where: { $0.age == .older }) { list.append("Spare hearing-aid batteries, mobility aids and medical devices") }
        if !data.home.pets.trimmingCharacters(in: .whitespaces).isEmpty { list.append("Pet food, water, leash and carrier") }
        if data.people.contains(where: { !$0.health.isBlank }) || data.extra.cards.contains(where: { !$0.allergies.isBlank || !$0.conditions.isBlank || $0.medications.contains { !$0.name.isBlank } }) {
            list.append("A written list of everyone’s medicines, doses and allergies")
        }
        if data.home.heat.localizedCaseInsensitiveContains("gas") || data.home.heat.localizedCaseInsensitiveContains("propane") {
            list.append("Know where your gas shut-off valve is")
        }
        let have = Set(data.checklist.map { $0.title.lowercased() })
        return list.filter { !have.contains($0.lowercased()) }
    }

    static let skills = [
        "First aid / CPR", "Nurse or doctor", "EMT or paramedic", "Electrical", "Plumbing", "Carpentry",
        "Auto mechanic", "Generators and small engines", "Ham radio (licensed)", "Gardening",
        "Hunting and fishing", "Cooking from scratch", "Water treatment", "Sewing", "Childcare",
    ]
}

// MARK: - What Ask is told

/// The private context added to a question asked on this device. Never used for questions from Wi-Fi sharing.
enum AskContext {
    /// Builds the text, keeping the most useful parts when space is short.
    static func build(_ data: HouseholdData, kit: String, limit: Int) -> String {
        let p = data.privacy
        var parts: [String] = []
        if p.personalize {
            let asking = data.people.first { $0.id == data.activePersonID }
            if let asking {
                parts.append("The person asking: " + describe(asking, in: data))
            }
            if p.useHousehold {
                let others = data.people.filter { $0.id != asking?.id }
                if !others.isEmpty {
                    parts.append("Others in the household:\n" + others.map { "- " + describe($0, in: data) }.joined(separator: "\n"))
                }
                let home = homeLine(data)
                if !home.isEmpty { parts.append("Home: " + home) }
            }
            if p.useMemories {
                let relevant = data.memories.filter { $0.personID == nil || $0.personID == asking?.id }
                if !relevant.isEmpty {
                    parts.append("Things they’ve told you:\n" + relevant.suffix(20).map { "- " + $0.text }.joined(separator: "\n"))
                }
            }
            if p.useChecklist {
                let have = data.checklist.filter(\.have).map(\.title)
                let missing = data.checklist.filter { !$0.have }.map(\.title)
                if !have.isEmpty { parts.append("Supplies they have: " + have.joined(separator: "; ")) }
                if !missing.isEmpty && !have.isEmpty { parts.append("Supplies they don’t have yet: " + missing.joined(separator: "; ")) }
            }
        }
        if !kit.isEmpty { parts.append(kit) }

        var text = ""
        for part in parts {
            let next = text.isEmpty ? part : text + "\n" + part
            if next.count > limit {
                let room = limit - text.count - 2
                if room > 120 { text += "\n" + part.prefix(room) + "…" }
                break
            }
            text = next
        }
        return text
    }

    /// One person: name and age, then the Family plan card's allergies, conditions and medicines, other health
    /// notes, skills and anything else Ask should know.
    private static func describe(_ person: Person, in data: HouseholdData) -> String {
        var bits = ["\(person.name.isEmpty ? "Unnamed" : person.name) (\(person.age.label.lowercased()))"]
        let card = data.card(for: person)
        if !card.allergies.isBlank { bits.append("allergies: \(card.allergies)") }
        if !card.conditions.isBlank { bits.append("conditions: \(card.conditions)") }
        let meds = card.medications.filter { !$0.name.isBlank }.map(\.line)
        if !meds.isEmpty { bits.append("medicines: \(meds.joined(separator: ", "))") }
        if !person.health.isBlank { bits.append("health: \(person.health)") }
        if !person.skills.isEmpty { bits.append("skills: \(person.skills.joined(separator: ", "))") }
        if !person.notes.isEmpty { bits.append(person.notes) }
        return bits.joined(separator: "; ")
    }

    private static func homeLine(_ data: HouseholdData) -> String {
        let home = data.home, plan = data.extra.plan
        let contact = [home.outOfAreaContact, plan.outOfAreaPhone].filter { !$0.isBlank }.joined(separator: " ")
        return [("lives in", home.area), ("home", home.type), ("water", home.water), ("heat", home.heat),
         ("backup power", home.power), ("pets", home.pets), ("family meeting place", home.meetingPlace),
         ("meeting place out of area", plan.meetingOutOfArea), ("out-of-area contact", contact), ("notes", home.notes)]
            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.0): \($0.1)" }.joined(separator: "; ")
    }
}
