import Combine
import XCTest
@testable import JarvisCore

// Fakes for each stage. If these compile and the tests pass, every stage can be swapped.

@MainActor
final class FakeWake: WakeSource {
    var onWake: ((Date) -> Void)?
    var onLevel: ((Float) -> Void)?
    nonisolated(unsafe) var audioTap: (([Float]) -> Void)?
    var pausedLog: [Bool] = []
    func setPaused(_ paused: Bool) { pausedLog.append(paused) }
    func fire() { onWake?(Date()) }
}

final class FakeTranscriber: Transcriber, @unchecked Sendable {
    let name = "fake"
    var isAvailable = true
    var starts = 0
    var startError: Error?
    private var onUpdate: ((TranscriptUpdate) -> Void)?
    private var onError: ((Error) -> Void)?
    func requestAuthorization() async -> Bool { true }
    func start(onUpdate: @escaping (TranscriptUpdate) -> Void, onError: @escaping (Error) -> Void) throws {
        if let startError { throw startError }
        starts += 1; self.onUpdate = onUpdate; self.onError = onError
    }
    func append(samples: [Float]) {}
    func finish() {}
    func cancel() { onUpdate = nil }
    func say(_ text: String) { onUpdate?(TranscriptUpdate(text: text, isFinal: true)) }
    func fail(_ error: Error) { onError?(error) }
}

@MainActor
final class FakeIntent: IntentEngine {
    var heard: [String] = []
    var reply = "Two things on the board today."
    var error: Error?
    /// Simulates a model or tool that never answers and ignores cancellation.
    var hangs = false
    func respond(to text: String, onText: @escaping (String) -> Void) async throws -> Reply {
        heard.append(text)
        if hangs { for _ in 0..<600 { try? await Task.sleep(for: .milliseconds(50)) } }
        if let error { throw error }
        onText(reply)
        return Reply(text: reply)
    }
}

final class FakeSpeech: SpeechOutput {
    let name = "fake"
    var isSpeaking = false
    var spoken: [String] = []
    var onAudioStart: ((String) -> Void)?
    private var drained: ((Bool) -> Void)?
    func speak(_ text: String, volume: Float, rate: Float, onFinished: @escaping (Bool) -> Void) { spoken.append(text); isSpeaking = true; drained = onFinished; onAudioStart?("fake") }
    func enqueue(_ text: String, volume: Float, rate: Float) { spoken.append(text); isSpeaking = true; onAudioStart?("fake") }
    func whenQueueDrained(_ onFinished: @escaping (Bool) -> Void) { drained = onFinished }
    func stop() { isSpeaking = false; let d = drained; drained = nil; d?(false) }
    var isWaitingToFinish: Bool { drained != nil }
    func finishSpeaking() { isSpeaking = false; let d = drained; drained = nil; d?(true) }
}

@MainActor
final class PipelineStagesTests: XCTestCase {
    func makeController(_ wake: FakeWake, _ stt: FakeTranscriber, _ intent: FakeIntent, _ speech: FakeSpeech,
                        env: [String: String] = [:]) -> ConversationController {
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: env)
        let notch = NotchViewModel()
        let c = ConversationController(notch: notch, wake: wake, transcriber: stt, speech: speech, config: config,
                                       modes: ModeManager(config: config, notch: notch), brain: intent)
        c.conversationMode = false      // no follow-up listen: the test ends at idle
        c.voiceMuted = false
        c.outputIsHeadphones = { false }
        c.strictTransitions = true      // any transition outside the table fails the turn
        return c
    }

    func wait(_ what: String, timeout: TimeInterval = 4, until done: @escaping @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !done(), Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        let ok = done()
        XCTAssertTrue(ok, "timed out waiting for \(what)")
    }

    func testFullRequestRunsThroughEveryStageOnFakes() async {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech()
        let c = makeController(wake, stt, intent, speech)
        var states: [PipelineState] = []
        let sub = c.$state.sink { states.append($0) }
        defer { sub.cancel() }

        wake.fire()                                   // heard
        XCTAssertEqual(c.state, .listening)
        XCTAssertEqual(stt.starts, 1)
        let request = c.trace
        XCTAssertNotNil(request)

        stt.say("what's on today")                    // transcribed
        await wait("the reply to be spoken") { speech.isWaitingToFinish && !speech.spoken.isEmpty }
        XCTAssertEqual(c.state, .speaking)
        XCTAssertEqual(intent.heard, ["what's on today"])
        XCTAssertEqual(speech.spoken.joined(separator: " "), intent.reply)

        speech.finishSpeaking()                       // spoken
        await wait("idle") { c.state == .idle }

        XCTAssertEqual(states, [.idle, .listening, .thinking, .speaking, .idle])
        XCTAssertEqual(c.illegalTransitions, 0)
        XCTAssertEqual(wake.pausedLog.first, true, "wake detection pauses while Jarvis listens")
        XCTAssertEqual(wake.pausedLog.last, false)

        // One request ID from wake to speech, with every stage it passed through and its timings.
        let summary = request!.finish(outcome: "ignored: already finished")
        XCTAssertEqual(summary["outcome"] as? String, "spoken")
        XCTAssertEqual(summary["stages"] as? [String], ["heard", "transcribed", "intent", "spoken"])
        let ms = summary["ms"] as? [String: Any]
        for key in ["listen", "llm_first_token", "first_audio", "total"] { XCTAssertNotNil(ms?[key], "missing \(key) latency") }
    }

    func testTypedRequestSkipsTheMicrophone() async {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech()
        let c = makeController(wake, stt, intent, speech)
        c.ask("status report")
        await wait("speech") { speech.isWaitingToFinish }
        XCTAssertEqual(intent.heard, ["status report"])
        speech.finishSpeaking()
        await wait("idle") { c.state == .idle }
        XCTAssertEqual(c.illegalTransitions, 0)
        XCTAssertEqual(c.trace?.source, "text")
    }

    func testWakeWithNothingSaidGoesBackToIdleQuietly() async {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech()
        let c = makeController(wake, stt, intent, speech)
        wake.fire()
        stt.say("")   // final result with no words
        await wait("idle") { c.state == .idle }
        XCTAssertTrue(intent.heard.isEmpty, "nothing reaches the model")
        XCTAssertTrue(speech.spoken.isEmpty)
        XCTAssertEqual(c.trace?.finish(outcome: "x")["outcome"] as? String, "no_speech")
    }

    func testStopCancelsFromAnyPoint() async {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech()
        let c = makeController(wake, stt, intent, speech)
        wake.fire()
        stt.say("tell me a long story")
        await wait("speech") { speech.isWaitingToFinish }
        c.stopEverything()
        XCTAssertEqual(c.state, .idle)
        XCTAssertFalse(speech.isSpeaking)
        XCTAssertEqual(c.illegalTransitions, 0)
    }
}

// MARK: - The intent stage on its own: scripted model, fake actions

final class ScriptedModel: LanguageModel, @unchecked Sendable {
    var rounds: [[ClaudeClient.Event]]
    private(set) var requests: [ClaudeClient.Request] = []
    private(set) var prewarms: [ClaudeClient.Request] = []
    init(rounds: [[ClaudeClient.Event]]) { self.rounds = rounds }
    func prewarm(_ request: ClaudeClient.Request) async throws -> (cacheRead: Int, cacheWrite: Int) {
        prewarms.append(request)
        return (0, 20_000)
    }
    func stream(_ request: ClaudeClient.Request) -> AsyncThrowingStream<ClaudeClient.Event, Error> {
        requests.append(request)
        let events = rounds.isEmpty ? [] : rounds.removeFirst()
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}

@MainActor
final class FakeActions: ActionRunner {
    var calls: [(name: String, input: JSONObject)] = []
    var result = ToolResult("Battery 76%, on power.")
    func definitions(for mode: ModeDefinition) -> [JSONObject] {
        [["name": "system_status", "description": "Battery and power.", "input_schema": ["type": "object", "properties": [String: Any]()]]]
    }
    func call(_ name: String, input: JSONObject, source: ToolCallSource) async -> ToolResult { calls.append((name, input)); return result }
    func recordServerTool(_ name: String, input: JSONObject) {}
}

@MainActor
final class IntentStageTests: XCTestCase {
    func testToolLoopAgainstScriptedModelAndFakeActions() async throws {
        let model = ScriptedModel(rounds: [
            [.blockStart(type: "tool_use"), .toolUseStart(id: "toolu_1", name: "system_status"), .toolInputDelta("{}"),
             .contentBlockStop, .stopReason("tool_use")],
            [.blockStart(type: "text"), .textDelta("Battery is at 76 percent."), .contentBlockStop, .stopReason("end_turn")],
        ])
        let actions = FakeActions()
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        let brain = Brain(client: model, dispatcher: actions, config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack())
        brain.privateMode = false

        var streamed = ""
        let reply = try await brain.respond(to: "how's the battery") { streamed += $0 }

        XCTAssertEqual(reply.text, "Battery is at 76 percent.")
        XCTAssertEqual(streamed, reply.text)
        XCTAssertEqual(reply.toolCalls, ["system_status"])
        XCTAssertEqual(actions.calls.map(\.name), ["system_status"], "the action stage ran exactly once")
        XCTAssertEqual(model.requests.count, 2, "one round to choose the tool, one to answer")
        // The second request carries the tool's result back to the model.
        let last = model.requests[1].messages.last?["content"] as? [JSONObject]
        XCTAssertEqual(last?.first?["type"] as? String, "tool_result")
        XCTAssertEqual(last?.first?["content"] as? String, "Battery 76%, on power.")
        XCTAssertEqual(model.requests[0].effort, config.tuning.llmEffort)
    }

    /// The API reports usage at message_start and again, cumulatively, at message_delta. Each round
    /// must be counted once. (Found on 2026-11-22: every token was being counted twice.)
    func testUsageIsCountedOncePerRound() async throws {
        let model = ScriptedModel(rounds: [
            [.usage(input: 190, output: 0, cacheRead: 10_405, cacheWrite: 0),
             .toolUseStart(id: "toolu_1", name: "system_status"), .toolInputDelta("{}"), .contentBlockStop,
             .stopReason("tool_use"), .usage(input: 190, output: 40, cacheRead: 10_405, cacheWrite: 0)],
            [.usage(input: 260, output: 0, cacheRead: 10_405, cacheWrite: 0),
             .textDelta("Battery is at 76 percent."), .contentBlockStop,
             .stopReason("end_turn"), .usage(input: 0, output: 25, cacheRead: 0, cacheWrite: 0)],   // a delta that only carries output
        ])
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        let brain = Brain(client: model, dispatcher: FakeActions(), config: config, modes: ModeManager(config: config, notch: notch), undo: UndoStack())
        brain.privateMode = false
        let reply = try await brain.respond(to: "battery?") { _ in }
        XCTAssertEqual(reply.inputTokens, 190 + 260)
        XCTAssertEqual(reply.outputTokens, 40 + 25)
        XCTAssertEqual(reply.cacheReadTokens, 10_405 * 2, "once per round, not once per usage event")
        XCTAssertEqual(reply.cacheWriteTokens, 0)
    }
}
