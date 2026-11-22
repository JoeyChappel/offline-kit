import SwiftUI
import AppKit

// MARK: - Window

/// The Connected Devices window. An AppKit window around SwiftUI, so it can be opened from a menu, the approval
/// prompt or a button anywhere without a scene of its own.
@MainActor
enum ShareDevicesWindow {
    private static var window: NSWindow?

    static func show(share: ShareController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let host = NSHostingController(rootView: ShareDevicesView().environment(share)
            .frame(minWidth: 640, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity, alignment: .topLeading))
        host.sizingOptions = []   // the window keeps its own size; the list scrolls
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentViewController = host
        window.title = "Connected Devices"
        window.contentMinSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 920, height: 600))
        window.center()
        // Remembers where it was put (not in a throwaway test home's run, which would write the real preferences).
        if KitLocation.testHome == nil { window.setFrameAutosaveName("ConnectedDevices") }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
    }
}

/// Menu items: Share › Connected Devices… (⇧⌘J), Stop Sharing.
struct ShareDevicesCommands: Commands {
    let share: ShareController

    var body: some Commands {
        CommandMenu("Share") {
            Button("Connected Devices…") { ShareDevicesWindow.show(share: share) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button("Stop Sharing") { ShareDevices.shared.stopSharing() }
                .disabled(!share.isRunning)
        }
    }
}

/// A compact summary for the Share window: who's connected, and a button to the full list.
struct ShareDevicesButton: View {
    @Environment(ShareController.self) private var share
    private var devices: ShareDevices { .shared }

    var body: some View {
        let online = devices.online.count, waiting = devices.pending.count
        Button { ShareDevicesWindow.show(share: share) } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.2.wave.2")
                Text(online == 0 ? "No devices connected" : "\(online) device\(online == 1 ? "" : "s") connected")
                if waiting > 0 { Pill(text: "\(waiting) waiting", symbol: "hourglass", tint: .orange) }
                Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
            }
        }
        .help("See and manage the devices using this Mac's library (⇧⌘J)")
    }
}

// MARK: - Main view

struct ShareDevicesView: View {
    @Environment(ShareController.self) private var share
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selection: String?
    @State private var showInspector = true
    @State private var confirmSignOutAll = false
    private var registry: ShareDevices { .shared }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !share.isRunning && registry.devices.isEmpty {
                ContentUnavailableView {
                    Label("Sharing is off", systemImage: "wifi.slash")
                } description: {
                    Text("Turn on Share on Wi-Fi in Offline Kit to let phones, tablets and computers in the house use this library. They'll show up here.")
                }
            } else if registry.devices.isEmpty {
                ContentUnavailableView {
                    Label("No one has connected yet", systemImage: "person.2.wave.2")
                } description: {
                    Text(share.primaryURL.map { "Open \($0) on a phone or tablet on the same Wi-Fi. It will show up here." } ?? "Devices that open this Mac's address show up here.")
                }
            } else {
                list
            }
        }
        .background(Design.canvas)
        .inspector(isPresented: $showInspector) {
            Group {
                if let id = selection, registry.devices[id] != nil {
                    ShareDeviceDetail(id: id)
                } else {
                    ContentUnavailableView("Select a device", systemImage: "sidebar.right",
                                           description: Text("Its history and the controls to sign it out, block or rename it appear here."))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Design.surface)
            .inspectorColumnWidth(min: 280, ideal: 320, max: 420)
        }
        .toolbar {
            ToolbarItemGroup {
                if registry.hasPIN {
                    Button { confirmSignOutAll = true } label: { Label("Sign Out Everyone", systemImage: "person.2.slash") }
                        .help("Everyone has to enter the PIN again")
                }
                if share.isRunning {
                    Button { registry.stopSharing() } label: { Label("Stop Sharing", systemImage: "stop.circle") }
                        .help("Turn off Share on Wi-Fi: every device loses access now")
                }
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.right") }
            }
        }
        .confirmationDialog("Sign out everyone?", isPresented: $confirmSignOutAll) {
            Button("Sign Out Everyone", role: .destructive) { registry.signOutEveryone() }
        } message: {
            Text("Every phone, tablet, computer and app will have to enter the PIN again.")
        }
        .animation(Motion.gentle(reduceMotion), value: registry.online.map(\.id))
        .animation(Motion.gentle(reduceMotion), value: registry.pending.map(\.id))
        #if DEBUG
        // Test hook: -devicesSelect <text> selects the first device whose name contains it, once one connects.
        .task {
            guard let wanted = UserDefaults.standard.string(forKey: "devicesSelect") else { return }
            for _ in 0..<120 where selection == nil {
                selection = registry.devices.values.sorted { $0.lastSeen > $1.lastSeen }.first { $0.name.contains(wanted) && registry.isOnline($0) }?.id
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        #endif
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connected Devices").font(.system(.title, design: .rounded, weight: .bold))
                    Text(statusLine).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            ApprovalToggle()
            if !registry.hasPIN {
                Label {
                    Text("No PIN is set. Without one, anyone on your Wi-Fi can use the library, and a blocked browser that clears its cookies and gets a new address can come back. Set a PIN in Share on Wi-Fi, or turn on asking first.")
                } icon: { Image(systemName: "key").foregroundStyle(.orange) }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var statusLine: String {
        if share.isRunning {
            let n = registry.online.count
            return "Sharing on \(share.primaryURL ?? "this Mac"). \(n == 0 ? "No one" : "\(n) device\(n == 1 ? "" : "s")") online now."
        }
        if share.pausedOnOtherNetwork { return "Sharing is paused: this Mac is on a different network." }
        return "Sharing is off. These are the devices that used it before."
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            let pending = registry.pending
            if !pending.isEmpty {
                Section("Waiting for you to allow") {
                    ForEach(pending) { device in
                        ShareDeviceRow(device: device).tag(device.id)
                    }
                }
            }
            section("Online now", registry.online, empty: share.isRunning ? "No one is using the library right now." : nil)
            section("Recently", registry.recent, empty: nil)
            section("Blocked", registry.blocked, empty: nil)
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let device = registry.devices[id] { ShareDeviceActions(device: device, style: .menu) }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ devices: [ShareDevices.Device], empty: String?) -> some View {
        if !devices.isEmpty {
            Section(title) {
                ForEach(devices) { device in ShareDeviceRow(device: device).tag(device.id) }
            }
        } else if let empty {
            Section(title) { Text(empty).foregroundStyle(.secondary).font(.callout) }
        }
    }
}

/// "Ask before new devices connect", with what it does in plain words.
private struct ApprovalToggle: View {
    private var registry: ShareDevices { .shared }

    var body: some View {
        Toggle(isOn: Binding(get: { registry.askFirst }, set: { registry.setAskFirst($0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Ask before new devices connect").font(.headline)
                Text(registry.askFirst
                     ? "On. A device this Mac hasn't allowed waits until you click Allow here, even if it knows the PIN."
                     : "Recommended. New devices wait for you to allow them on this Mac, in addition to the PIN. Devices online now stay allowed.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .card(padding: 14)
    }
}

// MARK: - Row

struct ShareDeviceRow: View {
    let device: ShareDevices.Device
    private var registry: ShareDevices { .shared }

    var body: some View {
        HStack(spacing: 12) {
            DeviceIcon(device: device, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(device.name).font(.headline).lineLimit(1)
                    if device.thisMac { Pill(text: "This Mac", symbol: "desktopcomputer") }
                    if registry.isSignedIn(device) { Pill(text: "Signed in", symbol: "lock.open.fill", tint: .green) }
                    if device.waitingSince != nil { Pill(text: "Waiting", symbol: "hourglass", tint: .orange) }
                    if registry.isBlocked(device) { Pill(text: "Blocked", symbol: "hand.raised.fill", tint: .red) }
                }
                Text(activityLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(ShareDeviceFormat.lastSeen(device, online: registry.isOnline(device)))
                        .font(.callout.weight(registry.isOnline(device) ? .semibold : .regular))
                        .foregroundStyle(registry.isOnline(device) ? Color.green : .secondary)
                }
                HStack(spacing: 6) {
                    if let ip = device.ips.first { Text(ip).font(.caption.monospaced()) }
                    if device.bytesSent > 0 { Text("· " + ShareDeviceFormat.bytes(device.bytesSent)).font(.caption) }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }

    private var activityLine: String {
        if device.waitingSince != nil { return "Asked to use Offline Kit. Allow it in the details, or block it." }
        guard let activity = device.activity else { return device.autoName }
        if let bytes = registry.downloading(device.id), activity.text.hasPrefix("Downloading") {
            return activity.text + " · \(ShareDeviceFormat.bytes(bytes)) so far"
        }
        return registry.isOnline(device) ? activity.text : "Last: " + activity.text
    }
}

private struct DeviceIcon: View {
    let device: ShareDevices.Device
    var size: CGFloat
    private var registry: ShareDevices { .shared }

    var body: some View {
        let blocked = registry.isBlocked(device)
        Image(systemName: device.symbol)
            .font(.system(size: size * 0.48, weight: .medium))
            .foregroundStyle(blocked ? Color.red : (registry.isOnline(device) ? Color.accentColor : .secondary))
            .frame(width: size, height: size)
            .background((blocked ? Color.red : Color.accentColor).opacity(registry.isOnline(device) || blocked ? 0.14 : 0.07),
                        in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Detail

struct ShareDeviceDetail: View {
    let id: String
    @State private var nickname = ""
    private var registry: ShareDevices { .shared }

    var body: some View {
        if let device = registry.devices[id] {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        DeviceIcon(device: device, size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name).font(.title3.weight(.semibold)).lineLimit(2)
                            Text(device.autoName).font(.callout).foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Name").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        TextField("Nickname, e.g. Kids' iPad", text: $nickname)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { registry.rename(id, to: nickname) }
                        Text("Shown only on this Mac.").font(.caption).foregroundStyle(.secondary)
                    }

                    ShareDeviceActions(device: device, style: .buttons)

                    facts(device)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent activity").font(.headline)
                        if device.history.isEmpty {
                            Text("Nothing yet.").foregroundStyle(.secondary).font(.callout)
                        }
                        ForEach(device.history) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: event.symbol).foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.text).font(.callout)
                                    Text(event.date, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear { nickname = device.nickname ?? "" }
            .onChange(of: id) { nickname = registry.devices[id]?.nickname ?? "" }
        }
    }

    private func facts(_ device: ShareDevices.Device) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                fact("Status", registry.isBlocked(device) ? "Blocked" : registry.isOnline(device) ? "Online now" : "Offline")
                fact("Signed in", registry.hasPIN ? (registry.isSignedIn(device) ? "Yes" : "No") : "No PIN set")
                if registry.askFirst { fact("Allowed", device.waitingSince != nil ? "Waiting for you" : (registry.isApproved(device) ? "Yes" : "No")) }
                fact("Address", device.ips.isEmpty ? "Not seen since the app opened" : device.ips.joined(separator: "\n"), mono: true)
                fact("Hardware address", device.macs.isEmpty ? (device.thisMac ? "This Mac" : "Not known (not on this network segment)")
                                                             : device.macs.sorted().joined(separator: "\n"), mono: !device.macs.isEmpty)
                fact("First seen", device.firstSeen.formatted(date: .abbreviated, time: .shortened))
                fact("Last seen", device.lastSeen.formatted(date: .abbreviated, time: .shortened))
                fact("Data sent", ShareDeviceFormat.bytes(device.bytesSent) + " since the app opened")
            }
            .font(.callout)
            if !device.macs.isEmpty {
                Text("Phones use a private Wi-Fi address for each network, so this stays the same on this network unless the person turns on rotating addresses or resets it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fact(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(mono ? .callout.monospaced() : .callout).textSelection(.enabled)
        }
    }
}

/// Allow, sign out, block, unblock and forget: as buttons in the details, or as a context menu.
struct ShareDeviceActions: View {
    enum Style { case buttons, menu }
    let device: ShareDevices.Device
    let style: Style
    @State private var confirmBlock = false
    @State private var confirmForget = false
    private var registry: ShareDevices { .shared }

    var body: some View {
        let blocked = registry.isBlocked(device)
        let content = Group {
            if device.waitingSince != nil {
                Button { registry.allow(device.id, remember: true) } label: { Label("Allow", systemImage: "checkmark.circle") }
                Button { registry.allow(device.id, remember: false) } label: { Label("Allow Once", systemImage: "clock") }
                    .help("Until Offline Kit quits")
            }
            if !blocked {
                Button { registry.signOut(device.id) } label: { Label("Sign Out", systemImage: "lock") }
                    .disabled(!registry.isSignedIn(device))
                    .help(registry.hasPIN ? "It has to enter the PIN again" : "Without a PIN there's nothing to sign out of")
                Button(role: .destructive) { confirmBlock = true } label: { Label("Block…", systemImage: "hand.raised") }
            } else {
                Button { registry.unblock(device.id) } label: { Label("Unblock", systemImage: "hand.thumbsup") }
            }
            if registry.askFirst && registry.isApproved(device) && !blocked && device.waitingSince == nil {
                Button { registry.revokeApproval(device.id) } label: { Label("Ask Again Next Time", systemImage: "arrow.uturn.backward") }
            }
            if !blocked {
                Button(role: .destructive) { confirmForget = true } label: { Label("Forget…", systemImage: "trash") }
            }
        }
        Group {
            switch style {
            case .menu: content
            case .buttons:
                VStack(alignment: .leading, spacing: 8) {
                    FlowButtons { content }
                    if !blocked {
                        Text(blockNote(device)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .confirmationDialog("Block \(device.name)?", isPresented: $confirmBlock) {
            Button("Block", role: .destructive) { registry.block(device.id) }
        } message: {
            Text("It's signed out and every request from it is refused with “This device has been blocked on the Mac.” You can unblock it later.")
        }
        .confirmationDialog("Forget \(device.name)?", isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { registry.forget(device.id) }
        } message: {
            Text("It's removed from this list, with its nickname. If it connects again it shows up as a new device.")
        }
    }

    private func blockNote(_ device: ShareDevices.Device) -> String {
        if !device.macs.isEmpty {
            return "Blocking uses its hardware address, browser cookie and IP address, so it holds even if the device clears its cookies or gets a new address. It can be dodged only by changing the phone's private Wi-Fi address; asking before new devices connect closes that too."
        }
        if registry.hasPIN || registry.askFirst {
            return "Blocking uses its browser cookie and IP address. Its hardware address isn't known (it isn't on this network segment), so with the PIN or asking first it can't simply come back."
        }
        return "Blocking uses its browser cookie and IP address. Without a PIN, a browser that clears its cookies and gets a new address can come back: set a PIN or turn on asking first."
    }
}

/// Buttons that wrap onto more lines in a narrow inspector.
private struct FlowButtons<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
        .controlSize(.regular)
    }
}

enum ShareDeviceFormat {
    static func lastSeen(_ device: ShareDevices.Device, online: Bool) -> String {
        let seconds = -device.lastSeen.timeIntervalSinceNow
        if online && (device.openRequests > 0 || seconds < 60) { return "now" }
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) min ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600)) hr ago" }
        return device.lastSeen.formatted(.relative(presentation: .named))
    }

    static func bytes(_ count: Int64) -> String { ByteCountFormatter.string(fromByteCount: count, countStyle: .file) }
}

// MARK: - Approval prompt

/// A small floating panel that asks about each device waiting to connect: Allow, Allow Once or Block. It appears
/// whatever window is open (or none), and bounces the Dock icon once.
@MainActor
enum ShareApprovalPanel {
    private static var panel: NSPanel?
    private static var shownIDs: Set<String> = []

    static func update() {
        let pending = ShareDevices.shared.pending
        guard !pending.isEmpty else {
            panel?.orderOut(nil)
            shownIDs = []
            return
        }
        if panel == nil {
            let host = NSHostingController(rootView: ShareApprovalView())
            host.sizingOptions = [.preferredContentSize]
            let panel = NSPanel(contentViewController: host)
            panel.title = "Allow a new device?"
            panel.styleMask = [.titled, .closable, .utilityWindow, .nonactivatingPanel]
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.isFloatingPanel = true
            self.panel = panel
        }
        let ids = Set(pending.map(\.id))
        if !ids.isSubset(of: shownIDs) {
            if !(panel?.isVisible ?? false) { panel?.center() }
            panel?.orderFrontRegardless()
            NSApp.requestUserAttention(.informationalRequest)
        }
        shownIDs = ids
    }
}

private struct ShareApprovalView: View {
    private var registry: ShareDevices { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(registry.pending) { device in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        DeviceIcon(device: device, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Allow \(device.name) to use Offline Kit?").font(.headline).fixedSize(horizontal: false, vertical: true)
                            Text(([device.ips.first] + [device.macs.sorted().first]).compactMap { $0 }.joined(separator: " · "))
                                .font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    HStack {
                        Button("Block", role: .destructive) { registry.block(device.id) }
                        Spacer()
                        Button("Allow Once") { registry.allow(device.id, remember: false) }
                            .help("Until Offline Kit quits")
                        Button("Allow") { registry.allow(device.id, remember: true) }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                if device.id != registry.pending.last?.id { Divider() }
            }
            Text("Allowed devices still need the PIN, if one is set.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 420)
    }
}
