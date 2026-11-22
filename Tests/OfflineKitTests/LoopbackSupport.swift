import Foundation
import Testing

/// The real WebServer on a free loopback port, with a test handler. Stopped when the value goes away.
final class LoopbackServer: @unchecked Sendable {
    let server: WebServer
    let port: UInt16

    init(handler: @escaping WebServer.Handler) async throws {
        server = WebServer(handler: handler)
        let ready = Flag()
        // A random range high up, so parallel tests (and anything else on this Mac) rarely meet.
        let base = UInt16.random(in: 30_000...60_000)
        try server.start(ports: base...(base + 300), serviceName: nil) { error in if error == nil { ready.set() } }
        port = server.port
        let started = await eventually { ready.isSet }
        try #require(started, "the test server didn't start")
    }

    deinit { server.stop() }

    func client(timeout: Double = 3) throws -> RawClient { try RawClient(port: port, timeout: timeout) }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

struct RawResponse {
    var status: Int
    var headers: [String: String]   // lowercased names
    var headerLines: [String]
    var body: Data
    var text: String { String(decoding: body, as: UTF8.self) }
}

enum RawClientError: Error { case connect(Int32), closed, timeout, malformed(String) }

/// A blocking TCP client over a POSIX socket: sends raw bytes and reads raw HTTP responses and WebSocket frames,
/// so the tests see exactly what the server writes.
final class RawClient {
    private let fd: Int32
    private var buffer = Data()

    init(port: UInt16, timeout: Double) throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw RawClientError.connect(errno) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { let e = errno; close(fd); throw RawClientError.connect(e) }
    }

    deinit { close(fd) }

    func send(_ text: String) { send(Data(text.utf8)) }

    func send(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + offset, raw.count - offset, 0)
                if n <= 0 { return }
                offset += n
            }
        }
    }

    /// Reads whatever arrives next into the buffer: false at the end of the stream (or an error), throws on timeout.
    private func fill() throws -> Bool {
        var chunk = [UInt8](repeating: 0, count: 256 * 1024)
        let n = recv(fd, &chunk, chunk.count, 0)
        if n > 0 { buffer.append(contentsOf: chunk[0..<n]); return true }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw RawClientError.timeout }
        return false
    }

    private func take(_ count: Int) throws -> Data {
        while buffer.count < count { guard try fill() else { throw RawClientError.closed } }
        let out = Data(buffer.prefix(count))
        buffer = Data(buffer.dropFirst(count))
        return out
    }

    /// One response: head, then a body of Content-Length bytes (none for 101, 204, 304 or HEAD-like answers).
    func readResponse(expectBody: Bool = true) throws -> RawResponse {
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil { guard try fill() else { throw RawClientError.closed } }
        let end = buffer.range(of: separator)!
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        buffer = Data(buffer[end.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let statusLine = lines.removeFirst().split(separator: " ")
        guard statusLine.count >= 2, let status = Int(statusLine[1]) else { throw RawClientError.malformed(head) }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var body = Data()
        if expectBody, status != 101, status != 204, status != 304, let length = headers["content-length"].flatMap(Int.init) {
            body = try take(length)
        }
        return RawResponse(status: status, headers: headers, headerLines: lines, body: body)
    }

    /// True when the server closes the connection (nothing more arrives) within the timeout.
    func isClosedByServer() -> Bool {
        do {
            while try fill() {}
            return true
        } catch { return false }
    }

    /// Bytes still unread (beyond the last response).
    var pending: Int { buffer.count }

    // MARK: WebSocket

    /// One frame from the server (never masked): FIN bit, opcode and payload.
    func readFrame() throws -> (fin: Bool, opcode: UInt8, payload: Data) {
        let head = try take(2)
        let fin = head[0] & 0x80 != 0, opcode = head[0] & 0x0F
        #expect(head[1] & 0x80 == 0, "server frames are never masked")
        var length = Int(head[1] & 0x7F)
        if length == 126 {
            let ext = try take(2)
            length = Int(ext[0]) << 8 | Int(ext[1])
        } else if length == 127 {
            let ext = try take(8)
            length = ext.reduce(0) { $0 << 8 | Int($1) }
        }
        return (fin, opcode, try take(length))
    }

    /// Sends one client frame, masked unless told otherwise. `lengthForm` forces 7-bit, 16-bit or 64-bit lengths.
    func sendFrame(opcode: UInt8, payload: Data, fin: Bool = true, masked: Bool = true, declaredLength: Int? = nil) {
        var frame = Data([(fin ? 0x80 : 0) | opcode])
        let length = declaredLength ?? payload.count
        let maskBit: UInt8 = masked ? 0x80 : 0
        if length < 126 {
            frame.append(maskBit | UInt8(length))
        } else if length <= 0xFFFF {
            frame.append(maskBit | 126)
            frame.append(UInt8(length >> 8)); frame.append(UInt8(length & 0xFF))
        } else {
            frame.append(maskBit | 127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((UInt64(length) >> UInt64(shift)) & 0xFF)) }
        }
        if masked {
            let mask: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]
            frame.append(contentsOf: mask)
            frame.append(contentsOf: payload.enumerated().map { $0.element ^ mask[$0.offset & 3] })
        } else {
            frame.append(payload)
        }
        send(frame)
    }
}
