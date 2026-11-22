import Foundation

/// A model file the app can run itself (llama.cpp), so answers work on any Mac or iPhone
/// without Ollama or Apple Intelligence. Kept in a "Models" folder beside the library.
struct LocalModel: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String
    let fileName: String
    let url: URL
    let size: Int64
    let sha256: String
    /// Tokens of context to allocate. Sources are sized from this.
    let contextTokens: Int32
    let recommendedOnPhone: Bool

    var license: String { "Apache 2.0, Google" }
    /// "Gemma 4 E4B"
    var shortName: String { String(title.prefix { $0 != "(" }).trimmingCharacters(in: .whitespaces) }

    /// A hand-made metalink for a single-URL download (Hugging Face supports ranges), checked by SHA-256.
    var metalink: Metalink {
        Metalink(fileName: fileName, size: size, sha256: sha256, pieceLength: nil, pieceSHA1: [], mirrors: [url])
    }

    /// Catalog-style entry so the download queue can treat it like an archive.
    var catalogEntry: CatalogEntry {
        CatalogEntry(name: id, flavour: "", title: title, summary: detail, size: size,
                     metalink: url, issued: "", articleCount: 0)
    }
}

enum LocalModels {
    static let gemma4E4B = LocalModel(
        id: "gemma-4-e4b",
        title: "Gemma 4 E4B (recommended for Macs)",
        detail: "Google's 4-billion-parameter Gemma 4, 4-bit. Reads more sources and writes better answers.",
        fileName: "gemma-4-E4B_q4_0-it.gguf",
        url: URL(string: "https://huggingface.co/google/gemma-4-E4B-it-qat-q4_0-gguf/resolve/main/gemma-4-E4B_q4_0-it.gguf")!,
        size: 5_154_941_280,
        sha256: "676c35070db6dbe52f93e9c864ee0fba4eddea94b9c875d9cb10daff453fbaee",
        contextTokens: 8192,
        recommendedOnPhone: false)

    static let gemma4E2B = LocalModel(
        id: "gemma-4-e2b",
        title: "Gemma 4 E2B (recommended for iPhone and iPad)",
        detail: "Google's 2-billion-parameter Gemma 4, 4-bit. Smaller and faster; fits phones with 8 GB of memory.",
        fileName: "gemma-4-E2B_q4_0-it.gguf",
        url: URL(string: "https://huggingface.co/google/gemma-4-E2B-it-qat-q4_0-gguf/resolve/main/gemma-4-E2B_q4_0-it.gguf")!,
        size: 3_349_516_256,
        sha256: "fa401b55b07ee70a54c6dae3903c783a6e65064312529ea57175cb5f8dec6634",
        contextTokens: 6144,
        recommendedOnPhone: true)

    static let all = [gemma4E4B, gemma4E2B]

    static func model(id: String) -> LocalModel? { all.first { $0.id == id } }

    static var recommended: LocalModel {
        #if os(iOS)
        gemma4E2B
        #else
        gemma4E4B
        #endif
    }

    /// The "Models" folder beside a library folder.
    static func folder(forLibrary library: URL) -> URL {
        library.appending(path: "Models", directoryHint: .isDirectory)
    }

    /// Installed model files, best first: the recommended model for this device, the other built-in one,
    /// then any other GGUF the person added (copied into a Models folder, or used where it is).
    static func installed(libraryFolders: [URL]) -> [InstalledModel] {
        let fm = FileManager.default
        var found: [InstalledModel] = []
        func add(_ url: URL, inPlace: Bool) {
            guard url.pathExtension.lowercased() == "gguf",
                  fm.fileExists(atPath: url.path), !fm.fileExists(atPath: url.path + ".okdl"),
                  !found.contains(where: { $0.url.lastPathComponent == url.lastPathComponent }) else { return }
            let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            if let known = all.first(where: { $0.fileName == url.lastPathComponent }) {
                found.append(InstalledModel(url: url, known: known, info: nil, size: size, inPlace: inPlace))
            } else if let info = GGUFInfo.cached(url), info.type != "mmproj", info.architecture != "clip",
                      (info.splitCount ?? 1) <= 1 {
                found.append(InstalledModel(url: url, known: nil, info: info, size: size, inPlace: inPlace))
            }
        }
        for library in libraryFolders {
            let dir = folder(forLibrary: library)
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) { add(url, inPlace: false) }
        }
        for path in customPaths { add(URL(fileURLWithPath: path), inPlace: true) }
        return found.sorted { a, b in
            switch (a.known, b.known) {
            case let (x?, y?):
                if x == recommended { return true }
                if y == recommended { return false }
                return x.size > y.size
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.shortName.localizedStandardCompare(b.shortName) == .orderedAscending
            }
        }
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cached: (folders: [String], models: [InstalledModel])?

    /// Same list as `installed(libraryFolders:)`, remembered until a model is added or removed, a download or a folder
    /// change reports new models (`KitChanges.modelsChanged`), or the folders differ. For views, which ask on every redraw
    /// (a download progress tick, say) and would otherwise list the Models folders and stat every file each time.
    static func installedCached(libraryFolders: [URL]) -> [InstalledModel] {
        let key = libraryFolders.map(\.path)
        if let hit = cacheLock.withLock({ cached.flatMap { $0.folders == key ? $0.models : nil } }) { return hit }
        let models = installed(libraryFolders: libraryFolders)
        cacheLock.withLock { cached = (key, models) }
        return models
    }

    /// Forget the remembered list; the next `installedCached` reads the folders again.
    static func invalidateInstalledCache() { cacheLock.withLock { cached = nil } }

    /// The model Ask uses: the one chosen in Settings when it's installed, else the best installed one.
    static func selected(libraryFolders: [URL], id: String) -> InstalledModel? {
        selected(in: installed(libraryFolders: libraryFolders), id: id)
    }

    static func selected(in installed: [InstalledModel], id: String) -> InstalledModel? {
        installed.first { $0.id == id } ?? installed.first
    }

    // MARK: Your own models

    private static let customPathsKey = "customModelPaths"

    /// Model files used where they are (not copied into the library), Mac only.
    static var customPaths: [String] {
        get { KitSettings.shared.stringArray(forKey: customPathsKey) ?? [] }
        set { KitSettings.shared.set(newValue, forKey: customPathsKey); invalidateInstalledCache() }
    }

    /// Checks a GGUF someone picked: a real chat model, in one file, that fits in this device's memory.
    static func check(_ url: URL) throws -> (info: GGUFInfo, size: Int64) {
        let info = try GGUFInfo.read(url)
        if info.type == "mmproj" || info.architecture == "clip" { throw GGUFError.visionAddOn }
        if let parts = info.splitCount, parts > 1 { throw GGUFError.split(parts) }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        switch ModelFit.plan(info: info, fileSize: size) {
        case .ready: break
        case .tooBig(let needed, let available): throw LlamaError.tooBig(needed: needed, available: available)
        case .contextTooSmall(let n): throw GGUFError.contextTooSmall(n)
        }
        return (info, size)
    }

    enum AddError: LocalizedError {
        case nameTaken(String), noSpace(needed: Int64, free: Int64)
        var errorDescription: String? {
            switch self {
            case .nameTaken(let name): "A different model named \(name) is already in your library. Rename the file and try again."
            case .noSpace(let needed, let free):
                "There isn't enough space for this model: it needs \(ModelFit.gigabytes(needed)) and \(free > 0 ? "only \(ModelFit.gigabytes(free)) is free" : "the drive is full"). Free up space or use it where it is."
            }
        }
    }

    /// Adds a checked model: copies it into `library`'s Models folder, or (Mac) remembers it where it is.
    /// Returns the model's id for the Settings choice. Blocking; call off the main thread.
    static func add(_ source: URL, toLibrary library: URL, inPlace: Bool) throws -> String {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let (_, size) = try check(source)
        let fm = FileManager.default
        let id = "file:" + source.lastPathComponent
        if inPlace {
            if !customPaths.contains(source.path) { customPaths.append(source.path) }
            return id
        }
        let dir = folder(forLibrary: library)
        let destination = dir.appending(path: source.lastPathComponent)
        if destination.standardizedFileURL.path == source.standardizedFileURL.path { return id }
        if fm.fileExists(atPath: destination.path) {
            let existing = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1)
            guard existing == size else { throw AddError.nameTaken(source.lastPathComponent) }
            return id
        }
        defer { invalidateInstalledCache() }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let free = (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? Int64.max
        guard free > size + (200 << 20) else { throw AddError.noSpace(needed: size, free: free) }
        // Copy under a temporary name, so a half-copied file is never listed.
        let partial = dir.appending(path: "." + source.lastPathComponent + ".copying")
        try? fm.removeItem(at: partial)
        do {
            try fm.copyItem(at: source, to: partial)
            try fm.moveItem(at: partial, to: destination)
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
        customPaths.removeAll { $0 == source.path }
        return id
    }

    /// True when the file is already in one of these libraries' Models folders.
    static func isInLibrary(_ url: URL, libraryFolders: [URL]) -> Bool {
        let dir = url.deletingLastPathComponent().standardizedFileURL.path
        return libraryFolders.contains { folder(forLibrary: $0).standardizedFileURL.path == dir }
    }

    /// Removes a model the person added: forgets one used in place, deletes one copied into the library.
    static func remove(_ model: InstalledModel) throws {
        guard model.isCustom else { return }
        defer { invalidateInstalledCache() }
        if model.inPlace {
            customPaths.removeAll { $0 == model.url.path }
        } else {
            try FileManager.default.removeItem(at: model.url)
        }
    }
}

/// A model file Ask can run: one of the built-in Gemma downloads, or a GGUF the person added.
struct InstalledModel: Identifiable, Hashable, Sendable {
    let url: URL
    /// The catalog entry when this is one of Offline Kit's own downloads.
    let known: LocalModel?
    /// Header details, read for models the person added.
    let info: GGUFInfo?
    let size: Int64
    /// Used where it is rather than copied into a Models folder.
    let inPlace: Bool

    var id: String { known?.id ?? "file:" + url.lastPathComponent }
    var isCustom: Bool { known == nil }

    /// "Gemma 4 E4B", "Llama 3.2 3B Instruct"
    var shortName: String {
        known?.shortName ?? info?.displayName ?? url.deletingPathExtension().lastPathComponent
    }

    /// "2.0 GB · 3.2B parameters · Q4_K_M"
    var summary: String {
        var parts = [ByteCountFormatter.string(fromByteCount: size, countStyle: .file)]
        if let known { parts.append(known.detail) }
        if let params = info?.parameterText { parts.append(params) }
        if let quant = info?.quantization { parts.append(quant) }
        return parts.joined(separator: " · ")
    }

    /// Context to run with, or why it can't run here. Built-in models keep their tested settings.
    var plan: ModelFit.Plan {
        if let known { return .ready(contextTokens: known.contextTokens) }
        guard let info else { return .tooBig(needed: size, available: ModelFit.memoryBudget) }
        return ModelFit.plan(info: info, fileSize: size)
    }

    static func == (a: InstalledModel, b: InstalledModel) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}
