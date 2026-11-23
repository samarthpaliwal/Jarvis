import XCTest
@testable import JarvisCore

// MARK: - HTTP parsing

final class HTTPParserTests: XCTestCase {
    func testAWholeRequestInOnePiece() {
        var p = HTTPRequestParser()
        let raw = "POST /v1/ask?audio=0&note=a%20b+c HTTP/1.1\r\nHost: 100.101.102.103:8787\r\nAuthorization: Bearer jrv_abc\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: 15\r\n\r\n{\"text\":\"hi!!\"}"
        guard case .complete(let r) = p.feed(Data(raw.utf8)) else { return XCTFail("not complete") }
        XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.path, "/v1/ask")
        XCTAssertEqual(r.query, ["audio": "0", "note": "a b c"])
        XCTAssertEqual(r.bearerToken, "jrv_abc"); XCTAssertEqual(r.contentType, "application/json")
        XCTAssertEqual(String(data: r.body, encoding: .utf8), "{\"text\":\"hi!!\"}")
    }

    func testArrivingByteByByteTheHeadersAreKnownBeforeTheBody() {
        var p = HTTPRequestParser()
        let raw = Array("POST /v1/ask HTTP/1.1\r\ncontent-length: 4\r\nauthorization: bearer t\r\n\r\nABCD".utf8)
        var done: HTTPRequest?
        var headSeenAt: Int?
        for (i, byte) in raw.enumerated() {
            let progress = p.feed(Data([byte]))
            if headSeenAt == nil, p.head != nil { headSeenAt = i }
            if case .complete(let r) = progress { done = r; XCTAssertEqual(i, raw.count - 1, "complete only when the last body byte is in") }
        }
        XCTAssertEqual(headSeenAt, raw.count - 5, "headers are available the moment the blank line arrives, before the body")
        XCTAssertEqual(done?.body, Data("ABCD".utf8)); XCTAssertEqual(done?.bearerToken, "t")
    }

    func testLimitsAndMalformedRequests() {
        func status(_ raw: String, maxBody: Int = 1024) -> Int? {
            var p = HTTPRequestParser(maxHeaderBytes: 512, maxBodyBytes: maxBody)
            if case .failed(let r) = p.feed(Data(raw.utf8)) { return r.status }
            return nil
        }
        XCTAssertEqual(status("POST /v1/ask HTTP/1.1\r\nContent-Length: 99999\r\n\r\n"), 413, "refused from the header, before any of the body is read")
        XCTAssertEqual(status("POST /v1/ask HTTP/1.1\r\n\r\n"), 411)
        XCTAssertEqual(status("POST /v1/ask HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"), 501)
        XCTAssertEqual(status("POST /v1/ask HTTP/1.1\r\nContent-Length: -5\r\n\r\n"), 400)
        XCTAssertEqual(status("POST /v1/ask HTTP/1.1\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n"), 400)
        XCTAssertEqual(status("GET /x HTTP/1.1\r\nAuthorization: Bearer a\r\nAuthorization: Bearer b\r\n\r\n"), 400)
        XCTAssertEqual(status("GARBAGE\r\n\r\n"), 400)
        XCTAssertEqual(status("GET http://evil.example/x HTTP/1.1\r\n\r\n"), 400, "only origin-form targets")
        XCTAssertEqual(status("GET /x HTTP/1.1\r\nX: " + String(repeating: "a", count: 600) + "\r\n\r\n"), 431)
        XCTAssertEqual(status(String(repeating: "a", count: 600)), 431, "no end of headers in sight")
        XCTAssertNil(status("GET /v1/status HTTP/1.1\r\n\r\n"))
    }

    func testBearerTokenReading() {
        func token(_ header: String?) -> String? { HTTPRequest(method: "GET", path: "/", headers: header.map { ["authorization": $0] } ?? [:]).bearerToken }
        XCTAssertEqual(token("Bearer abc"), "abc"); XCTAssertEqual(token("bearer   abc  "), "abc")
        XCTAssertNil(token(nil)); XCTAssertNil(token("Basic abc")); XCTAssertNil(token("Bearer")); XCTAssertNil(token("Bearer  "))
    }

    func testResponsesAlwaysCloseAndNeverCarryInjectedLines() {
        let r = HTTPResponse(status: 200, headers: ["X-Note": "a\r\nSet-Cookie: x=1"], body: Data("ok".utf8))
        let text = String(data: r.serialized(), encoding: .utf8)!
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(text.contains("Connection: close\r\n")); XCTAssertTrue(text.contains("Cache-Control: no-store\r\n")); XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertFalse(text.contains("\r\nSet-Cookie"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nok"))
    }
}

// MARK: - Tokens

final class RemoteTokenTests: XCTestCase {
    var url: URL!
    override func setUp() { url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-remote-tests-\(UUID().uuidString)/remote/tokens.json") }
    override func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }

    func testATokenIsShownOnceAndOnlyItsHashIsKept() throws {
        let store = RemoteTokenStore(url: url)
        XCTAssertTrue(store.isEmpty)
        let token = try store.create(name: "Sam's iPhone")
        XCTAssertTrue(token.hasPrefix("jrv_")); XCTAssertGreaterThanOrEqual(token.count, 40)
        XCTAssertNotEqual(token, try store.create(name: "iPad"), "every token is different")
        let onDisk = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk.contains(token), "the token itself is never written down")
        XCTAssertFalse(onDisk.contains(String(token.dropFirst(4).prefix(12))))
        XCTAssertTrue(onDisk.contains("Sam's iPhone"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        let dirPerms = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
        XCTAssertEqual(dirPerms, 0o700)
    }

    func testOnlyTheExactTokenIsAccepted() throws {
        let store = RemoteTokenStore(url: url)
        let token = try store.create(name: "phone")
        XCTAssertEqual(store.verify(token)?.name, "phone")
        XCTAssertNotNil(store.all.first?.lastUsed)
        for wrong in ["", "jrv_", token + "x", String(token.dropLast()), token.uppercased(), " " + token, RemoteTokenStore.hash(token)] {
            XCTAssertNil(store.verify(wrong), wrong)
        }
    }

    func testRevokingStopsATokenAtOnceEvenFromAnotherCopy() throws {
        let running = RemoteTokenStore(url: url)       // the running app
        let cli = RemoteTokenStore(url: url)           // `Jarvis --remote-token …`
        let token = try cli.create(name: "phone")
        XCTAssertEqual(running.verify(token)?.name, "phone", "the running copy picks up a token made on the command line")
        XCTAssertFalse(running.isEmpty)
        XCTAssertTrue(cli.revoke(name: "PHONE"))
        XCTAssertNil(running.verify(token))
        XCTAssertFalse(cli.revoke(name: "phone"))
        let a = try running.create(name: "a"); _ = try running.create(name: "b")
        running.revokeAll()
        XCTAssertNil(running.verify(a)); XCTAssertTrue(cli.isEmpty)
    }

    func testNamesAreCheckedAndUnique() throws {
        let store = RemoteTokenStore(url: url)
        _ = try store.create(name: "phone")
        XCTAssertThrowsError(try store.create(name: "Phone"))
        for bad in ["", "   ", String(repeating: "x", count: 41), "a\nb", "a/b", "<script>"] { XCTAssertThrowsError(try store.create(name: bad), bad) }
    }

    func testWrongTokensLockAnAddressOutForAWhile() {
        let t = AuthThrottle(maxFailures: 3, window: 60, lockout: 300)
        let now = Date()
        XCTAssertNil(t.retryAfter("100.64.0.9", now: now))
        XCTAssertFalse(t.recordFailure("100.64.0.9", now: now))
        XCTAssertFalse(t.recordFailure("100.64.0.9", now: now.addingTimeInterval(1)))
        XCTAssertTrue(t.recordFailure("100.64.0.9", now: now.addingTimeInterval(2)), "the third wrong token starts the lockout")
        XCTAssertEqual(t.retryAfter("100.64.0.9", now: now.addingTimeInterval(2)), 300)
        XCTAssertNil(t.retryAfter("100.64.0.10", now: now.addingTimeInterval(2)), "other devices are not affected")
        XCTAssertNil(t.retryAfter("100.64.0.9", now: now.addingTimeInterval(303)))
        // Slow guesses never add up, and a right token clears the count.
        let slow = AuthThrottle(maxFailures: 3, window: 60, lockout: 300)
        for i in 0..<10 { XCTAssertFalse(slow.recordFailure("a", now: now.addingTimeInterval(Double(i) * 61))) }
        let cleared = AuthThrottle(maxFailures: 3, window: 60, lockout: 300)
        cleared.recordFailure("a", now: now); cleared.recordFailure("a", now: now); cleared.recordSuccess("a")
        XCTAssertFalse(cleared.recordFailure("a", now: now))
    }
}

// MARK: - Audio

final class AudioCodecTests: XCTestCase {
    static func tone(seconds: Double, rate: Int = 16_000, hz: Double = 440) -> [Float] {
        (0..<Int(seconds * Double(rate))).map { Float(sin(2 * .pi * hz * Double($0) / Double(rate))) * 0.5 }
    }

    func testWavRoundTrip() throws {
        let original = Self.tone(seconds: 1)
        let back = try AudioCodec.decode(AudioCodec.wav(original), maxSeconds: 60)
        XCTAssertEqual(back.count, original.count)
        let worst = zip(original, back).map { abs($0 - $1) }.max() ?? 1
        XCTAssertLessThan(worst, 0.001)
    }

    func testOtherSampleRatesBecome16kMono() throws {
        let wav = AudioCodec.wav(Self.tone(seconds: 2, rate: 44_100), sampleRate: 44_100)
        let back = try AudioCodec.decode(wav, maxSeconds: 60)
        XCTAssertEqual(Double(back.count), 32_000, accuracy: 400)
        let rms = sqrt(back.map { $0 * $0 }.reduce(0, +) / Float(back.count))
        XCTAssertEqual(rms, 0.5 / sqrt(2), accuracy: 0.03, "still the same tone, not noise")
    }

    func testWhatIsRefused() {
        XCTAssertThrowsError(try AudioCodec.decode(Data(), maxSeconds: 60)) { XCTAssertEqual($0 as? AudioCodec.CodecError, .empty) }
        XCTAssertThrowsError(try AudioCodec.decode(AudioCodec.wav(Self.tone(seconds: 3)), maxSeconds: 2)) {
            guard case .tooLong = $0 as? AudioCodec.CodecError else { return XCTFail("\($0)") }
        }
        let webm = Data([0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 64))
        XCTAssertThrowsError(try AudioCodec.decode(webm, maxSeconds: 60)) { XCTAssertEqual($0 as? AudioCodec.CodecError, .unsupported("WEBM")) }
        XCTAssertThrowsError(try AudioCodec.decode(Data("<html>not audio at all</html>".utf8), maxSeconds: 60)) {
            guard case .unsupported = $0 as? AudioCodec.CodecError else { return XCTFail("\($0)") }
        }
        // Says WAV, is not: read by content, so it fails cleanly instead of being trusted.
        XCTAssertThrowsError(try AudioCodec.decode(Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVEjunkjunkjunkjunk".utf8), maxSeconds: 60))
        XCTAssertEqual(AudioCodec.kind(of: AudioCodec.wav([0, 0, 0, 0, 0, 0])), "wav")
    }
}

// MARK: - The API over a fake pipeline

final class FakeRemoteBackend: RemoteBackend, @unchecked Sendable {
    var heard = "what's on today"
    var transcribeError: Error?
    var voice: VoiceCheck? = VoiceCheck(outcome: .verified, score: 0.81, seconds: 2)
    var result = RemoteTurnResult(status: .done, requestID: "r-000001", text: "Two classes and the gym.", tools: ["calendar_list"])
    var decision: RemoteTurnResult? = RemoteTurnResult(status: .done, requestID: "r-000001", text: "Sent.")
    var renderError: Error?
    var asked: [(text: String, voice: VoiceCheck?)] = []
    var decided: [(id: UUID, approved: Bool)] = []
    var rendered: [String] = []
    var transcribed = 0

    func status() async -> RemoteStatus { RemoteStatus(busy: false, keysUnlocked: true, voiceIDEnrolled: true, mode: "home") }
    func transcribe(_ samples: [Float]) async throws -> String { transcribed += 1; if let transcribeError { throw transcribeError }; return heard }
    func verifyVoice(_ samples: [Float]) async -> VoiceCheck? { voice }
    func ask(_ text: String, voice: VoiceCheck?) async -> RemoteTurnResult { asked.append((text, voice)); return result }
    func decide(_ id: UUID, approved: Bool) async -> RemoteTurnResult? { decided.append((id, approved)); return decision }
    func render(_ text: String) async throws -> (data: Data, mime: String) {
        rendered.append(text)
        if let renderError { throw renderError }
        return (Data("AUDIO".utf8), "audio/wav")
    }
}

final class RemoteAPITests: XCTestCase {
    var url: URL!
    var store: RemoteTokenStore!
    var backend: FakeRemoteBackend!
    var api: RemoteAPI!
    var token = ""

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-remote-tests-\(UUID().uuidString)/remote/tokens.json")
        store = RemoteTokenStore(url: url)
        token = try store.create(name: "phone")
        backend = FakeRemoteBackend()
        api = RemoteAPI(tokens: store, throttle: AuthThrottle(maxFailures: 3, window: 60, lockout: 300), backend: backend, maxAudioSeconds: { 10 })
    }
    override func tearDown() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }

    func request(_ method: String, _ path: String, json: [String: Any]? = nil, audio: Data? = nil, query: [String: String] = [:], token: String? = nil) -> HTTPRequest {
        var headers: [String: String] = [:]
        if let t = token ?? Optional(self.token), !t.isEmpty { headers["authorization"] = "Bearer \(t)" }
        var body = Data()
        if let json { body = try! JSONSerialization.data(withJSONObject: json); headers["content-type"] = "application/json" }
        if let audio { body = audio; headers["content-type"] = "audio/wav" }
        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }
    func send(_ r: HTTPRequest, ip: String = "100.64.0.2") async -> (status: Int, body: [String: Any]) {
        if let refused = api.precheck(r, from: ip) { return (refused.status, (try? JSONSerialization.jsonObject(with: refused.body)) as? [String: Any] ?? [:]) }
        let response = await api.handle(r, from: ip)
        return (response.status, (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:])
    }
    var speech: Data { AudioCodec.wav(AudioCodecTests.tone(seconds: 1)) }

    func testEveryPathNeedsAToken() async {
        for (method, path) in [("GET", "/v1/status"), ("POST", "/v1/ask"), ("POST", "/v1/approve"), ("GET", "/"), ("GET", "/nothing/here"), ("DELETE", "/v1/ask")] {
            let none = await send(request(method, path, token: ""), ip: "100.64.1.\(path.count)")
            XCTAssertEqual(none.status, 401, "\(method) \(path) without a token")
            let wrong = await send(request(method, path, token: "jrv_wrong"), ip: "100.64.2.\(path.count)")
            XCTAssertEqual(wrong.status, 401, "\(method) \(path) with a wrong token")
            XCTAssertEqual(wrong.body["error"] as? String, "unauthorized", "the same answer whether or not the path exists")
        }
        XCTAssertTrue(backend.asked.isEmpty); XCTAssertEqual(backend.transcribed, 0)
        // The handler refuses by itself too, in case it is ever reached without the precheck.
        let direct = await api.handle(request("GET", "/v1/status", token: "jrv_wrong"), from: "100.64.0.2")
        XCTAssertEqual(direct.status, 401)
    }

    func testGuessingTokensGetsAnAddressLockedOutEvenWithTheRightOneAfterwards() async {
        for _ in 0..<3 { _ = await send(request("GET", "/v1/status", token: "jrv_guess"), ip: "100.64.0.66") }
        let locked = await send(request("GET", "/v1/status"), ip: "100.64.0.66")
        XCTAssertEqual(locked.status, 429)
        let other = await send(request("GET", "/v1/status"), ip: "100.64.0.2")
        XCTAssertEqual(other.status, 200, "the phone with the real token is not affected")
    }

    func testStatus() async {
        let r = await send(request("GET", "/v1/status"))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.body["device"] as? String, "phone"); XCTAssertEqual(r.body["busy"] as? Bool, false); XCTAssertEqual(r.body["voice_id"] as? Bool, true)
        let wrongMethod = await send(request("POST", "/v1/status", json: [:]))
        XCTAssertEqual(wrongMethod.status, 405)
        let missing = await send(request("GET", "/v1/else"))
        XCTAssertEqual(missing.status, 404)
    }

    func testASpokenRequestRunsAllStagesAndComesBackAsTextAndAudio() async {
        let r = await send(request("POST", "/v1/ask", audio: speech))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(r.body["status"] as? String, "done")
        XCTAssertEqual(r.body["transcript"] as? String, "what's on today")
        XCTAssertEqual(r.body["text"] as? String, "Two classes and the gym.")
        XCTAssertEqual(r.body["tools"] as? [String], ["calendar_list"])
        XCTAssertEqual(r.body["request_id"] as? String, "r-000001")
        XCTAssertEqual((r.body["voice"] as? [String: Any])?["outcome"] as? String, "verified")
        let audio = r.body["audio"] as? [String: Any]
        XCTAssertEqual(audio?["mime"] as? String, "audio/wav")
        XCTAssertEqual(Data(base64Encoded: audio?["base64"] as? String ?? ""), Data("AUDIO".utf8))
        XCTAssertEqual(backend.asked.first?.text, "what's on today")
        XCTAssertEqual(backend.asked.first?.voice?.outcome, .verified, "the voice check travels with the request")
        XCTAssertEqual(backend.rendered, ["Two classes and the gym."])
    }

    func testATypedRequestHasNoVoiceAndAudioCanBeSkipped() async {
        let r = await send(request("POST", "/v1/ask", json: ["text": "  what's left today?  ", "audio": false]))
        XCTAssertEqual(r.status, 200)
        XCTAssertNil(r.body["audio"]); XCTAssertNil(r.body["voice"])
        XCTAssertEqual(backend.asked.first?.text, "what's left today?")
        XCTAssertNil(backend.asked.first?.voice, "typed: nothing to verify, so nothing that needs approval can pass")
        XCTAssertTrue(backend.rendered.isEmpty); XCTAssertEqual(backend.transcribed, 0)
        let viaQuery = await send(request("POST", "/v1/ask", audio: speech, query: ["audio": "0"]))
        XCTAssertNil(viaQuery.body["audio"])
    }

    func testBadRequestsAreRefusedBeforeTheModelIsInvolved() async {
        var r = await send(request("POST", "/v1/ask", json: ["text": "   "]));                       XCTAssertEqual(r.status, 400)
        r = await send(request("POST", "/v1/ask", json: ["words": "hi"]));                            XCTAssertEqual(r.status, 400)
        r = await send(request("POST", "/v1/ask", json: ["text": String(repeating: "a", count: 2001)])); XCTAssertEqual(r.status, 413)
        r = await send(request("POST", "/v1/ask", audio: Data()));                                    XCTAssertEqual(r.status, 400)
        r = await send(request("POST", "/v1/ask", audio: Data([0x1A, 0x45, 0xDF, 0xA3] + [UInt8](repeating: 0, count: 64)))); XCTAssertEqual(r.status, 415)
        r = await send(request("POST", "/v1/ask", audio: AudioCodec.wav(AudioCodecTests.tone(seconds: 11)))); XCTAssertEqual(r.status, 413)
        backend.heard = ""
        r = await send(request("POST", "/v1/ask", audio: speech));                                    XCTAssertEqual(r.status, 422); XCTAssertEqual(r.body["error"] as? String, "no_speech")
        backend.transcribeError = TranscriberError.unavailable("speech assets not installed")
        r = await send(request("POST", "/v1/ask", audio: speech));                                    XCTAssertEqual(r.status, 503)
        XCTAssertTrue(backend.asked.isEmpty)
    }

    func testBusyAndFailures() async {
        backend.result = RemoteTurnResult(status: .busy)
        var r = await send(request("POST", "/v1/ask", json: ["text": "hello"]))
        XCTAssertEqual(r.status, 409); XCTAssertEqual(r.body["error"] as? String, "busy")
        backend.result = RemoteTurnResult(status: .done, requestID: "r-1", text: "I can't reach Claude right now.", failed: true)
        backend.renderError = NSError(domain: "tts", code: 1, userInfo: [NSLocalizedDescriptionKey: "kokoro is down"])
        r = await send(request("POST", "/v1/ask", json: ["text": "hello"]))
        XCTAssertEqual(r.status, 200); XCTAssertEqual(r.body["failed"] as? Bool, true)
        XCTAssertEqual(r.body["text"] as? String, "I can't reach Claude right now.", "the words come back even when the voice cannot be made")
        XCTAssertNil(r.body["audio"]); XCTAssertEqual(r.body["audio_error"] as? String, "kokoro is down")
    }

    func testAnApprovalComesBackAsAQuestionAndIsAnsweredInASecondRequest() async {
        let id = UUID()
        backend.result = RemoteTurnResult(status: .needsApproval, requestID: "r-9", text: "Approve: Send an email to Maya? Say yes or no.",
                                          approvalID: id, approvalPrompt: "Send an email to Maya", approvalExpiresIn: 60)
        let asked = await send(request("POST", "/v1/ask", audio: speech))
        XCTAssertEqual(asked.status, 200); XCTAssertEqual(asked.body["status"] as? String, "needs_approval")
        let approval = asked.body["approval"] as? [String: Any]
        XCTAssertEqual(approval?["id"] as? String, id.uuidString); XCTAssertEqual(approval?["prompt"] as? String, "Send an email to Maya"); XCTAssertEqual(approval?["expires_in"] as? Double, 60)
        XCTAssertEqual(backend.rendered.last, "Approve: Send an email to Maya? Say yes or no.", "the question is spoken on the phone")

        backend.heard = "Yes, go ahead."
        let spoken = await send(request("POST", "/v1/approve", audio: speech, query: ["id": id.uuidString]))
        XCTAssertEqual(spoken.status, 200); XCTAssertEqual(spoken.body["text"] as? String, "Sent.")
        XCTAssertEqual(backend.decided.last?.id, id); XCTAssertEqual(backend.decided.last?.approved, true)

        backend.heard = "no don't"
        _ = await send(request("POST", "/v1/approve", audio: speech, query: ["id": id.uuidString]))
        XCTAssertEqual(backend.decided.last?.approved, false)

        let tapped = await send(request("POST", "/v1/approve", json: ["id": id.uuidString, "decision": "no"]))
        XCTAssertEqual(tapped.status, 200); XCTAssertEqual(backend.decided.last?.approved, false)
    }

    func testAnUnclearOrLateAnswerApprovesNothing() async {
        let id = UUID()
        let before = backend.decided.count
        backend.heard = "what was that again"
        var r = await send(request("POST", "/v1/approve", audio: speech, query: ["id": id.uuidString]))
        XCTAssertEqual(r.status, 422)
        backend.heard = ""
        r = await send(request("POST", "/v1/approve", audio: speech, query: ["id": id.uuidString])); XCTAssertEqual(r.status, 422)
        r = await send(request("POST", "/v1/approve", json: ["id": id.uuidString, "decision": "maybe"])); XCTAssertEqual(r.status, 400)
        r = await send(request("POST", "/v1/approve", json: ["decision": "yes"])); XCTAssertEqual(r.status, 400)
        r = await send(request("POST", "/v1/approve", json: ["id": "not-a-uuid", "decision": "yes"])); XCTAssertEqual(r.status, 400)
        XCTAssertEqual(backend.decided.count, before, "none of those reached the pipeline")
        backend.decision = nil
        r = await send(request("POST", "/v1/approve", json: ["id": id.uuidString, "decision": "yes"]))
        XCTAssertEqual(r.status, 410, "answered already, or timed out")
    }

    func testReadingASpokenAnswer() {
        for yes in ["yes", "Yes.", "yeah go ahead", "Okay, do it", "approve", "sure!"] { XCTAssertEqual(ConversationController.approvalAnswer(yes), true, yes) }
        for no in ["no", "No!", "nope", "don't", "Don’t send it", "cancel that", "yes... no, stop", "ok no"] { XCTAssertEqual(ConversationController.approvalAnswer(no), false, no) }
        for unclear in ["", "what", "maybe later", "yesterday", "nothing", "know"] { XCTAssertNil(ConversationController.approvalAnswer(unclear), unclear) }
    }
}

// MARK: - The server on a real socket

final class HTTPServerTests: XCTestCase {
    func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        c.timeoutIntervalForRequest = 5
        return URLSession(configuration: c)
    }

    func testItNeverListensOnEveryAddress() async {
        for host in ["0.0.0.0", "::", "", "*", "localhost", "example.com"] {
            let s = HTTPServer(config: .init(host: host, port: 0), peerFilter: { _ in true }, precheck: { _, _ in nil }, handler: { _, _ in HTTPResponse(status: 200) })
            do { try await s.start(); XCTFail("listened on “\(host)”"); s.stop() } catch {}
            XCTAssertNil(s.port)
        }
        XCTAssertTrue(HTTPServer.isWildcard("0.0.0.0")); XCTAssertFalse(HTTPServer.isWildcard("100.64.0.1"))
    }

    func testServesOverLoopbackWithPrecheckAndPeerFilter() async throws {
        let handled = Counter()
        let s = HTTPServer(config: .init(host: "127.0.0.1", port: 0), peerFilter: { Tailnet.isLoopback($0) },
                           precheck: { head, _ in head.bearerToken == "good" ? nil : .error(401, "unauthorized", "no") },
                           handler: { request, ip in
                               handled.add()
                               return .json(200, ["path": request.path, "bytes": request.body.count, "from": ip])
                           })
        try await s.start()
        defer { s.stop() }
        let port = try XCTUnwrap(s.port)
        XCTAssertGreaterThan(port, 0)

        var ok = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/ask?x=1")!)
        ok.httpMethod = "POST"
        ok.setValue("Bearer good", forHTTPHeaderField: "Authorization")
        ok.httpBody = Data(repeating: 7, count: 300_000)        // several reads' worth
        let (data, response) = try await session().data(for: ok)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(body["path"] as? String, "/v1/ask"); XCTAssertEqual(body["bytes"] as? Int, 300_000); XCTAssertEqual(body["from"] as? String, "127.0.0.1")

        var bad = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/ask")!)
        bad.httpMethod = "POST"
        bad.httpBody = Data("{}".utf8)
        let (_, refused) = try await session().data(for: bad)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 401)
        XCTAssertEqual(handled.value, 1, "a request without a token never reaches the handler")
    }

    func testAPeerOutsideTheAllowedRangeIsDroppedWithoutAnAnswer() async throws {
        let s = HTTPServer(config: .init(host: "127.0.0.1", port: 0), peerFilter: { Tailnet.isTailscaleIPv4($0) },   // loopback is not a tailnet peer
                           precheck: { _, _ in nil }, handler: { _, _ in HTTPResponse(status: 200) })
        try await s.start()
        defer { s.stop() }
        let port = try XCTUnwrap(s.port)
        do {
            _ = try await session().data(from: URL(string: "http://127.0.0.1:\(port)/v1/status")!)
            XCTFail("got an answer")
        } catch {}
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func add() { lock.lock(); n += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return n }
}

// MARK: - Where it listens

@MainActor
final class RemoteAccessServiceTests: XCTestCase {
    func testWhereItMayListen() {
        let tail = Tailnet.Address(interface: "utun4", ip: "100.101.102.103")
        let wifi = Tailnet.Address(interface: "en0", ip: "192.168.1.20")
        XCTAssertEqual(RemoteAccess.bindHost(mode: "tailscale", addresses: [wifi, tail]), "100.101.102.103")
        XCTAssertNil(RemoteAccess.bindHost(mode: "tailscale", addresses: [wifi]), "no Tailscale: nowhere to listen, so it does not")
        XCTAssertEqual(RemoteAccess.bindHost(mode: "loopback", addresses: [wifi]), "127.0.0.1")
        // There is no setting that listens on every address or on the Wi-Fi address.
        for odd in ["all", "0.0.0.0", "any", "lan", "192.168.1.20", "", "*", "public"] {
            XCTAssertEqual(RemoteAccess.bindMode(odd), "tailscale", odd)
            XCTAssertNil(RemoteAccess.bindHost(mode: odd, addresses: [wifi]), odd)
        }
        XCTAssertTrue(RemoteAccess.peerAllowed("100.64.0.7", mode: "tailscale"))
        for outsider in ["192.168.1.9", "127.0.0.1", "8.8.8.8", "100.128.0.1", "::1"] { XCTAssertFalse(RemoteAccess.peerAllowed(outsider, mode: "tailscale"), outsider) }
        XCTAssertTrue(RemoteAccess.peerAllowed("127.0.0.1", mode: "loopback")); XCTAssertFalse(RemoteAccess.peerAllowed("100.64.0.7", mode: "loopback"))
    }

    func testOffByDefaultThenNeedsATokenThenNeedsTailscaleThenListens() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-remote-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let suite = "jarvis.tests.remote.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let port = Int.random(in: 20_000...60_000)
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: ["JARVIS_REMOTE_PORT": String(port)])
        XCTAssertEqual(config.tuning.remoteBind, "tailscale"); XCTAssertEqual(config.tuning.remotePort, port)
        let tokens = RemoteTokenStore(url: dir.appendingPathComponent("remote/tokens.json"))
        let remote = RemoteAccess(config: config, tokens: tokens, backend: FakeRemoteBackend(), defaults: defaults,
                                  addresses: { [.init(interface: "en0", ip: "192.168.1.20")] })     // a Mac without Tailscale
        defer { remote.stop() }
        XCTAssertFalse(remote.isEnabled, "nothing listens until it is switched on")
        remote.refresh(); XCTAssertEqual(remote.state, .off)
        remote.isEnabled = true
        XCTAssertEqual(remote.state, .noTokens, "on, but no device may connect yet: still not listening")
        let token = try tokens.create(name: "phone")
        remote.refresh()
        XCTAssertEqual(remote.state, .waitingForTailscale, "it does not fall back to the Wi-Fi address")

        // The debug override: loopback, for this process only.
        remote.bindOverride = "loopback"
        for _ in 0..<100 where remote.state == .waitingForTailscale { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(remote.state, .listening(host: "127.0.0.1", port: UInt16(port)))
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/status")!)
        let (_, anonymous) = try await URLSession(configuration: c).data(for: request)
        XCTAssertEqual((anonymous as? HTTPURLResponse)?.statusCode, 401)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, ok) = try await URLSession(configuration: c).data(for: request)
        XCTAssertEqual((ok as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["device"] as? String, "phone")

        // Revoking the last token closes the port.
        tokens.revokeAll()
        remote.refresh()
        XCTAssertEqual(remote.state, .noTokens)
        try await Task.sleep(for: .milliseconds(200))
        do { _ = try await URLSession(configuration: c).data(for: request); XCTFail("still listening") } catch {}
        remote.bindOverride = nil
        remote.isEnabled = false
        XCTAssertEqual(remote.state, .off)
    }

    func testTheToolDenylistCoversTheTokensAndTheKeyHelper() {
        XCTAssertTrue(Denylist.fallback.paths.contains("~/Library/Application Support/Jarvis/remote"))
        XCTAssertTrue(Denylist.fallback.paths.contains("~/Library/Application Support/Jarvis/bin"))
    }
}

// MARK: - A remote request through the conversation controller

@MainActor
final class RemoteTurnTests: XCTestCase {
    var wake: FakeWake!, stt: FakeTranscriber!, intent: FakeIntent!, speech: FakeSpeech!, notch: NotchViewModel!
    var voiceURL: URL!

    func controller(enrolled: Bool = true, env: [String: String] = [:]) throws -> ConversationController {
        wake = FakeWake(); stt = FakeTranscriber(); intent = FakeIntent(); speech = FakeSpeech(); notch = NotchViewModel()
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: env)
        let c = ConversationController(notch: notch, wake: wake, transcriber: stt, speech: speech, config: config,
                                       modes: ModeManager(config: config, notch: notch), brain: intent)
        c.conversationMode = false; c.voiceMuted = false; c.outputIsHeadphones = { false }; c.strictTransitions = true
        voiceURL = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-remote-voice-\(UUID().uuidString)/voiceprint.json")
        let verifier = SpeakerVerifier(embedder: FakeEmbedder(), store: VoiceprintStore(url: voiceURL))
        if enrolled { try verifier.enroll((0..<5).map { _ in FakeEmbedder.audio(voice: 2) }) }
        c.voiceID = verifier
        return c
    }
    override func tearDown() { if let voiceURL { try? FileManager.default.removeItem(at: voiceURL.deletingLastPathComponent()) } }
    let verified = VoiceCheck(outcome: .verified, score: 0.9, seconds: 2)
    let stranger = VoiceCheck(outcome: .mismatch, score: 0.1, seconds: 2)

    func testARemoteRequestIsAnsweredWithoutASoundOrAPixelOnTheMac() async throws {
        let c = try controller()
        intent.reply = "Two classes and the gym."
        let r = await c.remoteAsk("what's on today", voice: verified)
        XCTAssertEqual(r.status, .done); XCTAssertEqual(r.text, "Two classes and the gym."); XCTAssertFalse(r.failed)
        XCTAssertTrue(r.requestID.hasPrefix("r-"))
        XCTAssertEqual(intent.heard, ["what's on today"], "the same intent stage as a spoken request")
        XCTAssertTrue(speech.spoken.isEmpty, "nothing is said through the Mac's speakers")
        XCTAssertEqual(notch.replyText, "", "nothing is shown on the Mac's screen")
        XCTAssertEqual(c.state, .idle); XCTAssertEqual(c.illegalTransitions, 0); XCTAssertFalse(c.remoteTurnActive)
        XCTAssertTrue(stt.starts == 0, "the Mac's microphone is not used")
    }

    func testOneRequestAtATimeSharedWithTheMac() async throws {
        let c = try controller()
        wake.fire()                                       // someone is talking to Jarvis at the Mac
        XCTAssertEqual(c.state, .listening)
        let busy = await c.remoteAsk("hello", voice: nil)
        XCTAssertEqual(busy.status, .busy); XCTAssertTrue(intent.heard.isEmpty)
        c.stopEverything()

        // And the other way round: a wake word during a remote request does not cut in.
        var stateDuring: PipelineState?
        intent.duringReply = { [wake] in wake!.fire(); stateDuring = c.state; let again = await c.remoteAsk("second", voice: nil); XCTAssertEqual(again.status, .busy) }
        let r = await c.remoteAsk("first", voice: nil)
        XCTAssertEqual(r.status, .done); XCTAssertEqual(stateDuring, .thinking); XCTAssertEqual(intent.heard, ["first"])
    }

    func testAFailureComesBackAsTheSameWordsJarvisWouldSay() async throws {
        let c = try controller()
        intent.error = ClaudeClient.ClientError.noAPIKey
        let r = await c.remoteAsk("hello", voice: nil)
        XCTAssertEqual(r.status, .done); XCTAssertTrue(r.failed); XCTAssertFalse(r.text.isEmpty)
        XCTAssertEqual(c.state, .idle)
        XCTAssertTrue(speech.spoken.isEmpty)
    }

    func testWhoMayApproveRemotely() {
        XCTAssertNil(ConversationController.remoteApprovalRefusal(enrolled: true, voice: verified))
        XCTAssertNotNil(ConversationController.remoteApprovalRefusal(enrolled: false, voice: verified), "no Voice ID: no proof of who is asking")
        XCTAssertNotNil(ConversationController.remoteApprovalRefusal(enrolled: false, voice: nil))
        XCTAssertNotNil(ConversationController.remoteApprovalRefusal(enrolled: true, voice: nil), "typed")
        XCTAssertNotNil(ConversationController.remoteApprovalRefusal(enrolled: true, voice: stranger))
        XCTAssertNotNil(ConversationController.remoteApprovalRefusal(enrolled: true, voice: VoiceCheck(outcome: .tooShort, score: nil, seconds: 0.3)))
        XCTAssertNotNil(ConversationController.remoteApprovalRefusal(enrolled: true, voice: VoiceCheck(outcome: .unavailable, score: nil, seconds: 2)))
        XCTAssertNotNil(ConversationController.remoteApprovalRefusal(enrolled: true, voice: VoiceCheck(outcome: .notEnrolled, score: nil, seconds: 2)))
    }

    func testAnApprovalWaitsForTheCallersYes() async throws {
        let c = try controller()
        var granted: Bool?
        intent.reply = "Sent."
        intent.duringReply = { granted = await c.requestApproval(ApprovalRequest(toolName: "email_send", preview: "Send an email to Maya")) }
        let first = await c.remoteAsk("email maya that I'm running late", voice: verified)
        XCTAssertEqual(first.status, .needsApproval)
        XCTAssertEqual(first.approvalPrompt, "Send an email to Maya"); XCTAssertTrue(first.text.contains("Send an email to Maya"))
        XCTAssertNil(granted, "nothing has happened yet")
        XCTAssertEqual(c.state, .awaitingApproval); XCTAssertTrue(c.remoteTurnActive)
        XCTAssertTrue(speech.spoken.isEmpty, "the question is not asked through the Mac's speakers")
        XCTAssertTrue(notch.cards.isEmpty, "and there is no Approve button on the Mac for someone else to press")

        let wrong = await c.remoteDecide(id: UUID(), approved: true)
        XCTAssertNil(wrong, "a yes for some other approval does nothing"); XCTAssertNil(granted)

        let id = try XCTUnwrap(first.approvalID)
        let second = await c.remoteDecide(id: id, approved: true)
        XCTAssertEqual(second?.status, .done); XCTAssertEqual(second?.text, "Sent."); XCTAssertEqual(granted, true)
        XCTAssertEqual(c.state, .idle); XCTAssertEqual(c.illegalTransitions, 0)
        let late = await c.remoteDecide(id: id, approved: true)
        XCTAssertNil(late, "an approval is answered once")
    }

    func testNoMeansNoAndSilenceMeansNo() async throws {
        var c = try controller()
        var granted: Bool?
        intent.duringReply = { granted = await c.requestApproval(ApprovalRequest(toolName: "email_send", preview: "Send an email to Maya")) }
        var first = await c.remoteAsk("email maya", voice: verified)
        let no = await c.remoteDecide(id: try XCTUnwrap(first.approvalID), approved: false)
        XCTAssertEqual(no?.status, .done); XCTAssertEqual(granted, false)

        c = try controller(env: ["JARVIS_REMOTE_APPROVAL_TIMEOUT_SECONDS": "5"])
        granted = nil
        let waited = expectation(description: "timed out")
        intent.duringReply = { granted = await c.requestApproval(ApprovalRequest(toolName: "email_send", preview: "Send an email to Maya")); waited.fulfill() }
        first = await c.remoteAsk("email maya", voice: verified)
        XCTAssertEqual(first.approvalExpiresIn, 5)
        await fulfillment(of: [waited], timeout: 9)
        XCTAssertEqual(granted, false, "no answer within the time limit is a no")
        for _ in 0..<50 where c.remoteTurnActive { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(c.state, .idle)
        let late = await c.remoteDecide(id: try XCTUnwrap(first.approvalID), approved: true)
        XCTAssertNil(late, "a yes after the time limit does nothing")
    }

    func testAnUnverifiedOrTypedRemoteRequestCannotGetAnApprovalAtAll() async throws {
        for (label, enrolled, voice) in [("stranger", true, Optional(stranger)), ("typed", true, nil), ("no Voice ID", false, Optional(verified))] {
            let c = try controller(enrolled: enrolled)
            var granted: Bool?
            intent.reply = "I couldn't send it."
            intent.duringReply = { granted = await c.requestApproval(ApprovalRequest(toolName: "email_send", preview: "Send an email to Maya")) }
            let r = await c.remoteAsk("email maya", voice: voice)
            XCTAssertEqual(r.status, .done, "\(label): it is never even asked")
            XCTAssertEqual(granted, false, label)
            XCTAssertNil(r.approvalID, label)
            XCTAssertTrue(r.text.contains("remotely"), "\(label): the reply says why: \(r.text)")
            XCTAssertEqual(c.state, .idle, label)
        }
    }

    func testStoppingAtTheMacEndsARemoteRequest() async throws {
        let c = try controller()
        intent.hangs = true
        Task { try? await Task.sleep(for: .milliseconds(150)); c.stopEverything() }
        let r = await c.remoteAsk("something slow", voice: nil)
        XCTAssertEqual(r.status, .cancelled); XCTAssertEqual(c.state, .idle); XCTAssertFalse(c.remoteTurnActive)
    }

    func testTranscribingAWholeRecording() async throws {
        final class Recording: Transcriber, @unchecked Sendable {
            let name = "recording"; var isAvailable = true
            var fed = 0, finished = false, cancelled = false, waited = false
            var says = "what's on today"
            private var onUpdate: ((TranscriptUpdate) -> Void)?
            func requestAuthorization() async -> Bool { true }
            func start(onUpdate: @escaping (TranscriptUpdate) -> Void, onError: @escaping (Error) -> Void) throws { self.onUpdate = onUpdate }
            func append(samples: [Float]) { fed += samples.count }
            func finish() { finished = true; let u = onUpdate; let s = says; DispatchQueue.main.async { u?(TranscriptUpdate(text: s, isFinal: true)) } }
            func cancel() { cancelled = true }
            func waitUntilAcceptingAudio(timeout: TimeInterval) async -> Bool { waited = true; return true }
        }
        let t = Recording()
        let text = try await UtteranceTranscription.transcribe([Float](repeating: 0.1, count: 16_000 * 3 + 7), with: t)
        XCTAssertEqual(text, "what's on today")
        XCTAssertEqual(t.fed, 16_000 * 3 + 7 + 8000, "every sample is fed, plus the closing silence")
        XCTAssertTrue(t.waited, "audio is not fed before the recognizer can take it"); XCTAssertTrue(t.finished); XCTAssertTrue(t.cancelled)
    }
}
