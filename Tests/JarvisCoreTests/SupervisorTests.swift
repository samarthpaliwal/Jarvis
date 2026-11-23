import XCTest
@testable import JarvisCore

final class SupervisorTests: XCTestCase {
    func testAgentRestartsOnCrashButNotAfterACleanQuit() throws {
        let p = Supervisor.plist(executable: "/Apps/Jarvis.app/Contents/MacOS/Jarvis", logDirectory: "/tmp/logs")
        XCTAssertEqual(p["Label"] as? String, "com.samarth.jarvis")
        XCTAssertEqual(p["ProgramArguments"] as? [String], ["/Apps/Jarvis.app/Contents/MacOS/Jarvis"])
        XCTAssertEqual(p["RunAtLoad"] as? Bool, true, "starts at login")
        XCTAssertEqual((p["KeepAlive"] as? [String: Bool])?["SuccessfulExit"], false, "restart after a crash, stay quit after Quit")
        XCTAssertEqual(p["LimitLoadToSessionType"] as? String, "Aqua", "only in the logged-in graphical session")
        XCTAssertGreaterThanOrEqual(p["ThrottleInterval"] as? Int ?? 0, 10)
        // It must serialize as a property list launchd can read.
        let data = try PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)
        XCTAssertTrue(String(data: data, encoding: .utf8)!.contains("<key>KeepAlive</key>"))
    }

    func testCrashLoopDetection() {
        let now = Date()
        let burst = (0..<7).map { now.addingTimeInterval(-Double($0) * 10) }      // 7 starts in 70 s
        XCTAssertTrue(Supervisor.isCrashLooping(launches: burst, now: now))
        let normal = (0..<7).map { now.addingTimeInterval(-Double($0) * 300) }    // rebuilds through an evening
        XCTAssertFalse(Supervisor.isCrashLooping(launches: normal, now: now))
        XCTAssertFalse(Supervisor.isCrashLooping(launches: Array(burst.prefix(5)), now: now), "five quick restarts while developing is fine")
    }

    func testUncleanExitIsNoticedOnTheNextLaunch() {
        let suite = "jarvis-supervisor-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }

        XCTAssertFalse(Supervisor.noteLaunch(defaults: d).afterUncleanExit, "the very first launch is not a crash")
        Supervisor.noteCleanExit(defaults: d)
        XCTAssertFalse(Supervisor.noteLaunch(defaults: d).afterUncleanExit, "quit, then start")
        // No clean exit recorded this time: the process died.
        XCTAssertTrue(Supervisor.noteLaunch(defaults: d).afterUncleanExit, "crash, then restart")
    }

    func testCrashLoopIsReportedByNoteLaunch() {
        let suite = "jarvis-supervisor-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        let t0 = Date()
        var looping = false
        for i in 0..<7 { looping = Supervisor.noteLaunch(defaults: d, now: t0.addingTimeInterval(Double(i) * 12)).crashLooping }
        XCTAssertTrue(looping)
    }
}

final class HangWatchdogTests: XCTestCase {
    final class Clock: @unchecked Sendable { var t: TimeInterval = 1000 }

    func testFiresOnceWhenTheMainThreadStopsAnswering() {
        let clock = Clock()
        var hangs: [TimeInterval] = []
        let w = HangWatchdog(timeout: 30, interval: 5, uptime: { clock.t }) { hangs.append($0) }
        clock.t += 5;  w.tick(); w.pong()              // healthy: answered
        clock.t += 5;  w.tick(); w.pong()
        XCTAssertTrue(hangs.isEmpty)
        for _ in 0..<5 { clock.t += 5; w.tick() }      // 25 s of silence: not yet
        XCTAssertTrue(hangs.isEmpty)
        clock.t += 5; w.tick()                         // 30 s
        XCTAssertEqual(hangs.count, 1)
        XCTAssertEqual(hangs[0], 30, accuracy: 0.001)
        clock.t += 5; w.tick()
        XCTAssertEqual(hangs.count, 1, "it reports a hang once, not on every tick")
    }

    func testSleepDoesNotLookLikeAHang() {
        // The clock is system uptime, which does not advance while the Mac sleeps: after eight hours
        // asleep, the silence is still only the few seconds since the last answer.
        let clock = Clock()
        var hangs = 0
        let w = HangWatchdog(timeout: 30, uptime: { clock.t }) { _ in hangs += 1 }
        w.pong()
        clock.t += 4                                   // lid closed here; uptime stands still
        XCTAssertEqual(w.tick(), 4, accuracy: 0.001)
        XCTAssertEqual(hangs, 0)
    }

    func testRealMainThreadAnswersThePing() {
        var hangs = 0
        let w = HangWatchdog(timeout: 2, interval: 0.05) { _ in hangs += 1 }
        w.start()
        let done = expectation(description: "ran a while")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { done.fulfill() }
        wait(for: [done], timeout: 2)
        w.stop()
        XCTAssertEqual(hangs, 0, "a responsive main thread never trips it")
    }
}
