import Foundation
import Network

/// One WebSocket connection (RFC 6455, server side) on a connection WebServer has upgraded. Used by game streaming:
/// picture and sound go to the device, its buttons come back.
///
/// Safety limits, in place of the HTTP request rules:
/// - Messages from the device must be masked (as browsers always do) and at most `maxMessage` bytes.
/// - A send that makes no progress for 60 seconds closes the connection (as WebServer's writes do), but only while a
///   send is waiting: a quiet socket isn't "stalled".
/// - Nothing heard from the device for `idleLimit` seconds closes it (the page checks in every couple of seconds), so a
///   phone that vanished from the network doesn't hold its connection open.
final class WebSocket: @unchecked Sendable {
    enum Message: Sendable {
        case text(String)
        case binary(Data)
    }

    static let maxMessage = 64 * 1024
    static let stallLimit: TimeInterval = 60
    static let idleLimit: TimeInterval = 30

    private let connection: NWConnection
    private let lock = NSLock()
    // Guarded by `lock`.
    private var onMessage: (@Sendable (Message) -> Void)?
    private var onClose: (@Sendable () -> Void)?
    private var closed = false
    private var pendingSends = 0
    private var lastProgress = Date()
    private var lastHeard = Date()
    private var watchdog: DispatchSourceTimer?

    init(_ connection: NWConnection) { self.connection = connection }

    /// Starts reading. `onMessage` gets each whole message; `onClose` is called once, however the socket ends.
    func start(onMessage: @escaping @Sendable (Message) -> Void, onClose: @escaping @Sendable () -> Void) {
        lock.withLock {
            self.onMessage = onMessage
            self.onClose = onClose
            lastHeard = Date()
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.checkTimeouts() }
        lock.withLock { watchdog = timer }
        timer.resume()
        receive(buffer: Data(), fragments: nil)
    }

    /// Messages handed to the network that it hasn't finished taking yet. Game streaming sends a new picture only
    /// when this is low, so pictures never queue up behind a slow connection.
    var sendsInFlight: Int { lock.withLock { pendingSends } }

    var isClosed: Bool { lock.withLock { closed } }

    func send(text: String) { send(opcode: 0x1, payload: Data(text.utf8), completion: nil) }

    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(opcode: 0x1, payload: data, completion: nil)
    }

    func send(binary: Data, completion: (@Sendable (Bool) -> Void)? = nil) {
        send(opcode: 0x2, payload: binary, completion: completion)
    }

    /// Sends a close frame, then closes the connection.
    func close(code: UInt16 = 1000, reason: String = "") {
        var payload = Data([UInt8(code >> 8), UInt8(code & 0xFF)])
        payload.append(Data(reason.utf8.prefix(120)))
        let connection = self.connection
        send(opcode: 0x8, payload: payload) { _ in connection.cancel() }
        // If the close frame can't go out (the network is stuck), don't wait on it.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { connection.cancel() }
    }

    // MARK: Sending

    private func send(opcode: UInt8, payload: Data, completion: (@Sendable (Bool) -> Void)?) {
        let ok = lock.withLock { () -> Bool in
            guard !closed else { return false }
            if pendingSends == 0 { lastProgress = Date() }
            pendingSends += 1
            return true
        }
        guard ok else { completion?(false); return }
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode)   // FIN: messages are never split
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8)); frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(payload.count) >> UInt64(shift)) & 0xFF)) }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let self {
                self.lock.withLock {
                    self.pendingSends -= 1
                    self.lastProgress = Date()
                }
            }
            completion?(error == nil)
        })
    }

    // MARK: Receiving

    private struct Fragments {
        var opcode: UInt8
        var data: Data
    }

    private func receive(buffer: Data, fragments: Fragments?) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data, !data.isEmpty {
                buffer.append(data)
                self.lock.withLock { self.lastHeard = Date() }
            }
            if error != nil { self.end(); return }
            var fragments = fragments
            while true {
                switch self.nextFrame(&buffer, &fragments) {
                case .needMore: break
                case .frame: continue
                case .fail(let code):
                    self.close(code: code)
                    self.end()
                    return
                case .closed:
                    self.end()
                    return
                }
                break
            }
            if isComplete { self.end(); return }
            // A device sending more than one message's worth without finishing it is misbehaving.
            if buffer.count > Self.maxMessage + 16 { self.close(code: 1009); self.end(); return }
            self.receive(buffer: buffer, fragments: fragments)
        }
    }

    private enum Step { case needMore, frame, fail(UInt16), closed }

    /// Takes one frame off the front of `buffer`, if a whole one has arrived.
    private func nextFrame(_ buffer: inout Data, _ fragments: inout Fragments?) -> Step {
        let bytes = [UInt8](buffer.prefix(14))
        guard bytes.count >= 2 else { return .needMore }
        let fin = bytes[0] & 0x80 != 0
        let opcode = bytes[0] & 0x0F
        guard bytes[0] & 0x70 == 0 else { return .fail(1002) }        // no extensions were agreed
        guard bytes[1] & 0x80 != 0 else { return .fail(1002) }        // browsers must mask what they send
        var length = Int(bytes[1] & 0x7F)
        var offset = 2
        if length == 126 {
            guard bytes.count >= 4 else { return .needMore }
            length = Int(bytes[2]) << 8 | Int(bytes[3])
            offset = 4
        } else if length == 127 {
            guard bytes.count >= 10 else { return .needMore }
            var big: UInt64 = 0
            for i in 2..<10 { big = big << 8 | UInt64(bytes[i]) }
            guard big <= UInt64(Self.maxMessage) else { return .fail(1009) }
            length = Int(big)
            offset = 10
        }
        guard length <= Self.maxMessage else { return .fail(1009) }
        let isControl = opcode & 0x08 != 0
        if isControl && (!fin || length > 125) { return .fail(1002) }
        guard bytes.count >= offset + 4 || buffer.count >= offset + 4 else { return .needMore }
        guard buffer.count >= offset + 4 + length else { return .needMore }
        let start = buffer.startIndex
        let mask = [UInt8](buffer[(start + offset)..<(start + offset + 4)])
        var payload = [UInt8](buffer[(start + offset + 4)..<(start + offset + 4 + length)])
        for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
        buffer = Data(buffer.dropFirst(offset + 4 + length))

        switch opcode {
        case 0x0:   // continuation
            guard var current = fragments else { return .fail(1002) }
            current.data.append(contentsOf: payload)
            guard current.data.count <= Self.maxMessage else { return .fail(1009) }
            if fin {
                fragments = nil
                return deliver(opcode: current.opcode, current.data)
            }
            fragments = current
        case 0x1, 0x2:
            guard fragments == nil else { return .fail(1002) }
            if fin { return deliver(opcode: opcode, Data(payload)) }
            fragments = Fragments(opcode: opcode, data: Data(payload))
        case 0x8:   // close: answer it, then hang up
            let code: UInt16 = payload.count >= 2 ? UInt16(payload[0]) << 8 | UInt16(payload[1]) : 1000
            close(code: code == 1005 || code == 1006 ? 1000 : code)
            return .closed
        case 0x9:   // ping
            send(opcode: 0xA, payload: Data(payload), completion: nil)
        case 0xA:   // pong
            break
        default:
            return .fail(1002)
        }
        return .frame
    }

    private func deliver(opcode: UInt8, _ data: Data) -> Step {
        let handler = lock.withLock { onMessage }
        if opcode == 0x1 {
            guard let text = String(data: data, encoding: .utf8) else { return .fail(1007) }
            handler?(.text(text))
        } else {
            handler?(.binary(data))
        }
        return .frame
    }

    // MARK: Ending

    private func checkTimeouts() {
        let (stalled, idle) = lock.withLock { () -> (Bool, Bool) in
            (pendingSends > 0 && -lastProgress.timeIntervalSinceNow > Self.stallLimit,
             -lastHeard.timeIntervalSinceNow > Self.idleLimit)
        }
        if stalled { connection.cancel(); end() }
        else if idle { close(code: 1001, reason: "No word from the device"); end() }
    }

    private func end() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !closed else { return nil }
            closed = true
            watchdog?.cancel()
            watchdog = nil
            onMessage = nil
            let handler = onClose
            onClose = nil
            return handler
        }
        guard let handler else { return }
        connection.cancel()
        handler()
    }
}
