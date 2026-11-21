import SwiftUI
import UniformTypeIdentifiers
import ImageIO

// MARK: - Player

struct PlayerView: View {
    let game: Game
    @State private var session: GameSession
    @Environment(\.dismiss) private var dismiss
    @State private var showHelp = false
    @State private var confirmRestart = false

    init(game: Game, resumeSavedState: Bool = false) {
        self.game = game
        _session = State(initialValue: GameSession(game: game, resumeSavedState: resumeSavedState))
    }

    var body: some View {
        content
            .onAppear { session.start() }
            .onDisappear { session.stop() }
            // Only one game plays at a time: starting another closes this window.
            .onChange(of: session.ending) { _, ending in if ending == .replaced { dismiss() } }
            .overlay(alignment: .top) {
                if let toast = session.toast {
                    Text(toast)
                        .font(.callout.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 12).padding(.horizontal, 16)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: session.toast)
            .alert("Restart \(game.title)?", isPresented: $confirmRestart) {
                Button("Restart", role: .destructive) { session.reset() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(game.system.hasSaveStates ? "Unsaved progress will be lost. Your saved place is kept." : "Unsaved progress will be lost.")
            }
    }

    @ViewBuilder private var content: some View {
        if let failure = session.failure {
            ContentUnavailableView {
                Label(failure.title, systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure.message)
            } actions: {
                HStack {
                    #if os(macOS)
                    if failure.showFile {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
                    }
                    #endif
                    Button("Close") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .fixedSize()
            }
            #if os(macOS)
            .navigationTitle(game.title)
            .navigationSubtitle(game.system.name)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        } else if let ending = session.ending {
            ContentUnavailableView {
                Label(ending == .finished ? "The game has ended" : "Stopped because another game started",
                      systemImage: ending == .finished ? "flag.checkered" : "pause.circle")
            } description: {
                Text(ending == .finished ? "\(game.title) has closed." : "Only one game plays at a time.")
            } actions: {
                HStack {
                    Button(ending == .finished ? "Play Again" : "Restart") { session.restart() }.keyboardShortcut(.defaultAction)
                    Button("Close") { dismiss() }
                }
                .fixedSize()
            }
            #if os(macOS)
            .navigationTitle(game.title)
            .navigationSubtitle(game.system.name)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #endif
        } else {
            #if os(macOS)
            macPlayer
            #else
            phonePlayer
            #endif
        }
    }

    /// Shown over the picture while the game is paused.
    @ViewBuilder private var pausedBadge: some View {
        if session.isPaused && session.isRunning {
            VStack(spacing: 6) {
                Label("Paused", systemImage: "pause.fill").font(.title2.weight(.semibold))
                Text(session.autoPaused ? "Click the game to carry on." : "Press Resume to carry on.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .allowsHitTesting(false)
        }
    }

    #if os(macOS)
    @ViewBuilder private var macScreen: some View {
        if game.system.usesKeyboardAndMouse {
            // DOS and ScummVM get the whole keyboard and the mouse; the game view takes them itself.
            GameScreen(display: session.display, session: session)
                .aspectRatio(game.system.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
        } else {
            // Keys reach the game through GameWindowHook, whatever has keyboard focus in the window.
            GameScreen(display: session.display)
                .aspectRatio(game.system.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
        }
    }

    private var macPlayer: some View {
        macScreen
            .overlay { pausedBadge }
            .background(GameWindowHook(aspectRatio: game.system.aspectRatio,
                                       focusChanged: { focused in session.windowFocusChanged(focused) },
                                       keyEvent: { event in handleKey(event) }))
            #if DEBUG
            .task { await GameScript.runIfRequested(session: session) }
            #endif
            .navigationTitle(game.title)
            .navigationSubtitle(game.system.name)
            .toolbar {
                ToolbarItemGroup {
                    Button { session.setPaused(!session.isPaused) } label: {
                        Label(session.isPaused ? "Resume" : "Pause", systemImage: session.isPaused ? "play.fill" : "pause.fill")
                    }
                    .keyboardShortcut("p", modifiers: .command)
                    .help(session.isPaused ? "Carry on playing (⌘P)" : "Pause the game (⌘P)")
                    Button { confirmRestart = true } label: { Label("Restart", systemImage: "backward.end.fill") }
                        .help("Start the game again from the beginning")
                    if game.system.hasSaveStates {
                        Button { session.saveState() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                            .keyboardShortcut("s", modifiers: .command)
                            .help("Save your place (⌘S)")
                        Button { session.loadState() } label: { Label("Load", systemImage: "bookmark") }
                            .keyboardShortcut("l", modifiers: .command)
                            .help("Go back to your saved place (⌘L)")
                    } else {
                        Button { session.openGameMenu() } label: { Label("Game Menu", systemImage: "list.bullet.rectangle") }
                            .help("Open the game’s menu to save, load or quit (fn-F5)")
                    }
                    Button { showHelp.toggle() } label: { Label("Controls", systemImage: "keyboard") }
                        .help("Show which keys play the game")
                        .popover(isPresented: $showHelp) { KeyHelp(system: game.system, joystick: session.joystickMode).padding() }
                }
            }
            .labelStyle(.titleAndIcon)
    }

    /// A key pressed while the game's window is in front. Returns true when the game took it.
    ///
    /// Every plain key is claimed, repeats included: a key nothing claims makes the Mac beep, again and again
    /// while it's held. Keys with ⌘, ⌃ or ⌥ go on to the menus and toolbar (⌘P, ⌘S, ⌘L), and Esc leaves full screen.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard session.isRunning, session.failure == nil, session.ending == nil else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if game.system.usesKeyboardAndMouse {
            // DOS and ScummVM read the whole keyboard through the game view: make sure it has the keys.
            guard modifiers.isEmpty || event.type == .flagsChanged,
                  let view = session.display.inputView, let window = view.window else { return false }
            if window.firstResponder !== view { window.makeFirstResponder(view) }
            return false   // the event carries on to the game view
        }
        guard event.type != .flagsChanged, modifiers.isEmpty, event.keyCode != 53 else { return false }
        if let button = Self.keyMap(event, system: game.system), !event.isARepeat {
            let down = event.type == .keyDown
            // While paused, presses wait; releases always go through so nothing sticks down.
            if !down || !session.isPaused { session.set(button, down) }
        }
        return true
    }

    /// Arrows move. X = A, Z = B, S = X, A = Y, Q/W = shoulders, Return = Start, Space = Select.
    /// Atari 2600: X fires too (its one button is B), so either key works.
    private static func keyMap(_ event: NSEvent, system: GameSystem) -> RetroButton? {
        switch event.keyCode {
        case 0x7E: return .up
        case 0x7D: return .down
        case 0x7B: return .left
        case 0x7C: return .right
        case 0x24, 0x4C: return .start   // Return, keypad Enter
        case 0x31: return .select        // Space
        default: break
        }
        // By physical key, so AZERTY and Dvorak keep the same shape under the fingers.
        switch event.keyCode {
        case 0x07: return system == .atari2600 ? .B : .A   // X
        case 0x06: return .B                                // Z
        case 0x01: return .X                                // S
        case 0x00: return .Y                                // A
        case 0x0C: return .L                                // Q
        case 0x0D: return .R                                // W
        default: return nil
        }
    }
    #endif

    #if os(iOS)
    private var phonePlayer: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).frame(width: 36, height: 36)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Close")
                Spacer()
                Text(game.title).font(.headline).lineLimit(1)
                Spacer()
                Menu {
                    if game.system.hasSaveStates {
                        Button { session.saveState() } label: { Label("Save Your Place", systemImage: "square.and.arrow.down") }
                        Button { session.loadState() } label: { Label("Go Back to Saved Place", systemImage: "bookmark") }
                    } else {
                        Button { session.openGameMenu() } label: { Label("Game Menu (Save and Load)", systemImage: "list.bullet.rectangle") }
                    }
                    Button { confirmRestart = true } label: { Label("Restart Game", systemImage: "backward.end.fill") }
                } label: {
                    Image(systemName: "ellipsis").font(.headline).frame(width: 36, height: 36)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .accessibilityLabel("Game options")
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            GameScreen(display: session.display, session: game.system.usesKeyboardAndMouse ? session : nil)
                .aspectRatio(game.system.aspectRatio, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 8)
                .layoutPriority(1)

            Spacer(minLength: 12)
            TouchControls(session: session, shoulders: game.system.hasShoulderButtons)
                .padding(.bottom, 24)
        }
        .foregroundStyle(.white)
        .background(Color(white: 0.08).ignoresSafeArea())
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            // A text field behind the player may still own the keyboard.
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        }
    }
    #endif
}

#if os(macOS)
/// Reaches the game's window: sizes it to the system's screen shape once, and reports when it goes to the back or
/// comes forward (the game pauses meanwhile).
private struct GameWindowHook: NSViewRepresentable {
    let aspectRatio: CGFloat
    let focusChanged: (Bool) -> Void
    /// Sees each key event for the game's window before anything in the window does; true swallows it.
    let keyEvent: (NSEvent) -> Bool

    func makeNSView(context: Context) -> HookView {
        let view = HookView()
        view.aspectRatio = aspectRatio
        view.focusChanged = focusChanged
        view.keyEvent = keyEvent
        return view
    }
    func updateNSView(_ view: HookView, context: Context) {
        view.focusChanged = focusChanged
        view.keyEvent = keyEvent
    }

    final class HookView: NSView {
        var aspectRatio: CGFloat = 4.0 / 3.0
        var focusChanged: ((Bool) -> Void)?
        var keyEvent: ((NSEvent) -> Bool)?
        private var observers: [NSObjectProtocol] = []
        private var keyMonitor: Any?
        private var sized = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            guard let window else { return }
            // Keys are caught at the window, not through keyboard focus: clicking a toolbar button, the Controls
            // popover or an alert can move focus, and then every key would beep instead of playing.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self, weak window] event in
                nonisolated(unsafe) let key = event
                let swallow = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let window, key.window === window, window.isKeyWindow, window.attachedSheet == nil else { return false }
                    return self.keyEvent?(key) == true
                }
                return swallow ? nil : event
            }
            for (name, focused) in [(NSWindow.didResignKeyNotification, false), (NSWindow.didBecomeKeyNotification, true)] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.focusChanged?(focused) }
                })
            }
            guard !sized else { return }
            sized = true
            // Once the window is laid out: keep its width, make the picture area the system's shape.
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, let content = window.contentView else { return }
                let pictureHeight = self.bounds.height, chrome = content.frame.height - pictureHeight
                guard pictureHeight > 0, chrome >= 0 else { return }
                // At least 720 points wide, so the toolbar's labelled buttons fit.
                let width = max(content.frame.width, 720)
                let height = (width / self.aspectRatio).rounded() + chrome
                guard abs(height - content.frame.height) > 4 || width != content.frame.width else { return }
                let visible = window.screen?.visibleFrame.height ?? .greatestFiniteMagnitude
                window.setContentSize(NSSize(width: width, height: min(height, visible - 60)))
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit {
            observers.forEach(NotificationCenter.default.removeObserver)
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        }
    }
}

private struct KeyHelp: View {
    let system: GameSystem
    var joystick = false
    var body: some View {
        if system.usesKeyboardAndMouse { keyboardAndMouse } else { pad }
    }

    private func row(_ action: String, _ keys: String) -> some View {
        GridRow { Text(action); Text(keys).foregroundStyle(.secondary) }
    }

    private var keyboardAndMouse: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            Text("Controls").font(.headline)
            if joystick {
                row("Joystick", "Arrow keys")
                row("Fire (button 1)", "Z")
                row("Button 2", "X")
                row("Other keys", "Go straight to the game")
            } else {
                row("Keyboard", "Goes straight to the game")
            }
            row("Mouse", "Move and click on the picture")
            if system == .scummvm {
                row("Game menu", "fn-F5 or the Game Menu button")
                row("Skip a scene", "Esc")
                row("Save and load", "From the game’s menu (Game Menu button)")
            } else {
                row("Save / Load place", "⌘S / ⌘L")
            }
            row("Pause", "⌘P")
            Text(joystick ? "A game controller works as the joystick too." : "Click the picture if keys stop reaching the game.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var pad: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            Text("Controls").font(.headline)
            row("Move", "Arrow keys")
            switch system {
            case .atari2600:
                row("Fire", "Z or X")
                row("Game Reset", "Return")
                row("Game Select", "Space")
            case .pcEngine:
                row("I / II", "X / Z")
                row("Run / Select", "Return / Space")
            default:
                row("A / B", "X / Z")
                if system.hasShoulderButtons { row("L / R", "Q / W") }
                row("Start / Select", "Return / Space")
            }
            row("Save / Load place", "⌘S / ⌘L")
            row("Pause", "⌘P")
            Text("Game controllers (Xbox, PlayStation, Switch Pro) work too.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
#endif

extension GameSystem {
    /// One line on the game's page about how it's played.
    var controlsHint: String {
        #if os(macOS)
        switch self {
        case .atari2600: "Arrow keys move, Z or X fires, Return is Game Reset and Space is Game Select. Game controllers work too."
        case .pcEngine: "Arrow keys move, X and Z are buttons I and II, Return is Run and Space is Select. Game controllers work too."
        case .dos: "The keyboard and mouse go straight to the game. Choose Joystick below if the game needs one."
        case .scummvm: "Point and click with the mouse. Save and load from the game’s menu (the Game Menu button, or fn-F5)."
        case .gameBoyAdvance: "Arrow keys move, X and Z are A and B, Q and W are L and R, Return is Start and Space is Select. Game controllers work too."
        default: "Arrow keys move, X and Z are A and B, Return is Start and Space is Select. Game controllers work too."
        }
        #else
        switch self {
        case .dos: "Tap the picture to click; the on-screen buttons or a game controller play the joystick."
        case .scummvm: "Tap to click, touch and hold to right-click. Save and load from the game’s menu."
        default: "Use the on-screen controls or connect a game controller."
        }
        #endif
    }
}

// MARK: - Screen

#if os(macOS)
struct GameScreen: NSViewRepresentable {
    let display: GameDisplay
    /// Set for keyboard-and-mouse games: the view becomes first responder and forwards keys and the mouse.
    var session: GameSession? = nil

    func makeNSView(context: Context) -> LayerHost {
        let view = LayerHost()
        view.wantsLayer = true
        view.layer?.backgroundColor = .black
        view.layer?.addSublayer(display.layer)
        view.session = session
        view.display = display
        if session != nil { display.inputView = view }
        return view
    }
    func updateNSView(_ view: LayerHost, context: Context) {}

    final class LayerHost: NSView {
        weak var session: GameSession?
        weak var display: GameDisplay?
        /// Where the game's cursor is, in game pixels, as far as this view has told it (nil until pinned to a corner).
        private var cursor: CGPoint?
        private var cursorFrame: CGSize = .zero
        private var tracking: NSTrackingArea?
        private var modifiersDown: Set<UInt16> = []
        /// DOS: the last pointer position over the picture, for relative motion.
        private var lastPoint: CGPoint?

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
            let scale = window?.backingScaleFactor ?? 2
            display?.viewResized(CGSize(width: bounds.width * scale, height: bounds.height * scale))
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            needsLayout = true
        }

        // MARK: Keyboard

        override var acceptsFirstResponder: Bool { session != nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard session != nil, let window else { return }
            window.acceptsMouseMovedEvents = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder !== self else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func keyDown(with event: NSEvent) {
            // ⌘ shortcuts and keys the game can't use go on up the chain (and beep there, like any unused key).
            guard let session, !event.modifierFlags.contains(.command),
                  let code = MacKeys.retroKey(event.keyCode) else { return super.keyDown(with: event) }
            guard !event.isARepeat else { return }   // swallowed: DOS and ScummVM repeat held keys themselves
            if session.joystickMode, let button = Self.joystickButton(event.keyCode) { session.set(button, true); return }
            session.key(code, down: true, character: MacKeys.character(event), modifiers: MacKeys.modifiers(event.modifierFlags))
        }

        override func keyUp(with event: NSEvent) {
            guard let session, let code = MacKeys.retroKey(event.keyCode) else { return super.keyUp(with: event) }
            if session.joystickMode, let button = Self.joystickButton(event.keyCode) { session.set(button, false); return }
            session.key(code, down: false, modifiers: MacKeys.modifiers(event.modifierFlags))
        }

        /// DOS games set to Joystick: the arrow keys are the stick, Z is button 1 (fire) and X is button 2, so the game
        /// can be played without a controller. DOSBox Pure's two-button joystick reads buttons 1 and 2 from the
        /// pad's B and Y. Every other key, Return and Esc included, still goes to DOS.
        private static func joystickButton(_ keyCode: UInt16) -> RetroButton? {
            switch keyCode {
            case 0x7E: .up
            case 0x7D: .down
            case 0x7B: .left
            case 0x7C: .right
            case 0x06: .B   // Z
            case 0x07: .Y   // X
            default: nil
            }
        }

        /// Shift, Control, Option and Caps Lock arrive as flag changes; DOS games use them as buttons.
        override func flagsChanged(with event: NSEvent) {
            guard let session, let code = MacKeys.retroKey(event.keyCode) else { return super.flagsChanged(with: event) }
            let down: Bool
            if event.keyCode == 0x39 { down = event.modifierFlags.contains(.capsLock) }
            else if modifiersDown.contains(event.keyCode) { down = false } else { down = true }
            if down { modifiersDown.insert(event.keyCode) } else { modifiersDown.remove(event.keyCode) }
            session.key(code, down: down, modifiers: MacKeys.modifiers(event.modifierFlags))
        }

        override func resignFirstResponder() -> Bool {
            // Command-Tab and friends: let go of everything so no key sticks down in the game.
            for code in modifiersDown { if let key = MacKeys.retroKey(code) { session?.key(key, down: false) } }
            modifiersDown.removeAll()
            session?.releaseInput()
            return super.resignFirstResponder()
        }

        // MARK: Mouse

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            guard session != nil else { return }
            let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        /// The game draws its own cursor, so the Mac's hides over the picture.
        override func cursorUpdate(with event: NSEvent) {
            if session != nil { Self.blankCursor.set() } else { super.cursorUpdate(with: event) }
        }
        override func resetCursorRects() {
            if session != nil { addCursorRect(bounds, cursor: Self.blankCursor) }
        }
        private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

        /// A click on the game counts even when the window wasn't in front.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { session != nil }

        override func mouseExited(with event: NSEvent) { lastPoint = nil }
        override func mouseMoved(with event: NSEvent) { track(event) }
        override func mouseDragged(with event: NSEvent) { track(event) }
        override func rightMouseDragged(with event: NSEvent) { track(event) }
        override func otherMouseDragged(with event: NSEvent) { track(event) }

        override func mouseDown(with event: NSEvent) {
            if window?.firstResponder !== self { window?.makeFirstResponder(self) }
            track(event); session?.mouseButton(.left, true)
        }
        override func mouseUp(with event: NSEvent) { track(event); session?.mouseButton(.left, false) }
        override func rightMouseDown(with event: NSEvent) { track(event); session?.mouseButton(.right, true) }
        override func rightMouseUp(with event: NSEvent) { track(event); session?.mouseButton(.right, false) }
        override func otherMouseDown(with event: NSEvent) { track(event); session?.mouseButton(.middle, true) }
        override func otherMouseUp(with event: NSEvent) { track(event); session?.mouseButton(.middle, false) }
        override func scrollWheel(with event: NSEvent) {
            let notches = Int((-event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 30 : 1)).rounded())
            if notches != 0 { session?.scroll(notches) }
        }

        /// ScummVM: moves the game's cursor to where the Mac's pointer is. The core takes relative motion, so the first
        /// move pins the game cursor to the top-left corner and every move after sends the difference, keeping the two
        /// together. DOS: plain relative motion, since DOS mouse drivers scale and accelerate it their own way.
        private func track(_ event: NSEvent) {
            guard let session, let image = display?.lastImage, bounds.width > 0, bounds.height > 0 else { return }
            let frame = CGSize(width: image.width, height: image.height)
            let point = convert(event.locationInWindow, from: nil)
            if session.game.system == .dos {
                if let lastPoint {
                    session.moveMouse(dx: (point.x - lastPoint.x) / bounds.width * frame.width,
                                      dy: (lastPoint.y - point.y) / bounds.height * frame.height)
                }
                lastPoint = point
                return
            }
            let target = CGPoint(x: min(max(0, (point.x / bounds.width * frame.width).rounded(.down)), frame.width - 1),
                                 y: min(max(0, ((bounds.height - point.y) / bounds.height * frame.height).rounded(.down)), frame.height - 1))
            if cursor == nil || frame != cursorFrame {
                session.pinMouseToCorner()
                cursor = .zero
                cursorFrame = frame
            }
            guard let cursor, target != cursor else { return }
            session.moveMouse(dx: target.x - cursor.x, dy: target.y - cursor.y)
            self.cursor = target
        }
    }
}

#if DEBUG
/// Test hook: -gameScript "wait 3; key return; type dir; click 160 100; snap /tmp/x.png" drives a game with real
/// AppKit events (keys are queued like the keyboard's, so they pass the app's event monitors; clicks are hit-tested),
/// so the whole input path is exercised. Click and move take game-pixel coordinates; "click X Y right" right-clicks.
@MainActor
enum GameScript {
    static func runIfRequested(session: GameSession) async {
        guard let script = UserDefaults.standard.string(forKey: "gameScript") else { return }
        attach(session)
        try? await Task.sleep(for: .seconds(1))
        for raw in script.split(separator: ";") {
            let parts = raw.split(separator: " ").map(String.init)
            guard let command = parts.first else { continue }
            let args = Array(parts.dropFirst())
            switch command {
            case "wait": try? await Task.sleep(for: .seconds(Double(args.first ?? "1") ?? 1))
            case "key": await press(args.first ?? "", hold: Double(args.dropFirst().first ?? "") ?? 0.12)
            case "down": await press(args.first ?? "", hold: -1)
            case "up": await press(args.first ?? "", hold: -2)
            case "pad":      // "pad right 1.5": holds a game-controller button, as a Bluetooth controller would
                let buttons: [String: RetroButton] = ["up": .up, "down": .down, "left": .left, "right": .right, "a": .A, "b": .B,
                                                      "x": .X, "y": .Y, "l": .L, "r": .R, "start": .start, "select": .select]
                guard let button = buttons[args.first ?? ""] else { continue }
                session.set(button, true)
                try? await Task.sleep(for: .seconds(Double(args.dropFirst().first ?? "") ?? 0.15))
                session.set(button, false)
                try? await Task.sleep(for: .milliseconds(80))
            case "repeat":   // "repeat up 40": a held key, with AppKit's auto-repeat events, about 30 a second
                await press(args.first ?? "", hold: 0, repeats: Int(args.dropFirst().first ?? "") ?? 30)
            case "move", "click":
                guard args.count >= 2, let x = Double(args[0]), let y = Double(args[1]) else { continue }
                mouse(.mouseMoved, x, y)
                if command == "click" {
                    let right = args.count > 2 && args[2] == "right"
                    try? await Task.sleep(for: .milliseconds(120))
                    mouse(right ? .rightMouseDown : .leftMouseDown, x, y)
                    try? await Task.sleep(for: .milliseconds(120))
                    mouse(right ? .rightMouseUp : .leftMouseUp, x, y)
                }
                try? await Task.sleep(for: .milliseconds(120))
            case "close":    // closes the game's window, as its close button does
                NSApp.windows.first { $0.title == session.game.title }?.performClose(nil)
            case "quit": NSApp.terminate(nil)
            case "gamemenu": session.openGameMenu()
            case "pause": session.setPaused(true)
            case "save": session.saveState()
            case "load": session.loadState()
            case "blur": session.windowFocusChanged(false)   // as if the window went to the back
            case "unfocus":  // takes keyboard focus away from the picture, as clicking a toolbar button can
                NSApp.windows.first { $0.title == session.game.title }?.makeFirstResponder(nil)
            case "activate": // brings the game's window to the front (test runs start in the background)
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.title == session.game.title }?.makeKeyAndOrderFront(nil)
            case "snap":
                guard let path = args.first, let image = session.display.lastImage,
                      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { continue }
                CGImageDestinationAddImage(dest, image, nil)
                CGImageDestinationFinalize(dest)
            default: break
            }
        }
    }

    private static let names: [String: UInt32] = ["return": 13, "esc": 27, "space": 32, "tab": 9, "backspace": 8,
        "up": 273, "down": 274, "right": 275, "left": 276, "f1": 282, "f2": 283, "f3": 284, "f4": 285, "f5": 286,
        "f6": 287, "f7": 288, "f8": 289, "f9": 290, "f10": 291, "lshift": 304, "lctrl": 306, "lalt": 308]

    private static func press(_ name: String, hold: Double, repeats: Int = 0) async {
        // Keyboard-and-mouse games: the game view's window. Others: the game's window (SwiftUI handles their keys).
        guard let window = session?.display.inputView?.window
                ?? NSApp.windows.first(where: { $0.title == session?.game.title }) else { return }
        let retro = names[name.lowercased()] ?? name.lowercased().first?.asciiValue.map(UInt32.init) ?? 0
        guard let keyCode = MacKeys.keyCode(for: retro) else { return }
        let modifier = [304, 306, 308].contains(retro)
        let arrows: [UInt32: Int] = [273: NSUpArrowFunctionKey, 274: NSDownArrowFunctionKey, 276: NSLeftArrowFunctionKey, 275: NSRightArrowFunctionKey]
        let chars = arrows[retro].map { String(UnicodeScalar(UInt16($0))!) } ?? (retro < 128 ? String(UnicodeScalar(UInt8(retro))) : "")
        func event(_ type: NSEvent.EventType, _ flags: NSEvent.ModifierFlags, isRepeat: Bool = false) -> NSEvent? {
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags.union(arrows[retro] != nil ? [.numericPad, .function] : []),
                             timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: chars,
                             charactersIgnoringModifiers: chars, isARepeat: isRepeat, keyCode: keyCode)
        }
        let flag: NSEvent.ModifierFlags = retro == 304 ? .shift : retro == 306 ? .control : .option
        // hold -1: only press, -2: only release (for holding a modifier across other steps).
        if hold != -2, let down = event(modifier ? .flagsChanged : .keyDown, modifier ? flag : []) { NSApp.postEvent(down, atStart: false) }
        if hold >= 0 { try? await Task.sleep(for: .seconds(hold)) }
        for _ in 0..<repeats {
            if let again = event(.keyDown, [], isRepeat: true) { NSApp.postEvent(again, atStart: false) }
            try? await Task.sleep(for: .milliseconds(33))
        }
        if hold != -1, let up = event(modifier ? .flagsChanged : .keyUp, []) { NSApp.postEvent(up, atStart: false) }
        try? await Task.sleep(for: .milliseconds(60))
    }

    private static func mouse(_ type: NSEvent.EventType, _ x: Double, _ y: Double) {
        guard let view = session?.display.inputView, let window = view.window,
              let image = session?.display.lastImage else { return }
        let local = CGPoint(x: (x + 0.5) / Double(image.width) * view.bounds.width,
                            y: view.bounds.height - (y + 0.5) / Double(image.height) * view.bounds.height)
        let point = view.convert(local, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        else { return }
        if type == .mouseMoved { view.mouseMoved(with: event) } else { window.sendEvent(event) }
    }

    private static weak var session: GameSession?
    static func attach(_ session: GameSession) { self.session = session }
}

/// Test hook: -windowShots /path/prefix draws every visible window of the app offscreen once a second, to
/// prefix-<window number>.png (works while the screen is locked, unlike screencapture). Stops after 3 minutes.
@MainActor
enum WindowShots {
    private static var started = false
    static func startIfRequested() {
        guard !started, let prefix = UserDefaults.standard.string(forKey: "windowShots") else { return }
        started = true
        Task { @MainActor in
            for _ in 0..<180 {
                try? await Task.sleep(for: .seconds(1))
                for window in NSApp.windows where window.isVisible {
                    guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { continue }
                    let scale = window.backingScaleFactor
                    let size = CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale)
                    guard size.width > 0, size.height > 0,
                          let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { continue }
                    context.setFillColor(window.backgroundColor.cgColor)
                    context.fill(CGRect(origin: .zero, size: size))
                    context.scaleBy(x: scale, y: scale)
                    layer.render(in: context)
                    if let image = context.makeImage(),
                       let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(prefix)-\(window.windowNumber).png") as CFURL, UTType.png.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, image, nil)
                        CGImageDestinationFinalize(dest)
                    }
                    // The words on screen too, from accessibility (layer rendering misses some text and materials).
                    var lines = ["window: \(window.title) \(Int(window.frame.width))x\(Int(window.frame.height))"]
                    func walk(_ element: Any, depth: Int) {
                        guard depth < 40, let object = element as? NSObject else { return }
                        func ax(_ name: String) -> Any? {
                            let selector = Selector(name)
                            return object.responds(to: selector) ? object.perform(selector)?.takeUnretainedValue() : nil
                        }
                        let role = (ax("accessibilityRole") as? String) ?? ""
                        let words = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                            .compactMap { ax($0) as? String }.filter { !$0.isEmpty }
                        if !words.isEmpty { lines.append(String(repeating: " ", count: min(depth, 20)) + "\(role): " + words.joined(separator: " | ")) }
                        for child in (ax("accessibilityChildren") as? [Any]) ?? [] { walk(child, depth: depth + 1) }
                    }
                    walk(window, depth: 0)
                    try? lines.joined(separator: "\n").write(toFile: "\(prefix)-\(window.windowNumber).txt", atomically: true, encoding: .utf8)
                }
            }
        }
    }
}

#endif

/// Mac key codes (the physical key, whatever the layout) to libretro key codes, which follow the PC keyboard.
enum MacKeys {
    #if DEBUG
    static func keyCode(for retro: UInt32) -> UInt16? { table.first { $0.value == retro }?.key }
    #endif

    static func retroKey(_ keyCode: UInt16) -> UInt32? { table[keyCode] }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> UInt16 {
        var mods: UInt16 = 0
        if flags.contains(.shift) { mods |= 0x01 }      // RETROKMOD_SHIFT
        if flags.contains(.control) { mods |= 0x02 }    // RETROKMOD_CTRL
        if flags.contains(.option) { mods |= 0x04 }     // RETROKMOD_ALT
        if flags.contains(.command) { mods |= 0x08 }    // RETROKMOD_META
        if flags.contains(.capsLock) { mods |= 0x20 }   // RETROKMOD_CAPSLOCK
        return mods
    }

    /// The typed character, for games that read text (save names, typed commands). Zero for function and arrow keys.
    static func character(_ event: NSEvent) -> UInt32 {
        let flags = event.modifierFlags
        let text = flags.contains(.option) || flags.contains(.control) ? event.charactersIgnoringModifiers : event.characters
        guard let scalar = text?.unicodeScalars.first else { return 0 }
        if (0xF700...0xF8FF).contains(scalar.value) { return 0 }   // AppKit's private codes for arrows and F-keys
        return scalar.value
    }

    private static let table: [UInt16: UInt32] = {
        var t: [UInt16: UInt32] = [:]
        // Letters and digits: libretro uses lowercase ASCII.
        let letters: [(UInt16, Character)] = [(0x00, "a"), (0x0B, "b"), (0x08, "c"), (0x02, "d"), (0x0E, "e"), (0x03, "f"), (0x05, "g"),
            (0x04, "h"), (0x22, "i"), (0x26, "j"), (0x28, "k"), (0x25, "l"), (0x2E, "m"), (0x2D, "n"), (0x1F, "o"), (0x23, "p"),
            (0x0C, "q"), (0x0F, "r"), (0x01, "s"), (0x11, "t"), (0x20, "u"), (0x09, "v"), (0x0D, "w"), (0x07, "x"), (0x10, "y"),
            (0x06, "z"), (0x1D, "0"), (0x12, "1"), (0x13, "2"), (0x14, "3"), (0x15, "4"), (0x17, "5"), (0x16, "6"), (0x1A, "7"),
            (0x1C, "8"), (0x19, "9"), (0x18, "="), (0x1B, "-"), (0x1E, "]"), (0x21, "["), (0x27, "'"), (0x29, ";"), (0x2A, "\\"),
            (0x2B, ","), (0x2C, "/"), (0x2F, "."), (0x32, "`"), (0x31, " ")]
        for (code, char) in letters { t[code] = UInt32(char.asciiValue!) }
        let named: [UInt16: UInt32] = [
            0x24: 13, 0x30: 9, 0x33: 8, 0x35: 27, 0x75: 127,                      // return, tab, backspace, escape, delete
            0x7E: 273, 0x7D: 274, 0x7C: 275, 0x7B: 276,                           // up, down, right, left
            0x72: 277, 0x73: 278, 0x77: 279, 0x74: 280, 0x79: 281,                // insert (help), home, end, page up/down
            0x7A: 282, 0x78: 283, 0x63: 284, 0x76: 285, 0x60: 286, 0x61: 287,     // F1-F6
            0x62: 288, 0x64: 289, 0x65: 290, 0x6D: 291, 0x67: 292, 0x6F: 293,     // F7-F12
            0x52: 256, 0x53: 257, 0x54: 258, 0x55: 259, 0x56: 260, 0x57: 261,     // keypad 0-5
            0x58: 262, 0x59: 263, 0x5B: 264, 0x5C: 265, 0x41: 266, 0x4B: 267,     // keypad 6-9, . and /
            0x43: 268, 0x4E: 269, 0x45: 270, 0x4C: 271, 0x51: 272, 0x47: 300,     // keypad * - + enter =, clear as num lock
            0x39: 301, 0x3C: 303, 0x38: 304, 0x3E: 305, 0x3B: 306, 0x3D: 307, 0x3A: 308,   // caps, shifts, controls, options
        ]
        t.merge(named) { $1 }
        return t
    }()
}
#else
struct GameScreen: UIViewRepresentable {
    let display: GameDisplay
    /// Set for DOS and ScummVM: touches on the picture become pointer input (tap to click, hold for right-click in
    /// ScummVM; DOS uses it like a laptop touchpad).
    var session: GameSession? = nil

    func makeUIView(context: Context) -> LayerHost {
        let view = LayerHost()
        view.backgroundColor = .black
        view.layer.addSublayer(display.layer)
        view.session = session
        view.display = display
        view.isMultipleTouchEnabled = false
        return view
    }
    func updateUIView(_ view: LayerHost, context: Context) {}

    final class LayerHost: UIView {
        weak var session: GameSession?
        weak var display: GameDisplay?

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.sublayers?.forEach { $0.frame = bounds }
            CATransaction.commit()
            display?.viewResized(CGSize(width: bounds.width * contentScaleFactor, height: bounds.height * contentScaleFactor))
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches.first, pressed: true) }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches.first, pressed: true) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches.first, pressed: false) }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { send(touches.first, pressed: false) }

        private func send(_ touch: UITouch?, pressed: Bool) {
            guard let session, let touch, bounds.width > 0, bounds.height > 0 else { return }
            let point = touch.location(in: self)
            session.pointer(x: point.x / bounds.width * 2 - 1, y: point.y / bounds.height * 2 - 1, pressed: pressed)
        }
    }
}

// MARK: - Touch controls

private struct TouchControls: View {
    let session: GameSession
    let shoulders: Bool

    var body: some View {
        VStack(spacing: 22) {
            if shoulders {
                HStack {
                    PadButton(label: "L", button: .L, session: session, shape: .capsule)
                    Spacer()
                    PadButton(label: "R", button: .R, session: session, shape: .capsule)
                }
                .padding(.horizontal, 20)
            }
            HStack(alignment: .center) {
                DPad(session: session)
                Spacer()
                HStack(spacing: 18) {
                    PadButton(label: "B", button: .B, session: session, shape: .circle).offset(y: 22)
                    PadButton(label: "A", button: .A, session: session, shape: .circle)
                }
            }
            .padding(.horizontal, 24)
            HStack(spacing: 24) {
                PadButton(label: "SELECT", button: .select, session: session, shape: .pill)
                PadButton(label: "START", button: .start, session: session, shape: .pill)
            }
        }
    }
}

private struct PadButton: View {
    enum Shape { case circle, capsule, pill }
    let label: String
    let button: RetroButton
    let session: GameSession
    let shape: Shape
    @State private var pressed = false

    var body: some View {
        Text(label)
            .font(shape == .pill ? .caption2.weight(.bold) : .title3.weight(.bold))
            .frame(width: size.width, height: size.height)
            .background(Color.white.opacity(pressed ? 0.35 : 0.16), in: Capsule())
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        session.set(button, true)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                }
                .onEnded { _ in
                    pressed = false
                    session.set(button, false)
                })
            .accessibilityLabel(label)
    }

    private var size: CGSize {
        switch shape {
        case .circle: CGSize(width: 68, height: 68)
        case .capsule: CGSize(width: 90, height: 36)
        case .pill: CGSize(width: 74, height: 26)
        }
    }
}

/// One touch area for all four directions, so sliding a thumb (including diagonals) works.
private struct DPad: View {
    let session: GameSession
    @State private var active: Set<RetroButton> = []
    private let size: CGFloat = 150

    var body: some View {
        ZStack {
            Circle().fill(Color.white.opacity(0.08))
            ForEach([(RetroButton.up, "chevron.up", CGSize(width: 0, height: -46)),
                     (.down, "chevron.down", CGSize(width: 0, height: 46)),
                     (.left, "chevron.left", CGSize(width: -46, height: 0)),
                     (.right, "chevron.right", CGSize(width: 46, height: 0))], id: \.1) { button, symbol, offset in
                Image(systemName: symbol)
                    .font(.title2.weight(.bold))
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(active.contains(button) ? 0.35 : 0.16), in: RoundedRectangle(cornerRadius: 10))
                    .offset(offset)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { value in update(value.location) }
            .onEnded { _ in update(nil) })
        .accessibilityLabel("Direction pad")
    }

    private func update(_ point: CGPoint?) {
        var next: Set<RetroButton> = []
        if let point {
            let dx = point.x - size / 2, dy = point.y - size / 2
            if hypot(dx, dy) > 14 {
                let angle = atan2(-dy, dx) * 180 / .pi   // 0 = right, 90 = up
                if angle > 22.5 && angle < 157.5 { next.insert(.up) }
                if angle < -22.5 && angle > -157.5 { next.insert(.down) }
                if abs(angle) > 112.5 { next.insert(.left) }
                if abs(angle) < 67.5 { next.insert(.right) }
            }
        }
        for button in [RetroButton.up, .down, .left, .right] where next.contains(button) != active.contains(button) {
            session.set(button, next.contains(button))
        }
        if !next.isEmpty && next != active { UISelectionFeedbackGenerator().selectionChanged() }
        active = next
    }
}
#endif
