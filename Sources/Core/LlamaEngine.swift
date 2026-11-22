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

    /// What is loaded and when it was last used, readable without waiting for a load or a generation to finish.
    private let stateLock = NSLock()
    private var readyKey: String?
    private var lastUsed = Date()
    private var idleCheck = 0
    private var pressure: DispatchSourceMemoryPressure?

    /// A model nobody has asked anything of for this long is released (it holds several GB).
    static let idleSeconds: TimeInterval = 600

    private init() {
        llama_backend_init()
        // Low memory: give the model back unless it's answering right now (it loads again on the next question).
        let source = DispatchSource.makeMemoryPressureSource(eventMask: .critical, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self, self.lock.try() else { return }
            self.unload()
            self.lock.unlock()
        }
        source.resume()
        pressure = source
    }

    private static func key(path: String, contextTokens: Int32) -> String { "\(path)#\(contextTokens)" }

    /// True when this model is already in memory, so a question can start answering at once.
    func isReady(file: URL, contextTokens: Int32) -> Bool {
        stateLock.withLock { readyKey == Self.key(path: file.path, contextTokens: contextTokens) }
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
                if (try? decode(prefix[...], context: context, isCancelled: { false })) == true { keepPrefix(prefix, context: context) }
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
        lock.lock()
        defer { lock.unlock() }
        unload()
    }

    private func load(path: String, contextTokens: Int32, custom: Bool) throws {
        if loadedPath == path, self.contextTokens == UInt32(contextTokens), context != nil { return }
        unload()
        var params = llama_model_default_params()
        #if targetEnvironment(simulator)
        params.n_gpu_layers = 0          // the simulator's Metal is too limited for this
        #else
        params.n_gpu_layers = 999        // everything on the GPU (Metal)
        #endif
        guard let model = llama_model_load_from_file(path, params) else {
            throw custom ? LlamaError.loadFailedCustom(URL(fileURLWithPath: path).lastPathComponent) : LlamaError.loadFailed(path)
        }
        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(contextTokens)
        cparams.n_batch = 2048
        cparams.n_ubatch = 512
        guard let context = llama_init_from_model(model, cparams) else {
            llama_model_free(model)
            throw LlamaError.contextFailed
        }
        self.model = model
        self.context = context
        self.loadedPath = path
        self.contextTokens = UInt32(contextTokens)
        stateLock.withLock { readyKey = Self.key(path: path, contextTokens: contextTokens) }
    }

    private func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        loadedPath = nil
        prefixes = []
        stateLock.withLock { readyKey = nil }
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
            let count = min(2048, batch.count - offset)
            let status = batch.withUnsafeMutableBufferPointer { buf in
                llama_decode(context, llama_batch_get_one(buf.baseAddress! + offset, Int32(count)))
            }
            guard status == 0 else { throw LlamaError.decodeFailed(status) }
            offset += count
            if isCancelled() { return false }
        }
        return true
    }

    /// The tokens every prompt with these instructions starts with: the chat template up to where the question
    /// goes, less its last two tokens (which can merge with the question's first words). Nil when too short to keep.
    private func instructionTokens(system: String, custom: Bool, vocab: OpaquePointer?) -> [llama_token]? {
        let marker = "\u{1F}OKQ\u{1F}"
        let formatted = format(system: system, user: marker, custom: custom)
        guard let range = formatted.range(of: marker) else { return nil }
        let prefix = String(formatted[..<range.lowerBound])
        let needed = -llama_tokenize(vocab, prefix, Int32(prefix.utf8.count), nil, 0, true, true)
        guard needed > Int32(Self.minimumPrefixTokens) + 2 else { return nil }
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        guard llama_tokenize(vocab, prefix, Int32(prefix.utf8.count), &tokens, needed, true, true) == needed else { return nil }
        return Array(tokens.dropLast(2))
    }

    /// Saves the state the model is in right after evaluating `tokens`, for the next prompt that starts with them.
    private func keepPrefix(_ tokens: [llama_token], context: OpaquePointer) {
        let size = llama_state_seq_get_size(context, 0)
        guard size > 0 else { return }
        var state = [UInt8](repeating: 0, count: size)
        let written = state.withUnsafeMutableBufferPointer { llama_state_seq_get_data(context, $0.baseAddress, size, 0) }
        guard written > 0 else { return }
        prefixes.removeAll { $0.tokens == tokens }
        prefixes.insert((tokens, Array(state.prefix(written))), at: 0)
        if prefixes.count > 2 { prefixes.removeLast() }
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_TRACE"] != nil {
            FileHandle.standardError.write(Data("llama: kept \(tokens.count) instruction tokens (\(written / 1_048_576) MB of state)\n".utf8))
        }
        #endif
    }

    #if DEBUG
    /// Tokens in the last prompt, and how many of them came from the saved instructions (for the benchmark).
    nonisolated(unsafe) static var lastPrefill: (total: Int, reused: Int) = (0, 0)
    /// Test hook: false evaluates every prompt whole, the way it was before instructions were saved.
    nonisolated(unsafe) static var reusesInstructions = true

    /// Test hook: forget the saved instructions, so the next prompt evaluates and saves them again.
    func forgetInstructions() { lock.withLock { prefixes = [] } }
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
    func generate(file: URL, contextTokens: Int32, custom: Bool, system: String, user: String, maxTokens: Int = 1024,
                  isCancelled: () -> Bool, onText: (String) -> Void) throws {
        lock.lock()
        defer { lock.unlock(); touch() }
        try load(path: file.path, contextTokens: contextTokens, custom: custom)
        guard let model, let context else { throw LlamaError.contextFailed }
        let vocab = llama_model_get_vocab(model)

        let prompt = format(system: system, user: user, custom: custom)
        let needed = -llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), nil, 0, true, true)
        guard needed > 0 else { throw LlamaError.tokenizeFailed }
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        guard llama_tokenize(vocab, prompt, Int32(prompt.utf8.count), &tokens, needed, true, true) == needed else {
            throw LlamaError.tokenizeFailed
        }
        let room = Int(contextTokens) - maxTokens
        guard tokens.count <= room else { throw LlamaError.tooLong(tokens.count, room) }

        // Start from the instructions' saved state when this prompt begins with them; otherwise evaluate them first
        // and save that state for the next question. Either way the same tokens are evaluated in the same two steps
        // (instructions, then the rest), so the answer doesn't depend on whether the state was saved.
        let memory = llama_get_memory(context)
        llama_memory_clear(memory, true)
        var start = 0
        #if DEBUG
        let reuse = Self.reusesInstructions
        #else
        let reuse = true
        #endif
        if !reuse {
            // Test hook (DEBUG): the old way, the whole prompt in one go.
        } else if let saved = prefixes.first(where: { tokens.count > $0.tokens.count && tokens.starts(with: $0.tokens) }) {
            let restored = saved.state.withUnsafeBufferPointer { llama_state_seq_set_data(context, $0.baseAddress, $0.count, 0) }
            if restored > 0 { start = saved.tokens.count } else { llama_memory_clear(memory, true) }
        } else if let prefix = instructionTokens(system: system, custom: custom, vocab: vocab),
                  tokens.count > prefix.count, tokens.starts(with: prefix) {
            guard try decode(tokens[..<prefix.count], context: context, isCancelled: isCancelled) else { return }
            keepPrefix(prefix, context: context)
            start = prefix.count
        }
        #if DEBUG
        Self.lastPrefill = (tokens.count, start)
        #endif
        guard try decode(tokens[start...], context: context, isCancelled: isCancelled) else { return }

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

        var bytes: [UInt8] = []
        var piece = [CChar](repeating: 0, count: 256)
        var lastEmit = Date.distantPast
        for _ in 0..<maxTokens {
            if isCancelled() { break }
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let n = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 { bytes.append(contentsOf: piece.prefix(Int(n)).map { UInt8(bitPattern: $0) }) }
            if Date().timeIntervalSince(lastEmit) > 0.05 {
                lastEmit = Date()
                onText(Self.visibleAnswer(String(decoding: bytes, as: UTF8.self)))
            }
            let status = llama_decode(context, llama_batch_get_one(&token, 1))
            guard status == 0 else { throw LlamaError.decodeFailed(status) }
        }
        onText(Self.visibleAnswer(String(decoding: bytes, as: UTF8.self)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
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

    /// True when the model is already in memory.
    var isReady: Bool { LlamaRuntime.shared.isReady(file: model.url, contextTokens: contextTokens) }

    /// Starts loading the model in the background, so the first question doesn't wait for it. With `instructions`,
    /// also evaluates them, so the first question starts answering sooner.
    func preload(instructions: String? = nil) {
        guard case .ready = model.plan, instructions != nil || !isReady else { return }
        let url = model.url, tokens = contextTokens, custom = model.isCustom
        let thread = Thread { LlamaRuntime.shared.preload(file: url, contextTokens: tokens, custom: custom, instructions: instructions) }
        thread.stackSize = 8 << 20
        thread.qualityOfService = .utility
        thread.start()
    }

    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
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
                    try LlamaRuntime.shared.generate(file: model.url, contextTokens: contextTokens, custom: model.isCustom,
                                                     system: instructions, user: prompt,
                                                     isCancelled: { cancelled.value }) { continuation.yield($0) }
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

private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
