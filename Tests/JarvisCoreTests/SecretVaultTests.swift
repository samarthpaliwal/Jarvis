import XCTest
@testable import JarvisCore

/// Stands in for jarvis-keyhelper: a vault, an old store, and a Touch ID that can be made to fail.
final class FakeKeyHelper: KeyHelperRunning, @unchecked Sendable {
    var vault: [String: String] = [:]
    var legacy: [String: String] = [:]
    var touchID = true
    var fingerMatches = true
    /// Old items the user declines the keychain password prompt for.
    var declines: Set<String> = []
    var commands: [String] = []
    var prompts = 0

    func run(_ command: String, input: [String: Any], timeout: TimeInterval) throws -> [String: Any] {
        commands.append(command)
        let accounts = input["accounts"] as? [String] ?? []
        func authenticate() throws {
            guard touchID else { return }
            prompts += 1
            if !fingerMatches { throw VaultError.locked("canceled") }
        }
        switch command {
        case "status":
            return ["ok": true, "vault": accounts.filter { vault[$0] != nil }, "legacy": accounts.filter { legacy[$0] != nil }, "policy": touchID ? "touchid" : "none"]
        case "get":
            try authenticate()
            return ["ok": true, "values": vault.filter { accounts.contains($0.key) }, "needs_approval": [String]()]
        case "import":
            try authenticate()
            var imported: [String] = [], denied: [String] = []
            for a in accounts where vault[a] == nil && legacy[a] != nil {
                if declines.contains(a) { denied.append(a) } else { vault[a] = legacy[a]; imported.append(a) }
            }
            return ["ok": true, "values": vault.filter { accounts.contains($0.key) }, "imported": imported, "denied": denied, "needs_approval": [String]()]
        case "set": vault[input["account"] as! String] = input["value"] as? String; return ["ok": true]
        case "delete": vault[input["account"] as! String] = nil; return ["ok": true]
        case "policy":
            let require = input["require"] as? String
            if require == "none" { try authenticate() }
            touchID = require == "touchid"
            return ["ok": true]
        default: throw VaultError.helperFailed("unknown command")
        }
    }
}

final class SecretVaultTests: XCTestCase {
    func testNothingIsReadableUntilUnlockedThenEverythingComesFromMemory() {
        let helper = FakeKeyHelper()
        helper.vault = ["ANTHROPIC_API_KEY": "sk-ant-test", "NOTION_TOKEN": "ntn_test"]
        let vault = SecretVault(helper: helper)
        XCTAssertEqual(vault.state, .locked)
        XCTAssertNil(vault.read("ANTHROPIC_API_KEY"), "locked: no key, and no prompt")
        XCTAssertEqual(helper.prompts, 0)

        let report = vault.unlock()
        XCTAssertEqual(report.state, .unlocked)
        XCTAssertEqual(report.present, ["ANTHROPIC_API_KEY", "NOTION_TOKEN"])
        XCTAssertEqual(helper.prompts, 1, "one Touch ID for everything")

        let callsBefore = helper.commands.count
        for _ in 0..<50 { XCTAssertEqual(vault.read("ANTHROPIC_API_KEY"), "sk-ant-test") }
        XCTAssertEqual(vault.read("NOTION_TOKEN"), "ntn_test")
        XCTAssertNil(vault.read("OPENAI_API_KEY"), "never set")
        XCTAssertEqual(helper.commands.count, callsBefore, "reads never go back to the helper or the Keychain")
        XCTAssertEqual(helper.prompts, 1)
    }

    func testFirstRunMovesOldKeysInAndNeverAsksForThemAgain() {
        let helper = FakeKeyHelper()
        helper.legacy = ["ANTHROPIC_API_KEY": "sk-ant-old", "GOOGLE_REFRESH_TOKEN": "1//refresh", "GOOGLE_CLIENT_ID": "id.apps.googleusercontent.com"]
        var vault = SecretVault(helper: helper)
        let first = vault.unlock()
        XCTAssertEqual(first.imported, ["ANTHROPIC_API_KEY", "GOOGLE_CLIENT_ID", "GOOGLE_REFRESH_TOKEN"])
        XCTAssertEqual(vault.read("GOOGLE_REFRESH_TOKEN"), "1//refresh")
        XCTAssertTrue(helper.commands.contains("import"))

        // The next launch: everything is already in the vault, so nothing is imported.
        helper.commands = []
        vault = SecretVault(helper: helper)
        let second = vault.unlock()
        XCTAssertEqual(second.imported, [])
        XCTAssertEqual(helper.commands, ["status", "get"])
        XCTAssertEqual(vault.read("ANTHROPIC_API_KEY"), "sk-ant-old")
    }

    func testAKeyWhosePromptWasDeclinedStillWorksTheOldWay() {
        let helper = FakeKeyHelper()
        helper.legacy = ["ANTHROPIC_API_KEY": "sk-ant-old", "NOTION_TOKEN": "ntn_old"]
        helper.declines = ["NOTION_TOKEN"]
        let vault = SecretVault(helper: helper)
        var oldReads: [String] = []
        vault.legacyReader = { account in oldReads.append(account); return account == "NOTION_TOKEN" ? "ntn_old" : nil }
        let report = vault.unlock()
        XCTAssertEqual(report.imported, ["ANTHROPIC_API_KEY"])
        XCTAssertEqual(report.denied, ["NOTION_TOKEN"])
        // Not moved: read through the old path, exactly once, then from memory. Nothing that worked stops working.
        XCTAssertEqual(vault.read("NOTION_TOKEN"), "ntn_old")
        XCTAssertEqual(vault.read("NOTION_TOKEN"), "ntn_old")
        XCTAssertEqual(oldReads, ["NOTION_TOKEN"])
        XCTAssertNil(vault.read("OPENAI_API_KEY"))
        XCTAssertEqual(oldReads, ["NOTION_TOKEN"], "a key that never existed does not touch the old Keychain")
    }

    func testCancelledTouchIDLeavesTheVaultLockedAndCanBeRetried() {
        let helper = FakeKeyHelper()
        helper.vault = ["ANTHROPIC_API_KEY": "sk-ant-test"]
        helper.fingerMatches = false
        let vault = SecretVault(helper: helper)
        XCTAssertEqual(vault.unlock().state, .locked)
        XCTAssertNil(vault.read("ANTHROPIC_API_KEY"))
        helper.fingerMatches = true
        XCTAssertEqual(vault.unlock().state, .unlocked)
        XCTAssertEqual(vault.read("ANTHROPIC_API_KEY"), "sk-ant-test")
    }

    func testSavingAndRemovingAKey() throws {
        let helper = FakeKeyHelper()
        let vault = SecretVault(helper: helper)
        _ = vault.unlock()
        try vault.write("  sk-ant-new\n", account: "ANTHROPIC_API_KEY")
        XCTAssertEqual(helper.vault["ANTHROPIC_API_KEY"], "sk-ant-new", "stored trimmed, through the helper")
        XCTAssertEqual(vault.read("ANTHROPIC_API_KEY"), "sk-ant-new", "usable at once, no second Touch ID")
        vault.delete("ANTHROPIC_API_KEY")
        XCTAssertNil(helper.vault["ANTHROPIC_API_KEY"])
        XCTAssertNil(vault.read("ANTHROPIC_API_KEY"))
        XCTAssertEqual(helper.prompts, 1)
    }

    func testTurningTouchIDOffNeedsTouchID() throws {
        let helper = FakeKeyHelper()
        let vault = SecretVault(helper: helper)
        helper.fingerMatches = false
        XCTAssertThrowsError(try vault.setRequiresTouchID(false))
        XCTAssertTrue(helper.touchID, "someone who cannot pass Touch ID cannot switch it off")
        helper.fingerMatches = true
        try vault.setRequiresTouchID(false)
        XCTAssertFalse(helper.touchID)
        XCTAssertEqual(vault.status()?.touchID, false)
    }

    func testWithoutTheHelperTheOldPathIsCachedSoMacOSAsksOncePerKey() {
        let vault = SecretVault(helper: nil)
        XCTAssertEqual(vault.state, .legacy)
        var reads = 0
        vault.legacyReader = { account in reads += 1; return account == "ANTHROPIC_API_KEY" ? "sk-ant-old" : nil }
        for _ in 0..<20 { XCTAssertEqual(vault.read("ANTHROPIC_API_KEY"), "sk-ant-old") }
        for _ in 0..<20 { XCTAssertNil(vault.read("ELEVENLABS_API_KEY")) }
        XCTAssertEqual(reads, 2, "one Keychain read per key per launch, not one per request")
    }

    func testAFailingHelperIsReportedNotFatal() {
        final class Broken: KeyHelperRunning, @unchecked Sendable {
            func run(_ command: String, input: [String: Any], timeout: TimeInterval) throws -> [String: Any] { throw VaultError.helperFailed("refused: caller is not Jarvis") }
        }
        let vault = SecretVault(helper: Broken())
        let report = vault.unlock()
        if case .failed(let why) = report.state { XCTAssertTrue(why.contains("refused")) } else { XCTFail("\(report.state)") }
        XCTAssertNil(vault.read("ANTHROPIC_API_KEY"))
    }

    func testUnitTestsNeverTouchTheRealKeychain() throws {
        XCTAssertNil(KeychainStore.read(account: "SOME_ACCOUNT_THAT_IS_NOT_SET"))
        try KeychainStore.write("value", account: "TEST_ONLY")
        XCTAssertEqual(KeychainStore.read(account: "TEST_ONLY"), "value")
        KeychainStore.delete(account: "TEST_ONLY")
        XCTAssertNil(KeychainStore.read(account: "TEST_ONLY"))
        XCTAssertEqual(SecretVault.shared.state, .legacy, "the shared vault is never configured with a helper under test")
    }

    func testEveryAccountInTheCodeIsKnownToTheVault() {
        for account in [KeychainStore.apiKeyAccount, GoogleAuth.clientIDAccount, GoogleAuth.clientSecretAccount, GoogleAuth.refreshTokenAccount,
                        NotionClient.tokenAccount, SpotifySearch.clientIDAccount, SpotifySearch.clientSecretAccount,
                        CloudSpeechOutput.elevenLabsKeyAccount, CloudSpeechOutput.openAIKeyAccount] {
            XCTAssertTrue(SecretVault.accounts.contains(account), "\(account) would never be unlocked")
        }
    }
}
