import Foundation
import Network
import CryptoKit
import zlib

/// A small HTTP/1.1 server on Network.framework, plenty for a household of phones and tablets.
///
/// Connections stay open between requests (HTTP/1.1 keep-alive), so a phone loading forty covers doesn't open forty
/// connections. The next request is read only once the response before it has been written in full; every request
/// passes the same checks (Host, Connected Devices, sign-in) in ShareController, whatever connection it came on.
/// A connection closes after `maxRequests`, after `idleTimeout` with no new request, when the device asks, and after
/// any response that can't be framed by its length (server-sent events, WebSocket, a file that stopped mid-way).
final class WebServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String                 // percent-decoded, no query
        var rawPath: String              // as sent
        var rawQuery: String? = nil      // after "?", as sent
        var query: [String: String]
        var headers: [String: String]    // lowercased names
        var body: Data
        var remoteHost: String
        /// HTTP/1.1 without "Connection: close" (and nothing this server can't frame): another request may follow.
        var keepAlive = false

        var cookies: [String: String] {
            var out: [String: String] = [:]
            for part in (headers["cookie"] ?? "").split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2 { out[pair[0]] = pair[1] }
            }
            return out
        }
    }

    /// Writes a response. Either `send` once, or `startStream` then `write` repeatedly and `finish`.
    final class Responder: @unchecked Sendable {
        private let connection: NWConnection
        private var finished = false
        /// Whether the connection carries another request after this response. Starts as the server allows (the device
        /// asked to keep it, and it hasn't reached `maxRequests`) and turns false for any response that has to close.
        private(set) var keepAlive: Bool
        /// Requests this connection may still carry after this one, for the Keep-Alive header.
        private let remaining: Int
        /// The device sent "Accept-Encoding: gzip": text responses over 1 KB go compressed (see `send`).
        let acceptsGzip: Bool
        /// Called once this response has been written in full, on a connection that stays open: reads the next request.
        fileprivate var onReuse: (@Sendable () -> Void)?

        init(_ connection: NWConnection, keepAlive: Bool = false, remaining: Int = 0, acceptsGzip: Bool = false) {
            self.connection = connection
            self.keepAlive = keepAlive
            self.remaining = remaining
            self.acceptsGzip = acceptsGzip
        }

        /// This response ends the connection (a refusal, a stream with no length). Call before anything is written.
        func closeAfterResponse() { keepAlive = false }

        /// The Connection header lines for a response head, closing the connection when `close` (or when it can't stay open).
        func connectionHeaders(close: Bool = false) -> String {
            if close { keepAlive = false }
            return keepAlive ? "Connection: keep-alive\r\nKeep-Alive: timeout=\(Int(WebServer.idleTimeout)), max=\(remaining)\r\n" : "Connection: close\r\n"
        }

        // Connected Devices (ShareDevices): headers added to every response (the device cookie), and the bytes written
        // and the end of the response reported back. Set before the first write.
        var extraHeaders: [(String, String)] = []
        var onBytes: (@Sendable (Int64) -> Void)?
        var onFinish: (@Sendable () -> Void)?
        private var unreported: Int64 = 0
        private var reportedAt = Date()
        private var extraHeaderLines: String {
            extraHeaders.map { "\($0.0): \(WebServer.headerSafe($0.1))\r\n" }.joined()
        }
        deinit {
            // Answered nothing (or stopped part-way without finishing): the connection can't carry another request.
            if !finished { onFinish?(); connection.cancel() }
        }

        /// Sends a whole response. Text over 1 KB goes gzip-compressed when the device accepts it (see `Gzip`); a strong
        /// ETag then becomes weak, since the bytes differ from the uncompressed copy's.
        func send(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) async {
            // A type can come from inside an archive: a line break in it must not start a header of its own.
            let contentType = WebServer.headerSafe(contentType)
            var body = body, headers = headers
            if Gzip.isCompressible(contentType), headers["Content-Range"] == nil, headers["Content-Encoding"] == nil {
                headers["Vary"] = "Accept-Encoding"
                if acceptsGzip, status == 200, body.count > Gzip.minimumSize, let packed = Gzip.compress(body, key: headers["ETag"].map { $0 + contentType }) {
                    body = packed
                    headers["Content-Encoding"] = "gzip"
                    headers["Accept-Ranges"] = nil   // ranges would count compressed bytes; ranged requests get the plain bytes
                }
                if acceptsGzip, status == 200 || status == 304, let etag = headers["ETag"], !etag.hasPrefix("W/") { headers["ETag"] = "W/" + etag }
            }
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\n"
            // A 304 has no body; its length would describe the copy the device already has.
            if status != 304 { head += "Content-Length: \(body.count)\r\n" }
            head += connectionHeaders() + "X-Content-Type-Options: nosniff\r\n"
            if headers["Cache-Control"] == nil { head += "Cache-Control: no-store\r\n" }
            for (k, v) in headers { head += "\(k): \(WebServer.headerSafe(v))\r\n" }
            head += extraHeaderLines + "\r\n"
            let sent = await write(Data(head.utf8) + body)
            finish(complete: sent)
        }

        func send(status: Int = 200, json: Any, headers: [String: String] = [:]) async {
            let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data("{}".utf8)
            await send(status: status, contentType: "application/json; charset=utf-8", body: data, headers: headers)
        }

        func send(status: Int, text: String) async {
            await send(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
        }

        /// Sends a file, or the requested byte range of it, reading from disk in 1 MB pieces.
        /// Open-ended ranges are capped at 16 MB so a seek never streams a whole movie in one response.
        ///
        /// `cacheControl` (for artwork and other small files that rarely change) adds ETag and Last-Modified validators and
        /// answers a matching If-None-Match or If-Modified-Since in `requestHeaders` with 304, so a device keeps its copy.
        /// Without it the file is sent `no-store`, as video and audio always are.
        func sendFile(_ link: URL, contentType: String, rangeHeader: String?,
                      cacheControl: String? = nil, requestHeaders: [String: String] = [:]) async {
            // Follow aliases and symlinks, or the size would be the link's own few bytes.
            let url = link.resolvingSymlinksInPath()
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let total = values?.fileSize.map(Int64.init), total > 0 else {
                await send(status: 404, text: "Not found"); return
            }
            defer { try? handle.close() }
            var validators: [String: String] = [:]
            if let cacheControl, rangeHeader == nil {
                let modified = values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)
                let etag = "\"\(total)-\(Int(modified.timeIntervalSince1970))\""
                validators = ["ETag": etag, "Last-Modified": WebServer.httpDate(modified), "Cache-Control": cacheControl]
                if WebServer.isNotModified(requestHeaders, etag: etag, modified: modified) {
                    await send(status: 304, contentType: contentType, body: Data(), headers: validators)
                    return
                }
            }
            var lower: Int64 = 0, upper = total - 1, status = 200
            if let range = ByteRange(header: rangeHeader, total: Int(total)) {
                lower = Int64(range.lower); upper = Int64(range.upper); status = 206
                let openEnded = rangeHeader?.hasSuffix("-") == true
                if openEnded { upper = min(upper, lower + 16 * 1024 * 1024 - 1) }
            }
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(upper - lower + 1)\r\n"
            head += "Accept-Ranges: bytes\r\n" + connectionHeaders()
            if validators.isEmpty { head += "Cache-Control: no-store\r\n" }
            for (k, v) in validators { head += "\(k): \(v)\r\n" }
            if status == 206 { head += "Content-Range: bytes \(lower)-\(upper)/\(total)\r\n" }
            head += extraHeaderLines + "\r\n"
            guard await write(Data(head.utf8)) else { finish(complete: false); return }
            // The viewer closing the tab or seeking away stops the reading too.
            let sent = await writeFile(handle, from: lower, length: upper - lower + 1)
            // Fewer bytes than the Content-Length promised (the file shrank, a read failed): only closing can say so.
            finish(complete: sent == upper - lower + 1)
        }

        /// Writes `length` bytes of a file from `offset` in `chunk`-sized pieces and returns how many were written. The
        /// next piece is read while the last one is being sent, so a slow drive and the network overlap instead of taking
        /// turns. Stops at the end of the file, a failed read, or when the device goes away.
        /// `pause`: seconds to wait after each piece (Send to iPhone's slow-download test hook).
        func writeFile(_ handle: FileHandle, from offset: Int64, length: Int64, chunk: Int = 1 << 20,
                       pause: (@Sendable (Int) -> Double)? = nil) async -> Int64 {
            let fd = handle.fileDescriptor
            @Sendable func read(_ at: Int64, _ count: Int64) -> Data {
                guard count > 0 else { return Data() }
                var data = Data(count: Int(count))
                let got = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(count), off_t(at)) }
                guard got > 0 else { return Data() }
                if got < count { data.count = got }
                return data
            }
            var written: Int64 = 0
            var next = read(offset, min(length, Int64(chunk)))
            while !next.isEmpty {
                let piece = next
                let following = offset + written + Int64(piece.count)
                let left = length - written - Int64(piece.count)
                // Read ahead while this piece goes out.
                async let ahead = read(following, min(left, Int64(chunk)))
                let ok = await write(piece)
                next = await ahead
                guard ok else { break }
                written += Int64(piece.count)
                if let pause, case let wait = pause(piece.count), wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            }
            return written
        }

        func redirect(to location: String) async {
            await send(status: 302, contentType: "text/plain", body: Data(), headers: ["Location": location])
        }

        /// Server-sent events: the body stays open until `finish()`.
        func startEventStream() async {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\n"
                + connectionHeaders(close: true) + "X-Accel-Buffering: no\r\n" + extraHeaderLines + "\r\n"
            await write(Data(head.utf8))
        }

        /// False once the other end has gone away, so callers can stop producing the rest of the answer.
        @discardableResult
        func event(_ name: String, _ payload: Any) async -> Bool {
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])) ?? Data("null".utf8)
            return await write(Data("event: \(name)\ndata: ".utf8) + data + Data("\n\n".utf8))
        }

        /// False once the other end has gone away.
        @discardableResult
        func write(_ data: Data) async -> Bool {
            // A device that stops reading would hold its connection forever; after a minute with no progress, close it.
            let sent = Arrived()
            let connection = self.connection
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 60) { if !sent.value { connection.cancel() } }
            let ok = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                connection.send(content: data, completion: .contentProcessed { error in
                    sent.value = true
                    done.resume(returning: error == nil)
                })
            }
            if ok, let onBytes {
                unreported += Int64(data.count)
                // Reported at most twice a second (each report is a hop to the main thread), and at the end. By size
                // alone, a fast download woke the main thread dozens of times a second.
                if unreported >= 2 << 20, -reportedAt.timeIntervalSinceNow >= 0.5 {
                    onBytes(unreported); unreported = 0; reportedAt = Date()
                }
            }
            return ok
        }

        /// Switches this connection to a WebSocket (RFC 6455), for the one route that streams games. Answers 400 and
        /// returns nil when the request isn't a valid upgrade. The caller has already checked sign-in, Host and Origin.
        ///
        /// Timeouts after the switch: the 30-second request timeout no longer applies (the request has arrived); a send
        /// that makes no progress for 60 seconds still closes the connection, but only while a send is waiting (see
        /// WebSocket). An idle socket is closed when the device stops checking in.
        func upgradeToWebSocket(_ request: Request) async -> WebSocket? {
            let headers = request.headers
            guard request.method == "GET",
                  headers["upgrade"]?.lowercased().contains("websocket") == true,
                  headers["connection"]?.lowercased().split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "upgrade" }) == true,
                  headers["sec-websocket-version"] == "13",
                  let key = headers["sec-websocket-key"], Data(base64Encoded: key)?.count == 16 else {
                await send(status: 400, text: "Expected a WebSocket upgrade.")
                return nil
            }
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            finished = true   // the connection now belongs to the WebSocket
            keepAlive = false
            let sent = await write(Data(head.utf8))
            // The HTTP response is over either way: report it (Connected Devices counts open requests by it).
            if unreported > 0 { onBytes?(unreported); unreported = 0 }
            onFinish?()
            guard sent else { connection.cancel(); return nil }
            return WebSocket(connection)
        }

        /// Ends the response. On a connection that stays open, the server then reads the device's next request; otherwise
        /// the connection closes once everything written has gone out. `complete: false` when the body came up short
        /// of its Content-Length, which forces a close.
        func finish(complete: Bool = true) {
            guard !finished else { return }
            finished = true
            if !complete { keepAlive = false }
            if unreported > 0 { onBytes?(unreported); unreported = 0 }
            onFinish?()
            if keepAlive, let onReuse {
                self.onReuse = nil
                onReuse()
                return
            }
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }

        static func reason(_ status: Int) -> String {
            switch status {
            case 200: "OK"
            case 101: "Switching Protocols"
            case 206: "Partial Content"
            case 302: "Found"
            case 304: "Not Modified"
            case 400: "Bad Request"
            case 401: "Unauthorized"
            case 403: "Forbidden"
            case 404: "Not Found"
            case 413: "Payload Too Large"
            case 416: "Range Not Satisfiable"
            case 421: "Misdirected Request"
            case 422: "Unprocessable Content"
            case 429: "Too Many Requests"
            case 503: "Service Unavailable"
            default: "Error"
            }
        }
    }

    typealias Handler = @Sendable (Request, Responder) async -> Void

    // MARK: Conditional requests

    private static let httpDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    /// "Sat, 21 Nov 2026 17:00:00 GMT"
    static func httpDate(_ date: Date) -> String { httpDateFormatter.string(from: date) }

    /// True when the device's copy is still current: its If-None-Match lists this ETag, or (with no ETag sent) its
    /// If-Modified-Since is not older than the file.
    static func isNotModified(_ headers: [String: String], etag: String, modified: Date) -> Bool {
        if let match = headers["if-none-match"] {
            return match == "*" || match.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces) == etag || $0.trimmingCharacters(in: .whitespaces) == "W/" + etag }
        }
        if let since = headers["if-modified-since"], let date = httpDateFormatter.date(from: since) {
            return modified.timeIntervalSince1970.rounded(.down) <= date.timeIntervalSince1970
        }
        return false
    }

    private let queue = DispatchQueue(label: "OfflineKit.WebServer")
    private var listener: NWListener?
    private let handler: Handler
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) { self.handler = handler }

    /// Starts on the first free port in `ports`. Advertises over Bonjour as "_http._tcp".
    /// With no service name, it isn't advertised.
    /// `preferred` (the port used last time) is tried first, so phone bookmarks keep working across relaunches.
    func start(ports: ClosedRange<UInt16>, preferred: UInt16? = nil, serviceName: String?, onState: @escaping @Sendable (String?) -> Void) throws {
        var lastError: Error?
        var order = Array(ports)
        if let preferred, let at = order.firstIndex(of: preferred) { order.remove(at: at); order.insert(preferred, at: 0) }
        for candidate in order where Self.isPortFree(candidate) {
            do {
                // No Nagle delay: small writes (game sound chunks, WebSocket pongs, short JSON) go out at once instead of
                // waiting to be batched, which added tens of milliseconds to streamed games.
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                let params = NWParameters(tls: nil, tcp: tcp)
                // Lets the server take back its port while the last run's connections are still winding down.
                // isPortFree has already made sure no other program is listening on it.
                params.allowLocalEndpointReuse = true
                // Wi-Fi, Ethernet and this Mac only: not VPN tunnels, which can reach well beyond the home.
                params.prohibitedInterfaceTypes = [.other, .cellular]
                let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: candidate)!)
                // The TXT record lets the Apple TV app tell Offline Kit apart from other web servers on the network.
                if let serviceName {
                    let txt = NWTXTRecord(["app": "offlinekit", "v": "1", "name": String((Host.current().localizedName ?? "Mac").prefix(60))])
                    listener.service = NWListener.Service(name: serviceName, type: "_http._tcp", domain: nil, txtRecord: txt)
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready: onState(nil)
                    case .failed(let error): onState(error.localizedDescription)
                    default: break
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
                port = candidate
                return
            } catch {
                lastError = error
            }
        }
        throw lastError ?? NWError.posix(.EADDRINUSE)
    }

    /// True if nothing else is listening on this TCP port (IPv4 or IPv6).
    /// Whether the port can be used. A port whose only users are connections from the last run winding down
    /// (TIME_WAIT, after a quick quit and relaunch) counts as free, so phone bookmarks keep working; a port another
    /// program is listening on, even on one address only, never does.
    static func isPortFree(_ port: UInt16) -> Bool {
        if canBind(port, AF_INET, reuse: false) && canBind(port, AF_INET6, reuse: false) { return true }
        return canBind(port, AF_INET, reuse: true) && canBind(port, AF_INET6, reuse: true)
            && !answers(port, AF_INET) && !answers(port, AF_INET6)
    }

    private static func canBind(_ port: UInt16, _ family: Int32, reuse: Bool) -> Bool {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return true }   // family unsupported: don't block on it
        defer { close(fd) }
        if reuse {
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        }
        return withAddress(port, family, loopback: false) { bind(fd, $0, $1) == 0 }
    }

    /// True when something is listening on this port on this Mac's own loopback address.
    private static func answers(_ port: UInt16, _ family: Int32) -> Bool {
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withAddress(port, family, loopback: true) { connect(fd, $0, $1) == 0 }
    }

    private static func withAddress(_ port: UInt16, _ family: Int32, loopback: Bool,
                                    _ body: (UnsafePointer<sockaddr>, socklen_t) -> Bool) -> Bool {
        if family == AF_INET6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_addr = loopback ? in6addr_loopback : in6addr_any
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: loopback ? inet_addr("127.0.0.1") : INADDR_ANY)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        let remote: String = {
            if case .hostPort(let host, _) = connection.endpoint { return "\(host)" }
            return ""
        }()
        // Home network only: refuse anything that isn't a private, link-local or loopback address.
        guard Self.isLocal(remote) else {
            connection.cancel()
            return
        }
        // A cap on open connections, overall and per device, so one device can't tie up the server for everyone.
        let device = ShareDeviceKey.key(remote)
        guard openConnections < 48, connectionsByDevice[device, default: 0] < 16 else { connection.cancel(); return }
        openConnections += 1
        connectionsByDevice[device, default: 0] += 1
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed: connection?.cancel()   // counted once, when it reaches .cancelled
            case .cancelled:
                guard let self else { return }
                self.openConnections -= 1
                let left = self.connectionsByDevice[device, default: 1] - 1
                self.connectionsByDevice[device] = left > 0 ? left : nil
            default: break
            }
        }
        connection.start(queue: queue)
        nextRequest(connection, buffer: Data(), remote: remote, served: 0)
    }

    private final class Arrived: @unchecked Sendable { var value = false }
    /// Changed only on `queue`, where connections are accepted and report their state.
    private var openConnections = 0
    private var connectionsByDevice: [String: Int] = [:]

    /// Most requests one connection carries before it closes (a device then opens a fresh one).
    static let maxRequests = 100
    /// How long an open connection waits for the device's next request.
    static let idleTimeout: TimeInterval = 8

    /// Waits for the next request on a connection. A device gets 30 seconds to send each request in full, so slow or
    /// stalled connections can't pile up; between requests, a connection with nothing new for `idleTimeout` closes.
    /// `buffer` holds bytes that arrived after the last request (a device that sent its next request early).
    private func nextRequest(_ connection: NWConnection, buffer: Data, remote: String, served: Int) {
        let arrived = Arrived(), started = Arrived()
        started.value = !buffer.isEmpty
        queue.asyncAfter(deadline: .now() + 30) { if !arrived.value { connection.cancel() } }
        if served > 0 {
            queue.asyncAfter(deadline: .now() + Self.idleTimeout) { if !started.value { connection.cancel() } }
        }
        process(connection, buffer: buffer, remote: remote, served: served, arrived: arrived, started: started)
    }

    private func process(_ connection: NWConnection, buffer: Data, remote: String, served: Int, arrived: Arrived, started: Arrived) {
        if let (request, used) = Self.parseRequest(buffer, remote: remote) {
            arrived.value = true
            started.value = true
            let rest = buffer.count > used ? Data(buffer.suffix(from: buffer.startIndex + used)) : Data()
            let keep = request.keepAlive && served + 1 < Self.maxRequests
            let gzip = (request.headers["accept-encoding"] ?? "").lowercased().split(separator: ",")
                .contains { Self.acceptsGzip(String($0)) }
            let responder = Responder(connection, keepAlive: keep, remaining: Self.maxRequests - served - 1, acceptsGzip: gzip)
            if keep {
                responder.onReuse = { [weak self] in
                    guard let self else { connection.cancel(); return }
                    self.queue.async { self.nextRequest(connection, buffer: rest, remote: remote, served: served + 1) }
                }
            }
            let handler = self.handler
            Task { await handler(request, responder) }
            return
        }
        if buffer.count > 256 * 1024 { connection.cancel(); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data, !data.isEmpty { buffer.append(data); started.value = true }
            if error != nil { connection.cancel(); return }
            if isComplete && Self.parseRequest(buffer, remote: remote) == nil { connection.cancel(); return }
            self.process(connection, buffer: buffer, remote: remote, served: served, arrived: arrived, started: started)
        }
    }

    /// Returns a request once headers and the full body have arrived.
    static func parse(_ data: Data, remote: String) -> Request? { parseRequest(data, remote: remote)?.request }

    /// A request once its headers and full body have arrived, and how many bytes of `data` it took up.
    static func parseRequest(_ data: Data, remote: String) -> (request: Request, used: Int)? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let length = Int(headers["content-length"] ?? "0"), (0...256 * 1024).contains(length) else { return nil }
        let bodyStart = end.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let body = data[bodyStart..<(bodyStart + length)]
        let used = bodyStart + length - data.startIndex

        let target = String(parts[1])
        let pieces = target.split(separator: "?", maxSplits: 1).map(String.init)
        let rawPath = pieces.first ?? "/"
        var query: [String: String] = [:]
        if pieces.count > 1 {
            for pair in pieces[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map {
                    String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                }
                guard let key = kv.first, !key.isEmpty else { continue }
                query[key] = kv.count > 1 ? kv[1] : ""
            }
        }
        // Another request may follow only on HTTP/1.1 without "Connection: close", and only when this one's end is known:
        // a chunked body (which this server doesn't read) or a HEAD request (answered with a body) closes the connection.
        let tokens = (headers["connection"] ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let keepAlive = parts.count >= 3 && parts[2] == "HTTP/1.1" && !tokens.contains("close")
            && headers["transfer-encoding"] == nil && parts[0] != "HEAD"
        let request = Request(method: String(parts[0]), path: rawPath.removingPercentEncoding ?? rawPath, rawPath: rawPath,
                              rawQuery: pieces.count > 1 ? pieces[1] : nil,
                              query: query, headers: headers, body: Data(body), remoteHost: remote, keepAlive: keepAlive)
        return (request, used)
    }

    /// A header value with no line breaks. Filtered by Unicode scalar: Swift treats "\r\n" as one Character,
    /// so a Character filter for "\r" and "\n" would let the pair through and allow a header of its own.
    nonisolated static func headerSafe(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.filter { $0 != "\r" && $0 != "\n" }))
    }

    /// One Accept-Encoding entry: gzip, unless it carries q=0 ("gzip;q=0.5" still accepts it).
    nonisolated static func acceptsGzip(_ entry: String) -> Bool {
        let parts = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard parts.first == "gzip" else { return false }
        for part in parts.dropFirst() where part.hasPrefix("q=") {
            return (Double(part.dropFirst(2)) ?? 1) > 0
        }
        return true
    }

    static func isLocal(_ host: String) -> Bool {
        let h = host.split(separator: "%").first.map(String.init) ?? host   // drop IPv6 zone
        if h == "::1" || h.hasPrefix("127.") || h.hasPrefix("10.") || h.hasPrefix("192.168.") || h.hasPrefix("169.254.") { return true }
        if h.lowercased().hasPrefix("fe80:") || h.lowercased().hasPrefix("fd") || h.lowercased().hasPrefix("fc") { return true }
        if h.hasPrefix("::ffff:") { return isLocal(String(h.dropFirst(7))) }
        if h.hasPrefix("172."), let second = Int(h.split(separator: ".")[1]), (16...31).contains(second) { return true }
        return false
    }
}

enum ShareDeviceKey {
    /// One key per device address, for counting wrong PINs and open connections. Not grouped by IPv6 network:
    /// every device on a home network shares the router's /64. Address-hopping is covered by the overall limits.
    nonisolated static func key(_ host: String) -> String {
        let address = (host.split(separator: "%").first.map(String.init) ?? host).lowercased()
        if address.hasPrefix("::ffff:"), address.contains(".") { return String(address.dropFirst(7)) }   // IPv4 as IPv6
        return address
    }
}

/// Gzip for text responses (the page, scripts, JSON). Responses with an ETag are compressed once and the result kept,
/// so the page, play.js and an unchanged media list aren't compressed again for every device.
enum Gzip {
    /// Smaller bodies gain too little to be worth it.
    static let minimumSize = 1024

    /// Text types only: media, images (other than SVG), PDFs and archives are already compressed or are streamed by range.
    static func isCompressible(_ contentType: String) -> Bool {
        let type = contentType.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
        if type == "text/event-stream" { return false }
        return type.hasPrefix("text/") || type == "application/json" || type == "application/javascript"
            || type == "application/manifest+json" || type == "image/svg+xml" || type == "application/xhtml+xml"
            || type == "application/xml"
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [String: (data: Data, used: UInt64)] = [:]
        var bytes = 0
        var clock: UInt64 = 0
    }
    private static let cache = Cache()
    private static let cacheLimit = 16 << 20

    /// The gzip form of `data`, or nil if it couldn't be made (or wouldn't be smaller). `key` (an ETag plus the type)
    /// names content that never changes under that key: its compressed form is kept, least recently used dropped first.
    static func compress(_ data: Data, key: String?) -> Data? {
        let key = key.map { "\($0)|\(data.count)" }
        if let key {
            cache.lock.lock()
            defer { cache.lock.unlock() }
            if let hit = cache.entries[key] {
                cache.clock += 1
                cache.entries[key]?.used = cache.clock
                return hit.data
            }
        }
        guard let packed = deflate(data), packed.count < data.count else { return nil }
        if let key, packed.count < cacheLimit / 4 {
            cache.lock.lock()
            defer { cache.lock.unlock() }
            cache.clock += 1
            if cache.entries[key] == nil { cache.bytes += packed.count }
            cache.entries[key] = (packed, cache.clock)
            while cache.bytes > cacheLimit, let oldest = cache.entries.min(by: { $0.value.used < $1.value.used }) {
                cache.bytes -= oldest.value.data.count
                cache.entries[oldest.key] = nil
            }
        }
        return packed
    }

    /// zlib, with the gzip wrapper (window bits 15 + 16).
    static func deflate(_ data: Data, level: Int32 = 6) -> Data? {
        var stream = z_stream()
        guard deflateInit2_(&stream, level, Z_DEFLATED, 15 + 16, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { deflateEnd(&stream) }
        let bound = Int(deflateBound(&stream, uLong(data.count)))
        var out = Data(count: bound)
        let status = data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Int32 in
            out.withUnsafeMutableBytes { (output: UnsafeMutableRawBufferPointer) -> Int32 in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(output.count)
                return zlib.deflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END else { return nil }
        out.count = Int(stream.total_out)
        return out
    }
}
