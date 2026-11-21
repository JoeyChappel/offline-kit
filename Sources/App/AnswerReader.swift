import AVFoundation
import Observation

/// The voice and speed for reading answers aloud, remembered in the kit's settings.
@MainActor @Observable
final class ReadAloudSettings {
    static let shared = ReadAloudSettings()

    struct Speed: Identifiable, Hashable {
        let multiplier: Double
        let label: String
        var id: Double { multiplier }
    }
    static let speeds = [Speed(multiplier: 0.8, label: "Slower"), Speed(multiplier: 1.0, label: "Normal"),
                         Speed(multiplier: 1.2, label: "Faster"), Speed(multiplier: 1.4, label: "Fastest")]

    /// 1 is the system's normal speaking speed.
    var speed: Double {
        didSet { KitSettings.shared.set(String(speed), forKey: "readAloudSpeed") }
    }
    /// An `AVSpeechSynthesisVoice` identifier. Empty: the best voice installed for this language.
    var voiceID: String {
        didSet { KitSettings.shared.set(voiceID, forKey: "readAloudVoice") }
    }
    /// Read every answer aloud, not only in hands-free mode.
    var readEveryAnswer: Bool {
        didSet { KitSettings.shared.set(readEveryAnswer, forKey: "readEveryAnswer") }
    }

    private init() {
        let d = KitSettings.shared
        speed = d.string(forKey: "readAloudSpeed").flatMap(Double.init) ?? 1.0
        voiceID = d.string(forKey: "readAloudVoice") ?? ""
        readEveryAnswer = d.bool(forKey: "readEveryAnswer") ?? false
    }

    func slower() { speed = Self.speeds.last { $0.multiplier < speed - 0.01 }?.multiplier ?? Self.speeds[0].multiplier }
    func faster() { speed = Self.speeds.first { $0.multiplier > speed + 0.01 }?.multiplier ?? Self.speeds.last!.multiplier }

    var speedLabel: String { Self.speeds.first { abs($0.multiplier - speed) < 0.01 }?.label ?? String(format: "%.1f×", speed) }

    /// Voices for this device's language, best quality first. Novelty voices left out.
    static var voices: [AVSpeechSynthesisVoice] {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(prefix) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { a, b in
                if (a.language == language) != (b.language == language) { return a.language == language }
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    var voice: AVSpeechSynthesisVoice? {
        if !voiceID.isEmpty, let chosen = AVSpeechSynthesisVoice(identifier: voiceID) { return chosen }
        // An Enhanced or Premium voice when one is installed; otherwise the system's own voice for this language.
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        return Self.voices.first { $0.language == language && $0.quality != .default }
            ?? AVSpeechSynthesisVoice(language: language)
    }

    static func describe(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String = switch voice.quality {
        case .premium: " (Premium)"
        case .enhanced: " (Enhanced)"
        default: ""
        }
        let region = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        return "\(voice.name)\(quality) · \(region)"
    }
}

/// Reads answers aloud with `AVSpeechSynthesizer`, sentence by sentence while the answer is still streaming.
@MainActor @Observable
final class AnswerReader {
    /// True while something is queued or being spoken (paused counts).
    private(set) var isSpeaking = false
    private(set) var isPaused = false
    /// The answer being read, so a turn's Listen button can show Stop.
    private(set) var turnID: UUID?
    /// The last answer text read in full, for "read that again".
    private(set) var lastAnswer = ""

    /// Called when everything queued has been spoken and the answer is complete.
    var onFinished: (() -> Void)?

    private let synthesizer = AVSpeechSynthesizer()
    private let delegate = Delegate()
    private var stream = SpokenAnswerStream()
    private var live: Set<ObjectIdentifier> = []
    private var complete = false
    /// A turn the person stopped, so its remaining stream isn't picked up again.
    private var stoppedTurn: UUID?

    init() {
        synthesizer.delegate = delegate
        delegate.onEnd = { [weak self] id in
            Task { @MainActor in self?.ended(id) }
        }
        delegate.onStart = { text in VoiceLog.log("SPEAKING: «\(text)»") }
    }

    /// Feeds the answer so far. Speaks finished sentences now; the rest when `final`.
    func follow(turn: UUID, answer: String, final: Bool) {
        guard turn != stoppedTurn else { return }
        if turnID != turn {
            stopSpeaking()
            turnID = turn
            stream.reset()
            complete = false
        }
        guard !complete else { return }
        let (text, restarted) = stream.next(answer: answer, final: final)
        if restarted { stopSpeaking(keepTurn: true) }
        if !text.isEmpty { enqueue(text) }
        if final {
            complete = true
            lastAnswer = answer
            if live.isEmpty { finished() }
        }
    }

    /// Reads a whole answer from the start.
    func read(answer: String, turn: UUID? = nil) {
        stopSpeaking()
        turnID = turn
        lastAnswer = answer
        enqueue(SpokenAnswer.clean(answer))
        complete = true
        if live.isEmpty { finished() }
    }

    /// Says a short phrase as is (a reply to a spoken command or an error).
    func say(_ phrase: String, then done: Bool = true) {
        stopSpeaking()
        turnID = nil
        enqueue(phrase)
        complete = done
        if live.isEmpty && done { finished() }
    }

    func readAgain() {
        guard !lastAnswer.isEmpty else { return say("There’s no answer to read yet.") }
        read(answer: lastAnswer, turn: turnID)
    }

    func pause() {
        guard isSpeaking, !isPaused else { return }
        synthesizer.pauseSpeaking(at: .word)
        isPaused = true
    }

    func resume() {
        guard isPaused else { return }
        synthesizer.continueSpeaking()
        isPaused = false
    }

    /// Stops reading. `onFinished` isn't called.
    func stop() {
        stoppedTurn = turnID
        stopSpeaking()
        turnID = nil
        complete = true
    }

    private func stopSpeaking(keepTurn: Bool = false) {
        live.removeAll()
        if synthesizer.isSpeaking || synthesizer.isPaused { synthesizer.stopSpeaking(at: .immediate) }
        isSpeaking = false
        isPaused = false
        if !keepTurn { complete = false }
    }

    private func enqueue(_ text: String) {
        let settings = ReadAloudSettings.shared
        prepareAudioSession()
        // One utterance per paragraph keeps the gaps natural and lets "stop" cut in quickly.
        for part in text.components(separatedBy: "\n") where !part.trimmingCharacters(in: .whitespaces).isEmpty {
            let utterance = AVSpeechUtterance(string: part)
            utterance.voice = settings.voice
            utterance.rate = Float(min(Double(AVSpeechUtteranceMaximumSpeechRate),
                                       max(Double(AVSpeechUtteranceMinimumSpeechRate),
                                           Double(AVSpeechUtteranceDefaultSpeechRate) * settings.speed)))
            utterance.postUtteranceDelay = 0.15
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "muteSpeech") { utterance.volume = 0 }
            #endif
            VoiceLog.log("QUEUED: «\(part.prefix(40))»")
            live.insert(ObjectIdentifier(utterance))
            synthesizer.speak(utterance)
        }
        isSpeaking = !live.isEmpty
    }

    private func ended(_ id: ObjectIdentifier) {
        guard live.remove(id) != nil else { return }
        if live.isEmpty {
            isSpeaking = false
            isPaused = false
            if complete { finished() }
        }
    }

    private func finished() {
        VoiceLog.log("SPEECH finished")
        onFinished?()
    }

    private func prepareAudioSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // Keep the listening setup if it's in use; otherwise play through the speaker even with the ring switch off.
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        }
        try? session.setActive(true)
        #endif
    }

    private final class Delegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
        var onEnd: (@Sendable (ObjectIdentifier) -> Void)?
        var onStart: (@Sendable (String) -> Void)?
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
            onStart?(utterance.speechString)
        }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
            VoiceLog.log("FINISHED: «\(utterance.speechString.prefix(30))»")
            onEnd?(ObjectIdentifier(utterance))
        }
        func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
            onEnd?(ObjectIdentifier(utterance))
        }
    }
}

/// Debug log for voice tests: appends to <test home>/asklog.txt, like Ask's -autoAsk hook.
enum VoiceLog {
    nonisolated static func log(_ text: String) {
        #if DEBUG
        guard let home = KitLocation.testHome else { return }
        let url = home.appending(path: "asklog.txt")
        let stamp = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute().second().secondFraction(.fractional(1)))
        let line = Data(("[\(stamp)] " + text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(line); try? handle.close()
        } else {
            try? line.write(to: url)
        }
        #endif
    }
}
