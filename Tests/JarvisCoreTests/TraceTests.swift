import XCTest
@testable import JarvisCore

final class TraceTests: XCTestCase {
    /// A clock the test moves by hand.
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_000_000); func advance(_ ms: Double) { t += ms / 1000 } }

    func testSummaryHasPerStageLatency() {
        let clock = Clock(), sink = TraceSink(file: nil)
        let r = RequestTrace(source: "wake", sink: sink, id: "r-test01", now: { clock.t })
        r.event(.heard, "wake")
        clock.advance(900);  r.event(.transcribed, "first_word")
        clock.advance(2100); r.event(.transcribed, "speech_end", ["reason": "silenceAfterSpeech", "chars": 30])
        clock.advance(1500); r.event(.intent, "first_token")
        r.tool("calendar_read", ms: 320, outcome: "ran", tier: 0)
        clock.advance(700);  r.event(.spoken, "first_audio", ["engine": "kokoro"])
        clock.advance(300);  r.event(.intent, "llm_done")
        clock.advance(4000); r.event(.spoken, "speech_done")
        r.set("tokens", ["in": 700, "out": 60])
        let s = r.finish(outcome: "spoken")

        let ms = s["ms"] as? [String: Any]
        XCTAssertEqual(ms?["first_word"] as? Double, 900)
        XCTAssertEqual(ms?["listen"] as? Double, 3000)
        XCTAssertEqual(ms?["llm_first_token"] as? Double, 1500)
        XCTAssertEqual(ms?["first_audio"] as? Double, 2200)
        XCTAssertEqual(ms?["llm_total"] as? Double, 2500)
        XCTAssertEqual(ms?["tools"] as? Double, 320)
        XCTAssertEqual(ms?["total"] as? Double, 9500)
        XCTAssertEqual(s["stages"] as? [String], ["heard", "transcribed", "intent", "action", "spoken"], "every stage, in order")
        XCTAssertEqual(s["outcome"] as? String, "spoken")
        XCTAssertEqual(s["request"] as? String, "r-test01")

        // Every line carries the request ID; exactly one summary line.
        XCTAssertTrue(sink.recent.allSatisfy { $0["request"] as? String == "r-test01" })
        XCTAssertEqual(sink.recentRequests.count, 1)
    }

    func testFinishIsIdempotentAndLateEventsAreDropped() {
        let sink = TraceSink(file: nil)
        let r = RequestTrace(source: "text", sink: sink)
        XCTAssertEqual(r.finish(outcome: "cancelled")["outcome"] as? String, "cancelled")
        XCTAssertEqual(r.finish(outcome: "spoken")["outcome"] as? String, "cancelled", "the first outcome wins")
        r.event(.spoken, "speech_done")
        XCTAssertEqual(sink.recent.count, 1)
        XCTAssertTrue(r.isFinished)
    }

    func testMissingStagesAreOmittedNotZero() {
        let r = RequestTrace(source: "wake", sink: TraceSink(file: nil))
        r.event(.heard, "wake")
        let ms = r.finish(outcome: "no_speech")["ms"] as? [String: Any]
        XCTAssertNil(ms?["llm_first_token"])
        XCTAssertNil(ms?["first_audio"])
        XCTAssertNotNil(ms?["total"])
    }

    func testRequestIDFollowsTheTaskIntoNestedWork() async {
        let r = RequestTrace(source: "text", sink: TraceSink(file: nil), id: "r-abc123")
        XCTAssertNil(RequestTrace.current)
        await RequestTrace.$current.withValue(r) {
            XCTAssertEqual(RequestTrace.current?.id, "r-abc123")
            // An unstructured child task (how the reply stream hops to the main actor) inherits it.
            let inner = await Task { RequestTrace.current?.id }.value
            XCTAssertEqual(inner, "r-abc123")
        }
        XCTAssertNil(RequestTrace.current)
    }

    func testIDsLookRight() {
        let id = RequestTrace.newID()
        XCTAssertTrue(id.hasPrefix("r-"))
        XCTAssertEqual(id.count, 8)
    }

    func testTraceFileIsValidJSONLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-trace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = FileLog(url: dir.appendingPathComponent("trace.jsonl"))
        let r = RequestTrace(source: "wake", sink: TraceSink(file: file))
        r.event(.heard, "wake", ["mode": "home"])
        r.tool("web_search", ms: nil, outcome: "ran")
        r.finish(outcome: "spoken")
        file.flush()
        let lines = try String(contentsOf: file.url, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            XCTAssertEqual(obj?["request"] as? String, r.id)
            XCTAssertNotNil(obj?["ts"])
        }
    }

    func testLogRotatesBySizeAndKeepsLimitedHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-rot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (oldMax, oldKeep) = (FileLog.maxBytes, FileLog.keepFiles)
        defer { FileLog.maxBytes = oldMax; FileLog.keepFiles = oldKeep }
        FileLog.maxBytes = 300; FileLog.keepFiles = 2
        let log = FileLog(url: dir.appendingPathComponent("x.log"))
        for i in 0..<40 { log.writeRaw("line \(i) " + String(repeating: "x", count: 40)) }
        log.flush()
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(names, ["x.log", "x.log.1", "x.log.2"], "current file plus two rotated ones, nothing older")
        let current = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertTrue(current.contains("line 39"))
        XCTAssertLessThanOrEqual(current.utf8.count, 300)
    }

    func testTestsDoNotWriteToTheRealLogs() {
        XCTAssertTrue(Runtime.isTesting)
        XCTAssertFalse(FileLog.directory.path.contains("Library/Logs/Jarvis"))
    }
}
