import SwiftUI

struct ShareView: View {
    @Environment(ShareController.self) private var share

    var body: some View {
        @Bindable var share = share
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "wifi")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 56, height: 56)
                        .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("Share on Wi-Fi").font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("Let phones, tablets and computers in the house use this Mac's library and AI from a web browser. They only need to be on the same Wi-Fi; no internet and no app install.")
                        .font(.title3).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $share.enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share this library on Wi-Fi").font(.headline)
                            Text(share.isRunning ? "On. Anyone on your Wi-Fi can open the address below."
                                                 : "Off. Turn it on to get an address and a code to scan on a phone or tablet.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    if let error = share.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
                .card(padding: 18)

                if share.isRunning, let url = share.primaryURL {
                    HStack(alignment: .top, spacing: 20) {
                        if let qr = share.qrCode(for: url) {
                            qr.resizable()
                                .frame(width: 168, height: 168)
                                .padding(10)
                                .background(.white, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("QR code for \(url)")
                        }
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Open this on a phone or tablet").font(.headline)
                            Text(url)
                                .font(.system(.title2, design: .monospaced, weight: .semibold))
                                .textSelection(.enabled)
                            HStack {
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url, forType: .string)
                                } label: { Label("Copy Address", systemImage: "doc.on.doc") }
                                Button { NSWorkspace.shared.open(URL(string: url)!) } label: { Label("Open Here", systemImage: "safari") }
                            }
                            Text("Point the phone's camera at the code, or type the address into its browser.")
                                .font(.callout).foregroundStyle(.secondary)
                            if !share.ipURLs.isEmpty {
                                Text("If that address doesn't open (some Android phones and Windows PCs), use: \(share.ipURLs.joined(separator: " or "))")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .card(padding: 18)

                    HStack(spacing: 8) {
                        Pill(text: "\(share.activeDevices) device\(share.activeDevices == 1 ? "" : "s") in the last 5 min", symbol: "iphone")
                        Pill(text: "\(share.questionsAnswered) questions answered", symbol: "sparkles")
                    }
                }

                SendListSection()

                VStack(alignment: .leading, spacing: 10) {
                    Text("PIN (optional)").font(.headline)
                    TextField("Optional, e.g. 1234", text: $share.pin)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 160)
                        .onChange(of: share.pin) {
                            let digits = String(share.pin.filter(\.isNumber).prefix(8))
                            if digits != share.pin { share.pin = digits }
                        }
                    Text("Set a PIN to keep guests or neighbors on your Wi-Fi out. People enter it once per browser.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .card(padding: 18)

                VStack(alignment: .leading, spacing: 6) {
                    Label("Read-only: nothing can be changed or deleted from other devices.", systemImage: "lock")
                    Label("Only devices on the same network as this Mac can connect. Sharing isn’t encrypted, so set a PIN, and share only on Wi-Fi you trust.", systemImage: "house")
                    Label("Questions are answered by this Mac, so it has to stay awake with the app open.", systemImage: "desktopcomputer")
                    Label("The first time, macOS may ask to allow incoming connections. Click Allow.", systemImage: "checkmark.shield")
                    Label("In a power outage this needs the Wi-Fi router to have power (a small battery backup works).", systemImage: "bolt.badge.clock")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Share on Wi-Fi")
    }
}
