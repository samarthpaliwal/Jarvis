import XCTest
@testable import JarvisCore

@MainActor
final class FakeCamera: CameraControlling {
    var isFeedVisible = false
    var isRecording = false
    var events: [String] = []
    var startedAt: Date?
    var lastLimit: Double = 0
    var maximum: Double = 300

    func showFeed() async throws { isFeedVisible = true; events.append("show") }
    func hideFeed() async -> Recording? {
        events.append("hide")
        isFeedVisible = false
        guard isRecording else { return nil }
        isRecording = false
        return Recording(url: CameraFiles.url(.video), seconds: 4, bytes: 2_000_000)
    }
    func takePhoto() async throws -> URL { events.append("photo"); return CameraFiles.url(.photo) }
    func startRecording(seconds: Double?, audio: Bool) async throws -> (url: URL, limit: Double) {
        guard !isRecording else { throw VisionError.alreadyRecording }
        try await showFeed()                    // the real controller always opens the feed first
        isRecording = true
        lastLimit = CameraFiles.recordingLimit(requested: seconds, maximum: maximum)
        events.append("start audio=\(audio)")
        return (CameraFiles.url(.video), lastLimit)
    }
    func stopRecording() async throws -> Recording {
        guard isRecording else { throw VisionError.notRecording }
        isRecording = false
        events.append("stop")
        return Recording(url: CameraFiles.url(.video), seconds: 12, bytes: 9_500_000)
    }
}

final class CameraFilesTests: XCTestCase {
    func testFilesGoIntoFoldersJarvisOwnsWithReadableNames() {
        let home = URL(fileURLWithPath: "/Users/sam")
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 22; c.hour = 23; c.minute = 41; c.second = 5
        let when = Calendar.current.date(from: c)!
        XCTAssertEqual(CameraFiles.url(.video, now: when, home: home).path, "/Users/sam/Movies/Jarvis/Jarvis 2026-11-22 at 23.41.05.mov")
        XCTAssertEqual(CameraFiles.url(.photo, now: when, home: home).path, "/Users/sam/Pictures/Jarvis/Jarvis 2026-11-22 at 23.41.05.jpg")
        XCTAssertEqual(CameraFiles.display(CameraFiles.url(.video, now: when, home: home), home: home), "Movies/Jarvis/Jarvis 2026-11-22 at 23.41.05.mov")
    }

    func testRecordingLengthIsAlwaysCapped() {
        XCTAssertEqual(CameraFiles.recordingLimit(requested: nil, maximum: 300), 300, "no length given: the maximum")
        XCTAssertEqual(CameraFiles.recordingLimit(requested: 20, maximum: 300), 20)
        XCTAssertEqual(CameraFiles.recordingLimit(requested: 3600, maximum: 300), 300, "an hour is cut to the maximum")
        XCTAssertEqual(CameraFiles.recordingLimit(requested: -5, maximum: 300), 300)
        XCTAssertEqual(CameraFiles.recordingLimit(requested: 20, maximum: 0), 20, "a broken setting still leaves a cap")
        XCTAssertEqual(CameraFiles.recordingLimit(requested: nil, maximum: 0), 300)
    }

    func testSpokenLengths() {
        XCTAssertEqual(CameraFiles.spokenLength(12.4), "12-second")
        XCTAssertEqual(CameraFiles.spokenLength(120), "2-minute")
        XCTAssertEqual(CameraFiles.spokenLength(95), "1-minute 35-second")
    }
}

@MainActor
final class CameraToolTests: XCTestCase {
    var camera: FakeCamera!
    var dispatcher: ToolDispatcher!
    var asked: [String] = []
    var answer = true
    var logURL: URL!

    override func setUp() async throws {
        camera = FakeCamera()
        asked = []; answer = true
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID()).log")
        dispatcher = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack(), notch: notch), log: ActionLog(url: logURL))
        dispatcher.register(CameraTool(camera: camera))
        dispatcher.approvalHandler = { [unowned self] r in self.asked.append(r.preview); return self.answer }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: logURL) }

    func call(_ action: String, _ extra: JSONObject = [:], source: ToolCallSource = .user) async -> ToolResult {
        var input = extra; input["action"] = action
        return await dispatcher.call("camera", input: input, source: source)
    }

    func testShowAndHideTheLiveFeed() async {
        var r = await call("show_feed")
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(camera.isFeedVisible)
        r = await call("status")
        XCTAssertEqual(r.content, "Live feed: on. Recording: no.")
        r = await call("hide_feed")
        XCTAssertFalse(camera.isFeedVisible)
        XCTAssertEqual(r.summary, "Camera off")
        XCTAssertTrue(asked.isEmpty, "Sam asked directly: no extra confirmation")
    }

    func testRecordAVideoStartToFinish() async {
        var r = await call("start_video", ["seconds": 20])
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(camera.isFeedVisible, "recording always shows the live feed")
        XCTAssertEqual(camera.lastLimit, 20)
        XCTAssertTrue(r.content.contains("stops by itself after 20 seconds"), r.content)
        r = await call("stop_video")
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(r.content.contains("Saved a 12-second video to Movies/Jarvis/"), r.content)
        XCTAssertEqual(r.summary, "Saved a 12-second video")
        XCTAssertEqual(camera.events, ["show", "start audio=true", "stop"])
    }

    func testRecordingWithoutALengthStillStopsAtTheMaximum() async {
        camera.maximum = 300
        _ = await call("start_video", ["audio": false])
        XCTAssertEqual(camera.lastLimit, 300)
        XCTAssertEqual(camera.events.last, "start audio=false")
        _ = await call("start_video", ["seconds": 99_999])
        XCTAssertEqual(camera.events.filter { $0.hasPrefix("start") }.count, 1, "a second recording does not start on top of the first")
    }

    func testClosingTheFeedEndsTheRecordingAndSaysWhereItWent() async {
        _ = await call("start_video")
        let r = await call("hide_feed")
        XCTAssertFalse(camera.isRecording)
        XCTAssertTrue(r.content.contains("saved the video in progress"), r.content)
    }

    func testStoppingWhenNothingIsRecordingIsAPlainSentence() async {
        let r = await call("stop_video")
        XCTAssertTrue(r.isError)
        XCTAssertEqual(r.content, "I'm not recording anything right now.")
    }

    func testPhotoIsSavedToPicturesJarvis() async {
        let r = await call("photo")
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(r.content.hasPrefix("Photo saved to Pictures/Jarvis/Jarvis "), r.content)
    }

    func testTheCameraNeverTurnsOnWithoutALiveRequest() async {
        for action in ["show_feed", "photo", "start_video"] {
            let r = await call(action, source: .proactive)
            XCTAssertTrue(r.isError && r.content.contains("only runs when Sam asks"), "\(action): \(r.content)")
        }
        XCTAssertTrue(camera.events.isEmpty)
    }

    func testAfterReadingOutsideContentEveryCameraUseNeedsAYes() async {
        let trace = RequestTrace(source: "text", sink: TraceSink(file: nil))
        trace.markUntrusted("an email")
        answer = false
        for action in ["show_feed", "photo", "start_video"] {
            let r = await RequestTrace.$current.withValue(trace) { await call(action) }
            XCTAssertTrue(r.isError, action)
        }
        XCTAssertTrue(camera.events.isEmpty, "an email that says 'start recording' gets nothing without Sam's yes")
        XCTAssertEqual(asked, ["Turn on the camera and show the live feed. Note: I read an email before asking this",
                               "Take a photo with the camera and save it. Note: I read an email before asking this",
                               "Start recording video with the camera. Note: I read an email before asking this"])
        answer = true
        let r = await RequestTrace.$current.withValue(trace) { await call("start_video") }
        XCTAssertFalse(r.isError)
        // Turning the camera off never needs approval.
        answer = false
        let off = await RequestTrace.$current.withValue(trace) { await call("hide_feed") }
        XCTAssertFalse(off.isError)
        XCTAssertFalse(camera.isFeedVisible)
    }
}
