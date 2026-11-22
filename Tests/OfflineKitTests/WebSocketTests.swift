import Foundation
import Testing

/// WebSocket (RFC 6455) on the real server: the upgrade, frame parsing (masking, the three length forms,
/// fragments, control frames) and the limits that close a misbehaving connection.
@Suite("WebSocket over loopback")
struct WebSocketTests {
    static let sampleKey = "dGhlIHNhbXBsZSBub25jZQ=="          // RFC 6455's own example
    static let sampleAccept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="

    func start() async throws -> LoopbackServer {
        try await LoopbackServer { req, res in
            guard req.path == "/ws" else { await res.send(status: 404, text: "Not found"); return }
            guard let socket = await res.upgradeToWebSocket(req) else { return }
            // Echo every message back. The socket is kept alive by its own handler until it ends.
            socket.start(onMessage: { message in
                switch message {
                case .text(let text): socket.send(text: text)
                case .binary(let data): socket.send(binary: data)
                }
            }, onClose: {})
        }
    }

    /// An upgraded connection.
    func connect(_ server: LoopbackServer) throws -> RawClient {
        let c = try server.client()
        c.send("GET /ws HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n"
               + "Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(Self.sampleKey)\r\n\r\n")
        let response = try c.readResponse()
        try #require(response.status == 101)
        return c
    }

    /// The server sends a close frame with `code`, then closes the socket.
    func expectClose(_ c: RawClient, code: UInt16, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            let frame = try c.readFrame()
            #expect(closeCode(frame) == code, sourceLocation: sourceLocation)
        } catch {
            Issue.record("No close frame: \(error)", sourceLocation: sourceLocation)
        }
        #expect(c.isClosedByServer(), sourceLocation: sourceLocation)
    }

    func closeCode(_ frame: (fin: Bool, opcode: UInt8, payload: Data)) -> UInt16? {
        guard frame.opcode == 0x8, frame.payload.count >= 2 else { return nil }
        return UInt16(frame.payload[frame.payload.startIndex]) << 8 | UInt16(frame.payload[frame.payload.startIndex + 1])
    }

    @Test("The upgrade answers 101 with the RFC's accept value")
    func handshake() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /ws HTTP/1.1\r\nUpgrade: WebSocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\n"
               + "Sec-WebSocket-Key: \(Self.sampleKey)\r\n\r\n")
        let response = try c.readResponse()
        #expect(response.status == 101)
        #expect(response.headers["sec-websocket-accept"] == Self.sampleAccept)
        #expect(response.headers["upgrade"] == "websocket")
    }

    @Test("A request that isn't a valid upgrade gets 400", arguments: [
        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: \(sampleKey)\r\n",                                   // no version
        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 8\r\nSec-WebSocket-Key: \(sampleKey)\r\n",       // old version
        "Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: c2hvcnQ=\r\n",         // key not 16 bytes
        "Upgrade: websocket\r\nConnection: keep-alive\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(sampleKey)\r\n",  // no Upgrade token
        "Connection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: \(sampleKey)\r\n",                           // no Upgrade header
    ])
    func badUpgrade(_ headers: String) async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /ws HTTP/1.1\r\n" + headers + "\r\n")
        #expect(try c.readResponse().status == 400)
    }

    @Test("Masked text and binary messages in all three length forms are unmasked and delivered", arguments: [5, 125, 126, 300, 65_535, 65_536])
    func lengths(_ size: Int) async throws {
        let server = try await start()
        let c = try connect(server)
        let payload = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 * 7) })
        c.sendFrame(opcode: 0x2, payload: payload)
        let echo = try c.readFrame()
        #expect(echo.fin && echo.opcode == 0x2)
        #expect(echo.payload == payload)
        c.sendFrame(opcode: 0x1, payload: Data("héllo".utf8))
        let text = try c.readFrame()
        #expect(text.opcode == 0x1)
        #expect(String(decoding: text.payload, as: UTF8.self) == "héllo")
    }

    @Test("Fragments are joined into one message, with a ping answered in between")
    func fragments() async throws {
        let server = try await start()
        let c = try connect(server)
        c.sendFrame(opcode: 0x1, payload: Data("Hel".utf8), fin: false)
        c.sendFrame(opcode: 0x9, payload: Data("p1".utf8))                 // ping between fragments is allowed
        c.sendFrame(opcode: 0x0, payload: Data("lo, ".utf8), fin: false)
        c.sendFrame(opcode: 0x0, payload: Data("world".utf8), fin: true)
        let pong = try c.readFrame()
        #expect(pong.opcode == 0xA)
        #expect(pong.payload == Data("p1".utf8))
        let message = try c.readFrame()
        #expect(message.opcode == 0x1)
        #expect(String(decoding: message.payload, as: UTF8.self) == "Hello, world")
    }

    @Test("Several frames in one write are all read")
    func batched() async throws {
        let server = try await start()
        let c = try connect(server)
        for word in ["one", "two", "three"] { c.sendFrame(opcode: 0x1, payload: Data(word.utf8)) }
        for word in ["one", "two", "three"] {
            #expect(String(decoding: try c.readFrame().payload, as: UTF8.self) == word)
        }
    }

    @Test("An unmasked frame closes with 1002")
    func unmasked() async throws {
        let server = try await start()
        let c = try connect(server)
        c.sendFrame(opcode: 0x1, payload: Data("hi".utf8), masked: false)
        expectClose(c, code: 1002)
    }

    @Test("A message over 64 KB closes with 1009", arguments: [false, true])
    func oversize(_ fragmented: Bool) async throws {
        let server = try await start()
        let c = try connect(server)
        if fragmented {
            // Each piece is allowed, but together they pass the limit.
            c.sendFrame(opcode: 0x2, payload: Data(count: 40_000), fin: false)
            c.sendFrame(opcode: 0x0, payload: Data(count: 40_000), fin: true)
        } else {
            // Only the header: the declared length alone is enough to refuse it.
            c.sendFrame(opcode: 0x2, payload: Data(), declaredLength: WebSocket.maxMessage + 1)
        }
        expectClose(c, code: 1009)
    }

    @Test("Protocol errors close with 1002", arguments: [
        "control frame over 125 bytes", "fragmented control frame", "reserved bits", "unknown opcode", "continuation with nothing to continue",
        "new message inside a fragmented one",
    ])
    func protocolErrors(_ kind: String) async throws {
        let server = try await start()
        let c = try connect(server)
        switch kind {
        case "control frame over 125 bytes": c.sendFrame(opcode: 0x9, payload: Data(count: 126))
        case "fragmented control frame": c.sendFrame(opcode: 0x9, payload: Data("x".utf8), fin: false)
        case "reserved bits": c.sendFrame(opcode: 0x40 | 0x1, payload: Data("x".utf8))
        case "unknown opcode": c.sendFrame(opcode: 0x3, payload: Data("x".utf8))
        case "continuation with nothing to continue": c.sendFrame(opcode: 0x0, payload: Data("x".utf8))
        default:
            c.sendFrame(opcode: 0x1, payload: Data("a".utf8), fin: false)
            c.sendFrame(opcode: 0x1, payload: Data("b".utf8))
        }
        expectClose(c, code: 1002)
    }

    @Test("Text that isn't UTF-8 closes with 1007")
    func badUTF8() async throws {
        let server = try await start()
        let c = try connect(server)
        c.sendFrame(opcode: 0x1, payload: Data([0xC3, 0x28, 0xFF]))
        expectClose(c, code: 1007)
    }

    @Test("A close from the device is answered with its code, then the socket ends")
    func closeHandshake() async throws {
        let server = try await start()
        let c = try connect(server)
        c.sendFrame(opcode: 0x8, payload: Data([0x0F, 0xA0]))      // 4000, an application code
        expectClose(c, code: 4000)
        // 1005 and 1006 must never be sent on the wire: they're answered with 1000.
        let d = try connect(server)
        d.sendFrame(opcode: 0x8, payload: Data([0x03, 0xED]))      // 1005
        expectClose(d, code: 1000)
    }
}
