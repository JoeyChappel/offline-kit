import Foundation
import Testing
import zlib

// MARK: - ByteRange

@Suite("ByteRange")
struct ByteRangeTests {
    @Test("Closed, open-ended and suffix ranges", arguments: [
        ("bytes=0-9", 100, 0, 9),
        ("bytes=10-", 100, 10, 99),
        ("bytes=-5", 100, 95, 99),
        ("bytes=-500", 100, 0, 99),          // a suffix longer than the file is the whole file
        ("bytes=90-200", 100, 90, 99),       // the end is cut to the file
        ("bytes=99-99", 100, 99, 99),
        ("bytes= 5 - 9", 100, 5, 9),         // spaces around the numbers
        ("bytes=0-9,20-29", 100, 0, 9),      // only the first of several ranges
    ])
    func valid(_ header: String, _ total: Int, _ lower: Int, _ upper: Int) throws {
        let range = try #require(ByteRange(header: header, total: total))
        #expect(range.lower == lower)
        #expect(range.upper == upper)
    }

    @Test("Unsatisfiable or malformed ranges give nil", arguments: [
        ("bytes=100-", 100), ("bytes=200-300", 100), ("bytes=9-5", 100), ("bytes=-0", 100), ("bytes=", 100),
        ("bytes=-", 100), ("bytes=a-b", 100), ("items=0-9", 100), ("0-9", 100), ("bytes=1-2-3", 100), ("bytes=0-9", 0),
    ])
    func invalid(_ header: String, _ total: Int) {
        #expect(ByteRange(header: header, total: total) == nil)
    }

    @Test("No header, no range")
    func noHeader() {
        #expect(ByteRange(header: nil, total: 100) == nil)
    }

    @Test("Bounds always fall inside the file")
    func boundsFuzz() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2_000 {
            let total = Int.random(in: 1...10_000, using: &rng)
            let a = Int.random(in: -20...12_000, using: &rng), b = Int.random(in: -20...12_000, using: &rng)
            let forms = ["bytes=\(a)-\(b)", "bytes=\(a)-", "bytes=-\(b)"]
            for header in forms {
                guard let r = ByteRange(header: header, total: total) else { continue }
                #expect(r.lower >= 0 && r.lower <= r.upper && r.upper < total, "\(header) of \(total)")
            }
        }
    }
}

// MARK: - Gzip

/// Undoes gzip with zlib (window bits 15 + 16), independent of the code under test.
func gunzip(_ data: Data) -> Data? {
    var stream = z_stream()
    guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
    defer { inflateEnd(&stream) }
    var out = Data()
    var chunk = [UInt8](repeating: 0, count: 64 * 1024)
    let ok: Bool = data.withUnsafeBytes { input in
        stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
        stream.avail_in = uInt(input.count)
        while true {
            let status = chunk.withUnsafeMutableBufferPointer { buffer -> Int32 in
                stream.next_out = buffer.baseAddress
                stream.avail_out = uInt(buffer.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            out.append(contentsOf: chunk[0..<(chunk.count - Int(stream.avail_out))])
            if status == Z_STREAM_END { return true }
            if status != Z_OK { return false }
        }
    }
    return ok ? out : nil
}

@Suite("Gzip")
struct GzipTests {
    static let text = Data(String(repeating: "Offline Kit keeps a household's references on this Mac. ", count: 200).utf8)

    @Test("deflate round-trips through zlib's gzip reader")
    func roundTrip() throws {
        let packed = try #require(Gzip.deflate(Self.text))
        #expect(packed.count < Self.text.count / 5)
        #expect(packed.prefix(2) == Data([0x1f, 0x8b]), "gzip magic")
        #expect(gunzip(packed) == Self.text)
    }

    @Test("Empty and tiny bodies round-trip")
    func edges() throws {
        for body in [Data(), Data("a".utf8), Data((0..<256).map { UInt8($0) })] {
            let packed = try #require(Gzip.deflate(body))
            #expect(gunzip(packed) == body)
        }
    }

    @Test("compress gives nil when gzip wouldn't be smaller")
    func incompressible() {
        var random = SystemRandomNumberGenerator()
        let noise = Data((0..<4096).map { _ in UInt8.random(in: 0...255, using: &random) })
        #expect(Gzip.compress(noise, key: nil) == nil)
    }

    @Test("compress keeps the result per key and hands it back")
    func cache() throws {
        let key = "\"test-\(UUID().uuidString)\"text/html"
        let first = try #require(Gzip.compress(Self.text, key: key))
        #expect(gunzip(first) == Self.text)
        // Same key and length: the kept copy comes back (the key promises the content didn't change).
        var changed = Self.text
        changed[0] = UInt8(ascii: "X")
        #expect(Gzip.compress(changed, key: key) == first)
        // A different length is a different entry.
        let longer = Self.text + Data("more".utf8)
        let other = try #require(Gzip.compress(longer, key: key))
        #expect(gunzip(other) == longer)
    }

    @Test("Only text types are compressible", arguments: [
        ("text/html; charset=utf-8", true), ("TEXT/CSS", true), ("application/json", true), ("application/javascript", true),
        ("image/svg+xml", true), ("application/manifest+json", true), ("application/xml", true),
        ("text/event-stream", false), ("image/png", false), ("video/mp4", false), ("application/pdf", false),
        ("application/zip", false), ("", false),
    ])
    func compressible(_ type: String, _ expected: Bool) {
        #expect(Gzip.isCompressible(type) == expected)
    }
}

// MARK: - Request parsing

@Suite("HTTP request parsing")
struct RequestParsingTests {
    func parse(_ raw: String) -> (request: WebServer.Request, used: Int)? {
        WebServer.parseRequest(Data(raw.utf8), remote: "127.0.0.1")
    }

    @Test("A simple GET: method, decoded path, query and lowercased headers")
    func simpleGet() throws {
        let raw = "GET /content/abc/A%20B?q=heat+stroke&book=&x=%26y HTTP/1.1\r\nHost: 192.168.1.2:8080\r\nAccept-Encoding: gzip\r\n\r\n"
        let (request, used) = try #require(parse(raw))
        #expect(used == raw.utf8.count)
        #expect(request.method == "GET")
        #expect(request.path == "/content/abc/A B")
        #expect(request.rawPath == "/content/abc/A%20B")
        #expect(request.rawQuery == "q=heat+stroke&book=&x=%26y")
        #expect(request.query == ["q": "heat stroke", "book": "", "x": "&y"])
        #expect(request.headers["host"] == "192.168.1.2:8080")
        #expect(request.headers["accept-encoding"] == "gzip")
        #expect(request.remoteHost == "127.0.0.1")
        #expect(request.keepAlive)
    }

    @Test("Incomplete headers or body wait for more")
    func incomplete() {
        #expect(parse("GET / HTTP/1.1\r\nHost: x\r\n") == nil)
        #expect(parse("POST /x HTTP/1.1\r\nContent-Length: 10\r\n\r\n12345") == nil)
        #expect(parse("") == nil)
    }

    @Test("The body is exactly Content-Length bytes; what follows is the next request")
    func pipelined() throws {
        let first = "POST /echo HTTP/1.1\r\nContent-Length: 5\r\n\r\nhello"
        let second = "GET /next HTTP/1.1\r\n\r\n"
        let data = Data((first + second).utf8)
        let (request, used) = try #require(WebServer.parseRequest(data, remote: ""))
        #expect(request.body == Data("hello".utf8))
        #expect(used == first.utf8.count)
        let rest = data.suffix(from: used)
        let (next, _) = try #require(WebServer.parseRequest(Data(rest), remote: ""))
        #expect(next.path == "/next")
    }

    @Test("Works on a slice whose indices don't start at zero")
    func sliceIndices() throws {
        let data = Data(("XXXX" + "GET /a HTTP/1.1\r\nContent-Length: 2\r\n\r\nhiGET").utf8)
        let slice = data.suffix(from: 4)
        let (request, used) = try #require(WebServer.parseRequest(slice, remote: ""))
        #expect(request.path == "/a")
        #expect(request.body == Data("hi".utf8))
        #expect(used == slice.count - 3)
    }

    @Test("Bodies over 256 KB, negative or unreadable lengths are refused", arguments: ["262145", "-1", "abc", "1e3"])
    func badLength(_ length: String) {
        #expect(parse("POST /x HTTP/1.1\r\nContent-Length: \(length)\r\n\r\n") == nil)
    }

    @Test("A request line without a target is refused")
    func badRequestLine() {
        #expect(parse("GARBAGE\r\n\r\n") == nil)
    }

    @Test("Keep-alive only on HTTP/1.1 without close, chunked bodies or HEAD", arguments: [
        ("GET / HTTP/1.1\r\n\r\n", true),
        ("GET / HTTP/1.1\r\nConnection: keep-alive\r\n\r\n", true),
        ("GET / HTTP/1.1\r\nConnection: close\r\n\r\n", false),
        ("GET / HTTP/1.1\r\nConnection: Keep-Alive, Close\r\n\r\n", false),
        ("GET / HTTP/1.0\r\n\r\n", false),
        ("GET / HTTP/1.0\r\nConnection: keep-alive\r\n\r\n", false),
        ("GET /\r\n\r\n", false),
        ("HEAD / HTTP/1.1\r\n\r\n", false),
        ("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n", false),
    ])
    func keepAlive(_ raw: String, _ expected: Bool) throws {
        #expect(try #require(parse(raw)).request.keepAlive == expected)
    }

    @Test("Cookies are split into name and value")
    func cookies() throws {
        let (request, _) = try #require(parse("GET / HTTP/1.1\r\nCookie: okpin=abc123; okdev=d=e; broken\r\n\r\n"))
        #expect(request.cookies == ["okpin": "abc123", "okdev": "d=e"])
    }

    @Test("Header lines without a colon are skipped; values are trimmed")
    func headerLines() throws {
        let (request, _) = try #require(parse("GET / HTTP/1.1\r\nnonsense\r\nX-Thing:   spaced value  \r\nRange: bytes=0-1\r\n\r\n"))
        #expect(request.headers["x-thing"] == "spaced value")
        #expect(request.headers["range"] == "bytes=0-1")
        #expect(request.headers.count == 2)
    }
}

// MARK: - Conditional requests

@Suite("Conditional requests")
struct ConditionalTests {
    let modified = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("If-None-Match: exact, listed, weak or any")
    func ifNoneMatch() {
        let etag = "\"123-456\""
        #expect(WebServer.isNotModified(["if-none-match": etag], etag: etag, modified: modified))
        #expect(WebServer.isNotModified(["if-none-match": "\"x\", \(etag)"], etag: etag, modified: modified))
        #expect(WebServer.isNotModified(["if-none-match": "W/\(etag)"], etag: etag, modified: modified))
        #expect(WebServer.isNotModified(["if-none-match": "*"], etag: etag, modified: modified))
        #expect(!WebServer.isNotModified(["if-none-match": "\"other\""], etag: etag, modified: modified))
    }

    @Test("If-None-Match wins over If-Modified-Since")
    func etagFirst() {
        let headers = ["if-none-match": "\"other\"", "if-modified-since": WebServer.httpDate(modified.addingTimeInterval(60))]
        #expect(!WebServer.isNotModified(headers, etag: "\"e\"", modified: modified))
    }

    @Test("If-Modified-Since: same or later is not modified; earlier or unreadable is")
    func ifModifiedSince() {
        #expect(WebServer.isNotModified(["if-modified-since": WebServer.httpDate(modified)], etag: "\"e\"", modified: modified))
        #expect(WebServer.isNotModified(["if-modified-since": WebServer.httpDate(modified.addingTimeInterval(5))], etag: "\"e\"", modified: modified.addingTimeInterval(0.9)))
        #expect(!WebServer.isNotModified(["if-modified-since": WebServer.httpDate(modified.addingTimeInterval(-1))], etag: "\"e\"", modified: modified))
        #expect(!WebServer.isNotModified(["if-modified-since": "yesterday"], etag: "\"e\"", modified: modified))
        #expect(!WebServer.isNotModified([:], etag: "\"e\"", modified: modified))
    }

    @Test("HTTP dates are RFC 7231 GMT in English")
    func httpDate() {
        #expect(WebServer.httpDate(Date(timeIntervalSince1970: 0)) == "Thu, 01 Jan 1970 00:00:00 GMT")
    }
}

@Suite("Accept-Encoding")
struct AcceptEncodingTests {
    @Test("gzip is accepted unless its weight is zero")
    func gzipWeights() {
        #expect(WebServer.acceptsGzip("gzip"))
        #expect(WebServer.acceptsGzip(" gzip ;q=0.5"))
        #expect(WebServer.acceptsGzip("GZIP; q=1"))
        #expect(!WebServer.acceptsGzip("gzip;q=0"))
        #expect(!WebServer.acceptsGzip("gzip; q=0.000"))
        #expect(!WebServer.acceptsGzip("deflate"))
        #expect(!WebServer.acceptsGzip("x-gzip-ish"))
    }

    @Test("Header values lose line breaks, including a CRLF pair")
    func headerSafe() {
        #expect(WebServer.headerSafe("text/html\r\nSet-Cookie: x=1") == "text/htmlSet-Cookie: x=1")
        #expect(WebServer.headerSafe("a\rb\nc") == "abc")
    }
}
