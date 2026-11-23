import Darwin
import Foundation

/// Finds this Mac's address on the Tailscale network.
///
/// Tailscale gives every device a private address in 100.64.0.0/10 on a `utun` interface. That range is
/// reserved for carrier-grade NAT and is never routed on the public internet, so a server bound to that one
/// address can only be reached by devices signed in to the same tailnet. Jarvis's remote API listens there
/// and nowhere else: never on 0.0.0.0, never on the Wi-Fi address.
public enum Tailnet {
    public struct Address: Equatable, Sendable {
        public var interface: String
        public var ip: String
        public init(interface: String, ip: String) { self.interface = interface; self.ip = ip }
    }

    static func octets(_ ip: String) -> [UInt8]? {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let o = parts.compactMap { $0.allSatisfy(\.isNumber) ? UInt8($0) : nil }
        return o.count == 4 ? o : nil
    }

    /// True for 100.64.0.0 – 100.127.255.255.
    public static func isTailscaleIPv4(_ ip: String) -> Bool {
        guard let o = octets(ip) else { return false }
        return o[0] == 100 && (o[1] & 0xC0) == 64
    }

    public static func isLoopback(_ ip: String) -> Bool {
        if ip == "::1" { return true }
        guard let o = octets(ip) else { return false }
        return o[0] == 127
    }

    /// The Tailscale address among a machine's interfaces: a tunnel interface with an address in the range.
    /// A phone carrier or another VPN can use the same range on other interface kinds; those are ignored.
    public static func pick(from all: [Address]) -> Address? {
        all.first { $0.interface.hasPrefix("utun") && isTailscaleIPv4($0.ip) }
    }

    /// Every IPv4 address on an interface that is up.
    public static func interfaceAddresses() -> [Address] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [Address] = []
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (Int32(a.ifa_flags) & IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            out.append(Address(interface: String(cString: a.ifa_name), ip: String(cString: host)))
        }
        return out
    }

    /// This Mac's Tailscale address right now, or nil when Tailscale is off or not installed.
    public static var current: Address? { pick(from: interfaceAddresses()) }
}
