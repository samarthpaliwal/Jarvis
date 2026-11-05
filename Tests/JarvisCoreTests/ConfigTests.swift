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
