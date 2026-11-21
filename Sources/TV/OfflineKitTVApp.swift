import SwiftUI

@main
struct OfflineKitTVApp: App {
    @State private var store = TVStore()

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .environment(store)
                .task { await store.start() }
        }
    }
}

struct TVRootView: View {
    @Environment(TVStore.self) private var store

    var body: some View {
        switch store.phase {
        case .ready: TVHomeView()
        case .needsPIN: TVPINView()
        default: TVConnectView()
        }
    }
}

// MARK: - Connect

struct TVConnectView: View {
    @Environment(TVStore.self) private var store
    @State private var address = ""
    @State private var typing = false
    @FocusState private var focus: Focus?

    private enum Focus: Hashable { case server(String), address }

    var body: some View {
        HStack(alignment: .top, spacing: 80) {
            VStack(alignment: .leading, spacing: 24) {
                Image(systemName: "play.tv").font(.system(size: 80)).foregroundStyle(.tint)
                Text("Offline Kit").font(.largeTitle.bold())
                Text("Watch movies and listen to audiobooks saved on your Mac. No internet needed, just your home Wi-Fi.")
                    .font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Label("Open Offline Kit on your Mac", systemImage: "1.circle.fill")
                    Label("Go to Share on Wi-Fi and turn it on", systemImage: "2.circle.fill")
                    Label("Pick your Mac here", systemImage: "3.circle.fill")
                }
                .font(.headline)
            }
            .frame(maxWidth: 700, alignment: .leading)

            VStack(alignment: .leading, spacing: 20) {
                switch store.phase {
                case .loading:
                    ProgressView("Connecting…")
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Search Again") { store.forgetServer() }
                default:
                    if store.servers.isEmpty {
                        HStack(spacing: 16) {
                            ProgressView()
                            Text("Looking for Macs on your Wi-Fi…").font(.headline)
                        }
                    } else {
                        Text(store.servers.count == 1 ? "Found your Mac" : "Choose your Mac").font(.headline)
                    }
                }
                ForEach(store.servers) { server in
                    Button { Task { await store.connect(server) } } label: {
                        Label(server.name, systemImage: "desktopcomputer").frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .focused($focus, equals: .server(server.id))
                }
                Button("Enter an Address…") { typing = true }
                    .foregroundStyle(.secondary)
                    .focused($focus, equals: .address)
            }
            .frame(width: 700, alignment: .leading)
        }
        .padding(80)
        // Highlight the first Mac as soon as it appears, so one click connects.
        .onChange(of: store.servers.first?.id) { _, id in
            if let id, focus == nil || focus == .address { focus = .server(id) }
        }
        .alert("Mac address", isPresented: $typing) {
            TextField("192.168.1.20:8080", text: $address)
                .keyboardType(.URL)
            Button("Connect") { Task { await store.connect(address: address) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It’s shown on the Mac in Offline Kit › Share on Wi-Fi.")
        }
    }
}

struct TVPINView: View {
    @Environment(TVStore.self) private var store
    @State private var pin = ""

    var body: some View {
        VStack(spacing: 30) {
            Image(systemName: "lock.fill").font(.system(size: 70)).foregroundStyle(.tint)
            Text("Enter the PIN").font(.largeTitle.bold())
            Text("\(store.server?.name ?? "This Mac") asks for a PIN. You’ll find it on the Mac in Offline Kit › Share on Wi-Fi.")
                .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            SecureField("PIN", text: $pin)
                .keyboardType(.numberPad)
                .frame(width: 400)
                .onSubmit { Task { await store.signIn(pin: pin) } }
            if let error = store.pinError {
                Text(error).foregroundStyle(.orange)
            }
            HStack(spacing: 30) {
                Button("Continue") { Task { await store.signIn(pin: pin) } }
                Button("Choose Another Mac") { store.forgetServer() }
            }
        }
        .padding(80)
    }
}
