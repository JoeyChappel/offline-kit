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

    private init() {
        llama_backend_init()
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
    }

    private func unload() {
        if let context { llama_free(context) }
        if let model { llama_model_free(model) }
        context = nil
        model = nil
        loadedPath = nil
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
        defer { lock.unlock() }
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

        llama_memory_clear(llama_get_memory(context), true)
        // Feed the prompt in batches.
        var offset = 0
        while offset < tokens.count {
            let count = min(2048, tokens.count - offset)
            let status = tokens.withUnsafeMutableBufferPointer { buf in
                llama_decode(context, llama_batch_get_one(buf.baseAddress! + offset, Int32(count)))
            }
            guard status == 0 else { throw LlamaError.decodeFailed(status) }
            offset += count
            if isCancelled() { return }
        }

        // Low temperature: stay close to the sources.
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.3))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))

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
