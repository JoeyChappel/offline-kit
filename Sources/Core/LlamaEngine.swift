import Foundation
import llama

enum LlamaError: LocalizedError {
    case loadFailed(String), loadFailedCustom(String), contextFailed, tooLong(Int, Int), decodeFailed(Int32), tokenizeFailed
    case tooBig(needed: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .loadFailed(let path): "Couldn't load the answer model at \(path). The file may be damaged; delete it and download it again."
        case .loadFailedCustom(let name):
            "Offline Kit couldn't open \(name). It may be a kind of model this version can't run yet, or the file may be damaged. Try another model, or a different version of this one."
        case .tooBig(let needed, let available):
            "This model needs about \(ModelFit.gigabytes(needed)) of memory, but \(ModelFit.deviceName) can give it about \(ModelFit.gigabytes(available)). Choose a smaller model, or a smaller version of this one (Q4_K_M is a good balance)."
        case .contextFailed: "Not enough memory to run the answer model. Close other apps and try again."
        case .tooLong(let have, let max): "Too much text for the model (\(have) of \(max) tokens)."
        case .decodeFailed(let code): "The answer model stopped unexpectedly (code \(code))."
        case .tokenizeFailed: "Couldn't prepare the question for the answer model."
        }
    }

    /// Too much text: retrying with fewer sources may work.
    static func isContextOverflow(_ error: Error) -> Bool {
        if case .tooLong = error as? LlamaError { return true }
        return false
    }
}

/// llama.cpp settings for the built-in model and any model the person adds. One place, so they're easy to tune
/// and measure (okit --llama-bench; DEBUG builds read OFFLINEKIT_LLAMA overrides, e.g. "fa=0,kv=f16,ub=256").
struct LlamaTuning: Sendable, Equatable, CustomStringConvertible {
    var gpuLayers: Int32
    var flashAttention: llama_flash_attn_type
    /// Key and value cache type: f16, or q8_0 (half the memory).
    var cacheType: ggml_type
    var batch: UInt32
    var ubatch: UInt32
    /// CPU threads for generation and for prompts (only what isn't on the GPU runs on them).
    var threads: Int32
    var threadsBatch: Int32
    /// Full-size sliding-window cache (llama.cpp's default); off keeps only the window.
    var swaFull: Bool
    var opOffload: Bool
    var loadMode: llama_load_mode

    /// Measured with Gemma 4 E4B on an M4 Pro (okit --llama-bench, 15 questions, 1,000 to 1,500-token prompts):
    /// flash attention (auto turns it on with Metal) is 4% faster to the first word and 200 MB smaller than off;
    /// a 512-token micro-batch beats 256 slightly and 1,024 or 2,048 by 25%; 4 CPU threads beat 1 and 8; op offload
    /// helps; and a sliding-window cache sized to the window instead of the whole context saves 280 MB (and makes
    /// the saved instructions smaller) at the same speed, with identical answers. A q8_0 cache saves another 80 MB
    /// but generates 7% slower and changed 2 of 15 answers, so it stays f16. mmap keeps the weights out of the
    /// app's footprint (6.8 GB without it). Not measured on iPhone or iPad: they keep the same settings, all of
    /// which use less memory than llama.cpp's defaults or the same.
    static var platformDefault: LlamaTuning {
        let cores = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount))
        #if targetEnvironment(simulator)
        // The simulator's Metal is too limited for this: everything on the CPU.
        return LlamaTuning(gpuLayers: 0, flashAttention: LLAMA_FLASH_ATTN_TYPE_AUTO, cacheType: GGML_TYPE_F16,
                           batch: 2048, ubatch: 512, threads: min(4, cores), threadsBatch: min(4, cores),
                           swaFull: false, opOffload: true, loadMode: LLAMA_LOAD_MODE_MMAP)
        #else
        return LlamaTuning(gpuLayers: 999, flashAttention: LLAMA_FLASH_ATTN_TYPE_AUTO, cacheType: GGML_TYPE_F16,
                           batch: 2048, ubatch: 512, threads: min(4, cores), threadsBatch: min(4, cores),
                           swaFull: false, opOffload: true, loadMode: LLAMA_LOAD_MODE_MMAP)
        #endif
    }

    static let current: LlamaTuning = {
        var t = platformDefault
        #if DEBUG
        // Test hook: OFFLINEKIT_LLAMA="fa=1,kv=q8_0,b=2048,ub=1024,t=4,tb=4,swa=0,op=1,load=mmap,ngl=999"
        for pair in (ProcessInfo.processInfo.environment["OFFLINEKIT_LLAMA"] ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let (key, value) = (kv[0], kv[1])
            switch key {
            case "fa": t.flashAttention = value == "auto" ? LLAMA_FLASH_ATTN_TYPE_AUTO : (value == "1" ? LLAMA_FLASH_ATTN_TYPE_ENABLED : LLAMA_FLASH_ATTN_TYPE_DISABLED)
            case "kv": t.cacheType = value == "q8_0" ? GGML_TYPE_Q8_0 : (value == "q4_0" ? GGML_TYPE_Q4_0 : GGML_TYPE_F16)
            case "b": t.batch = UInt32(value) ?? t.batch
            case "ub": t.ubatch = UInt32(value) ?? t.ubatch
            case "t": t.threads = Int32(value) ?? t.threads
            case "tb": t.threadsBatch = Int32(value) ?? t.threadsBatch
            case "swa": t.swaFull = value == "1"
            case "op": t.opOffload = value == "1"
            case "ngl": t.gpuLayers = Int32(value) ?? t.gpuLayers
            case "load": t.loadMode = llama_load_mode_from_str(value)
            default: break
            }
        }
        #endif
        return t
    }()

    var description: String {
        let fa = flashAttention == LLAMA_FLASH_ATTN_TYPE_AUTO ? "auto" : (flashAttention == LLAMA_FLASH_ATTN_TYPE_ENABLED ? "on" : "off")
        let kv = cacheType == GGML_TYPE_Q8_0 ? "q8_0" : (cacheType == GGML_TYPE_Q4_0 ? "q4_0" : "f16")
        return "ngl=\(gpuLayers) fa=\(fa) kv=\(kv) b=\(batch) ub=\(ubatch) t=\(threads)/\(threadsBatch) swaFull=\(swaFull) opOffload=\(opOffload) load=\(String(cString: llama_load_mode_name(loadMode)))"
    }
}

/// Keeps one model loaded (loading takes seconds) and runs one generation at a time.
final class LlamaRuntime: @unchecked Sendable {
    static let shared = LlamaRuntime()

    private let lock = NSLock()
    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private var loadedPath: String?
    private var contextTokens: UInt32 = 0
    /// The instructions' evaluated state (their KV cache), so a question only evaluates what comes after them.
    /// Newest first, at most two (Ask's instructions, and the emergency version of them). Belongs to the loaded
    /// model and context; `unload` forgets it. Guarded by `lock`.
    private var prefixes: [(tokens: [llama_token], state: [UInt8])] = []
    /// Instructions shorter than this aren't worth keeping (the search-words and note-taking prompts).
    static let minimumPrefixTokens = 256
    /// The current conversation's settled part evaluated (instructions, household context, earlier turns), so a
    /// follow-up evaluates only its question and sources. One conversation; released on New Conversation, on
    /// unload and under memory pressure. Saved and restored whole, never trimmed: Gemma's sliding-window layers
    /// keep only the last window, so a longer state can't be cut back to a shorter one. Guarded by `lock`.
    private var conversation: (tokens: [llama_token], state: [UInt8])?
    /// Generations waiting for `lock`. A background warm-up stops at its next step when one arrives.
    private let waiting = Counter()
    /// Counts New Conversations. Static, so reading it never creates the runtime (which starts Metal). A
    /// conversation being prepared stops, and isn't kept, when this moves on from the count it started with.
    private static let conversations = Counter()
    static var conversationCount: Int { conversations.value }

    /// What is loaded and when it was last used, readable without waiting for a load or a generation to finish.
    private let stateLock = NSLock()
    /// Which model is loaded, kept outside `shared` on purpose: asking "is it ready?" (the main thread does, for each
    /// question) must never create the runtime, which starts Metal and takes seconds, or wait for a thread that is.
    private static let readyBox = ReadyBox()
    private final class ReadyBox: @unchecked Sendable {
        private let lock = NSLock()
        private var key: String?
        func get() -> String? { lock.withLock { key } }
        func set(_ value: String?) { lock.withLock { key = value } }
    }
    private var lastUsed = Date()
    private var idleCheck = 0
    private var pressure: DispatchSourceMemoryPressure?

    /// A model nobody has asked anything of for this long is released (it holds several GB).
    static let idleSeconds: TimeInterval = 600

    /// Set when the app quits: a prompt or answer in progress stops at its next step, so quitting doesn't wait for it.
    private let quitting = CancelFlag()
    private static let created = CancelFlag()
    /// Whether `shared` has been made. Making it starts llama.cpp's Metal backend (compiling its shaders takes seconds),
    /// which quitting must not do just to release a model that was never loaded.
    static var exists: Bool { created.value }

    private init() {
        Self.created.value = true
        llama_backend_init()
        // Memory getting short: let go of the saved conversation (a follow-up just evaluates its history again).
        // Low memory: give the model back too, unless it's answering right now (it loads again on the next question).
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            guard let self, self.lock.try() else { return }
            if source?.data.contains(.critical) == true { self.unload() } else { self.conversation = nil }
            self.lock.unlock()
        }
        source.resume()
        pressure = source
    }

    private static func key(path: String, contextTokens: Int32) -> String { "\(path)#\(contextTokens)" }

    /// True when this model is already in memory, so a question can start answering at once.
    static func isReady(file: URL, contextTokens: Int32) -> Bool {
        readyBox.get() == key(path: file.path, contextTokens: contextTokens)
    }

    /// Loads the model ahead of the first question. Blocking; call off the main thread. Errors are left for
    /// the question itself to report.
    func preload(file: URL, contextTokens: Int32, custom: Bool, instructions: String? = nil) {
        lock.lock()
        defer { lock.unlock(); touch() }
        try? load(path: file.path, contextTokens: contextTokens, custom: custom)
        // Evaluate the instructions now too, so even the first question starts after them.
        if let instructions, let model, let context {
            let vocab = llama_model_get_vocab(model)
            if let prefix = instructionTokens(system: instructions, custom: custom, vocab: vocab),
               !prefixes.contains(where: { $0.tokens == prefix }) {
                llama_memory_clear(llama_get_memory(context), true)
                if (try? decode(prefix[...], context: context, isCancelled: { false })) == true {
                    keepPrefix(prefix, context: context)
                    // One more token on its own: the first answer otherwise waits while Metal sets up the
                    // one-token steps answers are generated in. (Every prompt restores a saved state first.)
                    var token = prefix[prefix.count - 1]
                    _ = llama_decode(context, llama_batch_get_one(&token, 1))
                    llama_synchronize(context)
                }
            }
        }
    }

    /// Marks the model as just used and schedules the idle release.
    private func touch() {
        let check: Int = stateLock.withLock {
            lastUsed = Date()
            idleCheck += 1
            return idleCheck
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.idleSeconds + 1) { [weak self] in
            self?.releaseIfIdle(check)
        }
    }

    private func releaseIfIdle(_ check: Int) {
        // Only the latest scheduled check acts; an older one means the model was used since.
        guard stateLock.withLock({ idleCheck == check && Date().timeIntervalSince(lastUsed) >= Self.idleSeconds }),
              lock.try() else { return }   // busy: that generation's own touch() schedules the next check
        unload()
        lock.unlock()
    }

    /// Releases the model and its context. Call before the process exits (the Mac app does this on quit):
    /// freeing them during exit() runs after ggml's own Metal teardown and crashes.
    func shutdown() {
        quitting.value = true
        lock.lock()
        defer { lock.unlock() }
        unload()
    }

    private func load(path: String, contextTokens: Int32, custom: Bool) throws {
        if loadedPath == path, self.contextTokens == UInt32(contextTokens), context != nil { return }
        unload()
        let tuning = LlamaTuning.current
        var params = llama_model_default_params()
        params.n_gpu_layers = tuning.gpuLayers
        params.load_mode = tuning.loadMode
        guard let model = llama_model_load_from_file(path, params) else {
            throw custom ? LlamaError.loadFailedCustom(URL(fileURLWithPath: path).lastPathComponent) : LlamaError.loadFailed(path)
        }
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextTokens)
        cparams.n_batch = tuning.batch
        cparams.n_ubatch = tuning.ubatch
        cparams.n_threads = tuning.threads
        cparams.n_threads_batch = tuning.threadsBatch
        cparams.flash_attn_type = tuning.flashAttention
        cparams.type_k = tuning.cacheType
        cparams.type_v = tuning.cacheType
        cparams.swa_full = tuning.swaFull
        cparams.op_offload = tuning.opOffload
        guard let context = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw LlamaError.contextFailed
        }
        self.model = model
        self.context = context
        self.loadedPath = path
        self.contextTokens = UInt32(contextTokens)
        Self.readyBox.set(Self.key(path: path, contextTokens: contextTokens))
    }

    private func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        loadedPath = nil
        prefixes = []
        conversation = nil
        Self.readyBox.set(nil)
    }

    /// Formats the conversation with the model's own chat template.
    /// Built-in Gemma: instructions at the top of the user turn (Gemma has no system role), Gemma markers as a fallback.
    /// Other models: a system and a user message through their template; a generic one only when they have none.
    private func format(system: String, user: String, custom: Bool) -> String {
        guard let model else { return user }
        let own = llama_model_chat_template(model, nil).map { String(cString: $0) }
        if !custom {
            let content = system.isEmpty ? user : system + "\n\n" + user
            if let own, let applied = Self.apply(template: own, messages: [("user", content)]) { return applied }
            return "<start_of_turn>user\n\(content)<end_of_turn>\n<start_of_turn>model\n"
        }
        let messages = system.isEmpty ? [("user", user)] : [("system", system), ("user", user)]
        var architecture = [CChar](repeating: 0, count: 64)
        let arch = llama_model_meta_val_str(model, "general.architecture", &architecture, architecture.count) > 0
            ? String(cString: architecture) : ""
        let generic = arch.hasPrefix("gemma") ? "gemma" : "chatml"
        // A template llama.cpp doesn't know (it has no Jinja engine) also falls back to the generic one.
        var prompt = own.flatMap { Self.apply(template: $0, messages: messages) }
            ?? Self.apply(template: generic, messages: messages)
            ?? "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        // Models that think first in <think> tags (Qwen 3 and others): skip it, the way their template does
        // when thinking is off.
        if let own, own.contains("<think>"), prompt.hasSuffix("<|im_start|>assistant\n") {
            prompt += "<think>\n\n</think>\n\n"
        }
        return prompt
    }

    private static func apply(template: String, messages: [(role: String, content: String)]) -> String? {
        let strings = messages.flatMap { [strdup($0.role), strdup($0.content)] }
        defer { strings.forEach { free($0) } }
        guard strings.allSatisfy({ $0 != nil }) else { return nil }
        let chat = stride(from: 0, to: strings.count, by: 2).map {
            llama_chat_message(role: UnsafePointer(strings[$0]), content: UnsafePointer(strings[$0 + 1]))
        }
        var capacity = Int32(messages.reduce(0) { $0 + $1.content.utf8.count } * 2 + 1024)
        for _ in 0..<2 {
            var buffer = [CChar](repeating: 0, count: Int(capacity))
            let n = llama_chat_apply_template(template, chat, chat.count, true, &buffer, capacity)
            if n < 0 { return nil }                       // template not recognized
            if n <= capacity {
                return String(decoding: buffer.prefix(Int(n)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
            capacity = n + 1
        }
        return nil
    }

    /// Feeds tokens to the model in batches. False when cancelled partway.
    private func decode(_ tokens: ArraySlice<llama_token>, context: OpaquePointer, isCancelled: () -> Bool) throws -> Bool {
        var batch = Array(tokens)
        var offset = 0
        while offset < batch.count {
            let count = min(Int(llama_n_batch(context)), batch.count - offset)
            let status = batch.withUnsafeMutableBufferPointer { buf in
                llama_decode(context, llama_batch_get_one(buf.baseAddress! + offset, Int32(count)))
            }
            // 2: the abort callback stopped it partway (Stop was pressed). The caller clears the context before reuse.
            if status == 2 && isCancelled() { return false }
            guard status == 0 else { throw LlamaError.decodeFailed(status) }
            offset += count
            if isCancelled() || quitting.value { return false }
        }
        return true
    }

    /// The tokens every prompt with these instructions starts with: the chat template up to where the question
    /// goes, less its last two tokens (which can merge with the question's first words). Nil when too short to keep.
    private func instructionTokens(system: String, custom: Bool, vocab: OpaquePointer?) -> [llama_token]? {
        settledTokens(system: system, head: "", custom: custom, vocab: vocab)
    }

    /// The same for a prompt that starts with `head` (the household context and earlier turns, which the next
    /// question in the conversation starts with too): the template up to the end of `head`, less its last two
    /// tokens. A prompt starts with these tokens exactly when it starts with `head`, whatever follows.
    private func settledTokens(system: String, head: String, custom: Bool, vocab: OpaquePointer?) -> [llama_token]? {
        let marker = "\u{1F}OKQ\u{1F}"
        let formatted = format(system: system, user: head + marker, custom: custom)
        guard let range = formatted.range(of: marker) else { return nil }
        let prefix = String(formatted[..<range.lowerBound])
        let needed = -llama_tokenize(vocab, prefix, Int32(prefix.utf8.count), nil, 0, true, true)
        guard needed > Int32(Self.minimumPrefixTokens) + 2 else { return nil }
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        guard llama_tokenize(vocab, prefix, Int32(prefix.utf8.count), &tokens, needed, true, true) == needed else { return nil }
        return Array(tokens.dropLast(2))
    }

    /// The model's state right after evaluating `tokens` (all of sequence 0), or nil.
    private func saveState(_ context: OpaquePointer) -> [UInt8]? {
        let size = llama_state_seq_get_size(context, 0)
        guard size > 0 else { return nil }
        var state = [UInt8](repeating: 0, count: size)
        let written = state.withUnsafeMutableBufferPointer { llama_state_seq_get_data(context, $0.baseAddress, size, 0) }
        guard written > 0 else { return nil }
        if written < size { state.removeLast(size - written) }
        return state
    }

    /// Keeps the state after the conversation's settled part, for the follow-up.
    private func keepConversation(_ tokens: [llama_token], context: OpaquePointer) {
        conversation = nil   // the old one goes first: two at once would be tens of megabytes more at the peak
        guard let state = saveState(context) else { return }
        conversation = (tokens, state)
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
            FileHandle.standardError.write(Data("llama: kept the conversation's first \(tokens.count) tokens (\(state.count / 1_048_576) MB of state)\n".utf8))
        }
        #endif
    }

    /// Restores the longest saved state the prompt starts with (the conversation, or its instructions) and
    /// returns how many of its tokens that covers; 0 with a cleared context when none fits.
    private func restoreLongest(for tokens: [llama_token], context: OpaquePointer) -> Int {
        let memory = llama_get_memory(context)
        llama_memory_clear(memory, true)
        var candidates: [(tokens: [llama_token], state: [UInt8])] = prefixes
        if let conversation { candidates.append(conversation) }
        for saved in candidates.sorted(by: { $0.tokens.count > $1.tokens.count })
        where tokens.count > saved.tokens.count && tokens.starts(with: saved.tokens) {
            let restored = saved.state.withUnsafeBufferPointer { llama_state_seq_set_data(context, $0.baseAddress, $0.count, 0) }
            if restored > 0 { return saved.tokens.count }
            llama_memory_clear(memory, true)
        }
        return 0
    }

    /// Saves the state the model is in right after evaluating `tokens`, for the next prompt that starts with them.
    private func keepPrefix(_ tokens: [llama_token], context: OpaquePointer) {
        guard let state = saveState(context) else { return }
        prefixes.removeAll { $0.tokens == tokens }
        prefixes.insert((tokens, state), at: 0)
        if prefixes.count > 2 { prefixes.removeLast() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
            FileHandle.standardError.write(Data("llama: kept \(tokens.count) instruction tokens (\(state.count / 1_048_576) MB of state)\n".utf8))
        }
        #endif
    }

    /// Evaluates the next question's settled part ahead of time (instructions, household context and the
    /// conversation so far), so the follow-up only evaluates its question and sources. Blocking; call off the main
    /// thread. Does nothing when the model isn't loaded, and stops at its next step when a question arrives.
    /// `conversation` is `conversationCount` when it was asked for: a New Conversation since then stops it.
    func prepareConversation(file: URL, contextTokens: Int32, custom: Bool, system: String, head: String,
                             conversation count: Int = LlamaRuntime.conversationCount) {
        lock.lock()
        defer { lock.unlock() }
        let conversations = Self.conversations
        guard conversations.value == count, loadedPath == file.path, self.contextTokens == UInt32(contextTokens),
              let model, let context else { return }
        let vocab = llama_model_get_vocab(model)
        guard let target = settledTokens(system: system, head: head, custom: custom, vocab: vocab),
              conversation?.tokens != target else { return }
        let waiting = self.waiting, quitting = self.quitting
        let abort = AbortCheck { waiting.value > 0 || quitting.value || conversations.value != count }
        llama_set_abort_callback(context, { data in Unmanaged<AbortCheck>.fromOpaque(data!).takeUnretainedValue().check() },
                                 Unmanaged.passUnretained(abort).toOpaque())
        defer { llama_set_abort_callback(context, nil, nil) }
        let stop = { waiting.value > 0 || conversations.value != count }
        #if DEBUG
        let began = DispatchTime.now().uptimeNanoseconds
        #endif
        var start = restoreLongest(for: target + [0], context: context)
        // Same steps as a question takes: the instructions, then the rest of the settled part.
        if let instructions = instructionTokens(system: system, custom: custom, vocab: vocab),
           start < instructions.count, target.count > instructions.count, target.starts(with: instructions) {
            guard (try? decode(target[start..<instructions.count], context: context, isCancelled: stop)) == true else { return }
            keepPrefix(instructions, context: context)
            start = instructions.count
        }
        if start < target.count {
            guard (try? decode(target[start...], context: context, isCancelled: stop)) == true else { return }
        }
        // New Conversation while this was evaluated: it belongs to the conversation that was cleared.
        guard conversations.value == count else { return }
        keepConversation(target, context: context)
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
            FileHandle.standardError.write(Data(String(format: "llama: prepared the follow-up's %d tokens in %.0f ms\n", target.count,
                                                       Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6).utf8))
        }
        #endif
    }

    /// New Conversation: the saved conversation can't be used again. Returns at once; one being prepared stops at
    /// its next step, and the state is released as soon as nothing is using the model.
    func forgetConversation() {
        Self.newConversation()
        DispatchQueue.global(qos: .utility).async { [self] in lock.withLock { conversation = nil } }
    }

    /// Counts a New Conversation, so a conversation being prepared stops, without creating the runtime.
    static func newConversation() { conversations.add(1) }

    #if DEBUG
    /// Tokens in the last prompt, and how many of them came from the saved instructions (for the benchmark).
    nonisolated(unsafe) static var lastPrefill: (total: Int, reused: Int) = (0, 0)
    /// Where the last generation's time went, in milliseconds (for the benchmark): evaluating the prompt (restoring
    /// the instructions included), until the first visible text, and the answer's tokens after the first.
    struct Timings: Sendable { var prefillMs = 0.0, firstTextMs = 0.0, tokens = 0, generateMs = 0.0, sampleMs = 0.0, gpuWaitMs = 0.0, restoreMs = 0.0 }
    nonisolated(unsafe) static var lastTimings = Timings()
    /// Test hook: wait for the GPU after the prompt and before each token, so `lastTimings` splits the time
    /// accurately (decoding otherwise runs on while the CPU moves on).
    nonisolated(unsafe) static var measuresTimings = false
    /// Test hook: false evaluates every prompt whole, the way it was before instructions were saved.
    nonisolated(unsafe) static var reusesInstructions = true

    /// Test hook: forget the saved instructions (and conversation), so the next prompt evaluates and saves them again.
    func forgetInstructions() { lock.withLock { prefixes = []; conversation = nil } }

    /// Bytes of saved model state held for reuse (instructions and conversation), for the benchmark.
    var savedStateBytes: Int { lock.withLock { prefixes.reduce(0) { $0 + $1.state.count } + (conversation?.state.count ?? 0) } }
    #endif

    /// Hides a model's "thinking" from the answer, for models that think anyway:
    /// <think>…</think>, or Gemma's thought channel (its opening marker doesn't print, the closing one does).
    static func visibleAnswer(_ text: String) -> String {
        if let end = text.range(of: "<channel|>", options: .backwards) {
            return String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let trimmed = text.drop { $0.isWhitespace }
        guard trimmed.hasPrefix("<think>") else { return text }
        guard let end = trimmed.range(of: "</think>") else { return "" }
        return String(trimmed[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Generates a reply, calling `onText` with the full text so far. Blocking; call off the main thread.
    /// Returns true when it stopped because it reached `maxTokens` rather than finishing its answer.
    /// `head` is the start of `user` that the next question in this conversation will start with too (household
    /// context and earlier turns): its evaluated state is kept for that follow-up.
    @discardableResult
    func generate(file: URL, contextTokens: Int32, custom: Bool, system: String, user: String, head: String? = nil,
                  maxTokens: Int = 1024, isCancelled: @escaping () -> Bool, onText: (String) -> Void) throws -> Bool {
        waiting.add(1)
        lock.lock()
        waiting.add(-1)
        defer { lock.unlock(); touch() }
        try load(path: file.path, contextTokens: contextTokens, custom: custom)
        guard let model, let context else { throw LlamaError.contextFailed }
        let vocab = llama_model_get_vocab(model)
        // Stop works inside a batch, not only between them: llama.cpp asks this before each step of the graph.
        // It runs on the decoding thread, which holds `lock`, and takes no lock of its own. Cleared on the way out.
        let quitting = self.quitting
        let abort = AbortCheck { isCancelled() || quitting.value }   // Stop, or the app quitting
        llama_set_abort_callback(context, { data in Unmanaged<AbortCheck>.fromOpaque(data!).takeUnretainedValue().check() },
                                 Unmanaged.passUnretained(abort).toOpaque())
        defer { llama_set_abort_callback(context, nil, nil) }

        let prompt = format(system: system, user: user, custom: custom)
        let needed = -llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), nil, 0, true, true)
        guard needed > 0 else { throw LlamaError.tokenizeFailed }
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        guard llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, needed, true, true) == needed else {
            throw LlamaError.tokenizeFailed
        }
        let room = Int(contextTokens) - maxTokens
        guard tokens.count <= room else { throw LlamaError.tooLong(tokens.count, room) }

        // Start from the longest saved state this prompt begins with: the conversation so far (prepared after the
        // last answer), or the instructions. What isn't saved is evaluated in fixed steps (instructions, then the
        // settled part, then the question and sources), and each step's state is kept for the next question.
        #if DEBUG
        let began = DispatchTime.now().uptimeNanoseconds
        func ms(since t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }
        var timings = Timings()
        defer { Self.lastTimings = timings }
        #endif
        var start = 0
        #if DEBUG
        let reuse = Self.reusesInstructions
        #else
        let reuse = true
        #endif
        if reuse {
            start = restoreLongest(for: tokens, context: context)
            #if DEBUG
            timings.restoreMs = ms(since: began)
            #endif
            if let prefix = instructionTokens(system: system, custom: custom, vocab: vocab),
               start < prefix.count, tokens.count > prefix.count, tokens.starts(with: prefix) {
                guard try decode(tokens[start..<prefix.count], context: context, isCancelled: isCancelled) else { return false }
                keepPrefix(prefix, context: context)
                start = prefix.count
            }
            if let head, let settled = settledTokens(system: system, head: head, custom: custom, vocab: vocab),
               start < settled.count, tokens.count > settled.count, tokens.starts(with: settled) {
                guard try decode(tokens[start..<settled.count], context: context, isCancelled: isCancelled) else { return false }
                keepConversation(settled, context: context)
                start = settled.count
            }
        } else {
            // Test hook (DEBUG): the old way, the whole prompt in one go.
            llama_memory_clear(llama_get_memory(context), true)
        }
        #if DEBUG
        Self.lastPrefill = (tokens.count, start)
        #endif
        guard try decode(tokens[start...], context: context, isCancelled: isCancelled) else { return false }
        #if DEBUG
        if Self.measuresTimings { llama_synchronize(context) }
        timings.prefillMs = ms(since: began)
        let generating = DispatchTime.now().uptimeNanoseconds
        #endif

        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        #if DEBUG
        let greedy = ProcessInfo.processInfo.environment["OFFLINEKIT_GREEDY"] != nil   // test hook: repeatable answers
        #else
        let greedy = false
        #endif
        if greedy {
            llama_sampler_chain_add(sampler, llama_sampler_init_greedy())
        } else {
            // Low temperature: stay close to the sources.
            llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
            llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
            llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.3))
            llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))
        }

        // Per token: sample, append its bytes, start the next token on the GPU, and only then (while the GPU works)
        // hand the text over, at most every 50 ms once the reader has something to see. Until then every token is
        // passed on, so the first words appear the moment there are any (the first tokens are often whitespace
        // or a hidden "thinking" marker).
        var bytes: [UInt8] = []
        bytes.reserveCapacity(maxTokens * 4)
        var piece = [CChar](repeating: 0, count: 256)
        var lastEmit: UInt64 = 0
        var showing = false
        let interval: UInt64 = 50_000_000
        var ended = false          // finished its answer, or was stopped; otherwise it ran out of tokens
        for _ in 0..<maxTokens {
            if isCancelled() || quitting.value { ended = true; break }
            #if DEBUG
            let waiting = DispatchTime.now().uptimeNanoseconds
            if Self.measuresTimings { llama_synchronize(context) }
            timings.gpuWaitMs += ms(since: waiting)
            let sampling = DispatchTime.now().uptimeNanoseconds
            #endif
            var token = llama_sampler_sample(sampler, context, -1)
            #if DEBUG
            timings.sampleMs += ms(since: sampling)
            #endif
            if llama_vocab_is_eog(vocab, token) { ended = true; break }
            var n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n < 0 {
                piece = [CChar](repeating: 0, count: Int(-n))
                n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            }
            if n > 0 { piece.withUnsafeBytes { bytes.append(contentsOf: $0.prefix(Int(n))) } }
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            if status == 2 && isCancelled() { ended = true; break }
            guard status == 0 else { throw LlamaError.decodeFailed(status) }
            let now = DispatchTime.now().uptimeNanoseconds
            if !showing || now - lastEmit >= interval {
                let text = Self.visibleAnswer(String(decoding: bytes, as: UTF8.self))
                if showing || text.contains(where: { !$0.isWhitespace }) {
                    #if DEBUG
                    if !showing {
                        timings.firstTextMs = ms(since: began)
                        if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
                            FileHandle.standardError.write(Data("llama: first text after \(timings.tokens + 1) tokens: \(String(decoding: bytes, as: UTF8.self).debugDescription)\n".utf8))
                        }
                    }
                    #endif
                    showing = true
                    lastEmit = now
                    onText(text)
                }
            }
            #if DEBUG
            timings.tokens += 1
            #endif
        }
        #if DEBUG
        timings.generateMs = ms(since: generating)
        #endif
        onText(Self.visibleAnswer(String(decoding: bytes, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines))
        return !ended
    }
}

/// Lets llama.cpp ask "should I stop?" from inside a decode.
private final class AbortCheck {
    let check: () -> Bool
    init(_ check: @escaping () -> Bool) { self.check = check }
}

extension LlamaRuntime {
    /// Tokens in `text` for a model file, from its vocabulary alone (no weights loaded). For measuring prompt sizes.
    func tokenCount(file: URL, text: String) -> Int {
        Self.vocabLock.lock()
        defer { Self.vocabLock.unlock() }
        if Self.vocabModel?.path != file.path {
            if let old = Self.vocabModel { llama_model_free(old.model) }
            Self.vocabModel = nil
            var params = llama_model_default_params()
            params.vocab_only = true
            guard let model = llama_model_load_from_file(file.path, params) else { return text.count / 3 }
            Self.vocabModel = (file.path, model)
        }
        guard let model = Self.vocabModel?.model else { return text.count / 3 }
        let vocab = llama_model_get_vocab(model)
        return Int(-llama_tokenize(vocab, text, Int32(text.utf8.count), nil, 0, false, true))
    }

    private static let vocabLock = NSLock()
    nonisolated(unsafe) private static var vocabModel: (path: String, model: OpaquePointer)?
}

/// A GGUF model running inside the app through llama.cpp: no Ollama, no Apple Intelligence, no internet.
/// The built-in Gemma 4 downloads, or a model the person added.
struct LlamaEngine: AnswerEngine {
    let model: InstalledModel

    var displayName: String { "Answer model" }
    var technicalName: String { "Offline Kit answer model · \(model.shortName)" }
    var runsOnDevice: Bool { true }
    /// Context for this model on this device (built-in models keep their tested size).
    private var contextTokens: Int32 {
        if case .ready(let tokens) = model.plan { return tokens }
        return Int32(ModelFit.minimumContext)
    }
    /// About 3 characters per token, leaving room for the instructions and a 1,024-token answer.
    var sourceBudget: Int { min(14_000, (Int(contextTokens) - 1_700) * 3) }
    /// Everything but the instructions (about 1,100 tokens with the emergency ones) and a 1,024-token answer.
    var promptBudget: Int { max(4_000, (Int(contextTokens) - 1_024 - 1_100) * 3) }

    /// True when the model is already in memory.
    var isReady: Bool { LlamaRuntime.isReady(file: model.url, contextTokens: contextTokens) }

    /// Starts loading the model in the background, so the first question doesn't wait for it. With `instructions`,
    /// also evaluates them, so the first question starts answering sooner; with `head` (the household context and
    /// any conversation so far), that too.
    func preload(instructions: String? = nil, head: String? = nil) {
        guard case .ready = model.plan, instructions != nil || !isReady else { return }
        let url = model.url, tokens = contextTokens, custom = model.isCustom
        let count = LlamaRuntime.conversationCount
        let thread = Thread {
            LlamaRuntime.shared.preload(file: url, contextTokens: tokens, custom: custom, instructions: instructions)
            if let instructions, let head {
                LlamaRuntime.shared.prepareConversation(file: url, contextTokens: tokens, custom: custom, system: instructions,
                                                        head: head, conversation: count)
            }
        }
        thread.stackSize = 8 << 20
        thread.qualityOfService = .utility
        thread.start()
    }

    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        stream(instructions: instructions, prompt: prompt, notes: StreamNotes())
    }

    func stream(instructions: String, prompt: String, notes: StreamNotes) -> AsyncThrowingStream<String, Error> {
        stream(instructions: instructions, prompt: prompt, notes: notes, head: nil)
    }

    func prepareFollowUp(instructions: String, head: String) {
        guard case .ready = model.plan, isReady else { return }
        let url = model.url, tokens = contextTokens, custom = model.isCustom
        let count = LlamaRuntime.conversationCount
        let thread = Thread {
            LlamaRuntime.shared.prepareConversation(file: url, contextTokens: tokens, custom: custom, system: instructions,
                                                    head: head, conversation: count)
        }
        thread.stackSize = 8 << 20
        thread.qualityOfService = .utility
        thread.start()
    }

    func forgetConversation() { Self.forgetSavedConversation() }

    /// New Conversation, whichever engine answered last: the built-in model's saved conversation goes, and one
    /// being prepared stops. Never creates the runtime.
    static func forgetSavedConversation() {
        LlamaRuntime.newConversation()
        guard LlamaRuntime.exists else { return }
        LlamaRuntime.shared.forgetConversation()
    }

    func stream(instructions: String, prompt: String, notes: StreamNotes, head: String?) -> AsyncThrowingStream<String, Error> {
        let model = self.model, contextTokens = self.contextTokens
        return AsyncThrowingStream { continuation in
            // Checked before loading: an oversized model would fail partway, or push the device out of memory.
            switch model.plan {
            case .ready: break
            case .tooBig(let needed, let available):
                continuation.finish(throwing: LlamaError.tooBig(needed: needed, available: available)); return
            case .contextTooSmall(let n):
                continuation.finish(throwing: GGUFError.contextTooSmall(n)); return
            }
            let cancelled = CancelFlag()
            let thread = Thread {
                do {
                    let hitLimit = try LlamaRuntime.shared.generate(file: model.url, contextTokens: contextTokens, custom: model.isCustom,
                                                                    system: instructions, user: prompt, head: head,
                                                                    isCancelled: { cancelled.value }) { continuation.yield($0) }
                    if hitLimit { notes.cutShort = true }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            thread.stackSize = 8 << 20
            thread.qualityOfService = .userInitiated
            continuation.onTermination = { _ in cancelled.value = true }
            thread.start()
        }
    }
}

/// A thread-safe count.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = 0
    var value: Int { lock.withLock { _value } }
    func add(_ n: Int) { lock.withLock { _value += n } }
}

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
