import Foundation
import Testing

/// The real WebServer on loopback, driven with raw bytes: keep-alive framing, pipelining, close semantics,
/// ranges, conditional requests, gzip and the safety limits.
@Suite("WebServer over loopback")
struct WebServerTests {
    let tmp: TempDir
    let file: URL          // 1,000 bytes: 0, 1, 2 … 255, 0, 1 …
    let big: URL           // 17 MB, sparse
    let fileBytes = Data((0..<1000).map { UInt8($0 & 0xFF) })
    static let bigSize: Int64 = 17 * 1024 * 1024
    let pageTag = "\"page-\(UUID().uuidString)\""

    init() throws {
        tmp = try TempDir("webserver")
        file = tmp.url.appending(path: "clip.mp4")
        try fileBytes.write(to: file)
        big = tmp.url.appending(path: "movie.mp4")
        FileManager.default.createFile(atPath: big.path, contents: nil)
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(Self.bigSize))
        try handle.close()
    }

    func start() async throws -> LoopbackServer {
        let file = self.file, big = self.big, tag = pageTag
        return try await LoopbackServer { req, res in
            switch req.path {
            case "/hello":
                await res.send(status: 200, text: "hello \(req.query["n"] ?? "")")
            case "/echo":
                await res.send(status: 200, contentType: "application/octet-stream", body: req.body)
            case "/file":
                await res.sendFile(file, contentType: "video/mp4", rangeHeader: req.headers["range"])
            case "/cached":
                await res.sendFile(file, contentType: "image/jpeg", rangeHeader: req.headers["range"],
                                   cacheControl: "private, max-age=60", requestHeaders: req.headers)
            case "/big":
                await res.sendFile(big, contentType: "video/mp4", rangeHeader: req.headers["range"])
            case "/page":
                await res.send(status: 200, contentType: "text/html; charset=utf-8", body: GzipTests.text, headers: ["ETag": tag])
            case "/small":
                await res.send(status: 200, contentType: "text/html; charset=utf-8", body: Data("<p>short</p>".utf8))
            case "/inject":
                await res.send(status: 200, contentType: "text/plain\r\nX-Injected: 1", body: Data("x".utf8),
                               headers: ["X-Note": "a\r\nX-Evil: 2"])
            case "/inject-lone":
                await res.send(status: 200, contentType: "text/plain\nX-Lone: 1", body: Data("x".utf8),
                               headers: ["X-Note": "a\rX-Lone2: 2"])
            case "/events":
                await res.startEventStream()
                await res.event("hi", ["a": 1])
                res.finish()
            default:
                await res.send(status: 404, text: "Not found")
            }
        }
    }

    @Test("Keep-alive: requests one after another on one connection, with the Keep-Alive budget counting down")
    func keepAlive() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /hello?n=1 HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let first = try c.readResponse()
        #expect(first.status == 200)
        #expect(first.text == "hello 1")
        #expect(first.headers["connection"] == "keep-alive")
        #expect(first.headers["keep-alive"] == "timeout=8, max=99")
        #expect(first.headers["content-length"] == "7")
        #expect(first.headers["x-content-type-options"] == "nosniff")
        #expect(first.headers["cache-control"] == "no-store")
        c.send("GET /hello?n=2 HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let second = try c.readResponse()
        #expect(second.text == "hello 2")
        #expect(second.headers["keep-alive"] == "timeout=8, max=98")
    }

    @Test("Pipelining: several requests in one write come back in order")
    func pipelining() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /hello?n=1 HTTP/1.1\r\n\r\n" + "POST /echo HTTP/1.1\r\nContent-Length: 3\r\n\r\nabc" + "GET /hello?n=3 HTTP/1.1\r\n\r\n")
        #expect(try c.readResponse().text == "hello 1")
        #expect(try c.readResponse().text == "abc")
        let third = try c.readResponse()
        #expect(third.text == "hello 3")
        #expect(third.headers["keep-alive"] == "timeout=8, max=97")
    }

    @Test("A request split across writes is read once it's all there")
    func splitRequest() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("POST /echo HTTP/1.1\r\nCont")
        try await Task.sleep(for: .milliseconds(30))
        c.send("ent-Length: 11\r\n\r\nhello")
        try await Task.sleep(for: .milliseconds(30))
        c.send(" world")
        let response = try c.readResponse()
        #expect(response.text == "hello world")
        #expect(c.pending == 0)
    }

    @Test("Connection: close is answered with close, then the connection ends")
    func connectionClose() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /hello HTTP/1.1\r\nConnection: close\r\n\r\n")
        let response = try c.readResponse()
        #expect(response.status == 200)
        #expect(response.headers["connection"] == "close")
        #expect(response.headers["keep-alive"] == nil)
        #expect(c.isClosedByServer())
    }

    @Test("HTTP/1.0 and HEAD requests close after the response", arguments: ["GET /hello HTTP/1.0\r\n\r\n", "HEAD /hello HTTP/1.1\r\n\r\n"])
    func closesAfter(_ raw: String) async throws {
        let server = try await start()
        let c = try server.client()
        c.send(raw)
        #expect(try c.readResponse().headers["connection"] == "close")
        #expect(c.isClosedByServer())
    }

    @Test("A connection closes after its 100th request")
    func maxRequests() async throws {
        let server = try await start()
        let c = try server.client()
        for n in 1...WebServer.maxRequests {
            c.send("GET /hello?n=\(n) HTTP/1.1\r\n\r\n")
            let response = try c.readResponse()
            if n < WebServer.maxRequests {
                #expect(response.headers["connection"] == "keep-alive", "request \(n)")
            } else {
                #expect(response.headers["connection"] == "close")
            }
        }
        #expect(c.isClosedByServer())
    }

    @Test("A body over 256 KB is refused by closing the connection")
    func oversizedBody() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("POST /echo HTTP/1.1\r\nContent-Length: 1000000\r\n\r\n")
        c.send(Data(count: 300 * 1024))
        #expect(c.isClosedByServer())
        #expect(c.pending == 0, "nothing was answered")
    }

    @Test("Byte ranges: 206 with Content-Range; a range that can't be met gets the whole file")
    func ranges() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /file HTTP/1.1\r\nRange: bytes=2-5\r\n\r\n")
        let part = try c.readResponse()
        #expect(part.status == 206)
        #expect(part.headers["content-range"] == "bytes 2-5/1000")
        #expect(part.headers["accept-ranges"] == "bytes")
        #expect(part.body == fileBytes[2...5])
        c.send("GET /file HTTP/1.1\r\nRange: bytes=-10\r\n\r\n")
        let tail = try c.readResponse()
        #expect(tail.headers["content-range"] == "bytes 990-999/1000")
        #expect(tail.body == fileBytes.suffix(10))
        c.send("GET /file HTTP/1.1\r\nRange: bytes=5000-\r\n\r\n")
        let whole = try c.readResponse()
        #expect(whole.status == 200)
        #expect(whole.body == fileBytes)
        #expect(whole.headers["connection"] == "keep-alive", "still framed by length, so the connection stays")
    }

    @Test("Open-ended ranges are capped at 16 MB")
    func openEndedCap() async throws {
        let server = try await start()
        let c = try server.client(timeout: 10)
        c.send("GET /big HTTP/1.1\r\nRange: bytes=0-\r\n\r\n")
        let capped = try c.readResponse()
        #expect(capped.status == 206)
        #expect(capped.headers["content-length"] == "16777216")
        #expect(capped.headers["content-range"] == "bytes 0-16777215/\(Self.bigSize)")
        #expect(capped.body.count == 16_777_216)
        c.send("GET /big HTTP/1.1\r\nRange: bytes=17000000-\r\n\r\n")
        let rest = try c.readResponse()
        #expect(rest.headers["content-range"] == "bytes 17000000-\(Self.bigSize - 1)/\(Self.bigSize)")
        #expect(rest.body.count == Int(Self.bigSize) - 17_000_000)
        // A closed range is honored as asked, however long.
        c.send("GET /big HTTP/1.1\r\nRange: bytes=0-\(Self.bigSize - 1)\r\nConnection: close\r\n\r\n")
        #expect(try c.readResponse().body.count == Int(Self.bigSize))
    }

    @Test("Conditional requests: 304 with no body or length, and the connection carries on")
    func notModified() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /cached HTTP/1.1\r\n\r\n")
        let first = try c.readResponse()
        #expect(first.status == 200)
        #expect(first.headers["cache-control"] == "private, max-age=60")
        let etag = try #require(first.headers["etag"])
        let modified = try #require(first.headers["last-modified"])
        c.send("GET /cached HTTP/1.1\r\nIf-None-Match: \(etag)\r\n\r\n")
        let again = try c.readResponse()
        #expect(again.status == 304)
        #expect(again.headers["content-length"] == nil)
        #expect(again.headers["etag"] == etag)
        #expect(again.headers["connection"] == "keep-alive")
        c.send("GET /cached HTTP/1.1\r\nIf-Modified-Since: \(modified)\r\n\r\n")
        #expect(try c.readResponse().status == 304)
        c.send("GET /hello?n=after HTTP/1.1\r\n\r\n")
        let next = try c.readResponse()
        #expect(next.text == "hello after", "the 304 left nothing unread on the connection")
        // A range request skips the validators and gets the bytes.
        c.send("GET /cached HTTP/1.1\r\nIf-None-Match: \(etag)\r\nRange: bytes=0-0\r\n\r\n")
        #expect(try c.readResponse().status == 206)
    }

    @Test("Gzip for text when asked: weak ETag, Vary, and it unpacks to the original")
    func gzip() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /page HTTP/1.1\r\nAccept-Encoding: br, gzip, deflate\r\n\r\n")
        let packed = try c.readResponse()
        #expect(packed.headers["content-encoding"] == "gzip")
        #expect(packed.headers["vary"] == "Accept-Encoding")
        #expect(packed.headers["etag"] == "W/" + pageTag)
        #expect(packed.body.count < GzipTests.text.count)
        #expect(gunzip(packed.body) == GzipTests.text)
        c.send("GET /page HTTP/1.1\r\nAccept-Encoding: gzip;q=0\r\n\r\n")
        let refused = try c.readResponse()
        #expect(refused.headers["content-encoding"] == nil)
        #expect(refused.body == GzipTests.text)
        #expect(refused.headers["etag"] == pageTag)
        c.send("GET /page HTTP/1.1\r\n\r\n")
        #expect(try c.readResponse().headers["content-encoding"] == nil)
        c.send("GET /small HTTP/1.1\r\nAccept-Encoding: gzip\r\n\r\n")
        let small = try c.readResponse()
        #expect(small.headers["content-encoding"] == nil, "bodies under 1 KB aren't worth it")
        #expect(small.text == "<p>short</p>")
    }

    @Test("A lone CR or LF in a content type or header value is removed")
    func loneLineBreaks() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /inject-lone HTTP/1.1\r\n\r\n")
        let response = try c.readResponse()
        #expect(response.headers["content-type"] == "text/plainX-Lone: 1")
        #expect(response.headers["x-note"] == "aX-Lone2: 2")
        #expect(response.text == "x")
    }

    @Test("A CR LF pair in a content type or header value can't start a header of their own")
    func headerInjection() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /inject HTTP/1.1\r\n\r\n")
        let response = try c.readResponse()
        // A "\r\n" pair is one Swift Character; headerSafe filters by Unicode scalar so it can't start a header.
        #expect(!response.headerLines.contains { $0.lowercased().hasPrefix("x-injected") })
        #expect(!response.headerLines.contains { $0.lowercased().hasPrefix("x-evil") })
        #expect(response.text == "x")
    }

    @Test("Server-sent events close the connection when they end")
    func eventStream() async throws {
        let server = try await start()
        let c = try server.client()
        c.send("GET /events HTTP/1.1\r\n\r\n")
        let head = try c.readResponse(expectBody: false)
        #expect(head.headers["content-type"] == "text/event-stream; charset=utf-8")
        #expect(head.headers["connection"] == "close")
        #expect(head.headers["content-length"] == nil)
        #expect(c.isClosedByServer())
    }

    @Test("At most 16 open connections per device")
    func perDeviceCap() async throws {
        let server = try await start()
        var open: [RawClient] = []
        for n in 0..<16 {
            let c = try server.client()
            c.send("GET /hello?n=\(n) HTTP/1.1\r\n\r\n")
            #expect(try c.readResponse().status == 200)
            open.append(c)
        }
        let extra = try server.client()
        extra.send("GET /hello HTTP/1.1\r\n\r\n")
        #expect(extra.isClosedByServer())
        #expect(extra.pending == 0)
        open.removeAll()
    }
}
