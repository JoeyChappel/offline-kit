import Foundation
import Darwin

/// The Wi-Fi/Ethernet hardware (MAC) address behind a client's IP, read from this Mac's own neighbor tables: the
/// IPv4 link-layer routes (what `arp -an` shows) and the IPv6 neighbor cache (what `ndp -an` shows). No root needed.
///
/// Only devices on the same network segment have one; loopback, this Mac's own addresses and anything reached
/// through a router don't. Phones use a private Wi-Fi address per network, so it is stable on this network unless
/// the person turns on rotating addresses or resets it.
actor NeighborTable {
    static let shared = NeighborTable()

    private var table: [String: String] = [:]
    private var readAt = Date.distantPast
    private var locals: Set<String> = []

    /// The hardware address for an IP ("aa:bb:cc:dd:ee:ff"), or nil. The table is read again every 30 seconds, and at
    /// most every 2 seconds when an address isn't in it yet (a device that has only just joined).
    func mac(for host: String) -> String? {
        guard let ip = Self.normalize(host) else { return nil }
        let age = -readAt.timeIntervalSinceNow
        if age > 30 || (table[ip] == nil && age > 2) { refresh() }
        return table[ip]
    }

    /// True for loopback and this Mac's own addresses: a browser on this Mac.
    func isThisMac(_ host: String) -> Bool {
        guard let ip = Self.normalize(host) else { return false }
        if ip == "::1" || ip.hasPrefix("127.") { return true }
        if -readAt.timeIntervalSinceNow > 30 { refresh() }
        return locals.contains(ip)
    }

    private func refresh() {
        table = Self.read()
        locals = Self.localAddresses()
        readAt = Date()
    }

    /// "fe80::1%en0", "::ffff:192.168.1.5", "192.168.1.5" → the address in one canonical spelling.
    nonisolated static func normalize(_ host: String) -> String? {
        var text = (host.split(separator: "%").first.map(String.init) ?? host).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if text.lowercased().hasPrefix("::ffff:"), text.contains(".") { text = String(text.dropFirst(7)) }
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return ntop(v4) }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return ntop(v6) }
        return nil
    }

    nonisolated private static func ntop(_ addr: in_addr) -> String {
        var a = addr
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return inet_ntop(AF_INET, &a, &buffer, socklen_t(buffer.count)).map { String(cString: $0) } ?? ""
    }

    nonisolated private static func ntop(_ addr: in6_addr) -> String {
        var a = addr
        var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return inet_ntop(AF_INET6, &a, &buffer, socklen_t(buffer.count)).map { String(cString: $0) } ?? ""
    }

    /// Every IP → MAC pair in the IPv4 and IPv6 neighbor tables, from sysctl route dumps of link-layer entries: each
    /// message is a header, then a destination address and a link-layer gateway address.
    ///
    /// NET_RT_FLAGS/RTF_LLINFO is what `arp`/`ndp` have long used; newer macOS answers it with nothing for IPv4 and
    /// keeps those entries in NET_RT_DUMPX_FLAGS, whose messages carry a longer header (`rt_msghdr_ext`).
    nonisolated static func read() -> [String: String] {
        var out: [String: String] = [:]
        for family in [AF_INET, AF_INET6] {
            for operation in [NET_RT_FLAGS, netRtDumpxFlags] {
                let found = dump(family: family, operation: operation)
                out.merge(found) { first, _ in first }
                if !found.isEmpty { break }
            }
        }
        return out
    }

    /// NET_RT_DUMPX_FLAGS (sys/socket.h, not exported to Swift).
    nonisolated private static let netRtDumpxFlags: Int32 = 8
    /// RTM_GET_EXT: a message with the extended header.
    nonisolated private static let rtmGetExt: UInt8 = 0x15
    /// sizeof(struct rt_msghdr_ext), and where its rtm_addrs field sits.
    nonisolated private static let extHeaderSize = 136
    nonisolated private static let extAddrsOffset = 16

    nonisolated private static func dump(family: Int32, operation: Int32) -> [String: String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, operation, RTF_LLINFO]
        var length = 0
        var buffer: [UInt8] = []
        var read = false
        // The table can grow between asking its size and reading it: ask again with more room.
        for _ in 0..<4 {
            guard sysctl(&mib, 6, nil, &length, nil, 0) == 0, length > 0 else { break }
            length += length / 8 + 4096
            buffer = [UInt8](repeating: 0, count: length)
            if sysctl(&mib, 6, &buffer, &length, nil, 0) == 0 { read = true; break }
            guard errno == ENOMEM else { break }
        }
        guard read else { return [:] }
        var out: [String: String] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + 4 <= length {
                let size = Int(raw[offset]) | Int(raw[offset + 1]) << 8
                guard size >= 4, offset + size <= length else { break }
                defer { offset += size }
                let extended = raw[offset + 3] == rtmGetExt
                let header = extended ? extHeaderSize : MemoryLayout<rt_msghdr>.size
                guard size > header else { continue }
                let addrs = extended ? Int32(raw.loadUnaligned(fromByteOffset: offset + extAddrsOffset, as: UInt32.self))
                                     : raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self).rtm_addrs
                guard addrs & RTA_DST != 0, addrs & RTA_GATEWAY != 0 else { continue }
                // The destination, then the gateway, each padded to a 4-byte boundary.
                var at = offset + header
                let end = offset + size
                guard at + 2 <= end else { continue }
                let dstLength = Int(raw[at]), dstFamily = Int32(raw[at + 1])
                var ip: String?
                if dstFamily == AF_INET, dstLength >= MemoryLayout<sockaddr_in>.size, at + dstLength <= end {
                    ip = ntop(raw.loadUnaligned(fromByteOffset: at, as: sockaddr_in.self).sin_addr)
                } else if dstFamily == AF_INET6, dstLength >= MemoryLayout<sockaddr_in6>.size, at + dstLength <= end {
                    var addr = raw.loadUnaligned(fromByteOffset: at, as: sockaddr_in6.self).sin6_addr
                    // The kernel keeps a link-local address's interface in bytes 2-3; clear it to match what clients see.
                    withUnsafeMutableBytes(of: &addr) { bytes in
                        if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { bytes[2] = 0; bytes[3] = 0 }
                    }
                    ip = ntop(addr)
                }
                at += dstLength > 0 ? 1 + ((dstLength - 1) | 3) : 4
                guard let ip, at + 8 <= end, Int32(raw[at + 1]) == AF_LINK else { continue }
                let nameLength = Int(raw[at + 5]), addressLength = Int(raw[at + 6])
                let start = at + 8 + nameLength
                guard addressLength == 6, start + 6 <= end else { continue }
                let bytes = (0..<6).map { raw[start + $0] }
                // Incomplete entries are all zeros; broadcast and multicast aren't a device.
                guard bytes.contains(where: { $0 != 0 }), bytes[0] & 1 == 0 else { continue }
                out[ip] = bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
            }
        }
        return out
    }

    /// This Mac's own IPv4 and IPv6 addresses.
    nonisolated static func localAddresses() -> Set<String> {
        var result = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr else { continue }
            if addr.pointee.sa_family == UInt8(AF_INET) {
                result.insert(ntop(addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }))
            } else if addr.pointee.sa_family == UInt8(AF_INET6) {
                var a = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
                withUnsafeMutableBytes(of: &a) { bytes in
                    if bytes[0] == 0xfe, bytes[1] & 0xc0 == 0x80 { bytes[2] = 0; bytes[3] = 0 }
                }
                result.insert(ntop(a))
            }
        }
        return result
    }
}
