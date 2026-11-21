import AVFoundation
import Observation
import SwiftUI
#if os(macOS)
import AppKit
#else
import AudioToolbox
#endif

/// Ask by voice: dictate into the text field, or go hands-free (speak, hear the answer, speak again).
@MainActor @Observable
final class VoiceAsk {
    enum Phase: Equatable { case idle, preparing, listening, thinking, speaking }

    let listener = VoiceListener()
    let reader = AnswerReader()
    private(set) var handsFree = false
    /// Words going into the text field, to edit before sending.
    private(set) var dictating = false
    /// A short note shown above the text field, like why hands-free ended.
    var notice: String?

    /// Asks a question the same way typing it would. Set by the Ask view.
    /// Returns whether the question was taken.
    var ask: ((String) -> Bool)?
    weak var model: AskModel?
    /// Where the words come from. Debug tests swap in a recorded file.
    var source: VoiceListener.Source = .microphone
    #if DEBUG
    /// More recordings for a debug test, heard one after another in hands-free mode.
    var testFiles: [URL] = []
    #endif

    /// The turn whose answer is being read as it streams.
    private var followTurn: UUID?
    private var waitingForTurn = false

    init() {
        reader.onFinished = { [weak self] in self?.readingFinished() }
    }

    var phase: Phase {
        switch listener.state {
        case .listening: return .listening
        case .preparing: return .preparing
        case .idle: break
        }
        if reader.isSpeaking { return .speaking }
        if waitingForTurn { return .thinking }
        if let followTurn, let last = model?.turns.last, last.id == followTurn,
           last.status == .searching || last.status == .answering { return .thinking }
        return .idle
    }

    /// Shows the voice status line in the text field.
    var isActive: Bool { handsFree || phase != .idle }

    // MARK: Actions

    /// The mic button: dictate into the field, or in hands-free mode listen for the next question.
    /// While listening, it stops and keeps what was heard.
    func micTapped(dictation: @escaping (String) -> Void) {
        if listener.isActive { return listener.stop() }
        reader.stop()
        notice = nil
        if handsFree { return listenForQuestion() }
        dictating = true
        listener.quietBeforeWords = .seconds(8)
        VoiceCue.listening()
        listener.start(from: source) { [weak self] words in
            guard let self else { return }
            self.dictating = false
            if let words, !words.isEmpty { dictation(words) }
        }
    }

    func toggleHandsFree() {
        handsFree ? end() : begin()
    }

    func begin() {
        dictating = false
        listener.cancel()
        reader.stop()
        notice = nil
        handsFree = true
        listenForQuestion()
    }

    /// Ends hands-free mode and stops listening and reading.
    func end(notice: String? = nil) {
        handsFree = false
        dictating = false
        waitingForTurn = false
        followTurn = nil
        listener.cancel()
        reader.stop()
        self.notice = notice
    }

    /// The status line's Stop: quiet now. In hands-free mode, then listen for the next question.
    func stopTapped() {
        if listener.isActive {
            listener.cancel()
            if handsFree { end() }
            return
        }
        if let followTurn, model?.turns.last?.id == followTurn, model?.isBusy == true { model?.stop() }
        waitingForTurn = false
        followTurn = nil
        reader.stop()
        if handsFree { listenSoon() }
    }

    /// The Read Aloud button on an answer.
    func readAloud(_ turn: Turn) {
        listener.cancel()
        dictating = false
        if reader.turnID == turn.id, reader.isSpeaking { return reader.stop() }
        if turn.status == .searching || turn.status == .answering {
            followTurn = turn.id
            reader.follow(turn: turn.id, answer: turn.answer, final: false)
        } else {
            followTurn = nil
            reader.read(answer: turn.answer, turn: turn.id)
        }
    }

    // MARK: Following answers

    /// Called whenever the newest turn's answer or status changes.
    func update(_ turn: Turn) {
        let live = turn.status == .searching || turn.status == .answering
        if followTurn != turn.id {
            // Typed questions are read aloud too when that's turned on.
            guard live, !waitingForTurn, ReadAloudSettings.shared.readEveryAnswer || handsFree else { return }
            followTurn = turn.id
        }
        switch turn.status {
        case .searching:
            break
        case .answering:
            reader.follow(turn: turn.id, answer: turn.answer, final: false)
        case .done:
            followTurn = nil
            VoiceLog.log("ANSWER complete (\(turn.answer.count) characters)")
            reader.follow(turn: turn.id, answer: turn.answer, final: true)
        case .failed:
            followTurn = nil
            reader.say("Sorry, I couldn’t answer that. " + (turn.error ?? ""))
        case .stopped:
            followTurn = nil
            reader.stop()
            if handsFree { listenSoon() }
        }
    }

    private func readingFinished() {
        if handsFree { listenSoon() }
    }

    private func listenSoon() {
        Task {
            // A beat after the voice stops, so its tail isn't heard as the next question.
            try? await Task.sleep(for: .milliseconds(450))
            guard handsFree, !listener.isActive, !reader.isSpeaking, !waitingForTurn else { return }
            #if DEBUG
            if case .file = source {
                guard !testFiles.isEmpty else {
                    VoiceLog.log("HANDS-FREE would listen again (ending the file test here)")
                    return end(notice: "Test finished.")
                }
                source = .file(testFiles.removeFirst())
            }
            #endif
            listenForQuestion()
        }
    }

    private func listenForQuestion() {
        guard handsFree else { return }
        // A long quiet spell ends hands-free, so the mic isn't left on.
        listener.quietBeforeWords = .seconds(10)
        VoiceCue.listening()
        listener.start(from: source) { [weak self] words in self?.heard(words) }
    }

    private func heard(_ words: String?) {
        guard handsFree else { return }
        guard let words else { return end() }   // the listener's problem is shown instead
        guard !words.isEmpty else {
            VoiceCue.ended()
            return end(notice: "Hands-free ended after a quiet spell. \(ReadAloudSettingsSection.tap) Hands-Free to start again.")
        }
        if let command = Command(words) { return run(command) }
        submit(words)
    }

    private func submit(_ question: String) {
        waitingForTurn = true
        Task {
            // Wait out an answer that is still being written rather than drop the question.
            var waited = 0
            while model?.isBusy == true, waited < 100 {
                try? await Task.sleep(for: .milliseconds(150)); waited += 1
            }
            guard handsFree, waitingForTurn else { return }
            let accepted = ask?(question) ?? false
            waitingForTurn = false
            if accepted, let last = model?.turns.last {
                followTurn = last.id
                update(last)
            } else {
                reader.say("I couldn’t ask that right now. Try again in a moment.")
            }
        }
    }

    // MARK: Spoken commands

    enum Command: Equatable {
        case end, again, slower, faster

        static let suggestions = ["“Read that again”", "“Slower”", "“Faster”", "“Stop”"]

        init?(_ words: String) {
            let said = words.lowercased()
                .components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
                .split(separator: " ").joined(separator: " ")
            switch said {
            case "stop", "stop listening", "that's all", "thats all", "that is all", "that's it", "thats it", "done",
                 "i'm done", "im done", "thank you", "thanks", "goodbye", "bye", "cancel", "end", "end hands free",
                 "stop hands free", "never mind", "nevermind":
                self = .end
            case "read that again", "read it again", "say that again", "say it again", "repeat", "repeat that",
                 "repeat it", "again", "read again", "one more time", "what was that", "come again":
                self = .again
            case "slower", "slow down", "read slower", "speak slower", "talk slower", "too fast":
                self = .slower
            case "faster", "speed up", "read faster", "speak faster", "talk faster", "too slow":
                self = .faster
            default:
                return nil
            }
        }
    }

    private func run(_ command: Command) {
        VoiceLog.log("COMMAND: \(command)")
        switch command {
        case .end:
            end()
            reader.say("Okay. Hands-free is off.")
        case .again:
            reader.readAgain()
        case .slower:
            ReadAloudSettings.shared.slower()
            reader.say("Okay, \(ReadAloudSettings.shared.speedLabel.lowercased()).")
        case .faster:
            ReadAloudSettings.shared.faster()
            reader.say("Okay, \(ReadAloudSettings.shared.speedLabel.lowercased()).")
        }
    }
}

/// Short sounds so you know, without looking, when Ask starts and stops listening.
enum VoiceCue {
    static func listening() {
        #if os(macOS)
        NSSound(named: "Tink")?.play()
        #else
        AudioServicesPlaySystemSound(1113)
        #endif
    }

    static func ended() {
        #if os(macOS)
        NSSound(named: "Pop")?.play()
        #else
        AudioServicesPlaySystemSound(1114)
        #endif
    }
}

// MARK: - Views
// Voice lives inside Ask's text field: a mic and a hands-free toggle beside Send, and one compact status line
// at the top of the field while listening, thinking or reading aloud.

/// The mic button inside Ask's text field.
struct MicButton: View {
    @Environment(VoiceAsk.self) private var voice
    let dictation: (String) -> Void

    var body: some View {
        let listening = voice.listener.isActive
        Button { voice.micTapped(dictation: dictation) } label: {
            Image(systemName: listening ? "waveform" : "mic.fill")
                .font(.title3)
                .foregroundStyle(listening ? Color.red : Color.secondary)
                .symbolEffect(.variableColor.iterative, isActive: listening)
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .help(listening ? "Stop listening and keep the words (⇧⌘D)"
              : "Speak your question (⇧⌘D). Recognized on this device only.")
        .accessibilityLabel(listening ? "Stop listening" : "Speak your question")
    }
}

/// Hands-free on or off, beside the mic. Shows a word label when `labeled` (in an emergency).
struct HandsFreeToggle: View {
    @Environment(VoiceAsk.self) private var voice
    var labeled = false

    var body: some View {
        let on = voice.handsFree
        Button { voice.toggleHandsFree() } label: {
            HStack(spacing: 4) {
                Image(systemName: "ear.and.waveform")
                if labeled || on { Text(on ? "Hands-free on" : "Hands-free").font(.callout.weight(.medium)) }
            }
            .font(.title3)
            .foregroundStyle(on ? Color.white : (labeled ? Color.accentColor : Color.secondary))
            .padding(.horizontal, labeled || on ? 9 : 4)
            .frame(height: 30)
            .background(on ? Color.accentColor : (labeled ? Color.accentColor.opacity(0.12) : .clear), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("h", modifiers: [.command, .shift])
        .help(on ? "End hands-free (⇧⌘H)"
              : "Hands-free: speak, hear the answer, then ask a follow-up the same way. After an answer you can say "
                + VoiceAsk.Command.suggestions.joined(separator: ", ") + ". (⇧⌘H)")
        .accessibilityLabel(on ? "End hands-free" : "Start hands-free")
    }
}

/// One line at the top of the text field: what voice is doing, with stop, pause and speed.
struct VoiceStatusLine: View {
    @Environment(VoiceAsk.self) private var voice

    var body: some View {
        @Bindable var settings = ReadAloudSettings.shared
        let phase = voice.phase
        HStack(spacing: 8) {
            Group {
                switch phase {
                case .listening: LevelMeter(level: voice.listener.level, tint: .red)
                case .thinking, .preparing: ProgressView().controlSize(.mini)
                case .speaking: Image(systemName: voice.reader.isPaused ? "pause.fill" : "speaker.wave.2.fill")
                    .symbolEffect(.variableColor.iterative, isActive: !voice.reader.isPaused)
                case .idle: Image(systemName: "ear.and.waveform")
                }
            }
            .foregroundStyle(tint(phase))
            .frame(width: 22)
            Text(title(phase))
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint(phase))
                .lineLimit(1)
            if voice.handsFree, phase == .listening {
                Text("Say “read that again”, “slower” or “stop”")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if phase == .speaking {
                Button { voice.reader.isPaused ? voice.reader.resume() : voice.reader.pause() } label: {
                    Image(systemName: voice.reader.isPaused ? "play.fill" : "pause.fill")
                }
                .help(voice.reader.isPaused ? "Resume reading" : "Pause reading")
                .accessibilityLabel(voice.reader.isPaused ? "Resume" : "Pause")
                Menu {
                    Picker("Reading speed", selection: $settings.speed) {
                        ForEach(ReadAloudSettings.speeds) { Text($0.label).tag($0.multiplier) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(settings.speedLabel).font(.caption.weight(.medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Reading speed. Takes effect from the next sentence.")
            }
            if phase != .idle {
                Button { voice.stopTapped() } label: {
                    Image(systemName: "stop.circle.fill").foregroundStyle(tint(phase))
                }
                .keyboardShortcut(.cancelAction)
                .help(phase == .listening ? "Stop listening (Esc)" : "Stop (Esc)")
                .accessibilityLabel("Stop")
            }
        }
        .font(.callout)
        .buttonStyle(.borderless)
        .frame(height: 22)
        .accessibilityElement(children: .contain)
    }

    private func tint(_ phase: VoiceAsk.Phase) -> Color {
        switch phase {
        case .listening: .red
        case .thinking: .orange
        case .speaking: .green
        case .preparing, .idle: .accentColor
        }
    }

    private func title(_ phase: VoiceAsk.Phase) -> String {
        switch phase {
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .speaking: voice.reader.isPaused ? "Paused" : "Reading aloud"
        case .preparing: if case .preparing(let status?) = voice.listener.state { status } else { "Starting the mic…" }
        case .idle: "Hands-free on"
        }
    }
}

/// A small five-bar meter for the microphone level.
private struct LevelMeter: View {
    let level: Float
    let tint: Color

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { i in
                let weight: [CGFloat] = [0.5, 0.8, 1, 0.8, 0.5]
                Capsule().fill(tint)
                    .frame(width: 2.5, height: 4 + 12 * CGFloat(level) * weight[i])
            }
        }
        .frame(height: 16)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

/// A note under the composer: why listening can't work, or why hands-free ended.
struct VoiceNotice: View {
    @Environment(VoiceAsk.self) private var voice
    @Environment(\.openURL) private var openURL

    #if os(macOS)
    private static let settingsTitle = "Open System Settings"
    #else
    private static let settingsTitle = "Open Settings"
    #endif

    /// The privacy pane that turns the missing permission on, for a "… is off" problem.
    private static func settingsURL(for problem: String) -> URL? {
        #if os(macOS)
        if problem.contains("Privacy & Security › Microphone") {
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
        if problem.contains("Privacy & Security › Speech Recognition") {
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")
        }
        return nil
        #elseif os(iOS)
        return problem.contains("Privacy & Security") ? URL(string: UIApplication.openSettingsURLString) : nil
        #else
        return nil
        #endif
    }

    var body: some View {
        if let text = voice.listener.problem ?? voice.notice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: voice.listener.problem != nil ? "mic.slash" : "info.circle")
                    .foregroundStyle(voice.listener.problem != nil ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text(text).font(.callout).lineLimit(4)
                    if let settings = Self.settingsURL(for: text) {
                        Button(Self.settingsTitle) { openURL(settings) }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
                Button { voice.notice = nil; voice.listener.clearProblem() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Dismiss")
            }
            .padding(10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
}

/// Settings › Read Aloud & Hands-Free.
struct ReadAloudSettingsSection: View {
    @State private var tryReader = AnswerReader()

    var body: some View {
        @Bindable var settings = ReadAloudSettings.shared
        Section("Read Aloud & Hands-Free") {
            Picker("Voice", selection: $settings.voiceID) {
                Text("Best available").tag("")
                ForEach(ReadAloudSettings.voices, id: \.identifier) { voice in
                    Text(ReadAloudSettings.describe(voice)).tag(voice.identifier)
                }
            }
            Picker("Speed", selection: $settings.speed) {
                ForEach(ReadAloudSettings.speeds) { Text($0.label).tag($0.multiplier) }
            }
            Toggle("Read every answer aloud", isOn: $settings.readEveryAnswer)
            Button(tryReader.isSpeaking ? "Stop" : "Try This Voice") {
                if tryReader.isSpeaking { tryReader.stop() }
                else { tryReader.read(answer: "Press firmly on the wound with a clean cloth [1]. Keep pressing for ten minutes.") }
            }
            Text("\(Self.tap) the mic in Ask to speak a question, or turn on Hands-Free to hear answers and ask follow-ups without \(Self.touching). Speech is recognized on this device only and never sent to a server. More voices: \(Self.voicesPath).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    #if os(macOS)
    static let tap = "Click"
    private static let touching = "using the keyboard or mouse"
    #else
    static let tap = "Tap"
    private static let touching = "touching the screen"
    #endif

    private static var voicesPath: String {
        #if os(macOS)
        "System Settings › Accessibility › Spoken Content › System Voice › Manage Voices"
        #else
        "Settings › Accessibility › Spoken Content › Voices"
        #endif
    }
}
