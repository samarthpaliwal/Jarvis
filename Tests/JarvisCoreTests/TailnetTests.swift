import XCTest
@testable import JarvisCore

final class TailnetTests: XCTestCase {
    func testOnlyTheTailscaleRangeCounts() {
        for ip in ["100.64.0.1", "100.101.102.103", "100.127.255.254"] { XCTAssertTrue(Tailnet.isTailscaleIPv4(ip), ip) }
        for ip in ["100.63.255.255", "100.128.0.1", "100.0.0.1", "192.168.1.20", "10.0.0.5", "127.0.0.1", "0.0.0.0", "8.8.8.8",
                   "100.64.0", "100.64.0.1.5", "100.64.0.256", "100.64.0.x", "", "fd7a:115c:a1e0::1", " 100.64.0.1", "100.+64.0.1"] {
            XCTAssertFalse(Tailnet.isTailscaleIPv4(ip), ip)
        }
    }

    func testPicksTheTunnelAddressAndNothingElse() {
        let wifi = Tailnet.Address(interface: "en0", ip: "192.168.1.20")
        let lo = Tailnet.Address(interface: "lo0", ip: "127.0.0.1")
        let tail = Tailnet.Address(interface: "utun4", ip: "100.101.102.103")
        XCTAssertEqual(Tailnet.pick(from: [lo, wifi, tail]), tail)
        XCTAssertNil(Tailnet.pick(from: [lo, wifi]), "Tailscale off: there is nothing to bind to, so nothing listens")
        // A carrier or hotspot can hand out the same range on an ordinary interface. That is not the tailnet.
        XCTAssertNil(Tailnet.pick(from: [lo, .init(interface: "en0", ip: "100.72.1.9")]))
        // Another VPN's tunnel with an ordinary private address is not it either.
        XCTAssertNil(Tailnet.pick(from: [.init(interface: "utun2", ip: "10.8.0.2")]))
    }

    func testLoopback() {
        XCTAssertTrue(Tailnet.isLoopback("127.0.0.1")); XCTAssertTrue(Tailnet.isLoopback("127.8.9.1")); XCTAssertTrue(Tailnet.isLoopback("::1"))
        XCTAssertFalse(Tailnet.isLoopback("128.0.0.1")); XCTAssertFalse(Tailnet.isLoopback("100.64.0.1"))
    }

    func testThisMachineHasALoopbackAddress() {
        XCTAssertTrue(Tailnet.interfaceAddresses().contains { $0.interface == "lo0" && $0.ip == "127.0.0.1" })
    }
}
