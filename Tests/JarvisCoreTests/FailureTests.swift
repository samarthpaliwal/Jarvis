import XCTest
@testable import JarvisCore

/// Phase 1 item 4: any failure produces a short spoken message; never a silent hang.
final class DeadlineTests: XCTestCase {
    func testReturnsTheValueWhenInTime() async throws {
        let v = try await withDeadline("quick", seconds: 2) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testThrowsTimeoutAndDoesNotWaitForAStageThatIgnoresCancellation() async {
        let started = Date()
        do {
            _ = try await withDeadline("slow_tool", seconds: 0.2) { () -> Int in
                for _ in 0..<100 { try? await Task.sleep(for: .milliseconds(50)) }   // ignores cancellation: 5 s
                return 1
            }
            XCTFail("should have timed out")
        } catch let t as TimeoutError {
            XCTAssertEqual(t.what, "slow_tool")
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5, "the caller is released at the deadline")
    }

    func testOperationErrorsPassThrough() async {
        struct Boom: Error {}
        do { _ = try await withDeadline("x", seconds: 2) { () -> Int in throw Boom() }; XCTFail() }
        catch { XCTAssertTrue(error is Boom) }
    }

    func testRequestIDSurvivesTheDeadlineWrapper() async throws {
        let r = RequestTrace(source: "text", sink: TraceSink(file: nil), id: "r-dead01")
        let seen = try await RequestTrace.$current.withValue(r) {
            try await withDeadline("x", seconds: 2) { RequestTrace.current?.id }
        }
        XCTAssertEqual(seen, "r-dead01")
    }
}

final class SpokenFailureTests: XCTestCase {
    func testEveryFailureHasAShortPlainMessage() {
        let errors: [Error] = [
            TimeoutError(what: "The request", seconds: 120), TimeoutError(what: "email_search", seconds: 45),
            ClaudeClient.ClientError.noAPIKey, ClaudeClient.ClientError.http(401, "x"), ClaudeClient.ClientError.http(429, "x"),
            ClaudeClient.ClientError.http(529, "overloaded"), ClaudeClient.ClientError.http(400, "tool_use ids were found without tool_result"),
            ClaudeClient.ClientError.malformed("x"), TranscriberError.notAuthorized, TranscriberError.unavailable("assets"),
            AudioCaptureError.noInputDevice, URLError(.timedOut), URLError(.notConnectedToInternet), URLError(.cannotFindHost),
            NSError(domain: "whatever", code: -99, userInfo: [NSLocalizedDescriptionKey: "kAudioUnitErr_FormatNotSupported 0x8000FFFF"]),
        ]
        for e in errors {
            let m = SpokenFailure.message(for: e)
            XCTAssertFalse(m.isEmpty)
            XCTAssertLessThanOrEqual(m.split(separator: " ").count, 18, "too long to speak: \(m)")
            XCTAssertNil(m.range(of: #"\d{3}|0x|kAudio|tool_use|NSURL|Error Domain"#, options: .regularExpression), "jargon in: \(m)")
            XCTAssertTrue(m.hasSuffix("."), m)
        }
        XCTAssertEqual(SpokenFailure.message(for: URLError(.notConnectedToInternet)), "I'm offline right now.")
        XCTAssertEqual(SpokenFailure.stage(of: TranscriberError.notAuthorized), .transcribed)
        XCTAssertEqual(SpokenFailure.stage(of: URLError(.timedOut)), .intent)
    }

    func testSameErrorIsNotSpokenOverAndOver() {
        var limit = SpeechRateLimit(window: 60)
        let t0 = Date()
        XCTAssertTrue(limit.shouldSpeak("mic", at: t0))
        XCTAssertFalse(limit.shouldSpeak("mic", at: t0 + 10))
        XCTAssertTrue(limit.shouldSpeak("other", at: t0 + 10))
        XCTAssertTrue(limit.shouldSpeak("mic", at: t0 + 61))
    }
}

final class HangingTool: JarvisTool {
    let name = "slow_lookup"
    let tier: Tier = .auto
    let description = "never returns"
    let inputSchema: JSONObject = ["type": "object", "properties": [:]]
    func targets(for input: JSONObject) -> ToolTargets { ToolTargets() }
    func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        try await Task.sleep(for: .seconds(30))
        return ToolResult("too late")
    }
}

@MainActor
final class ToolTimeoutTests: XCTestCase {
    func testHangingToolBecomesAnErrorResultInsteadOfHangingTheRequest() async throws {
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: ["JARVIS_TOOL_TIMEOUT_SECONDS": "0.2"])
        XCTAssertEqual(config.tuning.toolTimeoutSeconds, 0.2)
        let notch = NotchViewModel()
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("actions-\(UUID()).log")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let log = ActionLog(url: logURL)
        let d = ToolDispatcher(config: config, context: ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack(), notch: notch), log: log)
        d.register(HangingTool())

        let started = Date()
        let result = await d.call("slow_lookup", input: [:], source: .user)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.content.contains("timed out"), result.content)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.records(since: .distantPast).last?.outcome, "timeout", "the action log records the timeout")
    }
}

@MainActor
final class PipelineFailureTests: XCTestCase {
    let rig = PipelineStagesTests()

    func testModelErrorIsSpokenAndThePipelineRecovers() async {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech()
        let c = rig.makeController(wake, stt, intent, speech)
        intent.error = ClaudeClient.ClientError.http(529, "overloaded_error")
        wake.fire(); stt.say("what's the weather")
        await rig.wait("the failure to be spoken") { speech.isWaitingToFinish && !speech.spoken.isEmpty }
        XCTAssertEqual(speech.spoken.joined(separator: " "), "Claude is having trouble right now. Try again in a moment.")
        let request = c.trace
        speech.finishSpeaking()
        await rig.wait("idle") { c.state == .idle }
        XCTAssertEqual(request?.finish(outcome: "x")["outcome"] as? String, "error")
        XCTAssertEqual(c.illegalTransitions, 0)

        // The next request works: one failure does not poison the pipeline.
        intent.error = nil
        wake.fire(); stt.say("and tomorrow")
        await rig.wait("the next reply") { speech.spoken.contains { $0.contains("Two things") } }
    }

    func testHungModelHitsTheTurnDeadlineAndSaysSo() async {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech()
        let c = rig.makeController(wake, stt, intent, speech, env: ["JARVIS_TURN_TIMEOUT_SECONDS": "0.3"])
        intent.hangs = true
        let started = Date()
        wake.fire(); stt.say("summarize my inbox")
        await rig.wait("the timeout to be spoken") { speech.isWaitingToFinish && !speech.spoken.isEmpty }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "no silent hang")
        XCTAssertEqual(speech.spoken.joined(separator: " "), "That took too long, so I stopped. Try again.")
        speech.finishSpeaking()
        await rig.wait("idle") { c.state == .idle }
    }

    func testRecognizerFailureIsSpokenNotJustShown() async {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech()
        let c = rig.makeController(wake, stt, intent, speech)
        stt.startError = TranscriberError.unavailable("speech assets not installed")
        wake.fire()
        await rig.wait("the failure to be spoken") { !speech.spoken.isEmpty }
        XCTAssertEqual(speech.spoken, ["Speech recognition isn't available right now."])
        XCTAssertEqual(c.state, .speaking)
        speech.finishSpeaking()
        await rig.wait("idle") { c.state == .idle }
        XCTAssertTrue(intent.heard.isEmpty)
        XCTAssertEqual(wake.pausedLog.last, false, "wake detection is back on")

        // Failing again right away is shown, not spoken a second time.
        wake.fire()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(speech.spoken.count, 1)
        XCTAssertEqual(c.state, .idle)
        XCTAssertEqual(c.illegalTransitions, 0)
    }

    func testMicrophoneTroubleIsAnnounced() async {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech()
        let c = rig.makeController(wake, stt, intent, speech)
        c.reportFailure(SpokenFailure.microphoneSilent)
        XCTAssertEqual(speech.spoken, [SpokenFailure.microphoneSilent])
        speech.finishSpeaking()
        await rig.wait("idle") { c.state == .idle }
    }
}
