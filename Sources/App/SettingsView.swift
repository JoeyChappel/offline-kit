import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(Library.self) private var library
    @Environment(AskModel.self) private var model
    @State private var showPicker = false
    /// What the file picker is for. Kept after it closes, so its result knows.
    @State private var picking = Picking.folder
    @State private var modelMessage: String?
    /// A large model file waiting on "copy it or use it where it is" (Mac).
    @State private var pendingModel: PendingModel?
    @State private var addingModel: String?
    @State private var removingModel: InstalledModel?
    /// Bumped when models are added or removed, so the list re-reads the Models folders.
    @State private var modelsChanged = 0

    private enum Picking { case folder, model }
    private struct PendingModel: Identifiable {
        let url: URL
        let name: String
        let size: Int64
        var id: URL { url }
    }

    var body: some View {
        @Bindable var model = model
        @Bindable var library = library
        Form {
            Section("Answers") {
                Picker("Answer with", selection: $model.choice) {
                    ForEach(EngineChoice.allCases) { Text($0.label).tag($0) }
                }
                LabeledContent("Apple Intelligence", value: AppleEngine.availability)
                Text("Automatic picks the best one available: the larger model in Ollama if it’s running, then the Offline Kit answer model, then Apple Intelligence. Answers are made on \(model.contextDestination).")
                    .font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced: Ollama (optional)") {
                    TextField("Ollama address", text: $model.ollamaHost)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        #endif
                    if let models = model.ollamaModels {
                        if models.isEmpty {
                            Text("Ollama is running but has no model yet. Download the larger answer model for it here.")
                                .foregroundStyle(.secondary)
                            OllamaModelDownload()
                        } else {
                            Picker("Ollama model", selection: $model.ollamaModel) {
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }
                        }
                    } else {
                        Text("Ollama isn’t running. That’s fine: it’s only needed if you want to use it.").foregroundStyle(.secondary)
                    }
                    if model.usesHomeNetwork {
                        Label("Questions, and the household details Ask uses with them, are sent to \(model.contextDestination) to be answered.",
                              systemImage: "wifi")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Check Again") { Task { await model.refreshOllama() } }
                }
            }

            answerModelSection

            ReadAloudSettingsSection()

            #if os(macOS)
            Section("Run from a USB drive") {
                if KitLocation.isPortable {
                    Label("Running from \(KitLocation.portableVolumeName ?? "an external drive")", systemImage: "externaldrive.fill")
                    Text("Your library and settings are kept on the drive with the app, so it works on any Apple silicon Mac with macOS 26 or later.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("To bring your private household details along too, set a passphrase in Prepare › What Ask knows.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Label("Currently running from this Mac", systemImage: "laptopcomputer")
                    Button("Copy Offline Kit to a Drive…") { openKitCopy() }
                    Text("Opens Kit Care › Copy my kit, which copies the app and your library to a USB drive and checks every file. Open the app from the drive and it runs, with that library, on any Apple silicon Mac with macOS 26 or later.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            #endif

            #if os(iOS)
            Section("Kit") {
                NavigationLink { KitCareView() } label: { Label("Kit Checkup", systemImage: "stethoscope") }
                Text("How current your references are, what needs fixing and how much room is left.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            #endif

            #if os(macOS)
            UpdateSettingsSection()
            LicenseSettingsSection()
            #endif

            Section("Welcome") {
                Button("Show Welcome Again") { showWelcome() }
                Text("Replays the short introduction shown when Offline Kit is first opened.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Use a library you already have") {
                ForEach(Library.defaultFolders, id: \.self) { url in
                    Label(url.path, systemImage: "folder").foregroundStyle(.secondary)
                }
                ForEach(library.extraFolders, id: \.self) { path in
                    HStack {
                        Label(path, systemImage: "folder.badge.plus")
                        Spacer()
                        Button("Remove", role: .destructive) {
                            library.extraFolders.removeAll { $0 == path }
                            Task { await library.reload() }
                        }
                    }
                }
                #if os(macOS)
                Button("Add a Drive or Folder…") { picking = .folder; showPicker = true }
                Text("Pick a drive or folder that already has an Offline Kit library on it. Libraries on connected USB drives are found automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                #endif
            }
        }
        .formStyle(.grouped)
        #if os(macOS)
        .frame(width: 560, height: 720)
        #endif
        // One picker for both uses: a view gets only one file importer.
        .fileImporter(isPresented: $showPicker, allowedContentTypes: picking == .folder ? [.folder] : Self.modelTypes) { result in
            guard case .success(let url) = result else { return }
            switch picking {
            case .folder:
                if !library.extraFolders.contains(url.path) {
                    library.extraFolders.append(url.path)
                    Task { await library.reload() }
                }
            case .model:
                chooseModel(url)
            }
        }
        .confirmationDialog("Add \(pendingModel?.name ?? "this model")?", isPresented: .constant(pendingModel != nil),
                            titleVisibility: .visible, presenting: pendingModel) { pending in
            Button("Copy to Library") { addModel(pending.url, inPlace: false); pendingModel = nil }
            Button("Use It Where It Is") { addModel(pending.url, inPlace: true); pendingModel = nil }
            Button("Cancel", role: .cancel) { pendingModel = nil }
        } message: { pending in
            Text("It’s \(ByteCountFormatter.string(fromByteCount: pending.size, countStyle: .file)). Copying keeps it with your library, so it travels with the kit. Using it where it is saves space, but Ask can use it only while the file stays there.")
        }
        .confirmationDialog("Remove \(removingModel?.shortName ?? "this model")?", isPresented: .constant(removingModel != nil),
                            titleVisibility: .visible, presenting: removingModel) { removing in
            Button(removing.inPlace ? "Remove" : "Delete", role: .destructive) { removeModel(removing) }
            Button("Cancel", role: .cancel) { removingModel = nil }
        } message: { removing in
            Text(removing.inPlace
                 ? "Offline Kit stops using it. The file stays where it is."
                 : "This deletes the model file from your library. It can’t be undone.")
        }
        .alert("Answer model", isPresented: .constant(modelMessage != nil)) {
            Button("OK") { modelMessage = nil }
        } message: { Text(modelMessage ?? "") }
        .task { await model.refreshOllama() }
    }

    // MARK: Answer model

    #if os(macOS)
    private static let modelTypes = [UTType(filenameExtension: "gguf") ?? .data]
    #else
    // Files may not know .gguf; any file can be picked and is checked before it's added.
    private static let modelTypes: [UTType] = [.data]
    #endif

    @ViewBuilder private var answerModelSection: some View {
        let _ = modelsChanged
        let _ = KitChanges.shared.models   // a download finished, or a model was added elsewhere
        let installed = LocalModels.installed(libraryFolders: library.folders)
        let selected = LocalModels.selected(in: installed, id: model.builtInModel)
        Section("Answer model") {
            if let selected {
                Picker("Offline Kit answer model", selection: Binding(get: { selected.id }, set: { model.builtInModel = $0 })) {
                    ForEach(installed) { Text($0.shortName).tag($0.id) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(selected.summary)
                    if selected.inPlace { Text("Used where it is: \(selected.url.path)").lineLimit(1).truncationMode(.middle) }
                    switch selected.plan {
                    case .tooBig(let needed, let available):
                        Label("Too big for \(ModelFit.deviceName): needs about \(ModelFit.gigabytes(needed)) of memory, \(ModelFit.gigabytes(available)) is available.",
                              systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    default: EmptyView()
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                LabeledContent("Offline Kit answer model") {
                    HStack(spacing: 10) {
                        Text("Not downloaded").foregroundStyle(.secondary)
                        Button("Get It…") { openGetResources() }
                    }
                }
            }
            if let addingModel {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Adding \(addingModel)…").foregroundStyle(.secondary)
                }
            }
            DisclosureGroup("Advanced: use your own model file") {
                if let selected, case .ready(let tokens) = selected.plan, selected.isCustom {
                    Text("Reads about \(tokens.formatted()) tokens at a time on \(ModelFit.deviceName).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("Use Your Own Model…") { picking = .model; showPicker = true }
                    if let selected, selected.isCustom {
                        Button(selected.inPlace ? "Stop Using…" : "Delete…", role: .destructive) { removingModel = selected }
                    }
                }
                .disabled(addingModel != nil)
                Text("Add any GGUF chat model, such as Llama 3.2 3B Instruct or Qwen 2.5 3B Instruct. A Q4_K_M version is a good balance of size and quality. Ask uses the model chosen here when it answers with the Offline Kit answer model.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// Checks the picked file, then copies it (or, for a big file on a Mac, asks whether to use it in place).
    private func chooseModel(_ url: URL) {
        let name = url.lastPathComponent
        Task {
            let checked: Result<(info: GGUFInfo, size: Int64), Error> = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return Result { try LocalModels.check(url) }
            }.value
            switch checked {
            case .failure(let error):
                modelMessage = error.localizedDescription
            case .success(let (info, size)):
                #if os(macOS)
                if size >= 1 << 30, !LocalModels.isInLibrary(url, libraryFolders: library.folders) {
                    pendingModel = PendingModel(url: url, name: info.displayName ?? name, size: size)
                    return
                }
                #endif
                addModel(url, inPlace: false)
            }
        }
    }

    private func addModel(_ url: URL, inPlace: Bool) {
        let destination = KitStorage.primaryLibrary
        addingModel = url.lastPathComponent
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { try LocalModels.add(url, toLibrary: destination, inPlace: inPlace) }
            }.value
            addingModel = nil
            switch result {
            case .success(let id):
                model.builtInModel = id
                modelsChanged += 1
                KitChanges.shared.modelsChanged()
            case .failure(let error):
                modelMessage = error.localizedDescription
            }
        }
    }

    private func removeModel(_ installed: InstalledModel) {
        removingModel = nil
        do {
            try LocalModels.remove(installed)
            if model.builtInModel == installed.id { model.builtInModel = "" }
            modelsChanged += 1
            KitChanges.shared.modelsChanged()
        } catch {
            modelMessage = "Couldn’t remove the model: \(error.localizedDescription)"
        }
    }

    /// The welcome sheet opens on the main window, so Settings closes first (or the sheet would sit behind it).
    private func showWelcome() {
        #if os(macOS)
        NSApp.keyWindow?.close()   // the Settings window
        DispatchQueue.main.async { NotificationCenter.default.post(name: .showOnboarding, object: nil) }
        #else
        NotificationCenter.default.post(name: .showOnboarding, object: nil)
        #endif
    }

    #if os(macOS)
    /// Copy my kit lives in Kit Care (checked, resumable, off the main thread); Settings just opens it.
    private func openKitCopy() {
        NSApp.keyWindow?.close()   // the Settings window; the main window comes forward showing Kit Care
        DispatchQueue.main.async { NotificationCenter.default.post(name: .openKitCopy, object: nil) }
    }
    #endif

    private func openGetResources() {
        NotificationCenter.default.post(name: .openGetResources, object: nil)
        #if os(macOS)
        NSApp.keyWindow?.close()   // the Settings window; the main window comes forward showing Get Resources
        #endif
    }

}
