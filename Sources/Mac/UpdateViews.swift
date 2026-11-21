import SwiftUI

/// A quiet note at the bottom of the sidebar while a new version is waiting. Click it to see what's new.
struct UpdateSidebarCard: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        if let manifest = updater.pending {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(headline(manifest)).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.10)))
            .contentShape(Rectangle())
            .onTapGesture { updater.showingSheet = true }
            .help("See what’s new and install it")
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: "Show update") { updater.showingSheet = true }
            .padding(.horizontal, 10).padding(.top, 10)
        }
    }

    private var icon: String {
        if case .failed = updater.phase { return "exclamationmark.arrow.circlepath" }
        return "sparkles"
    }

    private func headline(_ manifest: UpdateManifest) -> String {
        switch updater.phase {
        case .downloading, .verifying: "Getting version \(manifest.version)…"
        case .installing: "Installing version \(manifest.version)…"
        default: "Version \(manifest.version) is ready"
        }
    }

    private var detail: String {
        switch updater.phase {
        case .failed: "The update didn’t finish. Click to try again."
        case .downloading, .verifying, .installing: "Click to see progress"
        default: "Click to see what’s new"
        }
    }
}

/// The update window: what's new, then download, check and reopen, with plain progress along the way.
struct UpdateSheet: View {
    @State private var updater = AppUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            content
        }
        .padding(24)
        .frame(width: 480)
        .interactiveDismissDisabled(updater.isBusy)
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .idle, .checking:
            header("Checking for updates…", symbol: "arrow.triangle.2.circlepath")
            ProgressView().frame(maxWidth: .infinity)
            buttons { Button("Cancel") { updater.showingSheet = false }.keyboardShortcut(.cancelAction) }

        case .upToDate:
            header("Offline Kit is up to date", symbol: "checkmark.circle.fill")
            Text("You have the newest version, \(AppUpdater.currentVersion).").foregroundStyle(.secondary)
            Text("Offline Kit is free. If it helps your family, you can [buy me a coffee](https://buymeacoffee.com/joeychappel).")
                .font(.caption).foregroundStyle(.secondary)
            buttons { Button("OK") { updater.showingSheet = false }.keyboardShortcut(.defaultAction) }

        case .available(let manifest):
            header("Offline Kit \(manifest.version) is ready", symbol: "sparkles")
            Text("You have version \(AppUpdater.currentVersion). The update is \(size(manifest.size)).")
                .foregroundStyle(.secondary)
            notes(manifest)
            Text("Offline Kit will close and reopen by itself. Anything playing stops, and downloads pick up where they left off. Your library, settings and progress stay as they are.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Skip This Version") { updater.skip() }
                Spacer()
                Button("Later") { updater.later() }.keyboardShortcut(.cancelAction)
                Button("Install and Reopen") { updater.install() }.keyboardShortcut(.defaultAction)
            }

        case .downloading(let manifest, let received):
            header("Downloading Offline Kit \(manifest.version)…", symbol: "arrow.down.circle")
            ProgressView(value: Double(received), total: Double(max(manifest.size, 1)))
            Text("\(size(received)) of \(size(manifest.size))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            buttons { Button("Cancel") { updater.cancel() }.keyboardShortcut(.cancelAction) }

        case .verifying(let manifest):
            header("Checking Offline Kit \(manifest.version)…", symbol: "checkmark.shield")
            ProgressView().frame(maxWidth: .infinity)
            Text("Making sure the download is complete and comes from Offline Kit’s developer.")
                .font(.caption).foregroundStyle(.secondary)

        case .installing(let manifest):
            header("Installing Offline Kit \(manifest.version)…", symbol: "arrow.triangle.2.circlepath")
            ProgressView().frame(maxWidth: .infinity)
            Text("Offline Kit will close and reopen in a moment.").font(.caption).foregroundStyle(.secondary)

        case .failed(let message, let manifest):
            header(manifest == nil ? "Couldn’t check for updates" : "The update didn’t finish", symbol: "exclamationmark.triangle.fill")
            Text(message).fixedSize(horizontal: false, vertical: true)
            buttons {
                if manifest != nil {
                    Button("Download in Browser") { NSWorkspace.shared.open(AppUpdater.downloadPage) }
                }
                Spacer()
                Button("Close") { updater.showingSheet = false }.keyboardShortcut(.cancelAction)
                if manifest != nil {
                    Button("Try Again") { updater.install() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func header(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.title3.weight(.semibold))
    }

    private func notes(_ manifest: UpdateManifest) -> some View {
        ScrollView {
            Text(manifest.notes.isEmpty ? "Fixes and improvements." : manifest.notes)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxHeight: 180)
        .fixedSize(horizontal: false, vertical: true)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
    }

    private func buttons<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack { Spacer(); content() }.padding(.top, 4)
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Settings › Updates: the version, the daily check, and a way to check now.
struct UpdateSettingsSection: View {
    @State private var updater = AppUpdater.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var updater = updater
        Section("Updates") {
            LabeledContent("Version", value: "\(AppUpdater.currentVersion) (\(AppUpdater.currentBuild))")
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            HStack {
                Button("Check Now") {
                    NSApp.keyWindow?.close()   // the Settings window; the update window opens on the main one
                    // The update sheet shows on the main window, so make sure one is open first.
                    MainWindow.run(openWindow: openWindow) { Task { await updater.check(userInitiated: true) } }
                }
                .disabled(updater.isBusy)
                Spacer()
                if let checked = updater.lastChecked {
                    Text("Last checked \(checked.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("When this Mac is online, Offline Kit asks about once a day whether there’s a newer version. Nothing about you or your kit is sent, and nothing is installed until you choose Install.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Settings › Free and open source: the license, where the source is, and the bundled license texts.
struct LicenseSettingsSection: View {
    static let source = URL(string: "https://github.com/JoeyChappel/offline-kit")!
    static let tip = URL(string: "https://buymeacoffee.com/joeychappel")!

    var body: some View {
        Section("Free and open source") {
            Text("Copyright © 2026 Joey Chappel. Offline Kit is free software under the GNU General Public License, version 3. It comes with no warranty. You can read, change and share its source code. If it helps your family, a tip keeps it growing.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Buy Me a Coffee") { NSWorkspace.shared.open(Self.tip) }
                Button("Source Code") { NSWorkspace.shared.open(Self.source) }
                Button("Licenses") { showLicenses() }
                    .help("Shows the licenses of Offline Kit and the software it includes")
            }
        }
    }

    /// Opens the license texts that ship inside the app, with the notices listing which covers what.
    private func showLicenses() {
        guard let folder = Bundle.main.url(forResource: "Licenses", withExtension: nil) else { return }
        let notices = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md")
        NSWorkspace.shared.activateFileViewerSelecting([notices ?? folder, folder].compactMap { $0 })
    }
}
