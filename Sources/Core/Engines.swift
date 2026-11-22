import Foundation
import FoundationModels

/// A local language model. `stream` yields the full answer so far on each step.
protocol AnswerEngine: Sendable {
    /// A friendly name for people ("Answer model (larger)").
    var displayName: String { get }
    /// The model's technical name, for tooltips ("Ollama · gemma4:12b").
    var technicalName: String { get }
    var runsOnDevice: Bool { get }
    /// Characters of source text that fit comfortably in this model's context.
    var sourceBudget: Int { get }
    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error>
    /// Same, and `notes.cutShort` is set when the model ran out of room and stopped mid-answer.
    func stream(instructions: String, prompt: String, notes: StreamNotes) -> AsyncThrowingStream<String, Error>
    /// Same, for a question in a conversation: `head` is the start of `prompt` the next question will start with
    /// too (household context and earlier turns). Engines that can keep its evaluated state do.
    func stream(instructions: String, prompt: String, notes: StreamNotes, head: String?) -> AsyncThrowingStream<String, Error>
    /// Characters of household context, earlier conversation and sources that fit with the instructions and a full answer.
    var promptBudget: Int { get }
    /// Evaluates the next question's `head` ahead of time, in the background, when the engine keeps state.
    func prepareFollowUp(instructions: String, head: String)
    /// New Conversation: forget any state kept for follow-ups.
    func forgetConversation()
}

/// What an engine learned while streaming, read once the stream has ended.
final class StreamNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var _cutShort = false
    var cutShort: Bool {
        get { lock.withLock { _cutShort } }
        set { lock.withLock { _cutShort = newValue } }
    }
}

extension AnswerEngine {
    /// Engines that can't tell when they ran out of room just stream.
    func stream(instructions: String, prompt: String, notes: StreamNotes) -> AsyncThrowingStream<String, Error> {
        stream(instructions: instructions, prompt: prompt)
    }

    /// Engines that keep no state between prompts just stream.
    func stream(instructions: String, prompt: String, notes: StreamNotes, head: String?) -> AsyncThrowingStream<String, Error> {
        stream(instructions: instructions, prompt: prompt, notes: notes)
    }

    func prepareFollowUp(instructions: String, head: String) {}
    func forgetConversation() {}

    /// Engines that don't say: as much as Ask would ever send.
    var promptBudget: Int { 40_000 }

    /// Characters of personal and kit context to include. Small models get a short version.
    var contextBudget: Int { sourceBudget >= 10_000 ? 4_000 : 1_500 }
    var technicalName: String { displayName }
}

// MARK: Apple on-device model

struct AppleEngine: AnswerEngine {
    var displayName: String { "Apple Intelligence" }
    var technicalName: String { "Apple Intelligence on-device model" }
    var runsOnDevice: Bool { true }
    /// The on-device model has a ~4K token window shared by instructions, sources and the answer.
    var sourceBudget: Int { 5_000 }

    static var availability: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Ready"
        case .unavailable(.deviceNotEligible): return "Not supported on this device"
        case .unavailable(.appleIntelligenceNotEnabled): return "Turned off. Enable Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady): return "Model downloading. Keep this device online until it’s ready."
        case .unavailable: return "Not available yet"
        @unknown default: return "Unknown"
        }
    }

    /// Views ask in their bodies, so the answer is remembered briefly (the first ask costs ~100 ms and later ones add up).
    /// It's still fresh enough to notice Apple Intelligence being turned on or its model finishing a download.
    nonisolated(unsafe) private static var cachedAvailability: (value: Bool, at: ContinuousClock.Instant)?
    static var isAvailable: Bool {
        let now = ContinuousClock.now
        if let cached = cachedAvailability, now - cached.at < .seconds(3) { return cached.value }
        let value = SystemLanguageModel.default.isAvailable
        cachedAvailability = (value, now)
        return value
    }

    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(instructions: instructions)
                    for try await snapshot in session.streamResponse(to: prompt) {
                        continuation.yield(snapshot.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// True when the error means "too much text", so retrying with fewer sources may work.
    static func isContextOverflow(_ error: Error) -> Bool {
        if let e = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = e { return true }
        return false
    }
}

// MARK: Ollama (local server on this Mac, or another machine on the LAN)

struct OllamaEngine: AnswerEngine {
    var host: URL
    var model: String

    var displayName: String { "Answer model (larger)" }
    var technicalName: String { "Ollama · \(model)" + (Self.isLocalHost(host) ? "" : " on \(host.host() ?? "another computer")") }
    var sourceBudget: Int { 14_000 }
    /// num_ctx 16,384 tokens, less a full answer and the instructions, at about 3 characters a token.
    var promptBudget: Int { (16_384 - 1_024 - 1_100) * 3 }
    var runsOnDevice: Bool { Self.isLocalHost(host) }

    static func isLocalHost(_ host: URL) -> Bool {
        ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.host()?.lowercased() ?? "")
    }

    static let defaultHost = URL(string: "http://127.0.0.1:11434")!
    /// The model Offline Kit recommends for Ollama, and its download size (as reported by Ollama for gemma4:12b).
    static let recommendedModel = "gemma4:12b"
    static let recommendedModelBytes: Int64 = 7_714_091_504
    static let downloadPage = URL(string: "https://ollama.com/download")!

    /// Asks Ollama to download a model, reporting completed and total bytes as it goes.
    static func pull(model: String, host: URL, progress: @escaping @Sendable (Int64, Int64, String) -> Void) async throws {
        var req = URLRequest(url: host.appending(path: "api/pull"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3600
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        struct Line: Decodable { let status: String?; let total: Int64?; let completed: Int64?; let error: String? }
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8), let item = try? JSONDecoder().decode(Line.self, from: data) else { continue }
            if let error = item.error { throw NSError(domain: "Ollama", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            progress(item.completed ?? 0, item.total ?? 0, item.status ?? "")
        }
    }

    /// Installed model names, or nil if the server isn't reachable.
    static func installedModels(host: URL) async -> [String]? {
        #if DEBUG
        if ProcessInfo.processInfo.environment["OFFLINEKIT_NO_OLLAMA"] == "1" { return nil }   // test: a Mac without Ollama
        #endif
        var req = URLRequest(url: host.appending(path: "api/tags"))
        req.timeoutInterval = 2
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        return (try? JSONDecoder().decode(Tags.self, from: data))?.models.map(\.name) ?? []
    }

    struct ServerError: LocalizedError { let message: String; var errorDescription: String? { message } }

    func stream(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        stream(instructions: instructions, prompt: prompt, notes: StreamNotes())
    }

    func stream(instructions: String, prompt: String, notes: StreamNotes) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: host.appending(path: "api/chat"))
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.timeoutInterval = 600
                    let body: [String: Any] = [
                        "model": model,
                        "stream": true,
                        "think": false,
                        "options": ["num_ctx": 16384, "temperature": 0.3],
                        "messages": [
                            ["role": "system", "content": instructions],
                            ["role": "user", "content": prompt],
                        ],
                    ]
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                        var text = ""
                        for try await line in bytes.lines { text += line }
                        throw ServerError(message: "Ollama returned \(http.statusCode): \(text)")
                    }
                    struct Chunk: Decodable {
                        struct Msg: Decodable { let content: String? }
                        let message: Msg?; let done: Bool?; let error: String?; let done_reason: String?
                    }
                    var answer = ""
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { continue }
                        if let err = chunk.error { throw ServerError(message: err) }
                        if let piece = chunk.message?.content, !piece.isEmpty {
                            answer += piece
                            continuation.yield(answer)
                        }
                        if chunk.done == true {
                            if chunk.done_reason == "length" { notes.cutShort = true }
                            break
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
