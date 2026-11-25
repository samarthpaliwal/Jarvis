import XCTest
@testable import JarvisCore

final class CommandTapTests: XCTestCase {
    /// Plays a script of (milliseconds, command down, other modifier, presses so far), sampled every 12 ms
    /// like the real loop, and counts how often the detector fires.
    private func fires(_ steps: [(ms: Int, cmd: Bool, other: Bool, presses: UInt64)], settings: CommandTapDetector.Settings = .init()) -> Int {
        var d = CommandTapDetector(settings: settings)
        var fired = 0, i = 0
        var state = (cmd: false, other: false, presses: UInt64(0))
        let end = (steps.last?.ms ?? 0) + 60
        for t in stride(from: 0, through: end, by: 12) {
            while i < steps.count, steps[i].ms <= t { state = (steps[i].cmd, steps[i].other, steps[i].presses); i += 1 }
            if d.sample(command: state.cmd, otherModifier: state.other, presses: state.presses, at: Double(t) / 1000) { fired += 1 }
        }
        return fired
    }
    /// `n` clean taps: 80 ms down, `gap` ms up.
    private func taps(_ n: Int, hold: Int = 80, gap: Int = 120, from: Int = 0, presses: UInt64 = 0) -> [(ms: Int, cmd: Bool, other: Bool, presses: UInt64)] {
        (0..<n).flatMap { i -> [(ms: Int, cmd: Bool, other: Bool, presses: UInt64)] in
            let start = from + i * (hold + gap)
            return [(start, true, false, presses), (start + hold, false, false, presses)]
        }
    }

    func testThreeQuickTapsFireOnce() {
        XCTAssertEqual(fires(taps(3)), 1)
        XCTAssertEqual(fires(taps(2)), 0, "two is not enough")
        XCTAssertEqual(fires(taps(1)), 0)
    }

    func testSixTapsFireTwiceNotFourTimes() {
        XCTAssertEqual(fires(taps(6)), 2, "a finished run starts from nothing")
        XCTAssertEqual(fires(taps(4)), 1)
    }

    func testCopyThenPasteDoesNotCount() {
        // Cmd down, C pressed, Cmd up; Cmd down, V pressed, Cmd up; and a third chord for good measure.
        let s: [(ms: Int, cmd: Bool, other: Bool, presses: UInt64)] = [
            (0, true, false, 0), (40, true, false, 1), (90, false, false, 1),
            (200, true, false, 1), (240, true, false, 2), (290, false, false, 2),
            (400, true, false, 2), (440, true, false, 3), (490, false, false, 3)]
        XCTAssertEqual(fires(s), 0)
    }

    func testCommandClickDoesNotCount() {
        var s = taps(2)
        s += [(400, true, false, 0), (430, true, false, 1), (480, false, false, 1)]      // third "tap" had a click in it
        XCTAssertEqual(fires(s), 0)
    }

    func testAKeyPressedBetweenTapsStartsOver() {
        var s = taps(2)
        s += taps(1, from: 400, presses: 1)          // a letter was typed between the second and third tap
        XCTAssertEqual(fires(s), 0)
        s += taps(2, from: 600, presses: 1)          // …but that third tap counts as the first of a new run
        XCTAssertEqual(fires(s), 1)
    }

    func testHoldingCommandDoesNotCount() {
        XCTAssertEqual(fires([(0, true, false, 0), (1000, false, false, 0)] + taps(2, from: 1100)), 0, "a one-second hold is not a tap")
        XCTAssertEqual(fires(taps(3, hold: 300)), 0)
    }

    func testTapsTooFarApartDoNotCount() {
        XCTAssertEqual(fires(taps(3, gap: 500)), 0)
        XCTAssertEqual(fires(taps(2) + taps(1, from: 1200)), 0)
    }

    func testAnotherModifierSpoilsTheTap() {
        let s: [(ms: Int, cmd: Bool, other: Bool, presses: UInt64)] = taps(2) + [(400, true, true, 0), (480, false, false, 0)]
        XCTAssertEqual(fires(s), 0, "Command with Shift, Control or Option is a shortcut, not a tap")
        let late: [(ms: Int, cmd: Bool, other: Bool, presses: UInt64)] = taps(2) + [(400, true, false, 0), (440, true, true, 0), (480, false, false, 0)]
        XCTAssertEqual(fires(late), 0, "pressed part-way through the tap")
    }

    func testTheNumberOfTapsIsASetting() {
        XCTAssertEqual(fires(taps(2), settings: .init(taps: 2)), 1)
        XCTAssertEqual(fires(taps(3), settings: .init(taps: 4)), 0)
        XCTAssertEqual(CommandTapDetector.Settings(taps: 1).taps, 2, "one tap would fire on every shortcut-free Command press")
        XCTAssertEqual(CommandTapDetector.Settings(taps: 99).taps, 5)
        XCTAssertEqual(Tuning().commandTapCount, 3)
        XCTAssertEqual(Tuning.envName(for: "commandTapCount"), "JARVIS_COMMAND_TAP_COUNT")
    }

    func testTriggerStartsAndStops() {
        let t = CommandTapTrigger { }
        XCTAssertFalse(t.isRunning)
        t.start(); t.start()
        XCTAssertTrue(t.isRunning)
        t.stop()
        XCTAssertFalse(t.isRunning)
    }
}
