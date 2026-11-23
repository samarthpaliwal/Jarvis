import XCTest
@testable import JarvisCore

final class HostedBrainTests: XCTestCase {
    func testWhoAnswers() {
        func plan(_ choice: String, privateMode: Bool = false, online: Bool = true, claude: Bool = true, hosted: Bool = true) -> String {
            let p = Brain.plan(choice: choice, privateMode: privateMode, online: online, claudeReady: claude, hostedReady: hosted)
            return p.first.rawValue + (p.fallback.map { ">" + $0.rawValue } ?? "")
        }
        XCTAssertEqual(plan("claude"), "claude>hosted", "Claude answers; the hosted model steps in by itself when Claude cannot")
        XCTAssertEqual(plan("hosted"), "hosted>claude")
        XCTAssertEqual(plan("claude", hosted: false), "claude", "no Ollama key: exactly as before")
        XCTAssertEqual(plan("hosted", hosted: false), "claude", "chosen but not set up: Claude, not silence")
        XCTAssertEqual(plan("claude", claude: false), "hosted")
        XCTAssertEqual(plan("anything else"), "claude>hosted")
        // Private Mode and offline never use a hosted model: it is still someone else's computer.
        for choice in ["claude", "hosted"] {
            XCTAssertEqual(plan(choice, privateMode: true), "local", choice)
            XCTAssertEqual(plan(choice, online: false), "local", choice)
        }
    }

    func testWhenTheOtherBrainStepsIn() {
        XCTAssertTrue(Brain.shouldFallBack(from: ClaudeClient.ClientError.noAPIKey))
        XCTAssertTrue(Brain.shouldFallBack(from: ClaudeClient.ClientError.http(529, "overloaded")))
        XCTAssertTrue(Brain.shouldFallBack(from: ClaudeClient.ClientError.http(429, "rate limited")))
        XCTAssertTrue(Brain.shouldFallBack(from: ClaudeClient.ClientError.http(401, "bad key")))
        XCTAssertTrue(Brain.shouldFallBack(from: BudgetError.dailyCapReached(spent: 3, cap: 3)))
        XCTAssertTrue(Brain.shouldFallBack(from: URLError(.notConnectedToInternet)))
        XCTAssertFalse(Brain.shouldFallBack(from: ClaudeClient.ClientError.http(400, "bad request")), "a malformed request is our bug, not a reason to send it elsewhere")
        XCTAssertFalse(Brain.shouldFallBack(from: CancellationError()), "stopped by the user")
    }

    func testTheHostedRequestCarriesTheKeyAndALocalOneNever() throws {
        let hosted = OllamaClient.hosted(model: "gpt-oss:120b", apiKey: { "test-key" })
        XCTAssertTrue(hosted.isHosted); XCTAssertTrue(hosted.hasKey)
        let r = try hosted.request(messages: [["role": "user", "content": "hi"]], tools: [])
        XCTAssertEqual(r.url?.absoluteString, "https://ollama.com/api/chat")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(r.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-oss:120b"); XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertNil(body["keep_alive"], "nothing to keep loaded: it does not run here")

        let local = OllamaClient(model: "qwen3.5:9b")
        XCTAssertFalse(local.isHosted)
        let l = try local.request(messages: [], tools: [])
        XCTAssertNil(l.value(forHTTPHeaderField: "Authorization")); XCTAssertEqual(l.url?.host, "127.0.0.1")

        // No key, or an address that is not https: no request is made at all.
        XCTAssertFalse(OllamaClient.hosted(model: "m", apiKey: { nil }).hasKey)
        XCTAssertThrowsError(try OllamaClient.hosted(model: "m", apiKey: { nil }).request(messages: [], tools: []))
        XCTAssertThrowsError(try OllamaClient.hosted(model: "m", apiKey: { "" }).request(messages: [], tools: []))
        XCTAssertThrowsError(try OllamaClient.hosted(baseURL: URL(string: "http://example.com")!, model: "m", apiKey: { "k" }).request(messages: [], tools: []),
                             "the key is never sent in the clear")
    }

    func testThePrivacyMapNamesIt() {
        func flows(hosted: String?, privateMode: Bool) -> [DataFlow] {
            Privacy.flows(PrivacySnapshot(transcriber: "t", transcriberUsesServer: false, voiceEngine: "kokoro", claudeConfigured: true, hostedModel: hosted,
                                          privateMode: privateMode, googleConnected: false, notionConnected: false, spotifyConnected: false, remoteListening: false, voiceIDEnrolled: false))
        }
        XCTAssertTrue(flows(hosted: "gpt-oss:120b", privateMode: false).contains { $0.destination == "Ollama" && $0.leavesMac })
        XCTAssertFalse(flows(hosted: nil, privateMode: false).contains { $0.destination == "Ollama" })
        let priv = flows(hosted: "gpt-oss:120b", privateMode: true)
        XCTAssertFalse(priv.contains { $0.destination == "Ollama" || $0.destination == "Anthropic" }, "Private Mode: no thinking leaves the Mac")
        XCTAssertTrue(priv.contains { $0.stage == "Thinking" && !$0.leavesMac })
        XCTAssertTrue(SecretVault.accounts.contains(OllamaClient.hostedKeyAccount))
    }
}
