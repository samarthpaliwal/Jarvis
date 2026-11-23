import XCTest
@testable import JarvisCore

final class FakeFrameSource: FrameSource, @unchecked Sendable {
    let name: String
    var captures = 0
    var error: Error?
    init(name: String = "camera") { self.name = name }
    func captureFrame() async throws -> Frame {
        captures += 1
        if let error { throw error }
        return Frame(jpeg: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 0xFF, 0xD9]), width: 1280, height: 720, source: name)
    }
}

/// Phase 3 item 13: on-demand vision.
@MainActor
final class VisionTests: XCTestCase {
    var camera: FakeFrameSource!
    var dispatcher: ToolDispatcher!
    var config: ConfigStore!
    var notch: NotchViewModel!
    var asked: [String] = []
    var answer = true
    var logURL: URL!
    var log: ActionLog!

    override func setUp() async throws {
        camera = FakeFrameSource()
        asked = []; answer = true
        config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        notch = NotchViewModel()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID()).log")
        log = ActionLog(url: logURL)
        dispatcher = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack(), notch: notch), log: log)
        dispatcher.register(LookTool(sources: FrameSources([camera, PushedFrameSource(name: "glasses")], default: "camera")))
        dispatcher.approvalHandler = { [unowned self] r in self.asked.append(r.preview); return self.answer }
    }

    override func tearDown() { try? FileManager.default.removeItem(at: logURL) }

    func testLookTakesOnePictureAndHandsItToTheModel() async {
        let r = await dispatcher.call("look", input: ["about": "what am I holding"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertEqual(camera.captures, 1, "exactly one frame per request")
        XCTAssertEqual(r.images.count, 1)
        XCTAssertEqual(r.images[0].mediaType, "image/jpeg")
        XCTAssertTrue(asked.isEmpty, "Sam asked directly: no extra confirmation")
        XCTAssertEqual(r.summary, "Looked through the camera")
    }

    func testTheCameraNeverFiresWithoutALiveRequest() async {
        for source in [ToolCallSource.proactive] {
            let r = await dispatcher.call("look", input: [:], source: source)
            XCTAssertTrue(r.isError)
            XCTAssertTrue(r.content.contains("only runs when Sam asks"), r.content)
        }
        XCTAssertEqual(camera.captures, 0)
    }

    func testAfterReadingOutsideContentTheCameraNeedsAYes() async {
        let trace = RequestTrace(source: "text", sink: TraceSink(file: nil))
        trace.markUntrusted("a web page")
        answer = false
        var r = await RequestTrace.$current.withValue(trace) { await dispatcher.call("look", input: [:], source: .user) }
        XCTAssertTrue(r.isError)
        XCTAssertEqual(camera.captures, 0, "a page that says 'take a photo' gets nothing without Sam's yes")
        XCTAssertEqual(asked, ["Take a picture with the camera. Note: I read a web page before asking this"])

        answer = true
        r = await RequestTrace.$current.withValue(trace) { await dispatcher.call("look", input: [:], source: .user) }
        XCTAssertFalse(r.isError)
        XCTAssertEqual(camera.captures, 1)
    }

    func testCameraProblemsComeBackAsPlainSentences() async {
        camera.error = VisionError.cameraDenied
        var r = await dispatcher.call("look", input: [:], source: .user)
        XCTAssertTrue(r.isError && r.content.contains("camera access"), r.content)
        r = await dispatcher.call("look", input: ["source": "drone"], source: .user)
        XCTAssertTrue(r.isError && r.content.contains("“drone”"), r.content)
    }

    func testThePictureIsNeverWrittenToTheActionLog() async throws {
        _ = await dispatcher.call("look", input: ["about": "label"], source: .user)
        try await Task.sleep(for: .milliseconds(100))
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(text.contains("\"tool\":\"look\""))
        XCTAssertFalse(text.contains("/9j/"), "no base64 JPEG in the log")
        XCTAssertLessThan(text.count, 600)
    }

    // MARK: Glasses hook

    func testPushedSourceServesOnlyAFreshFrame() async throws {
        final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000) }
        let clock = Clock()
        let glasses = PushedFrameSource(name: "glasses", maxAge: 10, now: { clock.t })
        do { _ = try await glasses.captureFrame(); XCTFail("nothing pushed yet") } catch { XCTAssertEqual(error as? VisionError, .noFrame("glasses")) }
        glasses.push(jpeg: Data([1, 2, 3]), width: 640, height: 480)
        let f = try await glasses.captureFrame()
        XCTAssertEqual(f.source, "glasses")
        XCTAssertEqual(f.width, 640)
        clock.t += 11
        do { _ = try await glasses.captureFrame(); XCTFail("stale") } catch { XCTAssertEqual(error as? VisionError, .noFrame("glasses")) }
    }

    func testLookCanUseTheGlassesSourceOnceABridgeFeedsIt() async {
        let glasses = PushedFrameSource(name: "glasses")
        dispatcher.register(LookTool(sources: FrameSources([camera, glasses], default: "camera")))
        var r = await dispatcher.call("look", input: ["source": "glasses"], source: .user)
        XCTAssertTrue(r.isError && r.content.contains("no recent picture from the glasses"), r.content)
        glasses.push(jpeg: Data([9, 9, 9]), width: 1024, height: 768)
        r = await dispatcher.call("look", input: ["source": "glasses"], source: .user)
        XCTAssertFalse(r.isError)
        XCTAssertEqual(r.images.first?.data, Data([9, 9, 9]))
        XCTAssertEqual(camera.captures, 0)
    }

    // MARK: Getting the picture to the model, and out of the history again

    func testToolResultCarriesTheImageBlock() {
        var result = ToolResult("A picture is attached.")
        result.images = [ToolImage(data: Data([1, 2, 3]), mediaType: "image/jpeg")]
        let block = Brain.toolResultBlock(id: "toolu_1", result)
        let content = block["content"] as? [JSONObject]
        XCTAssertEqual(content?.count, 2)
        XCTAssertEqual(content?[0]["type"] as? String, "text")
        XCTAssertEqual(content?[1]["type"] as? String, "image")
        let source = content?[1]["source"] as? JSONObject
        XCTAssertEqual(source?["type"] as? String, "base64")
        XCTAssertEqual(source?["media_type"] as? String, "image/jpeg")
        XCTAssertEqual(source?["data"] as? String, "AQID")
        // No picture: the plain string form, as before.
        XCTAssertEqual(Brain.toolResultBlock(id: "t", ToolResult("ok"))["content"] as? String, "ok")
    }

    func testModelSeesThePictureAndOnlyTheNewestStaysInHistory() async throws {
        func look(_ id: String) -> [ClaudeClient.Event] { [.toolUseStart(id: id, name: "look"), .toolInputDelta("{}"), .contentBlockStop, .stopReason("tool_use")] }
        let model = ScriptedModel(rounds: [
            look("t1"), [.textDelta("A blue water bottle."), .contentBlockStop, .stopReason("end_turn")],
            look("t2"), [.textDelta("Now a red notebook."), .contentBlockStop, .stopReason("end_turn")],
            [.textDelta("The notebook was red."), .contentBlockStop, .stopReason("end_turn")],
        ])
        let brain = Brain(client: model, dispatcher: dispatcher, config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack())
        brain.privateMode = false
        func images(in request: ClaudeClient.Request) -> Int {
            request.messages.flatMap { $0["content"] as? [JSONObject] ?? [] }
                .flatMap { $0["content"] as? [JSONObject] ?? [] }.filter { $0["type"] as? String == "image" }.count
        }

        _ = try await brain.respond(to: "what am I holding") { _ in }
        XCTAssertEqual(images(in: model.requests[1]), 1, "the model's next round carries the picture")
        _ = try await brain.respond(to: "and now?") { _ in }
        XCTAssertEqual(images(in: model.requests[3]), 2, "within a request both pictures are still there")
        _ = try await brain.respond(to: "what colour was it") { _ in }
        XCTAssertEqual(images(in: model.requests[4]), 1, "afterwards only the newest picture is kept")
        let text = String(describing: model.requests[4].messages)
        XCTAssertTrue(text.contains("An earlier picture was here"))
        XCTAssertEqual(camera.captures, 2)
    }

    func testPromptKeepsTheCameraOnDemand() {
        let p = SystemPrompt.build(profile: .fallback, mode: ModesConfig.fallback.modes[0])
        XCTAssertTrue(p.contains("Use it only when"))
        XCTAssertTrue(p.contains("Don't identify real people from their face"))
    }
}
