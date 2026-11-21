import SwiftUI

// Private details on other Macs: an optional passphrase that lets a kit drive carry its household details
// (see PrivateStore for how the key is wrapped). Mac only; on iPhone and iPad nothing here appears.

/// Prepare › What Ask knows: turn the passphrase on, change it or turn it off.
struct PassphraseCard: View {
    @Environment(Household.self) private var household
    @State private var sheet: PassphraseSheet.Mode?
    @State private var confirmRemove = false
    @State private var confirmForget = false
    @State private var error: String?

    var body: some View {
        #if os(macOS)
        let _ = household.storeChanges
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                KitSymbol(PrivateStore.usesPassphrase ? "key.horizontal.fill" : "externaldrive.badge.person.crop")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use these details on other Macs").font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if PrivateStore.usesPassphrase {
                HStack(spacing: 10) {
                    Button("Change Passphrase…") { sheet = .change }
                    Button("Stop Using a Passphrase…", role: .destructive) { confirmRemove = true }
                }
                Button("Forget It on This Mac…") { confirmForget = true }
                    .buttonStyle(.borderless).font(.callout)
                    .help("Locks these details on this Mac now. You’ll need the passphrase to open them here again.")
                    .confirmationDialog("Forget the passphrase on this Mac?", isPresented: $confirmForget) {
                        Button("Forget and Lock Now") { household.forgetPassphraseOnThisMac() }
                    } message: {
                        Text("These details lock on this Mac right away, and you’ll need the passphrase to open them here again. Nothing is deleted, and other Macs aren’t affected.")
                    }
            } else if PrivateStore.canUsePassphrase {
                Button("Use a Passphrase…") { sheet = .set }.buttonStyle(.borderedProminent)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .card(padding: 18)
        .sheet(item: $sheet) { PassphraseSheet(mode: $0) }
        #if DEBUG
        .onAppear { if UserDefaults.standard.bool(forKey: "showPassphraseSheet") { sheet = PrivateStore.usesPassphrase ? .change : .set } }
        #endif
        .confirmationDialog("Stop using a passphrase?", isPresented: $confirmRemove) {
            Button("Move Details to This Mac", role: .destructive) {
                do { try household.removePassphrase(); error = nil } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Your private details move off the drive and back to this Mac only. Other Macs won’t be able to open them.")
        }
        #endif
    }

    private var subtitle: String {
        if PrivateStore.usesPassphrase {
            return "Protected by your passphrase and kept on this drive, so they open on any Mac it’s plugged into. If the drive is lost, the passphrase is all that protects them."
        }
        if PrivateStore.canUsePassphrase {
            return "Right now these details open only on this Mac. With a passphrase they’re kept, encrypted, on this drive and open on any Mac after you enter it once. If the drive is lost, the passphrase is all that protects them, so make it long."
        }
        return "These details open only on this Mac. To carry them to other Macs, run Offline Kit from a USB drive (Settings › Run from a USB drive), then set a passphrase here."
    }
}

/// Set or change the passphrase.
struct PassphraseSheet: View {
    enum Mode: String, Identifiable { case set, change; var id: String { rawValue } }
    let mode: Mode
    @Environment(Household.self) private var household
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var first = ""
    @State private var second = ""
    @State private var working = false
    @State private var error: String?

    static let minimumLength = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(mode == .set ? "Use a Passphrase" : "Change Passphrase").font(.title2.bold())
            Text("If the drive is lost or stolen, this passphrase is all that protects your family’s private details. Use a long one: four or more unrelated words is easy to remember and hard to guess.")
                .fixedSize(horizontal: false, vertical: true)
            if mode == .change {
                SecureField("Current passphrase", text: $current).textFieldStyle(.roundedBorder)
            }
            SecureField(mode == .change ? "New passphrase" : "Passphrase", text: $first).textFieldStyle(.roundedBorder)
            SecureField("Type it again", text: $second).textFieldStyle(.roundedBorder).onSubmit(save)
            Label(hint, systemImage: ready ? "checkmark.circle.fill" : "info.circle")
                .font(.callout).foregroundStyle(ready ? .green : .secondary)
            Label(recoveryNote, systemImage: "exclamationmark.lock")
                .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            if mode == .change {
                Label("Changing it doesn’t lock older copies. A copy of this drive, or of its “Offline Kit Private” folder, made before now still opens with the old passphrase, and Macs that remember it keep access.",
                      systemImage: "doc.on.doc")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(mode == .set ? "Use Passphrase" : "Change Passphrase", action: save)
                    .keyboardShortcut(.defaultAction).disabled(!ready || working)
            }
        }
        .padding(22)
        .frame(width: 460)
    }

    private var ready: Bool { first.count >= Self.minimumLength && first == second && (mode == .set || !current.isEmpty) }

    /// "This Mac can still open them" is true only when the key really is in this Mac's Keychain. Turning the passphrase
    /// on always saves it there; a Mac that unlocked without "Remember on this Mac" has it only until Offline Kit quits.
    private var recoveryNote: String {
        let base = "There’s no way to recover a forgotten passphrase. Without it, other Macs can’t open these details."
        if mode == .set || PrivateStore.remembersKeyOnThisMac {
            return base + " This Mac still can, through its own Keychain, so you can set a new one here."
        }
        return base + " This Mac doesn’t remember it, so it would need the passphrase too."
    }

    private var hint: String {
        if mode == .change && current.isEmpty { return "Enter your current passphrase." }
        if first.count < Self.minimumLength { return "At least \(Self.minimumLength) characters. Longer is better." }
        if first != second { return "The two don’t match yet." }
        return "Ready."
    }

    private func save() {
        guard ready else { return }
        working = true
        Task {
            defer { working = false }
            do {
                if mode == .change { try await household.changePassphrase(current: current, to: first) }
                else { try await household.setPassphrase(first) }
                dismiss()
            }
            catch { self.error = error.localizedDescription }
        }
    }
}

/// Asks for the drive's passphrase on a Mac that doesn't know it yet.
struct UnlockPrivateDetails: View {
    @Environment(Household.self) private var household
    /// Called after the details open, and for "Not Now" unless `notNow` is given.
    var onDone: (() -> Void)? = nil
    /// "Not Now": leaves the form without unlocking.
    var notNow: (() -> Void)? = nil
    /// A smaller form, for inside another card.
    var compact = false
    @State private var passphrase = ""
    @State private var remember = true
    @State private var working = false
    @State private var error: String?
    @State private var confirmErase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                KitSymbol("lock.fill")
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enter your passphrase").font(.headline)
                    Text(compact ? "Your own numbers are kept with this drive’s other private details, protected by a passphrase."
                                 : "This drive’s family plan, supplies, people and Ask history are protected by a passphrase. Enter it once to open them on this Mac.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            SecureField("Passphrase", text: $passphrase).textFieldStyle(.roundedBorder).onSubmit(unlock)
            Toggle("Remember on this Mac", isOn: $remember)
            Text(remember ? "Kept in this Mac’s Keychain, so you won’t be asked again here."
                          : "Asked again the next time Offline Kit opens.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Label(error, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red) }
            HStack {
                if let leave = notNow ?? onDone { Button("Not Now", action: leave) }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Open Details", action: unlock).buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction).disabled(passphrase.isEmpty || working)
            }
            if !compact {
                Divider()
                Text("Forgot it? There’s no way to recover it, and these details can’t be opened without it. The Mac where it was set up can still open them and set a new one, if it still remembers the passphrase.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Erase This Drive’s Details…", role: .destructive) { confirmErase = true }
                    .buttonStyle(.borderless).font(.caption)
                    .confirmationDialog("Erase this drive’s private details?", isPresented: $confirmErase) {
                        Button("Erase", role: .destructive) { household.eraseEverything(); onDone?() }
                    } message: {
                        Text("The family plan, supplies, people and history on this drive are deleted for good, on every Mac. This can’t be undone.")
                    }
            }
        }
        #if DEBUG
        // Test hook: -unlockPassphrase "…" [-rememberPassphrase NO] enters it automatically.
        .task {
            guard let test = UserDefaults.standard.string(forKey: "unlockPassphrase") else { return }
            passphrase = test
            remember = UserDefaults.standard.string(forKey: "rememberPassphrase")?.uppercased() != "NO"
            try? await Task.sleep(for: .seconds(1))
            unlock()
        }
        #endif
    }

    private func unlock() {
        guard !passphrase.isEmpty, !working else { return }
        working = true
        Task {
            defer { working = false }
            do {
                try await household.unlock(passphrase: passphrase, remember: remember)
                passphrase = ""
                onDone?()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// On launch, asks for the passphrase when this drive's details are locked (Mac).
struct PrivateUnlockPresentation: ViewModifier {
    @Environment(Household.self) private var household
    @State private var asking = false
    @State private var asked = false

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .sheet(isPresented: $asking) {
                UnlockPrivateDetails { asking = false }
                    .padding(22).frame(width: 480)
                    .environment(household)
            }
            .onChange(of: asking) { household.unlockPrompting = asking }
            .task {
                guard household.isLocked, !asked else { return }
                asked = true
                try? await Task.sleep(for: .seconds(1))   // let the window settle first
                asking = household.isLocked
            }
            #endif
            #if DEBUG
            // Test hook: -setPassphrase "…" turns the passphrase on at launch (drive mode only).
            .task {
                guard let pass = UserDefaults.standard.string(forKey: "setPassphrase"), !household.isLocked else { return }
                // -editWhileSettingPassphrase "fact" notes a fact while the key is being derived (checks nothing is lost).
                if let fact = UserDefaults.standard.string(forKey: "editWhileSettingPassphrase") {
                    Task { try? await Task.sleep(for: .milliseconds(150)); _ = household.remember(fact, about: nil, learned: false) }
                }
                try? await household.setPassphrase(pass)
            }
            .task {
                guard UserDefaults.standard.bool(forKey: "removePassphrase"), !household.isLocked else { return }
                try? household.removePassphrase()
            }
            #endif
    }
}
