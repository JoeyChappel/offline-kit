import SwiftUI

struct ShareView: View {
    @Environment(ShareController.self) private var share
    @State private var mode = SharingMode.browser
    /// What's typed in the PIN box. It becomes the PIN when Return is pressed or the box is left, not on each key:
    /// changing the PIN signs everyone out.
    @State private var pinDraft = ""
    @FocusState private var pinFocused: Bool

    private enum SharingMode: String, CaseIterable, Identifiable {
        case browser = "Use in a browser", phone = "Send to iPhone"
        var id: Self { self }
        var symbol: String { self == .browser ? "macwindow" : "iphone.and.arrow.forward" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    KitSymbol("wifi")
                    Text("Share on Wi-Fi").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Use this Mac’s library nearby, or save a copy for a trip.")
                        .font(.title3).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("How to share", selection: $mode) {
                    ForEach(SharingMode.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }.pickerStyle(.segmented).frame(maxWidth: 600)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 20) {
                        mainContent.frame(minWidth: 400, maxWidth: .infinity)
                        sideContent.frame(minWidth: 280, maxWidth: 350)
                    }
                    VStack(alignment: .leading, spacing: 20) { mainContent; sideContent }
                }
                connectionHelp
            }
            .padding(.horizontal, 24).padding(.vertical, 28)
            .frame(maxWidth: 1100, alignment: .leading).frame(maxWidth: .infinity)
        }
        .background(Design.canvas)
        .navigationTitle("Share on Wi-Fi")
        #if DEBUG
        .onAppear {
            if UserDefaults.standard.string(forKey: "sendTestPicks") != nil || UserDefaults.standard.string(forKey: "sendSnapshot") != nil { mode = .phone }
        }
        #endif
    }

    private var mainContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            sharingCard
            if mode == .phone { SendListSection() }
        }
    }

    private var sharingCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label(mode.rawValue, systemImage: mode.symbol).font(.title2.bold())
                Spacer(minLength: 0)
                Pill(text: share.isRunning ? "Sharing is on" : share.pausedOnOtherNetwork ? "Paused on another network" : (share.error != nil ? "Couldn’t start sharing" : (share.enabled ? "Starting…" : "Sharing is off")), symbol: share.isRunning ? "wifi" : share.pausedOnOtherNetwork ? "pause.circle" : "wifi.slash")
            }
            Text(mode == .browser
                 ? "Phones, tablets and computers can browse this library and ask questions on the same Wi-Fi. No app needed."
                 : "The iPhone saves selected items in Offline Kit for use away from home. Turn on sharing so the app can find this Mac.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error = share.error {
                // Paused on another network is expected, not a failure: say it calmly.
                Label(error, systemImage: share.pausedOnOtherNetwork ? "pause.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(share.pausedOnOtherNetwork ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if share.isRunning, let url = share.primaryURL {
                if mode == .browser {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) { qrCode(url); address(url).frame(minWidth: 210) }
                        VStack(alignment: .leading, spacing: 18) { qrCode(url); address(url) }
                    }
                } else {
                    Label("On iPhone, open Offline Kit › Get › From your Mac while connected to this Wi-Fi.", systemImage: "iphone")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                FlowLayout(spacing: 8) {
                    ShareDevicesButton()
                    Pill(text: "\(share.questionsAnswered) questions answered", symbol: "sparkles")
                }
            } else if mode == .browser {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 48)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).frame(height: 120)
                    .accessibilityHidden(true)
            }
            Button(share.enabled || share.isRunning ? "Turn Off Sharing" : "Turn On Sharing", systemImage: share.enabled || share.isRunning ? "wifi.slash" : "wifi") {
                share.enabled = !(share.enabled || share.isRunning)
            }.buttonStyle(.borderedProminent).controlSize(.large)
            Label("This Mac must stay awake with Offline Kit open, and your Wi-Fi router must stay on.", systemImage: "desktopcomputer")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.card(padding: 20)
    }

    @ViewBuilder private func qrCode(_ url: String) -> some View {
        if let qr = share.qrCode(for: url) {
            qr.resizable().frame(width: 148, height: 148).padding(10)
                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("QR code for \(url)")
        }
    }

    private func address(_ url: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open on another device").font(.headline)
            Text(url).font(.system(.title3, design: .monospaced, weight: .semibold))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url, forType: .string)
                } label: { Label("Copy Address", systemImage: "doc.on.doc") }
                Button { if let address = URL(string: url) { NSWorkspace.shared.open(address) } } label: {
                    Label("Open Here", systemImage: "safari")
                }
            }
            Text("Point the phone’s camera at the code, or type the address into its browser.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }

    private var sideContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            accessCard
            VStack(alignment: .leading, spacing: 14) {
                Label(mode == .browser ? "Taking files with you?" : "Just browsing nearby?", systemImage: mode == .browser ? "iphone" : "macwindow")
                    .font(.headline)
                Text(mode == .browser
                     ? "Send to iPhone saves selected items in the Offline Kit app for use away from home."
                     : "A browser uses this Mac’s library without saving a copy. This Mac and the router must stay on.")
                    .font(.callout).foregroundStyle(.secondary)
                Button(mode == .browser ? "Choose files to send →" : "Use in a browser →") {
                    mode = mode == .browser ? .phone : .browser
                }.buttonStyle(.bordered)
            }.card(padding: 20)
        }
    }

    private func applyPIN() {
        let digits = String(pinDraft.filter(\.isNumber).prefix(8))
        guard digits != share.pin else { return }
        share.pin = digits
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Access", systemImage: "lock").font(.title2.bold())
            HStack(spacing: 8) {
                TextField("Optional PIN, e.g. 1234", text: $pinDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($pinFocused)
                    .onChange(of: pinDraft) {
                        let digits = String(pinDraft.filter(\.isNumber).prefix(8))
                        if digits != pinDraft { pinDraft = digits }
                    }
                    .onSubmit(applyPIN)
                    .onChange(of: pinFocused) { if !pinFocused { applyPIN() } }
                if pinDraft != share.pin {
                    Button(pinDraft.isEmpty ? "Remove PIN" : "Set PIN", action: applyPIN)
                }
            }
            .onAppear { pinDraft = share.pin }
            if pinDraft != share.pin {
                Text(share.pin.isEmpty ? "Press Return to set this PIN." : "Press Return to change the PIN. Everyone who is signed in will need to enter the new one.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text("Set a PIN to keep guests or neighbors on your Wi-Fi out. People enter it once per browser.")
                .font(.callout).foregroundStyle(.secondary)
            Divider()
            Label("Local network only · Read-only access", systemImage: "checkmark.shield")
                .font(.callout.weight(.semibold))
            Text("Nothing can be changed or deleted from other devices.").font(.caption).foregroundStyle(.secondary)
            Label("Sharing isn’t encrypted. Use Wi-Fi you trust.", systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.secondary)
        }.card(padding: 20)
    }

    private var connectionHelp: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 10) {
                if share.isRunning && !share.ipURLs.isEmpty {
                    Text("If the main address doesn’t open (some Android phones and Windows PCs), use: \(share.ipURLs.joined(separator: " or "))")
                        .textSelection(.enabled)
                }
                Label("Only devices on the same network as this Mac can connect. Guest Wi-Fi may block connections between devices.", systemImage: "network")
                Label("The first time, macOS may ask to allow incoming connections. Click Allow.", systemImage: "checkmark.shield")
                Label("In a power outage, the Wi-Fi router needs power. A small battery backup works.", systemImage: "bolt.badge.clock")
            }.font(.callout).foregroundStyle(.secondary).padding(.top, 12)
        } label: {
            Label("Connection help", systemImage: "questionmark.circle").font(.headline)
        }.card(padding: 18)
    }
}
