import AVFoundation
import Observation
import Speech

/// Listens for a spoken question with Apple's on-device speech recognition only. It never sends audio to a server:
/// SpeechAnalyzer first, else SFSpeechRecognizer with on-device recognition required, else it says plainly why it can't.
@MainActor @Observable
final class VoiceListener {
    enum State: Equatable {
        case idle
        /// Checking permissions or loading the speech model; the text says what's happening when it takes a while.
        case preparing(String?)
        case listening
    }

    private(set) var state: State = .idle
    /// Everything heard so far: settled words plus the words still being worked out.
    private(set) var transcript = ""
    /// Microphone loudness, 0...1, for the on-screen meter.
    private(set) var level: Float = 0
    /// Why listening can't work, in plain words. Cleared on the next try.
    private(set) var problem: String?

    /// Stop after this much quiet once words have been heard.
    var quietAfterWords: Duration = .seconds(1.6)
    /// Give up after this long with no words at all.
    var quietBeforeWords: Duration = .seconds(8)

    var isActive: Bool { state != .idle }

    private var recognizer: SpeechRecognition?
    private var mic: MicCapture?
    private var watchdog: Task<Void, Never>?
    private var lastChange = ContinuousClock.now
    private var started = ContinuousClock.now
    private var finish: ((String?) -> Void)?
    private var session = 0

    /// Where the words come from. Tests feed a recorded file in real time instead of the microphone.
    enum Source { case microphone, file(URL) }

    /// Starts listening. `done` gets the words heard (empty if nothing was said) once it stops: after a pause,
    /// on `stop()`, or after `quietBeforeWords` of silence; or nil when listening can't work (see `problem`).
    /// Not called after `cancel()`.
    func start(from source: Source = .microphone, done: @escaping (String?) -> Void) {
        cancel()
        session += 1
        let id = session
        problem = nil
        transcript = ""
        level = 0
        finish = done
        state = .preparing(nil)
        Task {
            if case .microphone = source, let message = await Self.permissionProblem() {
                return fail(message, session: id)
            }
            guard session == id else { return }
            let recognition: SpeechRecognition
            do {
                recognition = try await Self.makeRecognizer(locale: .current) { [weak self] status in
                    guard let self, self.session == id else { return }
                    self.state = .preparing(status)
                }
            } catch {
                return fail((error as? ListenError)?.message ?? error.localizedDescription, session: id)
            }
            guard session == id else { recognition.cancel(); return }
            recognizer = recognition
            recognition.onText = { [weak self] text in
                Task { @MainActor in
                    guard let self, self.session == id, text != self.transcript else { return }
                    self.transcript = text
                    self.lastChange = .now
                }
            }
            let capture = MicCapture()
            capture.onLevel = { [weak self] value in
                Task { @MainActor in
                    guard let self, self.session == id else { return }
                    self.level = self.level * 0.6 + value * 0.4
                }
            }
            do {
                switch source {
                case .microphone: try capture.startMicrophone(feeding: recognition)
                case .file(let url): try capture.startFile(url, feeding: recognition)
                }
            } catch {
                recognition.cancel()
                return fail((error as? ListenError)?.message ?? "Offline Kit couldn't start the microphone: \(error.localizedDescription)", session: id)
            }
            mic = capture
            started = .now
            lastChange = .now
            state = .listening
            VoiceLog.log("LISTEN start (\(recognition.name))")
            watch(session: id)
        }
    }

    /// Stops now and hands over what was heard.
    func stop() {
        guard state != .idle else { return }
        let id = session
        guard let recognition = recognizer else { return cancel() }
        mic?.stop()
        mic = nil
        watchdog?.cancel()
        state = .preparing(nil)
        Task {
            let final = await recognition.finish()
            guard session == id else { return }
            let words = (final ?? transcript).trimmingCharacters(in: .whitespacesAndNewlines)
            transcript = words
            let done = finish
            reset()
            VoiceLog.log("HEARD: \(words)")
            done?(words)
        }
    }

    func clearProblem() { problem = nil }

    /// Stops without handing anything over.
    func cancel() {
        session += 1
        mic?.stop()
        mic = nil
        recognizer?.cancel()
        reset()
    }

    private func reset() {
        recognizer = nil
        watchdog?.cancel()
        watchdog = nil
        finish = nil
        level = 0
        state = .idle
        Self.releaseAudioSession()
    }

    private func fail(_ message: String, session id: Int) {
        guard session == id else { return }
        mic?.stop()
        mic = nil
        recognizer?.cancel()
        let done = finish
        reset()
        problem = message
        VoiceLog.log("LISTEN problem: \(message)")
        done?(nil)
    }

    /// Ends listening after a pause in speech, or when nothing is said at all.
    private func watch(session id: Int) {
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, self.session == id, self.state == .listening else { return }
                let now = ContinuousClock.now
                let heard = !self.transcript.trimmingCharacters(in: .whitespaces).isEmpty
                if heard, now - self.lastChange >= self.quietAfterWords { return self.stop() }
                if !heard, now - self.started >= self.quietBeforeWords { return self.stop() }
                if now - self.started >= .seconds(90) { return self.stop() }
            }
        }
    }

    // MARK: Permissions

    /// Asks for the microphone and speech recognition the first time; afterwards just checks.
    private static func permissionProblem() async -> String? {
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else {
            #if os(macOS)
            return "Offline Kit can’t hear you because microphone access is off. Turn it on in System Settings › Privacy & Security › Microphone."
            #else
            return "Offline Kit can’t hear you because microphone access is off. Turn it on in Settings › Privacy & Security › Microphone."
            #endif
        }
        let speech = await speechAuthorization()
        guard speech == .authorized else {
            #if os(macOS)
            return "Offline Kit can’t understand speech because Speech Recognition is off for it. Turn it on in System Settings › Privacy & Security › Speech Recognition."
            #else
            return "Offline Kit can’t understand speech because Speech Recognition is off for it. Turn it on in Settings › Privacy & Security › Speech Recognition."
            #endif
        }
        return nil
    }

    private nonisolated static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
    }

    // MARK: Recognizer choice

    /// SpeechAnalyzer when it supports this language and its model is on the device (or can be fetched now);
    /// else the older recognizer, on-device only; else a plain explanation. Never server recognition.
    private static func makeRecognizer(locale: Locale, status: @escaping (String) -> Void) async throws -> SpeechRecognition {
        let language = locale.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
        var analyzerProblem: ListenError?
        if SpeechTranscriber.isAvailable, let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) {
            do {
                return try await AnalyzerRecognition.make(locale: supported, language: language, status: status)
            } catch let error as ListenError {
                analyzerProblem = error
            } catch {
                analyzerProblem = ListenError("The on-device speech model couldn’t start: \(error.localizedDescription)")
            }
        }
        if let legacy = LegacyRecognition(locale: locale) { return legacy }
        throw analyzerProblem ?? ListenError(
            "On-device speech recognition isn’t available for \(language) on this device, so Offline Kit can’t listen. "
            + "It never sends your voice to a server. You can still type your question.")
    }

    // MARK: Audio session (iPhone)

    nonisolated static func useAudioSessionForListening() throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try session.setActive(true)
        #endif
    }

    nonisolated static func releaseAudioSession() {
        #if os(iOS)
        // Back to playback so read-aloud keeps using the speaker and the mic indicator goes away.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        #endif
    }
}

struct ListenError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

// MARK: - Recognizers

/// One listening session's recognizer. `append` is called on the audio thread.
class SpeechRecognition: @unchecked Sendable {
    var name: String { "" }
    /// Called with the full text heard so far, on any thread.
    var onText: (@Sendable (String) -> Void)?
    func append(_ buffer: AVAudioPCMBuffer) {}
    /// Ends the audio and returns the settled text, if the recognizer gave one.
    func finish() async -> String? { nil }
    func cancel() {}
}

/// SpeechAnalyzer + SpeechTranscriber (OS 26).
final class AnalyzerRecognition: SpeechRecognition, @unchecked Sendable {
    override var name: String { "SpeechAnalyzer" }
    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let format: AVAudioFormat
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private var results: Task<String, Never>?
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var settled = ""

    private init(analyzer: SpeechAnalyzer, transcriber: SpeechTranscriber, format: AVAudioFormat,
                 input: AsyncStream<AnalyzerInput>.Continuation) {
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.format = format
        self.input = input
    }

    static func make(locale: Locale, language: String, status: @escaping (String) -> Void) async throws -> AnalyzerRecognition {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [])
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: break
        case .unsupported:
            throw ListenError("On-device speech recognition isn’t available for \(language) on this device, so Offline Kit can’t listen. "
                              + "It never sends your voice to a server. You can still type your question.")
        case .supported, .downloading:
            // The model isn't on this device yet. Fetching it needs internet once; recognition itself stays on device.
            status("Getting the on-device speech model for \(language). This happens once and needs internet…")
            do {
                try await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
            } catch {
                throw ListenError("The on-device speech model for \(language) isn’t on this device yet, and it can’t be "
                                  + "downloaded without internet. Connect once to get it; after that, listening works offline.")
            }
        @unknown default: break
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw ListenError("The on-device speech model couldn’t pick an audio format.")
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let recognition = AnalyzerRecognition(analyzer: analyzer, transcriber: transcriber, format: format, input: continuation)
        recognition.results = Task {
            var settled = ""
            var volatile = ""
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if result.isFinal { settled += text; volatile = "" } else { volatile = text }
                    recognition.onText?(Self.join(settled, volatile))
                }
            } catch {}
            return Self.join(settled, volatile)
        }
        try await analyzer.start(inputSequence: stream)
        return recognition
    }

    private static func join(_ a: String, _ b: String) -> String {
        (a + b).replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
    }

    override func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let converted = convert(buffer) else { return }
        input.yield(AnalyzerInput(buffer: converted))
    }

    /// Microphone audio (often 48 kHz float) to what the model wants (often 16 kHz 16-bit mono).
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format == format { return buffer }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied { outStatus.pointee = .noDataNow; return nil }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    override func finish() async -> String? {
        input.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        return await results?.value
    }

    override func cancel() {
        input.finish()
        results?.cancel()
        let analyzer = analyzer
        Task { await analyzer.cancelAndFinishNow() }
    }
}

/// SFSpeechRecognizer with on-device recognition required. Used only when SpeechAnalyzer can't run.
final class LegacyRecognition: SpeechRecognition, @unchecked Sendable {
    override var name: String { "SFSpeechRecognizer (on-device)" }
    private let recognizer: SFSpeechRecognizer
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private var task: SFSpeechRecognitionTask?
    private let lock = NSLock()
    private var latest = ""
    private var finalText: String?
    private var waiters: [CheckedContinuation<String?, Never>] = []

    init?(locale: Locale) {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable else { return nil }
        self.recognizer = recognizer
        super.init()
        request.requiresOnDeviceRecognition = true   // never fall back to Apple's servers
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        task = Self.startTask(recognizer: recognizer, request: request, owner: self)
    }

    private nonisolated static func startTask(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              owner: LegacyRecognition) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { [weak owner] result, error in
            guard let owner else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                owner.lock.withLock { owner.latest = text }
                owner.onText?(text)
                if result.isFinal { owner.resolve(text) }
            } else if error != nil {
                owner.resolve(nil)
            }
        }
    }

    private func resolve(_ text: String?) {
        let waiting: [CheckedContinuation<String?, Never>] = lock.withLock {
            finalText = text ?? latest
            defer { waiters.removeAll() }
            return waiters
        }
        waiting.forEach { $0.resume(returning: text ?? latest) }
    }

    override func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }

    override func finish() async -> String? {
        request.endAudio()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.resolve(nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { continuation in
            let done: String?? = lock.withLock {
                if let finalText { return .some(finalText) }
                waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    override func cancel() { task?.cancel() }
}

// MARK: - Audio in

/// The microphone (or a test file played in real time), feeding a recognizer. Runs off the main thread.
final class MicCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var fileTask: Task<Void, Never>?
    var onLevel: (@Sendable (Float) -> Void)?

    func startMicrophone(feeding recognition: SpeechRecognition) throws {
        try VoiceListener.useAudioSessionForListening()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw ListenError("No microphone was found. Connect one, or type your question.")
        }
        Self.installTap(on: input, format: format, recognition: recognition, level: onLevel)
        engine.prepare()
        try engine.start()
    }

    /// Plays a recorded file into the recognizer at real-time speed, then a few seconds of silence,
    /// so the pause detection works as it would with a person.
    func startFile(_ url: URL, feeding recognition: SpeechRecognition) throws {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let level = onLevel
        fileTask = Task.detached {
            let chunk: AVAudioFrameCount = 4_096
            while !Task.isCancelled, file.framePosition < file.length,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) {
                guard (try? file.read(into: buffer, frameCount: chunk)) != nil, buffer.frameLength > 0 else { break }
                recognition.append(buffer)
                level?(Self.loudness(buffer))
                try? await Task.sleep(for: .seconds(Double(buffer.frameLength) / format.sampleRate))
            }
            // Trailing silence, like a person who has finished talking.
            for _ in 0..<40 where !Task.isCancelled {
                guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { break }
                silence.frameLength = chunk
                for channel in 0..<Int(format.channelCount) {
                    if let data = silence.floatChannelData?[channel] { data.update(repeating: 0, count: Int(chunk)) }
                }
                recognition.append(silence)
                level?(0)
                try? await Task.sleep(for: .seconds(Double(chunk) / format.sampleRate))
            }
        }
    }

    func stop() {
        fileTask?.cancel()
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
    }

    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat,
                                               recognition: SpeechRecognition, level: (@Sendable (Float) -> Void)?) {
        input.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            recognition.append(buffer)
            level?(loudness(buffer))
        }
    }

    /// A rough 0...1 loudness for the meter.
    nonisolated static func loudness(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-6))
        return max(0, min(1, (db + 50) / 45))
    }
}
