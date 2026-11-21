import Foundation
import Network

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

        func send(status: Int, contentType: String, body: Data, headers: [String: String] = [:]) async {
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\n"
            head += "Connection: close\r\nX-Content-Type-Options: nosniff\r\n"
            if headers["Cache-Control"] == nil { head += "Cache-Control: no-store\r\n" }
            for (k, v) in headers { head += "\(k): \(v)\r\n" }
            head += "\r\n"
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
        func sendFile(_ link: URL, contentType: String, rangeHeader: String?) async {
            // Follow aliases and symlinks, or the size would be the link's own few bytes.
            let url = link.resolvingSymlinksInPath()
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let total = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init), total > 0 else {
                await send(status: 404, text: "Not found"); return
            }
            defer { try? handle.close() }
            var lower: Int64 = 0, upper = total - 1, status = 200
            if let range = ByteRange(header: rangeHeader, total: Int(total)) {
                lower = Int64(range.lower); upper = Int64(range.upper); status = 206
                let openEnded = rangeHeader?.hasSuffix("-") == true
                if openEnded { upper = min(upper, lower + 16 * 1024 * 1024 - 1) }
            }
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\nContent-Type: \(contentType)\r\nContent-Length: \(upper - lower + 1)\r\n"
            head += "Accept-Ranges: bytes\r\nConnection: close\r\nCache-Control: no-store\r\n"
            if status == 206 { head += "Content-Range: bytes \(lower)-\(upper)/\(total)\r\n" }
            head += "\r\n"
            await write(Data(head.utf8))
            do {
                try handle.seek(toOffset: UInt64(lower))
                var remaining = upper - lower + 1
                while remaining > 0 {
                    let chunk = try handle.read(upToCount: Int(min(remaining, 1 << 20))) ?? Data()
                    if chunk.isEmpty { break }
                    await write(chunk)
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
            let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\nX-Accel-Buffering: no\r\n\r\n"
            await write(Data(head.utf8))
        }

        func event(_ name: String, _ payload: Any) async {
            let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.fragmentsAllowed])) ?? Data("null".utf8)
            await write(Data("event: \(name)\ndata: ".utf8) + data + Data("\n\n".utf8))
        }

        /// False once the other end has gone away.
        @discardableResult
        func write(_ data: Data) async -> Bool {
            await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                connection.send(content: data, completion: .contentProcessed { error in done.resume(returning: error == nil) })
            }
        }

        func finish() {
            guard !finished else { return }
            finished = true
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
                connection.cancel()
            })
        }

        static func reason(_ status: Int) -> String {
            switch status {
            case 200: "OK"
            case 206: "Partial Content"
            case 302: "Found"
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

    private let queue = DispatchQueue(label: "OfflineKit.WebServer")
    private var listener: NWListener?
    private let handler: Handler
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) { self.handler = handler }

    /// Starts on the first free port in `ports`. Advertises over Bonjour as "_http._tcp".
    /// With no service name, it isn't advertised.
    func start(ports: ClosedRange<UInt16>, serviceName: String?, onState: @escaping @Sendable (String?) -> Void) throws {
        var lastError: Error?
        for candidate in ports where Self.isPortFree(candidate) {
            do {
                let params = NWParameters.tcp
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
    static func isPortFree(_ port: UInt16) -> Bool {
        func canBind(_ family: Int32) -> Bool {
            let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
            guard fd >= 0 else { return true }   // family unsupported: don't block on it
            defer { close(fd) }
            if family == AF_INET6 {
                var addr = sockaddr_in6()
                addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                addr.sin6_family = sa_family_t(AF_INET6)
                addr.sin6_port = port.bigEndian
                addr.sin6_addr = in6addr_any
                return withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
                }
            }
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr = in_addr(s_addr: INADDR_ANY)
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        }
        return canBind(AF_INET) && canBind(AF_INET6)
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
        // A cap on open connections, so one device can't tie up the server for everyone.
        guard openConnections < 48 else { connection.cancel(); return }
        openConnections += 1
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed: self?.openConnections -= 1
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
