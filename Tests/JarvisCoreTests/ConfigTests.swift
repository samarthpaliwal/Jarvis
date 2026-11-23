import XCTest
@testable import JarvisCore

/// The shipped config files must parse and contain the safety floor.
final class ConfigTests: XCTestCase {
    static var repoConfigDir: URL {
        // Tests/JarvisCoreTests/ConfigTests.swift -> repo root -> config/
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config", isDirectory: true)
    }

    @MainActor
    func testShippedConfigParses() {
        let store = ConfigStore(directory: Self.repoConfigDir)
        XCTAssertEqual(store.errors, [], "config files should decode cleanly")
        XCTAssertEqual(store.profile.assistant.addressUserAs, "Sam")
        XCTAssertEqual(store.profile.claude.model, "claude-sonnet-5-5")
        XCTAssertNotNil(store.modes.mode(id: "class"))
        XCTAssertNotNil(store.modes.mode(id: "road"))
        XCTAssertEqual(store.modes.defaultMode, "home")
    }

    @MainActor
    func testDenylistAlwaysIncludesFloor() {
        let store = ConfigStore(directory: Self.repoConfigDir)
        XCTAssertTrue(store.denylist.paths.contains("~/.ssh"))
        XCTAssertTrue(store.denylist.paths.contains("~/Library/Keychains"))
        XCTAssertTrue(store.denylist.filePatterns.contains(".env"))
        XCTAssertTrue(store.denylist.shellPatterns.contains("sudo"))
    }

    @MainActor
    func testMissingDirectoryFallsBackAndReportsErrors() {
        let store = ConfigStore(directory: URL(fileURLWithPath: "/nonexistent/jarvis-config"))
        XCTAssertEqual(store.errors.count, 4)
        XCTAssertEqual(store.profile, .fallback)
        XCTAssertTrue(store.denylist.paths.contains("~/.ssh"))
    }

    func testClassModeIsQuiet() throws {
        let data = try Data(contentsOf: Self.repoConfigDir.appendingPathComponent("modes.json"))
        let modes = try JSONDecoder().decode(ModesConfig.self, from: data)
        let classMode = try XCTUnwrap(modes.mode(id: "class"))
        XCTAssertFalse(classMode.voice.enabled)
        XCTAssertTrue(classMode.holdNotifications)
    }
}

final class SettingsTests: XCTestCase {
    func testEnvFileParsingSkipsCommentsQuotesAndSecrets() {
        let text = """
        # comment
        export JARVIS_WAKE_THRESHOLD=0.35
        CLAUDE_MODEL="claude-sonnet-5-5"   
        JARVIS_LLM_EFFORT=medium # trailing comment
        ANTHROPIC_API_KEY=sk-ant-should-never-load
        SPOTIFY_CLIENT_SECRET=nope
        not a line
        """
        let parsed = Env.parse(text)
        XCTAssertEqual(parsed.values["JARVIS_WAKE_THRESHOLD"], "0.35")
        XCTAssertEqual(parsed.values["CLAUDE_MODEL"], "claude-sonnet-5-5")
        XCTAssertEqual(parsed.values["JARVIS_LLM_EFFORT"], "medium")
        XCTAssertNil(parsed.values["ANTHROPIC_API_KEY"], "secrets must never come from the env file")
        XCTAssertEqual(Set(parsed.ignoredSecrets), ["ANTHROPIC_API_KEY", "SPOTIFY_CLIENT_SECRET"])
    }

    func testEnvNames() {
        XCTAssertEqual(Tuning.envName(for: "wakeThreshold"), "JARVIS_WAKE_THRESHOLD")
        XCTAssertEqual(Tuning.envName(for: "openaiTtsModel"), "JARVIS_OPENAI_TTS_MODEL")
        XCTAssertEqual(Tuning.envName(for: "llmMaxToolRounds"), "JARVIS_LLM_MAX_TOOL_ROUNDS")
    }

    func testEnvOverridesTuningAndRejectsGarbage() {
        let r = Tuning().applying(env: ["JARVIS_WAKE_THRESHOLD": "0.3", "JARVIS_LLM_MAX_TOOL_ROUNDS": "4",
                                        "JARVIS_LLM_EFFORT": "medium", "JARVIS_KOKORO_PORT": "abc", "JARVIS_APPROVAL_TIMEOUT_SECONDS": "-5"])
        XCTAssertEqual(r.tuning.wakeThreshold, 0.3)
        XCTAssertEqual(r.tuning.llmMaxToolRounds, 4)
        XCTAssertEqual(r.tuning.llmEffort, "medium")
        XCTAssertEqual(r.tuning.kokoroPort, 8880, "a bad value keeps the default")
        XCTAssertEqual(r.tuning.approvalTimeoutSeconds, 12)
        XCTAssertEqual(r.applied, ["JARVIS_LLM_EFFORT", "JARVIS_LLM_MAX_TOOL_ROUNDS", "JARVIS_WAKE_THRESHOLD"])
        XCTAssertEqual(r.rejected.count, 2)
    }

    func testPartialTuningInProfileKeepsDefaults() throws {
        let t = try JSONDecoder().decode(Tuning.self, from: Data(#"{"wakeThreshold": 0.4, "somethingNew": 1}"#.utf8))
        XCTAssertEqual(t.wakeThreshold, 0.4)
        XCTAssertEqual(t.llmMaxHistoryMessages, 24)
    }

    /// Every field must be read back from JSON and be overridable. A field added to the struct but not to
    /// the decoder would silently keep its default.
    func testEveryTuningFieldCanBeOverridden() throws {
        let defaults = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Tuning())) as? [String: Any])
        var env: [String: String] = [:]
        for (field, value) in defaults { env[Tuning.envName(for: field)] = value is String ? "changed" : "7" }
        let r = Tuning().applying(env: env)
        XCTAssertTrue(r.rejected.isEmpty, "\(r.rejected)")
        let changed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(r.tuning)) as? [String: Any])
        for (field, value) in changed {
            if value is String { XCTAssertEqual(value as? String, "changed", field) }
            else { XCTAssertEqual((value as? NSNumber)?.doubleValue, 7, field) }
        }
    }

    @MainActor func testRepoProfileTuningMatchesCodeDefaults() {
        let store = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        XCTAssertTrue(store.errors.isEmpty, "\(store.errors)")
        XCTAssertEqual(store.tuning, Tuning(), "config/profile.json tuning drifted from the defaults in Settings.swift")
    }

    /// .env.example must document every override, and must never contain a real-looking secret.
    func testEnvExampleDocumentsEveryTuningVariable() throws {
        let example = try String(contentsOf: ConfigTests.repoConfigDir.deletingLastPathComponent().appendingPathComponent(".env.example"), encoding: .utf8)
        for entry in Tuning.envNames {
            XCTAssertTrue(example.contains(entry.env + "="), "\(entry.env) (\(entry.field)) is missing from .env.example")
        }
        XCTAssertFalse(example.contains("sk-ant-"))
        XCTAssertTrue(Env.parse(example).values.isEmpty, "everything in the example must be commented out")
    }
}
