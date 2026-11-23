import XCTest
@testable import JarvisCore

final class PrivacyTests: XCTestCase {
    func snapshot(server: Bool = false, voice: String = "kokoro", google: Bool = false, remote: Bool = false) -> PrivacySnapshot {
        PrivacySnapshot(transcriber: "test", transcriberUsesServer: server, voiceEngine: voice, claudeConfigured: true, googleConnected: google,
                        notionConnected: false, spotifyConnected: false, remoteListening: remote, voiceIDEnrolled: true)
    }

    func testWithTheDefaultSetupNoAudioLeavesTheMac() {
        let flows = Privacy.flows(snapshot(remote: true))
        XCTAssertTrue(Privacy.audioLeavingMac(flows).isEmpty)
        for f in flows where f.kind == .audio { XCTAssertFalse(f.leavesMac, f.stage) }
        XCTAssertTrue(flows.contains { $0.stage == "Wake word" }); XCTAssertTrue(flows.contains { $0.stage == "Voice ID" }); XCTAssertTrue(flows.contains { $0.stage == "Remote access" })
        XCTAssertTrue(Privacy.summary(flows).hasPrefix("No audio leaves this Mac."))
        // What does leave is named, with who gets it.
        XCTAssertEqual(flows.first { $0.stage == "Thinking" }?.destination, "Anthropic")
        XCTAssertEqual(flows.first { $0.stage == "Looking" }?.kind, .image)
        XCTAssertEqual(flows.first { $0.stage == "Speaking" }?.leavesMac, false, "Kokoro speaks on this Mac")
        XCTAssertFalse(flows.contains { $0.destination == "Google" }, "not connected: not listed")
    }

    func testAStageThatSendsAudioAwayIsFlagged() {
        let flows = Privacy.flows(snapshot(server: true))
        XCTAssertEqual(Privacy.audioLeavingMac(flows).map(\.stage), ["Speech recognition"])
        XCTAssertTrue(Privacy.summary(flows).hasPrefix("AUDIO LEAVES THIS MAC: Speech recognition."))
    }

    func testCloudVoicesAndIntegrationsAreListedWhenInUse() {
        let flows = Privacy.flows(snapshot(voice: "elevenlabs", google: true))
        XCTAssertEqual(flows.first { $0.stage == "Speaking" }?.destination, "ElevenLabs")
        XCTAssertEqual(flows.first { $0.stage == "Speaking" }?.kind, .text, "reply text, not your voice")
        XCTAssertTrue(flows.contains { $0.destination == "Google" })
        XCTAssertTrue(Privacy.summary(flows).contains("ElevenLabs"))
    }

    func testCloudSpeechRecognitionIsOffUnlessAllowed() {
        XCTAssertEqual(Tuning().cloudSpeechRecognition, "never")
        XCTAssertFalse(AppleSpeechTranscriber.allowServer)
        final class OnDevice: Transcriber { let name = "x"; let isAvailable = true
            func requestAuthorization() async -> Bool { true }
            func start(onUpdate: @escaping (TranscriptUpdate) -> Void, onError: @escaping (Error) -> Void) throws {}
            func append(samples: [Float]) {}; func finish() {}; func cancel() {} }
        XCTAssertFalse(OnDevice().sendsAudioOffDevice, "an engine is on-device unless it says otherwise")
    }
}

final class RetentionTests: XCTestCase {
    let now = ISO8601DateFormatter().date(from: "2026-11-23T12:00:00Z")!
    var dir: URL!
    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-retention-\(UUID().uuidString)"); try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testOldLinesGoAndRecentOnesStay() {
        let text = """
        2026-10-01T09:00:00.000Z [CHAT] you: old question
          a continuation line of the old entry
        {"tool":"email_send","timestamp":"2026-10-02T09:00:00Z","outcome":"ran"}
        2026-11-20T09:00:00.000Z [CHAT] you: recent question
          its continuation
        {"event":"state","ts":"2026-11-22T10:00:00.123Z"}
        """
        let r = Retention.prune(text, olderThan: now.addingTimeInterval(-30 * 86_400))
        XCTAssertEqual(r.removed, 3)
        XCTAssertFalse(r.text.contains("old question")); XCTAssertFalse(r.text.contains("continuation line of the old")); XCTAssertFalse(r.text.contains("email_send"))
        XCTAssertTrue(r.text.contains("recent question")); XCTAssertTrue(r.text.contains("its continuation")); XCTAssertTrue(r.text.contains("2026-11-22T10:00:00.123Z"))
        XCTAssertEqual(Retention.prune(r.text, olderThan: now.addingTimeInterval(-30 * 86_400)).removed, 0, "nothing more to remove the second time")
        XCTAssertEqual(Retention.prune("no timestamps here\nat all", olderThan: now).removed, 0, "lines that cannot be dated are left alone")
    }

    func testEachLogHasItsOwnLimitAndNothingElseIsTouched() throws {
        func line(_ daysAgo: Double, _ what: String) -> String { "\(ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * 86_400))) [INFO] \(what)\n" }
        for file in ["conversations.log", "trace.jsonl", "jarvis.log", "actions.log", "unrelated.txt"] {
            try (line(100, "d100") + line(40, "d40") + line(20, "d20") + line(1, "d1")).write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        try line(100, "rotated").write(to: dir.appendingPathComponent("jarvis.log.2"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-100 * 86_400)], ofItemAtPath: dir.appendingPathComponent("jarvis.log.2").path)
        let report = Retention.sweep(Retention.Policy(), logs: dir, now: now)
        func read(_ f: String) -> String { (try? String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8)) ?? "" }
        XCTAssertFalse(read("conversations.log").contains("d40")); XCTAssertTrue(read("conversations.log").contains("d20"))           // 30 days
        XCTAssertFalse(read("jarvis.log").contains("d20")); XCTAssertTrue(read("jarvis.log").contains("d1"))                             // 14 days
        XCTAssertFalse(read("actions.log").contains("d100")); XCTAssertTrue(read("actions.log").contains("d40"))                         // 90 days
        XCTAssertTrue(read("unrelated.txt").contains("d100"), "a file that is not one of Jarvis's logs is never touched")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("jarvis.log.2").path), "an old rotated file is removed whole")
        XCTAssertEqual(report.filesRemoved, 1); XCTAssertEqual(report.linesRemoved, 2 + 2 + 3 + 1)

        let forever = Retention.sweep(Retention.Policy(conversationsDays: 0, traceDays: 0, logDays: 0, actionsDays: 0), logs: dir, now: now.addingTimeInterval(400 * 86_400))
        XCTAssertTrue(forever.isEmpty, "0 days means keep forever"); XCTAssertTrue(read("jarvis.log").contains("d1"))
    }

    func testRecordingsAreKeptUnlessALimitIsSetAndThenOnlyJarvisFilesGoToTheTrash() throws {
        let media = dir.appendingPathComponent("Movies"); try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        for (name, age) in [("Jarvis 2026-08-01 at 10.00.00.mov", 100.0), ("Jarvis 2026-11-22 at 23.41.05.mov", 1.0), ("family.mov", 300.0)] {
            let f = media.appendingPathComponent(name); try Data("x".utf8).write(to: f)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age * 86_400)], ofItemAtPath: f.path)
        }
        XCTAssertEqual(Retention.sweep(Retention.Policy(), logs: dir, media: [media], now: now).mediaTrashed, 0, "by default recordings are kept")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: media.path).count, 3)
        XCTAssertEqual(Retention.Policy(Tuning()), Retention.Policy(), "the documented defaults are the real ones")
    }

    func testPruningALogThatIsBeingWrittenLosesNothing() throws {
        let log = FileLog(url: dir.appendingPathComponent("live.log"))
        log.writeRaw("2020-01-01T00:00:00Z [INFO] ancient")
        for i in 0..<200 { log.write(level: "INFO", "line \(i)") }
        let removed = FileLog.rewrite(log.url) { Retention.prune($0, olderThan: Date().addingTimeInterval(-86_400)) }
        for i in 200..<400 { log.write(level: "INFO", "line \(i)") }
        log.flush()
        let text = try String(contentsOf: log.url, encoding: .utf8)
        XCTAssertEqual(removed, 1); XCTAssertFalse(text.contains("ancient"))
        XCTAssertEqual(text.split(separator: "\n").count, 400, "every line written before and after the sweep is there")
    }
}
