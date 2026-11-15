import Foundation

/// Whether apelin_web_fetch may send a request to a host, by what its name
/// or address says: a local name, or a literal loopback, link-local,
/// private, shared (CGNAT), multicast or reserved address, is refused, in
/// whatever form the resolver also reads (`2130706433` and `127.1` are
/// 127.0.0.1, `::ffff:10.0.0.1` is 10.0.0.1). A name that resolves to such
/// an address is not caught: URLSession cannot be held to the address
/// checked here.
enum PublicHost {
    /// Why `host` is not a public host, as a clause; nil for one that is.
    static func refusal(_ host: String) -> String? {
        var name = host.lowercased()
        if name.hasSuffix(".") {
            name.removeLast()
        }
        if let address = ipv4(name) {
            return ipv4Refusal(address).map { "\(host) is \($0)" }
        }
        if let address = ipv6(name) {
            return ipv6Refusal(address).map { "\(host) is \($0)" }
        }
        if name == "localhost" || name.hasSuffix(".localhost") {
            return "\(host) is this device"
        }
        if !name.contains(".") || localSuffixes.contains(where: { name.hasSuffix($0) }) {
            return "\(host) is a name on the local network"
        }
        return nil
    }

    /// mDNS, and the names reserved for private networks.
    private static let localSuffixes = [".local", ".internal", ".home.arpa"]

    private static let refusedIPv4: [(network: UInt32, bits: UInt32, what: String)] = [
        (0x0000_0000, 8, "this network's address"),
        (0x0A00_0000, 8, "a private network address"),
        (0x6440_0000, 10, "a shared (CGNAT) address"),
        (0x7F00_0000, 8, "this device (loopback)"),
        (0xA9FE_0000, 16, "a link-local address"),
        (0xAC10_0000, 12, "a private network address"),
        (0xC0A8_0000, 16, "a private network address"),
        (0xE000_0000, 4, "a multicast address"),
        (0xF000_0000, 4, "a reserved address"),
    ]

    private static func ipv4Refusal(_ address: UInt32) -> String? {
        refusedIPv4.first { address >> (32 - $0.bits) == $0.network >> (32 - $0.bits) }?.what
    }

    private static func ipv6Refusal(_ bytes: [UInt8]) -> String? {
        if bytes[0 ..< 15].allSatisfy({ $0 == 0 }), bytes[15] <= 1 {
            return bytes[15] == 1 ? "this device (loopback)" : "an unspecified address"
        }
        // ::a.b.c.d, ::ffff:a.b.c.d and NAT64's 64:ff9b::a.b.c.d reach an
        // IPv4 address, judged as that address.
        let compatible = bytes[0 ..< 12].allSatisfy { $0 == 0 }
        let mapped = bytes[0 ..< 10].allSatisfy { $0 == 0 } && bytes[10] == 0xFF && bytes[11] == 0xFF
        let translated = bytes[0 ..< 12].elementsEqual([0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0])
        if compatible || mapped || translated {
            return ipv4Refusal(bytes[12 ..< 16].reduce(0) { $0 << 8 | UInt32($1) })
        }
        if bytes[0] == 0xFF {
            return "a multicast address"
        }
        if bytes[0] & 0xFE == 0xFC {
            return "a private network address" // fc00::/7
        }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 {
            return "a link-local address" // fe80::/10
        }
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0xC0 {
            return "a site-local address" // fec0::/10
        }
        return nil
    }

    /// A literal IPv4 address in any form inet_aton reads, as the resolver
    /// reads them too.
    private static func ipv4(_ name: String) -> UInt32? {
        var address = in_addr()
        guard inet_aton(name, &address) == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    /// A literal IPv6 address, its zone (`%en0`) left off.
    private static func ipv6(_ name: String) -> [UInt8]? {
        let literal = name.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? name
        var address = in6_addr()
        guard inet_pton(AF_INET6, literal, &address) == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0) }
    }
}
