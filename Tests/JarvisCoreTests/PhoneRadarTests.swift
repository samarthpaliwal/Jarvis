import XCTest
@testable import JarvisCore

final class PresenceTrackerTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 2_000_000)
    func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testAStrongSignalTwiceIsNearAndOneStrayPacketIsNot() {
        var t = PresenceTracker()
        XCTAssertNil(t.sighting(rssi: -50, at: at(0)))
        XCTAssertEqual(t.state, .unknown)
        XCTAssertEqual(t.sighting(rssi: -52, at: at(1)), .near)
        XCTAssertNil(t.sighting(rssi: -51, at: at(2)), "already near: no second announcement")
    }

    func testWalkingOutOfRangeIsAwayAfterAWhileNotAtOnce() {
        var t = PresenceTracker()
        _ = t.sighting(rssi: -50, at: at(0)); _ = t.sighting(rssi: -50, at: at(1))
        var changes: [PresenceTracker.State] = []
        for s in stride(from: 2.0, through: 80, by: 2) {            // the signal fades to very weak and stays there
            if let c = t.sighting(rssi: -95, at: at(s)) { changes.append(c) }
        }
        XCTAssertEqual(changes, [.away])
        XCTAssertEqual(t.state, .away)
    }

    func testSilenceIsAwayToo() {
        var t = PresenceTracker()
        _ = t.sighting(rssi: -50, at: at(0)); _ = t.sighting(rssi: -50, at: at(1))
        XCTAssertNil(t.tick(at: at(60)))
        XCTAssertEqual(t.tick(at: at(91)), .away)
        XCTAssertNil(t.tick(at: at(200)), "said once")
    }

    func testTheEdgeOfTheRoomDoesNotFlap() {
        var t = PresenceTracker()
        _ = t.sighting(rssi: -60, at: at(0)); _ = t.sighting(rssi: -60, at: at(1))
        var changes = 0
        for (i, r) in [-78.0, -70, -80, -74, -79, -71, -82, -76, -80, -73].enumerated() {   // between the two thresholds
            if t.sighting(rssi: r, at: at(Double(2 + i * 5))) != nil { changes += 1 }
        }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(t.state, .near)
    }

    func testComingBackIsNearAgain() {
        var t = PresenceTracker()
        _ = t.sighting(rssi: -50, at: at(0)); _ = t.sighting(rssi: -50, at: at(1))
        _ = t.tick(at: at(100))
        XCTAssertEqual(t.state, .away)
        XCTAssertNil(t.sighting(rssi: -60, at: at(500)))
        XCTAssertEqual(t.sighting(rssi: -58, at: at(501)), .near)
    }

    func testAPhoneNeverHeardStaysUnknownAndNonsenseReadingsAreIgnored() {
        var t = PresenceTracker()
        XCTAssertNil(t.tick(at: at(1000)))
        XCTAssertEqual(t.state, .unknown)
        XCTAssertNil(t.sighting(rssi: 127, at: at(1001)))
        XCTAssertNil(t.smoothed)
    }

    func testDistanceWords() {
        XCTAssertEqual(PresenceTracker.describe(rssi: -45), "right here")
        XCTAssertEqual(PresenceTracker.describe(rssi: -68), "about 2 m away")
        XCTAssertTrue(PresenceTracker.describe(rssi: -80).hasPrefix("in the next room"))
        XCTAssertEqual(PresenceTracker.describe(rssi: -95), "far (10 m or more)")
    }

    func testChoosingThePhoneTakesTheClosestRecentAppleDevice() {
        let now = t0
        func s(_ name: String, _ rssi: Double, apple: Bool = true, age: TimeInterval = 1) -> BluetoothSighting {
            BluetoothSighting(id: UUID(), name: name, rssi: rssi, isApple: apple, at: now.addingTimeInterval(-age))
        }
        let list = [s("TV", -30, apple: false), s("iPhone", -38), s("AirPods", -60), s("Old iPad", -20, age: 30)]
        XCTAssertEqual(PhoneRadar.closest(list, now: now)?.name, "iPhone")
        XCTAssertNil(PhoneRadar.closest([s("Far iPhone", -70)], now: now), "it has to be held against the Mac")
    }
}
