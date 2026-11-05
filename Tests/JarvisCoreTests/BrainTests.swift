import XCTest
@testable import JarvisCore

final class ClaudeClientTests: XCTestCase {
    func testRequestBodyShape() throws {
        let client = ClaudeClient(apiKeyProvider: { "k" })
        let body = client.body(for: .init(model: "claude-sonnet-5-5", system: "sys", messages: [["role": "user", "content": "hi"]],
                                          tools: [["name": "t", "description": "d", "input_schema": ["type": "object"]]], maxTokens: 500))
        XCTAssertEqual(body["model"] as? String, "claude-sonnet-5-5")
        let system = body["system"] as? [JSONObject]
        XCTAssertEqual(system?.first?["text"] as? String, "sys")
        XCTAssertNotNil(system?.first?["cache_control"])
        XCTAssertNotNil((body["tools"] as? [JSONObject])?.last?["cache_control"])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual((body["output_config"] as? JSONObject)?["effort"] as? String, "low")
        XCTAssertEqual((body["thinking"] as? JSONObject)?["type"] as? String, "between_tools")
        XCTAssertNotNil(body["tools"])
        XCTAssertTrue(JSONSerialization.isValidJSONObject(body))

        let opus = client.body(for: .init(model: "claude-opus-5-5", system: "s", messages: [], tools: [], maxTokens: 10))
        XCTAssertNil(opus["thinking"], "only Sonnet 5.5 takes between_tools")
        XCTAssertNil(opus["tools"], "empty tool list is omitted")
    }

    func testSystemPromptSplitsStableAndVolatile() {
        let a = SystemPrompt.parts(profile: .fallback, mode: ModesConfig.fallback.modes[0], now: Date(), undoAvailable: nil)
        let b = SystemPrompt.parts(profile: .fallback, mode: ModesConfig.fallback.modes[0], now: Date().addingTimeInterval(3600), undoAvailable: "x")
        XCTAssertEqual(a.stable, b.stable, "stable part must not change with time or undo state")
        XCTAssertNotEqual(a.volatile, b.volatile)
        XCTAssertTrue(a.volatile.hasPrefix("Current mode:"))
    }

    func testSystemPromptMentionsSafetyAndMode() {
        let p = SystemPrompt.build(profile: .fallback, mode: ModesConfig.fallback.modes[0], online: false, undoAvailable: "volume to 40%")
        XCTAssertTrue(p.contains("untrusted_content"))
        XCTAssertTrue(p.contains("sudo is never available"))
        XCTAssertTrue(p.contains("offline"))
        XCTAssertTrue(p.contains("volume to 40%"))
        XCTAssertTrue(p.contains("Sam"))
    }
}

final class SSEParsingTests: XCTestCase {
    func testHandlerParsesTextAndToolEvents() throws {
        var events: [ClaudeClient.Event] = []
        let stream = AsyncThrowingStream<ClaudeClient.Event, Error> { cont in
            let lines = [
                #"{"type":"message_start","message":{"id":"m"}}"#,
                #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Battery is "}}"#,
                #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"76%."}}"#,
                #"{"type":"content_block_stop","index":0}"#,
                #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"system_status","input":{}}}"#,
                #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
                #"{"type":"content_block_stop","index":1}"#,
                #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":12}}"#,
            ]
            for l in lines { try? ClaudeClient.handleForTesting(l, cont) }
            cont.finish()
        }
        let exp = expectation(description: "drain")
        Task { for try await e in stream { events.append(e) }; exp.fulfill() }
        wait(for: [exp], timeout: 2)
        var text = ""
        var tool: String?
        var stop: String?
        for e in events {
            switch e {
            case .textDelta(let t): text += t
            case .toolUseStart(_, let name): tool = name
            case .stopReason(let s): stop = s
            default: break
            }
        }
        XCTAssertEqual(text, "Battery is 76%.")
        XCTAssertEqual(tool, "system_status")
        XCTAssertEqual(stop, "tool_use")
    }
}

final class LiveToolTests: XCTestCase {
    @MainActor
    func makeDispatcher() -> ToolDispatcher {
        let config = ConfigStore(directory: ConfigTests.repoConfigDir)
        let notch = NotchViewModel()
        let modes = ModeManager(config: config, notch: notch)
        let log = ActionLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("a-\(UUID()).log"))
        let d = ToolDispatcher(config: config, context: ToolContext(config: config, modes: modes, undo: UndoStack(), notch: notch), log: log)
        d.register([SystemStatusTool(), FileSearchTool(), FileReadTool(), RunShellTool(), GetLocationContextTool(), ActionsTodayTool(log: log)])
        return d
    }

    @MainActor
    func testSystemStatusRuns() async {
        let r = await makeDispatcher().call("system_status", input: [:], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(r.content.contains("Memory:"))
        XCTAssertTrue(r.content.contains("Disk free:"))
    }

    @MainActor
    func testFileSearchFindsThisRepoAndSkipsDenied() async {
        let d = makeDispatcher()
        let r = await d.call("file_search", input: ["query": "Package.swift", "folder": "~/Developer/Jarvis"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(r.content.contains("Package.swift"))
        let denied = await d.call("file_search", input: ["query": "x", "folder": "~/.ssh"], source: .user)
        XCTAssertTrue(denied.isError)
        let outside = await d.call("file_read", input: ["path": "/etc/hosts"], source: .user)
        XCTAssertTrue(outside.isError)
    }

    @MainActor
    func testFileReadWrapsAsUntrusted() async {
        let r = await makeDispatcher().call("file_read", input: ["path": "~/Developer/Jarvis/Package.swift"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(r.content.hasPrefix("<untrusted_content source=\"file:Package.swift\">"))
    }

    @MainActor
    func testShellNeedsApprovalThenRunsSandboxed() async {
        let d = makeDispatcher()
        var preview = ""
        d.approvalHandler = { req in preview = req.preview; return true }
        let r = await d.call("run_shell", input: ["command": "echo hi && pwd", "why": "test"], source: .user)
        XCTAssertFalse(r.isError, r.content)
        XCTAssertTrue(r.content.contains("hi"))
        XCTAssertTrue(r.content.contains(NSHomeDirectory()))
        XCTAssertEqual(preview, "Run: echo hi && pwd — test")
        let sudo = await d.call("run_shell", input: ["command": "sudo ls"], source: .user)
        XCTAssertTrue(sudo.isError)
        XCTAssertTrue(sudo.content.contains("denylist"))
    }

    func testMissingKeyIsAClearError() async {
        let client = ClaudeClient(apiKeyProvider: { nil })
        do {
            for try await _ in client.stream(.init(model: "claude-sonnet-5-5", system: "", messages: [], tools: [], maxTokens: 10)) {}
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, ClaudeClient.ClientError.noAPIKey.localizedDescription)
        }
    }
}

final class SentenceChunkerTests: XCTestCase {
    func testSplitsOnSentenceEndsOnly() {
        var c = SentenceChunker()
        XCTAssertEqual(c.push("Two things today. Your exam is in 3.5 "), ["Two things today."])
        XCTAssertEqual(c.push("days! Go"), ["Your exam is in 3.5 days!"])
        XCTAssertEqual(c.flush(), "Go")
    }
}
