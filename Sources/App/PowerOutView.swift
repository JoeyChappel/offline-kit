import SwiftUI
import UserNotifications
import os

/// Power-out mode: when the power went out, kept in settings so the timers survive restarts and reboots.
@MainActor @Observable
final class PowerOut {
    static let shared = PowerOut()

    private enum Key {
        static let start = "powerOutStart", freezer = "powerOutFreezerFull", done = "powerOutChecklist"
    }

    private(set) var start: Date?
    var freezerFull: Bool { didSet { KitSettings.shared.set(freezerFull, forKey: Key.freezer); Task { await rescheduleIfAllowed() } } }
    var done: Set<String> { didSet { KitSettings.shared.set(Array(done).sorted(), forKey: Key.done) } }
    /// nil until we've asked; false when the person said no or turned alerts off in Settings.
    private(set) var alertsAllowed: Bool?
    /// True while the system's notification prompt is up.
    private(set) var askingForAlerts = false

    var isActive: Bool { start != nil }

    private init() {
        let d = KitSettings.shared
        start = d.string(forKey: Key.start).flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
        freezerFull = d.bool(forKey: Key.freezer) ?? true
        done = Set(d.stringArray(forKey: Key.done) ?? [])
    }

    /// Starts (or moves) the outage clock and sets alerts for the food-safety limits.
    func begin(at date: Date = Date()) {
        start = min(date, Date())
        KitSettings.shared.set(String(start!.timeIntervalSince1970), forKey: Key.start)
        Task { await enableAlerts() }
    }

    func end() {
        start = nil
        done = []
        KitSettings.shared.set(nil, forKey: Key.start)
        PowerOutAlerts.cancel()
    }

    /// Asks for notification permission now, when alerts are about to matter, then schedules them.
    func enableAlerts() async {
        guard let start else { return }
        askingForAlerts = true
        alertsAllowed = await PowerOutAlerts.requestPermission()
        askingForAlerts = false
        if alertsAllowed == true { await PowerOutAlerts.schedule(from: start, freezerFull: freezerFull) }
    }

    func refreshPermission() async {
        alertsAllowed = await PowerOutAlerts.currentPermission()
    }

    private func rescheduleIfAllowed() async {
        guard let start, alertsAllowed == true else { return }
        await PowerOutAlerts.schedule(from: start, freezerFull: freezerFull)
    }
}

/// Local notifications at the food-safety limits. The system keeps them across app restarts and reboots.
enum PowerOutAlerts {
    static let prefix = "powerout."

    /// Test runs (OFFLINEKIT_HOME) share the real app's bundle ID, so they leave its notification settings alone.
    /// OFFLINEKIT_TEST_ALERTS=1 turns alerts back on, for a test copy built with its own bundle ID.
    static var isTestRun: Bool {
        KitLocation.testHome != nil && ProcessInfo.processInfo.environment["OFFLINEKIT_TEST_ALERTS"] != "1"
    }

    static func currentPermission() async -> Bool? {
        guard !isTestRun else { return nil }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return nil
        case .denied: return false
        default: return true
        }
    }

    /// Why the last permission request failed, when the system gave a reason.
    @MainActor static var lastError: String?
    private static let log = Logger(subsystem: "com.joeychappel.offlinekit", category: "PowerOut")

    static func requestPermission() async -> Bool {
        guard !isTestRun else { return false }
        UNUserNotificationCenter.current().delegate = ForegroundBanners.shared
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            log.info("Notification permission: \(granted)")
            await MainActor.run { lastError = nil }
            return granted
        } catch {
            log.error("Notification permission failed: \(error.localizedDescription, privacy: .public)")
            await MainActor.run { lastError = error.localizedDescription }
            return false
        }
    }

    static func schedule(from start: Date, freezerFull: Bool) async {
        guard !isTestRun else { return }
        cancel()
        let center = UNUserNotificationCenter.current()
        for alert in PowerOutGuide.alerts(freezerFull: freezerFull) {
            let fire = start.addingTimeInterval(alert.hours * 3600)
            let wait = fire.timeIntervalSinceNow
            guard wait > 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            let request = UNNotificationRequest(identifier: prefix + alert.id, content: content,
                                                trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false))
            do { try await center.add(request) } catch {
                log.error("Couldn't schedule \(alert.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    static func cancel() {
        guard !isTestRun else { return }
        let ids = PowerOutGuide.alerts(freezerFull: true).map { prefix + $0.id } + PowerOutGuide.alerts(freezerFull: false).map { prefix + $0.id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}

/// Shows power-out alerts even while Offline Kit is open.
private final class ForegroundBanners: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = ForegroundBanners()
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound, .list] }
}

// MARK: - Views

struct PowerOutSection: View {
    @Environment(KitNavigation.self) private var navigation
    @State private var power = PowerOut.shared
    @State private var pickingStart = false
    @State private var startPick = Date()
    @State private var confirmEnd = false
    let openWaterCalculator: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if power.isActive {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(alignment: .leading, spacing: 16) {
                        status(now: context.date)
                        foodTimers(now: context.date)
                    }
                }
            } else {
                startCard
            }
            ForEach(PowerOutGuide.sections) { section in
                if section.id == PowerOutGuide.checklistID {
                    checklist(section)
                } else {
                    guideCard(section)
                }
            }
            if power.isActive { endButton }
        }
        .sheet(isPresented: $pickingStart) { startPicker }
        .task { await power.refreshPermission() }
        #if DEBUG
        // Test hooks: -powerOutHoursAgo 5 starts power-out mode as if the power went out 5 hours ago.
        .task {
            if let hours = UserDefaults.standard.string(forKey: "powerOutHoursAgo").flatMap(Double.init) {
                power.begin(at: Date().addingTimeInterval(-hours * 3600))
            }
            // -powerOutPickStart YES opens "When did the power go out?"
            if UserDefaults.standard.bool(forKey: "powerOutPickStart") { pickingStart = true }
        }
        #endif
    }

    // MARK: Start and status

    private var startCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                KitSymbol("bolt.slash.fill")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Is the power out?").font(.title3.bold())
                    Text("Start power-out mode to time how long your fridge and freezer food stays safe, get alerts at the limits, and work through the steps below.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { startButtons }
                VStack(alignment: .leading, spacing: 10) { startButtons }
            }
        }
        .card(padding: 18)
    }

    @ViewBuilder private var startButtons: some View {
        Button { power.begin() } label: {
            Label("The Power’s Out", systemImage: "bolt.slash.fill").font(.headline).padding(.horizontal, 6).padding(.vertical, 4)
        }
        .buttonStyle(.borderedProminent)
        Button("It Went Out Earlier…") { startPick = Date(); pickingStart = true }
            .buttonStyle(.bordered)
    }

    private func status(now: Date) -> some View {
        let start = power.start ?? now
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                KitSymbol("bolt.slash.fill")
                VStack(alignment: .leading, spacing: 3) {
                    Text("POWER OUT").font(.caption.weight(.semibold)).tracking(1.2).foregroundStyle(.orange)
                    Text("Out for \(Self.duration(now.timeIntervalSince(start)))")
                        .font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
                    Text("Since \(start.formatted(date: Calendar.current.isDateInToday(start) ? .omitted : .abbreviated, time: .shortened))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Change") { startPick = start; pickingStart = true }.buttonStyle(.borderless)
            }
            alertStatus
        }
        .card(padding: 18)
    }

    @ViewBuilder private var alertStatus: some View {
        switch power.alertsAllowed {
        case true?:
            Label("Alerts are on for the food-safety limits below.", systemImage: "bell.badge")
                .font(.callout).foregroundStyle(.secondary)
        case false?:
            Label(PowerOutAlerts.isTestRun ? "Alerts are off in this test run."
                  : "Alerts are off. Turn on notifications for Offline Kit in \(Self.settingsName) to get them."
                    + (PowerOutAlerts.lastError.map { " (\($0))" } ?? ""),
                  systemImage: "bell.slash")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        case nil where power.askingForAlerts:
            Label("Allow notifications to get alerts at the limits.", systemImage: "bell.badge")
                .font(.callout).foregroundStyle(.secondary)
        case nil:
            Button { Task { await power.enableAlerts() } } label: { Label("Alert Me at the Limits", systemImage: "bell") }
                .buttonStyle(.bordered)
        }
    }

    private var startPicker: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("When did the power go out?").font(.title3.bold())
            DatePicker("Went out", selection: $startPick, in: Date().addingTimeInterval(-14 * 86_400)...Date(),
                       displayedComponents: [.date, .hourAndMinute])
            #if os(iOS)
                .datePickerStyle(.wheel)
            #endif
            HStack {
                Button("Cancel") { pickingStart = false }
                Spacer()
                Button(power.isActive ? "Save" : "Start Power-Out Mode") { power.begin(at: startPick); pickingStart = false }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 340)
        .presentationDetents([.medium])
    }

    private var endButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { confirmEnd = true } label: { Label("End Power-Out Mode", systemImage: "bolt.fill") }
                .buttonStyle(.borderedProminent).tint(.secondary)
            Text("Stops the timers and alerts and clears the checklist below.").font(.caption).foregroundStyle(.secondary)
        }
        .confirmationDialog("End power-out mode?", isPresented: $confirmEnd) {
            Button("End Power-Out Mode") { power.end() }
        } message: {
            Text("Is the power back on? Check the food first: see “\(PowerOutGuide.section(PowerOutGuide.returnsID)?.title ?? "When the power comes back on")”.")
        }
    }

    // MARK: Food timers

    private func foodTimers(now: Date) -> some View {
        let hours = now.timeIntervalSince(power.start ?? now) / 3600
        let freezerLimit = power.freezerFull ? PowerOutGuide.fullFreezerHours : PowerOutGuide.halfFreezerHours
        return SectionCard(symbol: "refrigerator", title: "Fridge and freezer",
                           subtitle: "Keep the doors shut. These limits count on that.") {
            timerRow(name: "Fridge", limit: PowerOutGuide.fridgeHours, hours: hours,
                     safe: PowerOutGuide.fridgeSafeNote, past: PowerOutGuide.fridgePastNote)
            Divider()
            Picker("Freezer", selection: $power.freezerFull) {
                Text("Full freezer").tag(true)
                Text("Half-full freezer").tag(false)
            }
            .pickerStyle(.segmented)
            timerRow(name: power.freezerFull ? "Full freezer" : "Half-full freezer", limit: freezerLimit, hours: hours,
                     safe: PowerOutGuide.freezerSafeNote, past: PowerOutGuide.freezerPastNote)
            SourceList(sources: [SafetySources.foodOutage, SafetySources.cdcFood, SafetySources.fsis, SafetySources.fda])
        }
    }

    private func timerRow(name: String, limit: Double, hours: Double, safe: String, past: String) -> some View {
        let left = limit - hours
        let over = left <= 0
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(name).font(.headline)
                Spacer()
                Text(over ? "Past \(Self.limitText(limit))" : "\(Self.duration(left * 3600)) left")
                    .font(.headline.monospacedDigit()).foregroundStyle(over ? .red : left < 1 ? .orange : Color.accentColor)
            }
            ProgressView(value: min(hours, limit), total: limit).tint(over ? .red : left < 1 ? .orange : .accentColor)
            Text(over ? past : safe).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Guide

    private func guideCard(_ section: GuideSection) -> some View {
        SectionCard(symbol: section.symbol, title: section.title, subtitle: section.intro) {
            BulletList(items: section.points).font(.callout)
            if section.id == PowerOutGuide.waterID {
                Button { openWaterCalculator() } label: { Label("Open the Bleach Calculator", systemImage: "drop") }
                    .buttonStyle(.bordered)
            }
            SourceList(sources: section.sources)
        }
    }

    private func checklist(_ section: GuideSection) -> some View {
        SectionCard(symbol: section.symbol, title: section.title, subtitle: section.intro) {
            ForEach(section.points, id: \.self) { item in
                let on = power.done.contains(item)
                Toggle(isOn: Binding(get: { on }, set: { if $0 { power.done.insert(item) } else { power.done.remove(item) } })) {
                    Text(item).foregroundStyle(on ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(SquareCheckStyle(alignment: .firstTextBaseline))
                .padding(.vertical, 2)
            }
            SourceList(sources: section.sources)
        }
    }

    // MARK: Formatting

    #if os(macOS)
    static let settingsName = "System Settings › Notifications"
    #else
    static let settingsName = "Settings › Notifications"
    #endif

    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        let d = minutes / 1440, h = (minutes % 1440) / 60, m = minutes % 60
        if d > 0 { return "\(d) d \(h) h" }
        if h > 0 { return "\(h) h \(m) min" }
        return m > 0 ? "\(m) min" : "under 1 min"
    }

    static func limitText(_ hours: Double) -> String {
        hours >= 24 && hours.truncatingRemainder(dividingBy: 24) == 0 ? "\(Int(hours)) hours (\(Int(hours / 24)) day\(hours > 24 ? "s" : ""))" : "\(Int(hours)) hours"
    }
}
