import XCTest
@testable import JarvisCore

@MainActor
final class ApprovalSessionTests: XCTestCase {
    var dispatcher: ToolDispatcher!
    var logURL: URL!
    var clock = Date(timeIntervalSince1970: 3_000_000)
    var asked: [String] = []
    var answer = true
    var send: FakeTool!, shell: FakeTool!

    override func setUp() async throws {
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        logURL = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID()).log")
        dispatcher = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack(), notch: notch), log: ActionLog(url: logURL))
        clock = Date(timeIntervalSince1970: 3_000_000); asked = []; answer = true
        dispatcher.now = { [unowned self] in self.clock }
        dispatcher.approvalHandler = { [unowned self] r in self.asked.append(r.toolName); return self.answer }
        send = FakeTool(name: "send_thing", tier: .approve); shell = FakeTool(name: "shell_thing", tier: .approve)
        dispatcher.register([send, shell])
    }
    override func tearDown() { try? FileManager.default.removeItem(at: logURL) }
    func call(_ name: String) async -> ToolResult { await dispatcher.call(name, input: [:], source: .user) }

    func testOffByDefaultEveryActionAsks() async {
        XCTAssertFalse(dispatcher.approvalSession.enabled)
        _ = await call("send_thing"); _ = await call("send_thing")
        XCTAssertEqual(asked, ["send_thing", "send_thing"])
    }

    func testOneYesCoversTheSameKindOfActionForTheChat() async {
        dispatcher.approvalSession.enabled = true
        _ = await call("send_thing")
        clock += 60
        let r = await call("send_thing")
        XCTAssertFalse(r.isError)
        XCTAssertEqual(asked, ["send_thing"], "asked once")
        XCTAssertEqual(send.runs, 2)
        _ = await call("shell_thing")
        XCTAssertEqual(asked, ["send_thing", "shell_thing"], "a yes to one kind is not a yes to another")
    }

    func testTwoQuietMinutesEndTheChatAndTheYes() async {
        dispatcher.approvalSession.enabled = true
        _ = await call("send_thing")
        clock += 100; _ = await call("send_thing")          // still talking: the clock restarts
        clock += 100; _ = await call("send_thing")
        XCTAssertEqual(asked.count, 1)
        clock += 121
        _ = await call("send_thing")
        XCTAssertEqual(asked.count, 2, "after two quiet minutes it asks again")
    }

    func testANoIsNotRememberedAndNeitherIsAYesAfterReadingOutsideContent() async {
        dispatcher.approvalSession.enabled = true
        answer = false
        _ = await call("send_thing"); _ = await call("send_thing")
        XCTAssertEqual(asked.count, 2)
        XCTAssertEqual(send.runs, 0)
        answer = true
        _ = await call("send_thing")                           // a clean yes
        let trace = RequestTrace(source: "text", sink: TraceSink(file: nil))
        trace.markUntrusted("an email")
        _ = await RequestTrace.$current.withValue(trace) { await call("send_thing") }
        XCTAssertEqual(asked.count, 4, "a request that read an email asks for the specific action, whatever was approved before")
    }

    func testNeverFromThePhone() async {
        dispatcher.approvalSession.enabled = true
        _ = await call("send_thing")
        let remote = RequestTrace(source: "remote", sink: TraceSink(file: nil))
        _ = await RequestTrace.$current.withValue(remote) { await call("send_thing") }
        XCTAssertEqual(asked.count, 2)
    }

    func testBothExtraLimitsCanBeSwitchedOffAndTheMacAndPhoneStaySeparate() async {
        dispatcher.approvalSession = ApprovalSession(enabled: true, coversOutsideContent: true, coversPhone: true)
        let tainted = RequestTrace(source: "text", sink: TraceSink(file: nil))
        tainted.markUntrusted("the screen")
        _ = await RequestTrace.$current.withValue(tainted) { await call("send_thing") }
        _ = await RequestTrace.$current.withValue(tainted) { await call("send_thing") }
        XCTAssertEqual(asked.count, 1, "loosened: one yes covers a request that read the screen")
        _ = await RequestTrace.$current.withValue(tainted) { await call("shell_thing") }
        XCTAssertEqual(asked.count, 2, "still one yes per kind of action")

        let remote = RequestTrace(source: "remote", sink: TraceSink(file: nil))
        _ = await RequestTrace.$current.withValue(remote) { await call("send_thing") }
        XCTAssertEqual(asked.count, 3, "a yes at the Mac is not a yes on the phone")
        _ = await RequestTrace.$current.withValue(remote) { await call("send_thing") }
        XCTAssertEqual(asked.count, 3, "loosened: the phone's own yes covers the phone")
        clock += 121
        _ = await RequestTrace.$current.withValue(remote) { await call("send_thing") }
        XCTAssertEqual(asked.count, 4, "two quiet minutes still end it")
    }

    func testInterruptingThroughTheSpeakersNeedsThreeWords() {
        let spoken = "The weather in Tucson is sunny with a high of twenty four"
        XCTAssertFalse(ConversationController.isGenuineInterruption(heard: "wait stop", spoken: spoken, minimumWords: 3))
        XCTAssertTrue(ConversationController.isGenuineInterruption(heard: "actually open my calendar instead", spoken: spoken, minimumWords: 3))
        XCTAssertFalse(ConversationController.isGenuineInterruption(heard: "weather in Tucson is sunny", spoken: spoken, minimumWords: 3), "its own voice")
    }
}
