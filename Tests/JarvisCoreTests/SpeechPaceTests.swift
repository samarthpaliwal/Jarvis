import XCTest
@testable import JarvisCore

@MainActor
final class SpeechPaceTests: XCTestCase {
    private var dir: URL!
    private var savedPace = SpeechPace.current

    override func setUp() async throws {
        savedPace = SpeechPace.current
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pace-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws {
        SpeechPace.current = savedPace
        try? FileManager.default.removeItem(at: dir)
    }

    /// The repo's own sample profile, with one key Jarvis does not know about added.
    private func writeProfile() throws {
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config/profile.json")
        var root = try JSONSerialization.jsonObject(with: Data(contentsOf: sample)) as! [String: Any]
        root["_comment"] = "keep me"
        root["somethingJarvisDoesNotKnow"] = ["a": 1]
        var assistant = root["assistant"] as! [String: Any]
        assistant.removeValue(forKey: "speechSpeed")
        root["assistant"] = assistant
        try JSONSerialization.data(withJSONObject: root).write(to: dir.appendingPathComponent("profile.json"))
    }

    func testDefaultIsThirtyPercentFaster() {
        XCTAssertEqual(Profile.fallback.assistant.pace, 1.3)
        XCTAssertEqual(SpeechPace.defaultSpeed, 1.3)
    }

    func testClampAndNudge() {
        XCTAssertEqual(SpeechPace.clamp(9), 2.0)
        XCTAssertEqual(SpeechPace.clamp(0.1), 0.7)
        XCTAssertEqual(SpeechPace.clamp(.nan), 1.3)
        XCTAssertEqual(SpeechPace.nudged(1.3, faster: true), 1.4)
        XCTAssertEqual(SpeechPace.nudged(1.3, faster: false), 1.2)
        XCTAssertEqual(SpeechPace.nudged(2.0, faster: true), 2.0)
        XCTAssertEqual(SpeechPace.nudged(0.7, faster: false), 0.7)
    }

    func testEveryEngineFollowsTheOneSetting() {
        XCTAssertEqual(SpeechPace.kokoro(base: 1.0, speed: 1.3), 1.3)
        XCTAssertEqual(SpeechPace.kokoro(base: 1.0, speed: 1.0), 1.0)
        XCTAssertEqual(SpeechPace.elevenLabs(speed: 1.3), 1.2, "ElevenLabs tops out at 1.2")
        XCTAssertEqual(SpeechPace.elevenLabs(speed: 1.1), 1.1)
        XCTAssertEqual(SpeechPace.appleRate(base: 0.52, speed: 1.0), 0.52, accuracy: 0.001)
        XCTAssertGreaterThan(SpeechPace.appleRate(base: 0.52, speed: 1.3), 0.58)
        XCTAssertLessThanOrEqual(SpeechPace.appleRate(base: 0.52, speed: 2.0), 0.8)

        SpeechPace.current = 1.4
        let kokoro = CloudSpeechOutput(provider: .kokoro, voice: Profile.Voice())
        XCTAssertEqual(kokoro.payload(for: "hi")["speed"] as? Double, 1.4)
        let eleven = CloudSpeechOutput(provider: .elevenlabs, voice: Profile.Voice())
        XCTAssertEqual((eleven.payload(for: "hi")["voice_settings"] as? JSONObject)?["speed"] as? Double, 1.2)
    }

    func testSavingKeepsTheRestOfTheFile() throws {
        try writeProfile()
        let store = ConfigStore(directory: dir, env: [:])
        XCTAssertTrue(store.errors.filter { $0.contains("profile") }.isEmpty, "\(store.errors)")
        XCTAssertEqual(store.profile.assistant.pace, 1.3, "an older file with no speechSpeed gets the default")
        try store.save(speechSpeed: 1.5)
        XCTAssertEqual(store.profile.assistant.pace, 1.5)
        XCTAssertEqual(SpeechPace.current, 1.5)

        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("profile.json"))) as! [String: Any]
        XCTAssertEqual(root["_comment"] as? String, "keep me")
        XCTAssertNotNil(root["somethingJarvisDoesNotKnow"])
        XCTAssertEqual((root["assistant"] as? [String: Any])?["speechSpeed"] as? Double, 1.5)
        XCTAssertNotNil((root["assistant"] as? [String: Any])?["name"])

        let again = ConfigStore(directory: dir, env: [:])
        XCTAssertEqual(again.profile.assistant.pace, 1.5, "it survives a restart")
    }

    func testSavingRefusesToReplaceABrokenFile() throws {
        try "{ not json".write(to: dir.appendingPathComponent("profile.json"), atomically: true, encoding: .utf8)
        let store = ConfigStore(directory: dir, env: [:])
        XCTAssertThrowsError(try store.save(speechSpeed: 1.5))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("profile.json"), encoding: .utf8), "{ not json")
    }

    func testToolNudgesSavesAndUndoes() async throws {
        var speed = 1.3
        let tool = SpeechSpeedTool(read: { speed }, save: { speed = $0 })
        let config = ConfigStore(directory: dir, env: [:])
        let notch = NotchViewModel()
        let undo = UndoStack()
        let ctx = ToolContext(config: config, modes: ModeManager(config: config, notch: notch), undo: undo, notch: notch)
        let modeBefore = UserDefaults.standard.string(forKey: "jarvis.currentMode")
        defer { UserDefaults.standard.set(modeBefore, forKey: "jarvis.currentMode") }
        var r = try await tool.run(input: ["action": "faster"], context: ctx)
        XCTAssertFalse(r.isError); XCTAssertEqual(speed, 1.4)
        r = try await tool.run(input: ["action": "slower"], context: ctx)
        r = try await tool.run(input: ["action": "slower"], context: ctx)
        XCTAssertEqual(speed, 1.2)
        r = try await tool.run(input: ["action": "set", "speed": 5], context: ctx)
        XCTAssertEqual(speed, 2.0)
        r = try await tool.run(input: ["action": "faster"], context: ctx)
        XCTAssertTrue(r.content.contains("Nothing changed")); XCTAssertEqual(speed, 2.0)
        r = try await tool.run(input: ["action": "reset"], context: ctx)
        XCTAssertEqual(speed, 1.3)
        XCTAssertFalse(undo.entries.isEmpty, "a speed change can be undone")
        r = try await tool.run(input: ["action": "sideways"], context: ctx)
        XCTAssertTrue(r.isError)
    }

    func testOfflinePhrases() {
        XCTAssertEqual(Brain.speechSpeedAction("talk faster"), "faster")
        XCTAssertEqual(Brain.speechSpeedAction("can you speak a bit slower please"), "slower")
        XCTAssertEqual(Brain.speechSpeedAction("you talk too fast"), "slower")
        XCTAssertEqual(Brain.speechSpeedAction("talk at normal speed"), "reset")
        XCTAssertNil(Brain.speechSpeedAction("play something faster"))
        XCTAssertNil(Brain.speechSpeedAction("talk to me about cars"))
    }
}
