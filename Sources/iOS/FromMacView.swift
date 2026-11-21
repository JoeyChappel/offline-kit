import SwiftUI

/// The card at the top of Get on iPhone and iPad that opens "From your Mac".
struct FromMacCard: View {
    @State private var open = false
    private var transfers: MacTransfers { MacTransfers.shared }

    var body: some View {
        Button { open = true } label: {
            HStack(spacing: 14) {
                KitSymbol("laptopcomputer.and.arrow.down")
                VStack(alignment: .leading, spacing: 3) {
                    Text("From your Mac").font(.headline).foregroundStyle(Design.ink)
                    Text(transfers.activeCount > 0 ? "Downloading \(transfers.activeCount) item\(transfers.activeCount == 1 ? "" : "s") over Wi-Fi"
                                                   : "Download what you picked with Send to iPhone, over home Wi-Fi. No internet needed.")
                        .font(.callout).foregroundStyle(Design.muted).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $open) {
            NavigationStack { FromMacView() }
        }
        #if DEBUG
        // Test hook: -fromMacOpen YES opens the screen on launch.
        .onAppear { if UserDefaults.standard.bool(forKey: "fromMacOpen") { open = true } }
        #endif
    }
}

/// What the Mac picked with Send to iPhone: sizes, room on this phone, and downloads with pause, resume and retry.
struct FromMacView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var pin = ""
    @State private var spaceWarning: String?
    private var transfers: MacTransfers { MacTransfers.shared }

    var body: some View {
        List {
            switch transfers.phase {
            case .idle, .searching: searching
            case .loading: Section { HStack { ProgressView(); Text("Connecting to \(transfers.server?.name ?? "your Mac")…") } }
            case .needsPIN: pinEntry
            case .failed(let message):
                Section {
                    Label(message, systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                    Button("Search Again", systemImage: "arrow.clockwise") { transfers.browse() }
                }
                typeAddress
            case .ready: ready
            }
        }
        .navigationTitle("From your Mac")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            if transfers.phase == .ready {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Use a Different Mac", systemImage: "laptopcomputer") { transfers.forgetMac() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
        }
        .refreshable { await transfers.refresh() }
        .task { await transfers.start() }
        // While a download is stopped, check for the Mac now and then, and pick up where it left off when it's back.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if transfers.jobs.values.contains(where: \.isFailed) { await transfers.refresh() }
            }
        }
        #if DEBUG
        // Test hook: -fromMacDownloadAll YES starts everything waiting as soon as the list loads.
        .onChange(of: transfers.phase) {
            guard transfers.phase == .ready, UserDefaults.standard.bool(forKey: "fromMacDownloadAll") else { return }
            spaceWarning = transfers.download(transfers.items)
        }
        #endif
        .alert("Not enough room on this iPhone", isPresented: Binding(get: { spaceWarning != nil }, set: { if !$0 { spaceWarning = nil } })) {
            Button("OK") { spaceWarning = nil }
        } message: { Text(spaceWarning ?? "") }
    }

    // MARK: Connecting

    @ViewBuilder private var searching: some View {
        Section {
            HStack(spacing: 10) { ProgressView(); Text("Looking for Offline Kit on your Wi-Fi…") }
            ForEach(transfers.servers) { server in
                Button { Task { await transfers.connect(server) } } label: {
                    Label(server.name, systemImage: "laptopcomputer")
                }
            }
        } footer: {
            Text("On the Mac, open Offline Kit › Share on Wi-Fi and turn it on. This iPhone needs to be on the same Wi-Fi.")
        }
        typeAddress
    }

    private var typeAddress: some View {
        Section("Or type the address the Mac shows") {
            TextField("192.168.1.20:8080", text: $address)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .onSubmit { Task { await transfers.connect(address: address) } }
            Button("Connect") { Task { await transfers.connect(address: address) } }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var pinEntry: some View {
        Section {
            TextField("PIN", text: $pin).keyboardType(.numberPad)
            Button("Continue") { Task { await transfers.signIn(pin: pin) } }.disabled(pin.isEmpty)
            if let error = transfers.pinError { Text(error).foregroundStyle(.red).font(.callout) }
        } header: {
            Text("\(transfers.server?.name ?? "The Mac") has a PIN")
        } footer: {
            Text("It’s on the Mac in Offline Kit › Share on Wi-Fi.")
        }
    }

    // MARK: The list

    @ViewBuilder private var ready: some View {
        let items = transfers.items
        let waiting = items.filter { !transfers.isOnPhone($0) && transfers.jobs[$0.id] == nil }
        Section {
            LabeledContent("Mac", value: transfers.server?.name ?? "Mac")
            LabeledContent("Free on this iPhone", value: MacTransfers.bytes(transfers.freeSpace))
            if !waiting.isEmpty {
                let needed = transfers.needed(waiting)
                Button {
                    spaceWarning = transfers.download(waiting)
                } label: {
                    Label("Download \(waiting.count == 1 ? "It" : "All \(waiting.count)") · \(MacTransfers.bytes(needed))", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                }
                if needed > transfers.freeSpace {
                    Label("That’s more than the free space on this iPhone.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
        } footer: {
            Text("Downloads keep going if you switch apps or lock the phone, as long as it stays on the Mac’s Wi-Fi.")
        }

        if items.isEmpty {
            Section {
                Text("Nothing is waiting. On the Mac, right-click a movie, audiobook, book, game or reference and choose Send to iPhone, then pull down here to refresh.")
                    .foregroundStyle(.secondary)
            }
        } else {
            Section("Picked on \(transfers.server?.name ?? "the Mac")") {
                ForEach(items) { item in FromMacRow(item: item, spaceWarning: $spaceWarning) }
            }
        }
    }
}

private struct FromMacRow: View {
    let item: SendManifest.Item
    @Binding var spaceWarning: String?
    private var transfers: MacTransfers { MacTransfers.shared }

    var body: some View {
        let job = transfers.jobs[item.id]
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.kind.symbol).font(.title3).foregroundStyle(Color.accentColor).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).lineLimit(2)
                if let job {
                    ProgressView(value: job.fraction)
                    Text(status(job)).font(.caption).foregroundStyle(job.isFailed ? .red : .secondary).lineLimit(2)
                } else {
                    Text([item.detail ?? item.kind.label, MacTransfers.bytes(item.size)].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            controls(job)
        }
        .padding(.vertical, 2)
        .swipeActions {
            if job != nil { Button("Cancel", role: .destructive) { transfers.cancel(item.id) } }
        }
    }

    @ViewBuilder private func controls(_ job: MacTransfers.Job?) -> some View {
        if let job {
            if job.isRunning {
                Button { transfers.pause(item.id) } label: { Image(systemName: "pause.circle.fill").font(.title2) }
                    .accessibilityLabel("Pause \(item.title)")
            } else if job.isPaused {
                Button { transfers.resume(item.id) } label: { Image(systemName: "play.circle.fill").font(.title2) }
                    .accessibilityLabel("Resume \(item.title)")
            } else if job.isFailed {
                Button("Retry") { transfers.resume(item.id) }.buttonStyle(.bordered)
            }
        } else if transfers.isOnPhone(item) {
            Label("On iPhone", systemImage: "checkmark.circle.fill").labelStyle(.iconOnly).foregroundStyle(.green).font(.title2)
                .accessibilityLabel("On this iPhone")
        } else {
            Button { spaceWarning = transfers.download([item]) } label: { Image(systemName: "arrow.down.circle").font(.title2) }
                .accessibilityLabel("Download \(item.title)")
        }
    }

    private func status(_ job: MacTransfers.Job) -> String {
        let amounts = "\(MacTransfers.bytes(job.written)) of \(MacTransfers.bytes(job.size))"
        if job.isFailed { return job.error ?? "Didn’t finish. Tap Retry." }
        if job.isPaused { return "Paused · \(amounts)" }
        return amounts
    }
}
