import XCTest
@testable import JarvisCore

final class ModeScorerTests: XCTestCase {
    var config: ModesConfig { try! JSONDecoder().decode(ModesConfig.self, from: Data(contentsOf: ConfigTests.repoConfigDir.appendingPathComponent("modes.json"))) }

    func testCampusLocationPicksClass() {
        var s = ContextSignals()
        s.locationAuthorized = true
        s.latitude = 32.2325; s.longitude = -110.9505 // ~70 m from the UA centre
        s.pluggedIn = false
        let v = ModeScorer.best(s, config: config)
        XCTAssertEqual(v?.modeID, "class")
        XCTAssertTrue(v!.reasons.contains { $0.contains("campus") })
    }

    func testHomeWifiPlusDockPicksHome() {
        var s = ContextSignals()
        s.ssid = "CHANGE-ME-HomeWifi"; s.pluggedIn = true; s.externalDisplays = 1
        XCTAssertEqual(ModeScorer.best(s, config: config)?.modeID, "home")
    }

    func testCalendarKeywordOutranksPlace() {
        var s = ContextSignals()
        s.ssid = "CHANGE-ME-HomeWifi"; s.pluggedIn = true
        s.currentEventTitle = "CSC 210 Lecture"
        XCTAssertEqual(ModeScorer.best(s, config: config)?.modeID, "class")
    }

    func testHomeWifiInsideCampusGeofenceStaysHome() {
        var s = ContextSignals()
        s.locationAuthorized = true
        s.latitude = 32.2325; s.longitude = -110.9505   // on campus…
        s.ssid = "5G Honors"                              // …but on the dorm Wi-Fi
        s.pluggedIn = true; s.externalDisplays = 2
        XCTAssertEqual(ModeScorer.best(s, config: config)?.modeID, "home")
        // Ties keep the current mode.
        var t = ContextSignals(); t.pluggedIn = true
        XCTAssertEqual(ModeScorer.best(t, config: config, current: "home")?.modeID, "home")
    }

    func testAwayOnBatteryIsRoad() {
        var s = ContextSignals()
        s.ssid = "Starbucks"; s.pluggedIn = false; s.externalDisplays = 0; s.locationAuthorized = false
        XCTAssertEqual(ModeScorer.best(s, config: config)?.modeID, "road")
    }

    func testNoSignalsNoVerdict() {
        XCTAssertNil(ModeScorer.best(ContextSignals(), config: config))
    }
}

final class QuietHoursTests: XCTestCase {
    func at(_ h: Int, _ m: Int) -> Date { Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: h, minute: m))! }
    func testOvernightWindow() {
        XCTAssertTrue(ProactiveScheduler.inWindow(start: "22:30", end: "06:00", now: at(23, 0)))
        XCTAssertTrue(ProactiveScheduler.inWindow(start: "22:30", end: "06:00", now: at(5, 59)))
        XCTAssertFalse(ProactiveScheduler.inWindow(start: "22:30", end: "06:00", now: at(6, 0)))
        XCTAssertFalse(ProactiveScheduler.inWindow(start: "22:30", end: "06:00", now: at(12, 0)))
        XCTAssertTrue(ProactiveScheduler.inWindow(start: "07:00", end: "23:59", now: at(7, 0)))
        XCTAssertFalse(ProactiveScheduler.inWindow(start: "07:00", end: "23:59", now: at(6, 59)))
    }
}

final class OrganizePlannerTests: XCTestCase {
    func testCategoriesAndSkips() {
        XCTAssertEqual(OrganizePlanner.category(for: "Screenshot 2026-11-05.png"), "Screenshots")
        XCTAssertEqual(OrganizePlanner.category(for: "report.PDF"), "Documents")
        XCTAssertEqual(OrganizePlanner.category(for: "setup.dmg"), "Archives")
        XCTAssertEqual(OrganizePlanner.category(for: "weird.xyz"), "Other")
        let now = Date()
        let plan = OrganizePlanner.plan(entries: [("a.png", false, now), ("Sorted", true, now), (".DS_Store", false, now), ("Projects", true, now), ("Tool.app", true, now)],
                                        folder: "/u/Desktop", sortedName: "Sorted", byDate: false)
        XCTAssertEqual(plan.map(\.to), ["/u/Desktop/Sorted/Images/a.png", "/u/Desktop/Sorted/Installers/Tool.app"])
        let dated = OrganizePlanner.plan(entries: [("a.png", false, now)], folder: "/u/Desktop", sortedName: "Sorted", byDate: true)
        XCTAssertTrue(dated[0].to.contains("/Sorted/20"))
    }

    @MainActor
    func testOrganizeMovesAndUndoRestores() async throws {
        let fm = FileManager.default
        // Not the system temp dir: /private is denylisted (correctly). Use a scratch folder inside the repo.
        let tmp = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/jarvis-org-\(UUID())")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        try "x".write(to: tmp.appendingPathComponent("photo.jpg"), atomically: true, encoding: .utf8)
        try "y".write(to: tmp.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: tmp) }

        // Config whose organize list includes the temp folder.
        let dir = fm.temporaryDirectory.appendingPathComponent("jarvis-cfg-\(UUID())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in ConfigLocator.requiredFiles { try fm.copyItem(at: ConfigTests.repoConfigDir.appendingPathComponent(f), to: dir.appendingPathComponent(f)) }
        let allowed = AllowedFolders(read: [tmp.path], organize: [tmp.path], sortedFolderName: "Sorted", largeFileMB: 500, oldFileDays: 90)
        try JSONEncoder().encode(allowed).write(to: dir.appendingPathComponent("allowed-folders.json"))
        let config = ConfigStore(directory: dir)
        let notch = NotchViewModel()
        let undo = UndoStack()
        let d = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: undo, notch: notch),
                               log: ActionLog(url: dir.appendingPathComponent("a.log")))
        d.register(OrganizeFolderTool(log: MoveLog(url: dir.appendingPathComponent("moves.json"))))

        let preview = await d.call("organize_folder", input: ["folder": tmp.path, "dry_run": true], source: .user)
        XCTAssertTrue(preview.content.contains("Would move 2"))
        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("photo.jpg").path))

        let r = await d.call("organize_folder", input: ["folder": tmp.path], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("Sorted/Images/photo.jpg").path))
        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("Sorted/Documents/notes.txt").path))
        XCTAssertFalse(fm.fileExists(atPath: tmp.appendingPathComponent("photo.jpg").path))

        let msg = try await undo.undoLast()
        XCTAssertEqual(msg, "Put 2 file(s) back.")
        XCTAssertTrue(fm.fileExists(atPath: tmp.appendingPathComponent("photo.jpg").path))
    }

    @MainActor
    func testOrganizeRefusesFoldersOutsideOrganizeList() async {
        let config = ConfigStore(directory: ConfigTests.repoConfigDir)
        let notch = NotchViewModel()
        let d = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack(), notch: notch),
                               log: ActionLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID()).log")))
        d.register(OrganizeFolderTool(log: MoveLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID()).json"))))
        let r = await d.call("organize_folder", input: ["folder": "~/Developer"], source: .user)
        XCTAssertTrue(r.isError)
        XCTAssertTrue(r.content.contains("organize"))
    }
}

final class LenientConfigTests: XCTestCase {
    func testOldProactiveBlockStillDecodes() throws {
        let old = #"{"breakReminders":true,"breakAfterMinutes":60,"quietHoursStart":"23:00","quietHoursEnd":"07:00"}"#
        let p = try JSONDecoder().decode(Profile.Proactive.self, from: Data(old.utf8))
        XCTAssertTrue(p.breakReminders)
        XCTAssertTrue(p.autoModes)
        XCTAssertEqual(p.callApps, PresenceDetector.defaultCallApps)
    }
}
