import Foundation
import Network
import CryptoKit

/// A small HTTP/1.1 server on Network.framework. One request per connection (Connection: close),
/// which keeps it simple and is plenty for a household of phones and tablets.
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
        init(_ connection: NWConnection) { self.connection = connection }

        // Connected Devices (ShareDevices): headers added to every response (the device cookie), and the bytes written
        // and the end of the response reported back. Set before the first write.
        var extraHeaders: [(String, String)] = []
        var onBytes: (@Sendable (Int64) -> Void)?
        var onFinish: (@Sendable () -> Void)?
        private var unreported: Int64 = 0
        private var extraHeaderLines: String {
            extraHeaders.map { "\($0.0): \($0.1.filter { $0 != "\r" && $0 != "\n" })\r\n" }.joined()
        }
        deinit { if !finished { onFinish?() } }

        func send(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) async {
            // A type can come from inside an archive: a line break in it must not start a header of its own.
            let contentType = contentType.filter { $0 != "\r" && $0 != "\n" }
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
            head += "Connection: close\r\nX-Content-Type-Options: nosniff\r\n"
            if headers["Cache-Control"] == nil { head += "Cache-Control: no-store\r\n" }
            for (k, v) in headers { head += "\(k): \(v.filter { $0 != "\r" && $0 != "\n" })\r\n" }
            head += extraHeaderLines + "\r\n"
            await write(Data(head.utf8) + body)
            finish()
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
            head += "Accept-Ranges: bytes\r\nConnection: close\r\n"
            if validators.isEmpty { head += "Cache-Control: no-store\r\n" }
            for (k, v) in validators { head += "\(k): \(v)\r\n" }
            if status == 206 { head += "Content-Range: bytes \(lower)-\(upper)/\(total)\r\n" }
            head += extraHeaderLines + "\r\n"
            await write(Data(head.utf8))
            do {
                try handle.seek(toOffset: UInt64(lower))
                var remaining = upper - lower + 1
                while remaining > 0 {
                    let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data()
                    if chunk.isEmpty { break }
                    // The viewer closed the tab or seeked away: stop reading the file for nobody.
                    if !(await write(chunk)) { break }
                    remaining -= Int64(chunk.count)
                }
            } catch {}
            finish()
        }

        func redirect(to location: String) async {
            await send(status: 302, contentType: "text/plain", body: Data(), headers: ["Location": location])
        }

        /// Server-sent events: the body stays open until `finish()`.
        func startEventStream() async {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nX-Accel-Buffering: no\r\n" + extraHeaderLines + "\r\n"
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
                if unreported >= 2 << 20 { onBytes(unreported); unreported = 0 }   // reported every 2 MB, and at the end
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
            guard await write(Data(head.utf8)) else { connection.cancel(); return nil }
            return WebSocket(connection)
        }

        func finish() {
            guard !finished else { return }
            finished = true
            if unreported > 0 { onBytes?(unreported); unreported = 0 }
            onFinish?()
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
                let params = NWParameters.tcp
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
        // A device gets 30 seconds to send its request, so slow or stalled connections can't pile up.
        let arrived = Arrived()
        queue.asyncAfter(deadline: .now() + 30) { if !arrived.value { connection.cancel() } }
        receive(connection, buffer: Data(), remote: remote, arrived: arrived)
    }

    private final class Arrived: @unchecked Sendable { var value = false }
    /// Changed only on `queue`, where connections are accepted and report their state.
    private var openConnections = 0
    private var connectionsByDevice: [String: Int] = [:]

    private func receive(_ connection: NWConnection, buffer: Data, remote: String, arrived: Arrived) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.count > 256 * 1024 || error != nil {
                connection.cancel()
                return
            }
            if let request = Self.parse(buffer, remote: remote) {
                arrived.value = true
                let responder = Responder(connection)
                let handler = self.handler
                Task { await handler(request, responder) }
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer, remote: remote, arrived: arrived)
            }
        }
    }

    /// Returns a request once headers and the full body have arrived.
    static func parse(_ data: Data, remote: String) -> Request? {
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
        return Request(method: String(parts[0]), path: rawPath.removingPercentEncoding ?? rawPath, rawPath: rawPath,
                       rawQuery: pieces.count > 1 ? pieces[1] : nil,
                       query: query, headers: headers, body: Data(body), remoteHost: remote)
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
