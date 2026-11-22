import Foundation
import Observation

enum EngineChoice: String, CaseIterable, Identifiable {
    case auto, builtIn, apple, ollama
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: "Automatic"
        case .builtIn: "Offline Kit answer model"
        case .apple: "Apple Intelligence"
        case .ollama: "Ollama (larger model)"
        }
    }
}

struct Turn: Identifiable, Equatable {
    enum Status { case searching, answering, done, failed, stopped }
    let id = UUID()
    let question: String
    let started = Date()
    var finished: Date?
    var answer = ""
    var sources: [Source] = []
    var status: Status = .searching
    /// The friendly name of the model that answered ("Answer model (larger)").
    var engine = ""
    /// Its technical name ("Ollama · gemma4:12b"), for a tooltip.
    var engineDetail = ""
    var runsOnDevice = true
    var error: String?
    /// The private context sent with this question, shown under "What Ask used".
    var context = ""
    var isEmergency = false
    /// Facts Ask noted from this question, shown with an Undo.
    var noted: [Memory] = []
    /// When the first search missed and a corrected or reworded search was used instead.
    var searchedFor: String?
    /// True while the built-in answer model is still loading into memory, before the first words arrive.
    var waking = false
    /// The model ran out of room and stopped mid-answer.
    var cutShort = false
    /// The topic the question was scoped to, so Try Again asks it the same way.
    var scope: SubjectTopic?
}

@MainActor @Observable
final class AskModel {
    var turns: [Turn] = []
    /// Set while someone may be in danger: shows the can't-miss alert and quiets the rest of the app.
    var alert: EmergencyAlert?

    var choice: EngineChoice {
        didSet { KitSettings.shared.set(choice.rawValue, forKey: "engineChoice") }
    }
    var ollamaHost: String {
        didSet { KitSettings.shared.set(ollamaHost, forKey: "ollamaHost") }
    }
    var ollamaModel: String {
        didSet { KitSettings.shared.set(ollamaModel, forKey: "ollamaModel") }
    }
    /// Which installed model the built-in engine runs (`InstalledModel.id`). Empty: the recommended one.
    var builtInModel: String {
        didSet { KitSettings.shared.set(builtInModel, forKey: "builtInModel") }
    }

    private(set) var ollamaModels: [String]? = nil
    /// Library folders, for finding a built-in model file (kept current by `ask` and Wi-Fi sharing).
    var libraryFolders: [URL] = []
    var isBusy: Bool { task != nil }
    var usesHomeNetwork: Bool {
        guard choice != .apple, choice == .ollama || !(ollamaModels ?? []).isEmpty,
              let host = URL(string: ollamaHost) else { return false }
        return !OllamaEngine.isLocalHost(host)
    }
    /// Where a question and the private household context sent with it go to be answered, for privacy wording:
    /// "this Mac", or another computer running Ollama on the home network when one is set up.
    var contextDestination: String {
        if usesHomeNetwork { return "the Ollama computer you chose on your home network" }
        #if os(macOS)
        return "this Mac"
        #else
        return "this device"
        #endif
    }
    private var task: Task<Void, Never>?
    /// The after-answer pass that notes lasting facts. Separate from `task` so it never blocks the next question.
    private var learnTask: Task<Void, Never>?
    /// The engine that answered last, told when the conversation starts over.
    private var lastEngine: AnswerEngine?
    /// The oldest turn the conversation history still includes. Older turns are dropped a few at a time, so the
    /// history keeps the same beginning for several turns (and the model's saved state of it stays usable).
    private var historyStart: UUID?
    private var requestID = UUID()

    /// http(s) to localhost, a ".local" name or a private IPv4 address.
    nonisolated static func isHomeNetworkAddress(_ address: String) -> Bool {
        guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? ""),
              let host = url.host()?.lowercased() else { return false }
        if host == "localhost" || host.hasSuffix(".local") || host == "::1" { return true }
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4, host.split(separator: ".").count == 4 else { return false }
        return p[0] == 127 || p[0] == 10 || (p[0] == 192 && p[1] == 168) || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 169 && p[1] == 254)
    }

    init() {
        let d = KitSettings.shared
        choice = EngineChoice(rawValue: d.string(forKey: "engineChoice") ?? "") ?? .auto
        // Questions and household details go to this address, so a saved one (which may come from a kit drive's
        // settings file) must be on this computer or the home network; anything else falls back to this Mac.
        let saved = d.string(forKey: "ollamaHost") ?? ""
        ollamaHost = Self.isHomeNetworkAddress(saved) ? saved : OllamaEngine.defaultHost.absoluteString
        ollamaModel = d.string(forKey: "ollamaModel") ?? "gemma4:12b"
        builtInModel = d.string(forKey: "builtInModel") ?? ""
    }

    /// Who Ask is. Shared by questions asked here and over Wi-Fi sharing (which never gets personal context).
    static let instructions = """
    You are the calm, steady guide inside Offline Kit, a family's offline emergency library. The internet may be \
    down and help may be far away. The person asking may be scared, rushed or unsure what to do.
    How you speak:
    - Calm, clear and kind: the voice of reason. Never alarmed, dramatic or preachy.
    - Lead with what to do. Short sentences. Numbered steps for anything hands-on.
    - Plain words. Explain a technical term the first time you use it.
    - Stick to facts. Never guess at doses, wiring, gas or structural safety; say what to check instead.
    - A few words of reassurance when it helps, then back to the facts.
    How you answer:
    - Answer what they mean, not the literal words. Read the earlier conversation first: a short follow-up \
    ("what about first?", "and for kids?") continues the last topic.
    - Questions about Offline Kit itself (what's downloaded, what you know, what you can do) are answered from \
    the description of their kit. Don't look for the words in the sources, and don't say you couldn't find it.
    - The numbered sources come from a keyword search of their offline library and are often unrelated. Use \
    only sources that actually answer the question. Ignore the rest completely: don't mention them, list them \
    or stretch them to fit.
    - Base answers on the useful sources. Cite them inline like [1] or [2][3]. Every step or fact taken from a \
    source carries its citation.
    - If you're told about the person, household, skills or supplies, use it where it changes the answer: match \
    the detail to their skills, work with what they have, and mention a missing supply only when it matters. \
    Leave out personal details that don't affect this question; never force them in.
    - Only if none of the sources help, your very first sentence must be "I couldn't find this in your offline \
    library." Say it before anything else: no steps, tips or advice before it. Then you may add a short answer \
    from general knowledge under the heading "Not from the library:". Never write uncited steps outside that \
    heading. If the sources help with part of it, answer that part from them with citations and put only the \
    rest under that heading.
    - For "what if" and hypothetical questions: state your assumptions, reason step by step from established \
    facts, and keep the scenario exactly as the person set it up across follow-ups. When they change or correct \
    it, restate the new scenario in one line before answering. Don't simplify their setup into an easier one.
    - If the question is about a gas, water or electrical problem (a gas smell, a burst pipe, a sparking outlet) \
    and you're told where that shut-off is, say where it is in the first steps. If you aren't told, say to look for \
    it and suggest writing it in Prepare afterward.
    - Mention a part of Offline Kit only when it directly helps (for example Emergency info for phone numbers and \
    radio frequencies, or Prepare for their checklist). Don't end answers with "find more in your library" lines.
    - Only for medical, electrical, gas, chemical or structural safety topics, end with one line telling them to \
    double-check the cited article and get professional help when it's available. Leave it off everyday topics \
    like cooking, knots, camping, gardening, cars or how-to questions.
    - Write the heading as plain text exactly "Not from the library:" (no bold, no other wording).
    """

    /// Added when someone may be in danger right now.
    static let emergencyInstructions = """

    THIS MAY BE AN EMERGENCY. Someone may be in danger right now.
    - Start with the single most important action, in a few words.
    - Then numbered steps, at most 8, one short sentence each. No background.
    - If calling 911, Poison Help or 988 is right, make that step 1.
    - Stay calm and reassuring.
    """

    /// The answer model Ask will use, in plain words, with its technical name for a tooltip.
    func engineLabel(libraryFolders: [URL]) -> (name: String, detail: String) {
        let ollamaReady = !(ollamaModels ?? []).isEmpty
        let builtIn = LocalModels.selected(in: installedBuiltIn(libraryFolders: libraryFolders), id: builtInModel)
        let larger = ("Answer model (larger)", "Ollama · \(ollamaModel)")
        let apple = ("Apple Intelligence", "Apple Intelligence on-device model")
        let mine = builtIn.map { ("Answer model", "Offline Kit answer model · \($0.shortName)") }
        switch choice {
        case .apple: return AppleEngine.isAvailable ? apple : ("Apple Intelligence is off", AppleEngine.availability)
        case .ollama: return ollamaReady ? larger : ("Ollama isn’t running", "Ollama at \(ollamaHost)")
        case .builtIn: return mine ?? ("Answer model not downloaded", "Get it in Get Resources")
        case .auto:
            if ollamaReady { return larger }
            if let mine { return mine }
            return AppleEngine.isAvailable ? apple : ("No answer model yet", "Get the answer model in Get Resources")
        }
    }

    /// Installed model files are listed from disk; a label redrawn on every keystroke shouldn't do that each time.
    private var installedCache: (folders: [URL], at: Date, models: [InstalledModel])?

    private func installedBuiltIn(libraryFolders: [URL]) -> [InstalledModel] {
        if let cache = installedCache, cache.folders == libraryFolders, Date().timeIntervalSince(cache.at) < 5 {
            return cache.models
        }
        let models = LocalModels.installed(libraryFolders: libraryFolders)
        installedCache = (libraryFolders, Date(), models)
        return models
    }

    /// The last look at what Ollama has installed, so a question doesn't wait on a probe (up to 2 seconds
    /// when the home computer is away) every time.
    private var ollamaProbe: (host: String, models: [String]?, at: Date)?
    private static let ollamaProbeLifetime: TimeInterval = 30

    private func probeOllama(host: URL, force: Bool) async -> [String]? {
        if !force, let probe = ollamaProbe, probe.host == host.absoluteString,
           Date().timeIntervalSince(probe.at) < Self.ollamaProbeLifetime {
            return probe.models
        }
        let models = await OllamaEngine.installedModels(host: host)
        ollamaProbe = (host.absoluteString, models, Date())
        return models
    }

    /// Looks for Ollama. `force: false` accepts a result from the last 30 seconds; Check Again always asks.
    func refreshOllama(force: Bool = true) async {
        guard let url = URL(string: ollamaHost) else { ollamaModels = nil; return }
        ollamaModels = await probeOllama(host: url, force: force)
        if let models = ollamaModels, !models.isEmpty, !models.contains(ollamaModel) {
            ollamaModel = models[0]
        }
    }

    /// Loads the built-in answer model in the background when Ask would use it, so the first question
    /// doesn't wait for it. Call once Ollama has been looked for.
    func preloadIfNeeded(libraryFolders: [URL]) {
        guard let engine = preloadEngine(libraryFolders: libraryFolders) else { return }
        engine.preload(instructions: Self.instructions)
    }

    /// Ask opened: gets everything the first question needs ready in the background, the main thread never
    /// waiting on it: the answer model (loaded, with the instructions and this household's context evaluated),
    /// and the searches (each reference's search index opened, the word embeddings loaded).
    func preloadIfNeeded(library: Library, household: Household?) {
        libraryFolders = library.folders
        Retriever.warm(library.books.map(\.archive))
        guard let engine = preloadEngine(libraryFolders: library.folders) else { return }
        let kit = Self.kitSummary(library)
        Task { [weak self] in
            // The household loads just after launch; its context is part of every question's start.
            await household?.ensureLoaded()
            guard let self, self.task == nil else { engine.preload(instructions: Self.instructions); return }
            let context = AskContext.build(household?.data ?? HouseholdData(privacy: AskPrivacy(personalize: false)),
                                           kit: kit, limit: engine.contextBudget)
            let head = Self.promptHead(context: context, history: self.conversationSoFar(engine: engine, context: context))
            engine.preload(instructions: self.currentInstructions, head: head)
        }
    }

    private func preloadEngine(libraryFolders: [URL]) -> LlamaEngine? {
        guard choice == .builtIn || (choice == .auto && (ollamaModels ?? []).isEmpty),
              let installed = LocalModels.selected(in: installedBuiltIn(libraryFolders: libraryFolders), id: builtInModel)
        else { return nil }
        return LlamaEngine(model: installed)
    }

    /// Ask's instructions for the next question: the emergency version while an alert is showing.
    private var currentInstructions: String { Self.instructions + (alert != nil ? Self.emergencyInstructions : "") }

    /// Picks an engine. Automatic prefers Ollama (bigger model and context) when it's running.
    func resolveEngine() async -> AnswerEngine? {
        // Only Automatic and Ollama look for Ollama; the other choices never wait on it.
        let ollama: AnswerEngine? = await {
            guard choice == .auto || choice == .ollama, let url = URL(string: ollamaHost),
                  let models = await probeOllama(host: url, force: false), !models.isEmpty else { return nil }
            let model = models.contains(ollamaModel) ? ollamaModel : models[0]
            return OllamaEngine(host: url, model: model)
        }()
        let apple: AnswerEngine? = AppleEngine.isAvailable ? AppleEngine() : nil
        let builtIn: AnswerEngine? = LocalModels.selected(libraryFolders: libraryFolders, id: builtInModel)
            .map { LlamaEngine(model: $0) }
        switch choice {
        case .apple: return apple
        case .ollama: return ollama
        case .builtIn: return builtIn
        // Biggest model first: Ollama on this Mac, then the built-in Gemma 4, then Apple's small model.
        case .auto: return ollama ?? builtIn ?? apple
        }
    }

    func stop() {
        learnTask?.cancel()
        learnTask = nil
        task?.cancel()
        task = nil
        requestID = UUID()
        if let last = turns.indices.last, turns[last].status == .searching || turns[last].status == .answering {
            turns[last].status = .stopped
            turns[last].finished = Date()
        }
    }

    /// The conversation New Conversation just cleared, kept briefly so Undo can bring it back.
    private(set) var clearedTurns: [Turn]?
    private(set) var clearedAt = Date.distantPast

    func clear() {
        stop()
        if !turns.isEmpty { clearedTurns = turns; clearedAt = Date() }
        turns.removeAll()
        historyStart = nil
        lastEngine?.forgetConversation()
    }

    /// Undo for New Conversation. Does nothing if a new question has been asked since.
    func restoreCleared() {
        guard let saved = clearedTurns, turns.isEmpty else { clearedTurns = nil; return }
        turns = saved
        clearedTurns = nil
        historyStart = nil
    }

    func dismissUndo() { clearedTurns = nil }

    /// Asks the last question again after it failed or was stopped, replacing that turn.
    func retryLast(library: Library, household: Household?) {
        guard !isBusy, let last = turns.last, last.status == .failed || last.status == .stopped else { return }
        turns.removeLast()
        if !ask(last.question, library: library, scope: last.scope, household: household) { turns.append(last) }
    }

    /// The Emergency button: show the alert and switch to short, steps-first answers.
    /// An alert raised by the words of a question becomes the full emergency screen, keeping its advice.
    func startEmergency() {
        if var current = alert {
            current.detected = false
            alert = current
        } else {
            alert = .general
        }
    }

    /// True while the Emergency button's full-window emergency screen is showing (not a smaller detected alert).
    var isFullEmergency: Bool { alert.map { !$0.detected } ?? false }

    func endEmergency() { alert = nil }

    /// Returns whether the question was taken, so the caller only clears what the person typed when it was.
    @discardableResult
    func ask(_ rawQuestion: String, library: Library, scope: SubjectTopic? = nil, household: Household? = nil) -> Bool {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, task == nil else { return false }
        clearedTurns = nil
        // A new question outranks noting facts from the last one.
        learnTask?.cancel()
        learnTask = nil
        libraryFolders = library.folders
        // Words that sound like danger now raise a smaller alert; once the Emergency button is on, it stays full-window.
        if var found = EmergencyAlert.detect(in: question) {
            if isFullEmergency { found.detected = false }
            alert = found
        }
        let emergency = alert != nil
        var turn = Turn(question: question)
        turn.scope = scope
        turn.isEmergency = emergency
        turns.append(turn)
        let index = turns.count - 1
        // A short follow-up ("would we notice it first?") is searched together with the question before it.
        let previous = turns.dropLast().last(where: { $0.status == .done })?.question
        let searchText = previous.map { Self.isFollowUp(question) ? $0 + " " + question : question } ?? question
        // The bare question is always tried first; the merged one is the fallback for a follow-up.
        let retrievalQuestion = scope.map { "\($0.title): \(question)" } ?? question
        let aboutKit = Self.isAboutKit(question)
        let request = UUID()
        requestID = request

        task = Task { [weak self] in
            guard let self else { return }
            // The answer index builds in the background; it waits while a question is answered.
            AnswerIndex.shared.beginAsk()
            defer {
                AnswerIndex.shared.endAsk()
                if self.requestID == request { self.task = nil }
            }

            // Asked while the library is still opening (a big USB drive takes a while): wait, then search all of it.
            while library.isLoading {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, self.requestID == request else { return }
            }
            // Movies, comics and sports encyclopedias match everyday words ("Water & Power", "The App") and crowd
            // out real answers; leave them out unless the question is about entertainment.
            let wantsEntertainment = Self.matches(#"\b(movie|film|actor|actress|comic|superhero|sport|team|player|league|game|football|soccer|baseball|basketball|hockey|tennis|golf)s?\b"#, question)
            let allArchives = library.books
                .filter { book in scope.map { $0.area.contains(archiveName: book.archive.name) } ?? true }
                .filter { wantsEntertainment || !Self.isEntertainment($0.archive.name) }
                .map(\.archive)
            // Health questions search the medical references first (MedlinePlus, WikiMed, MDWiki, the medical PDFs).
            let medical = Self.isHealthQuestion(question) ? allArchives.filter { Self.isMedical($0.name) } : []
            let archives = allArchives
            let kit = Self.kitSummary(library)

            let resolved = await resolveEngine()
            guard !Task.isCancelled, self.requestID == request else { return }
            guard let engine = resolved else {
                fail(index, "No answer model is ready yet. Download the Offline Kit answer model in Get Resources, or turn on Apple Intelligence in System Settings.")
                return
            }
            lastEngine = engine
            turns[index].engine = engine.displayName
            turns[index].engineDetail = engine.technicalName
            turns[index].runsOnDevice = engine.runsOnDevice
            // Start loading the built-in model now, and evaluating the instructions, while the library is searched.
            (engine as? LlamaEngine)?.preload(instructions: Self.instructions)

            // The household loads just after launch; a question asked in that moment waits for it.
            await household?.ensureLoaded()
            guard !Task.isCancelled, self.requestID == request else { return }
            let data = household?.data ?? HouseholdData(privacy: AskPrivacy(personalize: false))
            let context = AskContext.build(data, kit: kit, limit: engine.contextBudget)
            let earlier = conversationSoFar(engine: engine, context: context)
            turns[index].context = context
            let instructions = Self.instructions + (emergency ? Self.emergencyInstructions : "")

            // Personal context and history share the model's window with the sources, which get the rest of it:
            // too much text would only be refused and asked again with less.
            let small = engine.sourceBudget < 10_000
            var budget = max(2_000, small ? engine.sourceBudget - context.count - earlier.count
                                          : min(engine.sourceBudget, engine.promptBudget - context.count - earlier.count))
            // A follow-up usually needs the model's keyword search below (its words lean on the question before):
            // start writing it now, on the model, while the library is searched. Cancelled if it isn't needed.
            let earlyKeywords: Task<String?, Never>? = !aboutKit && !emergency && searchText != question
                ? Task { await Self.searchWords(for: searchText, engine: engine) } : nil
            defer { earlyKeywords?.cancel() }
            // Questions about the kit itself are answered from the kit description; a keyword search only adds noise.
            var sources: [Source] = []
            // What the searches for this exact question found, per archive: a later pass reuses it.
            var searched: [String: Retriever.Gathered] = [:]
            #if DEBUG
            let traceStart = Date()
            func trace(_ what: String) { AskTrace.log(String(format: "%6.0f ms  ", Date().timeIntervalSince(traceStart) * 1000) + what) }
            trace("searching")
            #else
            func trace(_ what: @autoclosure () -> String) {}
            #endif
            if !aboutKit, !medical.isEmpty {
                let result = await Retriever.retrieveConcurrently(question: retrievalQuestion, archives: medical, budgetChars: budget)
                sources = result.sources
                searched = result.gathered
                trace("medical search: \(sources.count) sources")
            }
            if !aboutKit, Retriever.strength(sources, question: question) == 0 {
                let result = await Retriever.retrieveConcurrently(question: retrievalQuestion, archives: archives,
                                                                  budgetChars: budget, reusing: searched)
                sources = result.sources
                searched = result.gathered
                trace("search: \(sources.count) sources, strength \(Retriever.strength(sources, question: question))")
            }
            if Task.isCancelled { return }
            // A follow-up the bare question didn't answer: search it together with the question before it.
            if !aboutKit, searchText != question, Retriever.strength(sources, question: question) == 0 {
                let merged = scope.map { "\($0.title): \(searchText)" } ?? searchText
                let found = await Retriever.retrieveConcurrently(question: merged, archives: archives, budgetChars: budget).sources
                if Retriever.strength(found, question: searchText) > 0 { sources = found }
                trace("follow-up search with the question before: strength \(Retriever.strength(found, question: searchText))")
            }
            if Task.isCancelled { return }
            // The search missed (a misspelling like "carpel tunel", or everyday words the articles don't use):
            // try the spell-checked question, then a model-written keyword search, and keep whichever finds more.
            if !aboutKit, Retriever.strength(sources, question: searchText) == 0 {
                var alternatives: [String] = []
                if let fixed = Retriever.spellCorrected(searchText) { alternatives.append(fixed) }
                trace("spelling checked")
                let keywords: String?
                if let earlyKeywords { keywords = await earlyKeywords.value } else if !emergency { keywords = await Self.searchWords(for: searchText, engine: engine) } else { keywords = nil }
                if let keywords { alternatives.append(keywords) }
                trace("search words: \(alternatives)")
                var best = 0
                for alternative in alternatives where !Task.isCancelled {
                    let query = scope.map { "\($0.title): \(alternative)" } ?? alternative
                    let found = await Retriever.retrieveConcurrently(question: query, archives: archives, budgetChars: budget).sources
                    let strength = Retriever.strength(found, question: alternative)
                    if strength > best {
                        best = strength
                        sources = found
                        turns[index].searchedFor = alternative
                    }
                }
                if Task.isCancelled { return }
                trace("alternative searches done")
            }
            // Not needed after all: stop it now, so the answer doesn't wait for it.
            earlyKeywords?.cancel()
            // Still nothing, but PDF and reference packs are being read for the first time: give them a moment
            // rather than answering "not in the library" about books that are about to be searchable.
            if !aboutKit, Retriever.strength(sources, question: searchText) == 0, PDFIndex.shared.isBuilding {
                var waited = 0
                while PDFIndex.shared.isBuilding, waited < 80 {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, self.requestID == request else { return }
                    waited += 1
                }
                // Same question as the first search: only the PDF pages and guide are new, so reuse the archive searches.
                let found = await Retriever.retrieveConcurrently(question: retrievalQuestion, archives: archives,
                                                                 budgetChars: budget, reusing: searched).sources
                if Task.isCancelled { return }
                if Retriever.strength(found, question: question) > 0 { sources = found }
            }
            turns[index].sources = sources
            turns[index].status = .answering

            var current = sources
            var history = earlier
            // The built-in model may still be loading: say so instead of looking stuck.
            if let llama = engine as? LlamaEngine { turns[index].waking = !llama.isReady }
            for attempt in 0..<3 {
                // The answer is shown about ten times a second, not on every token: each change redraws the answer.
                var lastShown = Date.distantPast
                var unshown: String?
                do {
                    let head = Self.promptHead(context: context, history: history)
                    let prompt = head + Self.promptQuestion(question: question, sources: current)
                    let notes = StreamNotes()
                    trace("answering: prompt \(prompt.count) chars (context \(context.count), history \(history.count))")
                    for try await text in engine.stream(instructions: instructions, prompt: prompt, notes: notes, head: head) {
                        if Task.isCancelled { break }
                        if turns[index].waking { turns[index].waking = false }
                        if lastShown == .distantPast { trace("first words") }
                        let now = Date()
                        if now.timeIntervalSince(lastShown) >= Self.answerRefresh {
                            turns[index].answer = text
                            lastShown = now
                            unshown = nil
                        } else {
                            unshown = text
                        }
                    }
                    guard !Task.isCancelled else { return }
                    if let unshown { turns[index].answer = unshown }
                    // The model finished but wrote nothing (or only a hidden "thinking" part): say so, with Try Again.
                    if turns[index].answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        turns[index].answer = ""
                        fail(index, Self.emptyMessage)
                        return
                    }
                    turns[index].cutShort = notes.cutShort
                    turns[index].status = .done
                    turns[index].finished = Date()
                    household?.log(question: question, answer: turns[index].answer, sources: current.map(\.ref.title))
                    if let household, !emergency {
                        // Run after this turn's task ends (the defer above), so a new question is never refused.
                        learnTask = Task(priority: .utility) { [weak self] in
                            await self?.learn(from: question, engine: engine, household: household, turn: index)
                            // Then (with anything just noted in the context) get the follow-up's start ready.
                            guard !Task.isCancelled else { return }
                            self?.prepareFollowUp(engine: engine, household: household, kit: kit)
                        }
                    } else {
                        prepareFollowUp(engine: engine, household: household, kit: kit)
                    }
                    return
                } catch where (AppleEngine.isContextOverflow(error) || LlamaError.isContextOverflow(error)) && attempt < 2 {
                    guard !Task.isCancelled, self.requestID == request else { return }
                    // Too much text for the model: drop the older conversation first, then the weakest sources.
                    turns[index].answer = ""
                    if attempt == 0, !history.isEmpty {
                        history = String(history.suffix(history.count / 3))
                    } else if current.count > 1 {
                        history = ""
                        budget /= 2
                        current = Array(current.prefix(max(1, current.count / 2)))
                        turns[index].sources = current
                    } else if !history.isEmpty {
                        history = ""
                    } else {
                        fail(index, Self.tooLongMessage)
                        return
                    }
                } catch {
                    if Task.isCancelled { break }
                    if let unshown, turns.indices.contains(index) { turns[index].answer = unshown }
                    if AppleEngine.isContextOverflow(error) || LlamaError.isContextOverflow(error) {
                        fail(index, Self.tooLongMessage)
                    } else {
                        fail(index, error.localizedDescription)
                    }
                    return
                }
            }
            guard !Task.isCancelled, self.requestID == request, turns.indices.contains(index) else { return }
            if turns[index].status != .done { turns[index].status = .done; turns[index].finished = Date() }
        }
        return true
    }

    /// Seconds between redraws of a streaming answer.
    private static let answerRefresh: TimeInterval = 0.1

    private static let emptyMessage = "Ask didn’t come up with an answer this time. Try again, or ask it in different words."

    private static let tooLongMessage = "That conversation got too long for the answer model. Start a new conversation and ask again."

    private func fail(_ index: Int, _ message: String) {
        turns[index].status = .failed
        turns[index].error = message
        turns[index].finished = Date()
    }

    static func prompt(question: String, sources: [Source], context: String = "", history: String = "") -> String {
        promptHead(context: context, history: history) + promptQuestion(question: question, sources: sources)
    }

    /// The start of a question's prompt that the next question in the conversation starts with too: household
    /// context, then the conversation so far. The new question and its sources come after it.
    static func promptHead(context: String, history: String) -> String {
        var text = ""
        if !context.isEmpty { text += "About the person and their kit (private, from this device):\n\(context)\n\n" }
        if !history.isEmpty { text += "Earlier in this conversation:\n\(history)\n\n" }
        return text
    }

    /// The question and its numbered sources.
    static func promptQuestion(question: String, sources: [Source]) -> String {
        let text = "Question: \(question)\n\n"
        guard !sources.isEmpty else {
            return text + (isAboutKit(question)
                ? "This is a question about Offline Kit itself. Answer from the description of their kit."
                : "Sources: none found in the offline library.")
        }
        let body = sources.map { "[\($0.id)] \($0.ref.title) (\($0.bookTitle))\n\($0.text)" }
            .joined(separator: "\n\n")
        return text + "Sources:\n\(body)"
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isEntertainment(_ archiveName: String) -> Bool {
        let n = archiveName.lowercased()
        return ["wikipedia_en_movies", "wikipedia_en_comics", "wikipedia_en_football", "wikipedia_en_baseball",
                "wikipedia_en_basketball", "wikipedia_en_ice-hockey", "wikipedia_en_tennis", "wikipedia_en_golf"]
            .contains { n.hasPrefix($0) }
    }

    static func isMedical(_ archiveName: String) -> Bool {
        let n = archiveName.lowercased()
        return ["medlineplus", "mdwiki", "wikipedia_en_medicine", "zimgit-medicine", "military-medicine", "wikem", "fas-military-medicine"]
            .contains { n.contains($0) }
    }

    /// Symptoms, injuries, illness, medicine.
    static func isHealthQuestion(_ question: String) -> Bool {
        matches(#"\b(fever|pain|ache|hurts?|bleed\w*|burn(ed|s)?|cut|wound|rash|cough\w*|vomit\w*|diarrh\w*|nause\w*|sick|ill|illness|infect\w*|medicine|medication|dose|dosage|tylenol|ibuprofen|acetaminophen|sprain\w*|broken|fracture|bite|sting|allerg\w*|symptom\w*|swollen|swelling|dizzy|faint\w*|headache|migraine|diabet\w*|asthma|pregnan\w*|baby|infant|choking|cpr|poison\w*|stroke|seizure|heart|blood|wrist|ankle|knee|tunnel|syndrome|disease|virus|flu|cold|covid|dehydrat\w*|heat ?stroke|hypotherm\w*|frostbite)\b"#, question)
    }

    /// "What has been downloaded?", "What do you know?": about the kit, not a topic to look up.
    static func isAboutKit(_ question: String) -> Bool {
        let patterns = [
            #"\b(what|which)\b.*\b(downloaded|loaded|installed|saved|stored|have access|access to)\b"#,
            #"\bwhat('s| is| do i have| have i got)\b.*\b(in )?(my|the|your|this) (library|kit|app|offline kit)\b"#,
            #"\b(what can|how do) (i|you) (do|use) (with )?(this|the) app\b"#,
            #"\bwhat (do|can) you (know|do|access|see|help)\b"#,
            #"\bwho are you\b"#,
        ]
        return patterns.contains { matches($0, question) }
    }

    /// Short questions that lean on the one before ("would we notice it first?").
    static func isFollowUp(_ question: String) -> Bool {
        question.split(separator: " ").count <= 12
            && (matches(#"\b(it|that|they|them|those|these|instead|else|continue)\b"#, question)
                || matches(#"^(and|but|so|or|what about|how about)\b"#, question))
    }

    private static let searchWordsInstructions = """
    Turn the question into a library search of 2 to 6 keywords. Fix spelling and use the standard medical, \
    technical or common name for the topic. Reply with the keywords only, on one line, no punctuation.
    """

    /// Asks the model for a short library search ("carpel tunel stretches" → "carpal tunnel syndrome exercises").
    static func searchWords(for question: String, engine: AnswerEngine) async -> String? {
        var reply = ""
        do {
            for try await text in engine.stream(instructions: searchWordsInstructions, prompt: question) { reply = text }
        } catch { return nil }
        let line = reply.split(separator: "\n").first.map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)) ?? ""
        guard !line.isEmpty, line.count <= 80, line.lowercased() != question.lowercased() else { return nil }
        return line
    }

    /// Earlier questions and answers in this conversation, newest last, so follow-ups make sense.
    /// Big models keep most of the conversation, so a scenario built up over several turns stays intact: up to six
    /// turns, within half of what the model's window has left after the household context (the sources get the
    /// rest). When that's full, the oldest turns go until a third is free again, so the history keeps the same
    /// beginning for the next few turns and the model's saved state of it can be reused. Small models keep the
    /// last two turns.
    func conversationSoFar(engine: AnswerEngine, context: String) -> String {
        let done = turns.filter { $0.status == .done && !$0.answer.isEmpty }
        guard engine.sourceBudget >= 10_000 else {
            return String(Self.historyText(done.suffix(2), perAnswer: 400).suffix(engine.contextBudget / 2))
        }
        let limit = min(10_000, max(1_000, (engine.promptBudget - context.count) / 2)), most = 6
        var kept = ArraySlice(done)
        if let start = historyStart, let i = kept.firstIndex(where: { $0.id == start }) { kept = kept[i...] }
        if kept.count > most || Self.historyText(kept, perAnswer: 1_500).count > limit {
            while kept.count > 1, kept.count > most * 2 / 3 || Self.historyText(kept, perAnswer: 1_500).count > limit * 2 / 3 {
                kept = kept.dropFirst()
            }
        }
        historyStart = kept.first?.id
        return String(Self.historyText(kept, perAnswer: 1_500).suffix(limit))
    }

    /// "Q: …\nA: …" for each turn. Citation marks are left out: they point at that turn's sources, not this one's.
    static func historyText(_ turns: ArraySlice<Turn>, perAnswer: Int) -> String {
        turns.map { "Q: \($0.question)\nA: \(withoutCitations(String($0.answer.prefix(perAnswer))))" }.joined(separator: "\n")
    }

    private static let citation = try! NSRegularExpression(pattern: #" ?\[\d+(?:[,–-] ?\d+)*\]"#)

    /// The answer without its "[1]" and "[2, 3]" citation marks.
    static func withoutCitations(_ text: String) -> String {
        citation.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    }

    /// After an answer: evaluate the next question's start (instructions, household context and the conversation
    /// so far, this answer included) in the background, so a follow-up only evaluates its own question and sources.
    private func prepareFollowUp(engine: AnswerEngine, household: Household?, kit: String) {
        let context = AskContext.build(household?.data ?? HouseholdData(privacy: AskPrivacy(personalize: false)),
                                       kit: kit, limit: engine.contextBudget)
        engine.prepareFollowUp(instructions: currentInstructions,
                               head: Self.promptHead(context: context, history: conversationSoFar(engine: engine, context: context)))
    }

    /// What's in the kit, so Ask can point to it and knows what it can't answer.
    static func kitSummary(_ library: Library) -> String {
        let maps = library.books.filter { $0.archive.name.hasPrefix("maps_") }.map(\.shortTitle)
        let refs = library.books.filter { !$0.archive.name.hasPrefix("maps_") }.map(\.shortTitle)
        var lines: [String] = []
        if !refs.isEmpty { lines.append("References in their offline library: " + refs.prefix(30).joined(separator: "; ")) }
        if !maps.isEmpty { lines.append("Offline maps: " + maps.joined(separator: ", ")) }
        lines.append("Offline Kit's sections: Ask (this), Library (browse references by area), Get Resources (download more), "
                     + "Watch (videos), Audiobooks, Music, Books (EPUB and PDF reader), Play (retro games), "
                     + "Prepare (household, supplies checklist, Emergency info with phone numbers and radio frequencies) "
                     + "and Share on Wi-Fi (phones, tablets and Apple TV on the home network).")
        return lines.joined(separator: "\n")
    }

    // MARK: Memories

    private static let firstPerson = try! NSRegularExpression(
        pattern: "\\b(i|i'm|im|i've|my|we|we're|we've|our|us|me)\\b", options: [.caseInsensitive])

    private static let noteInstructions = """
    You pick out lasting facts a person states about themselves or their household, to remember later. \
    Only facts stated in the message: health, allergies, medicines, skills, equipment, supplies, home, pets, \
    people, location. Write each on its own line starting with "- ", short, in third person, like \
    "- Has a well for water." If there are none, reply NONE.
    """

    /// Notes lasting facts the person mentions ("I'm allergic to penicillin", "we have a well").
    private func learn(from question: String, engine: AnswerEngine, household: Household, turn index: Int) async {
        let p = household.data.privacy
        guard p.personalize, p.learnMemories,
              Self.firstPerson.firstMatch(in: question, range: NSRange(question.startIndex..., in: question)) != nil else { return }
        var reply = ""
        do {
            for try await text in engine.stream(instructions: Self.noteInstructions, prompt: "Message: \(question)") { reply = text }
        } catch { return }
        guard !Task.isCancelled, turns.indices.contains(index), turns[index].question == question else { return }
        var facts: [String] = []
        for line in reply.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else { continue }
            let fact: String = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            if fact.count > 3, fact.count < 160, fact.uppercased() != "NONE" { facts.append(fact) }
            if facts.count == 3 { break }
        }
        for fact in facts {
            if let memory = household.remember(fact, about: household.data.activePersonID, learned: true) {
                turns[index].noted.append(memory)
            }
        }
    }

    /// Undo for a noted fact.
    func unnote(_ memory: Memory, household: Household) {
        household.forget(memory.id)
        for i in turns.indices { turns[i].noted.removeAll { $0.id == memory.id } }
    }
}

#if DEBUG
/// Where a question's time goes, on standard error (OFFLINEKIT_TRACE=1).
enum AskTrace {
    static let enabled = ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil
    static func log(_ line: @autoclosure () -> String) {
        guard enabled else { return }
        FileHandle.standardError.write(Data(("ask: " + line() + "\n").utf8))
    }
}
#endif
