import XCTest
@testable import JarvisCore

/// A scripted server: each request pops the next response.
final class StubProtocol: URLProtocol {
    enum Step { case status(Int, headers: [String: String] = [:], body: String = "{}"), fail(URLError.Code) }
    nonisolated(unsafe) static var script: [Step] = []
    nonisolated(unsafe) static var requests: [URLRequest] = []
    static let lock = NSLock()

    static func session(_ steps: [Step]) -> URLSession {
        lock.lock(); script = steps; requests = []; lock.unlock()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let step = Self.script.isEmpty ? Step.status(500) : Self.script.removeFirst()
        Self.lock.unlock()
        switch step {
        case .fail(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let code, let headers, let body):
            let r = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: r, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}

final class RetryTests: XCTestCase {
    var fast: RetryPolicy { var p = RetryPolicy(); p.baseDelay = 0.01; p.maxDelay = 0.05; return p }
    func request(_ method: String = "GET") -> URLRequest {
        var r = URLRequest(url: URL(string: "https://api.example.test/thing")!); r.httpMethod = method; return r
    }
    func status(_ r: URLResponse) -> Int { (r as? HTTPURLResponse)?.statusCode ?? 0 }

    // MARK: Policy

    func testBackoffDoublesIsCappedAndObeysTheServer() {
        var p = RetryPolicy(); p.baseDelay = 0.5; p.maxDelay = 8
        XCTAssertEqual(p.delay(attempt: 0, jitter: 1), 0.5)
        XCTAssertEqual(p.delay(attempt: 2, jitter: 1), 2)
        XCTAssertEqual(p.delay(attempt: 9, jitter: 1), 8, "capped")
        XCTAssertEqual(p.delay(attempt: 0, retryAfter: 3), 3, "Retry-After wins over backoff")
        XCTAssertEqual(p.delay(attempt: 0, retryAfter: 120), 8, "but a voice assistant never waits two minutes")
        XCTAssertTrue((0.375...0.625).contains(p.delay(attempt: 0)), "jitter stays within 25%")
    }

    func testWhichFailuresAreWorthRetrying() {
        for code in [408, 429, 500, 502, 503, 504, 529] { XCTAssertTrue(RetryPolicy.isRetryable(status: code), "\(code)") }
        for code in [200, 400, 401, 403, 404, 422] { XCTAssertFalse(RetryPolicy.isRetryable(status: code), "\(code)") }
        XCTAssertEqual(RetryPolicy.classify(URLError(.cannotConnectToHost)), .neverSent)
        XCTAssertEqual(RetryPolicy.classify(URLError(.timedOut)), .maybeSent)
        XCTAssertEqual(RetryPolicy.classify(URLError(.notConnectedToInternet)), .permanent, "offline: say so now, don't wait")
        XCTAssertEqual(RetryPolicy.classify(URLError(.cancelled)), .permanent)
    }

    func testRetryAfterHeaderForms() {
        func resp(_ h: [String: String]) -> HTTPURLResponse { HTTPURLResponse(url: URL(string: "https://x.test")!, statusCode: 429, httpVersion: nil, headerFields: h)! }
        XCTAssertEqual(RetryPolicy.retryAfter(resp(["Retry-After": "7"])), 7)
        let now = Date(timeIntervalSince1970: 1_700_000_000)   // Tue, 14 Nov 2023 22:13:20 GMT
        XCTAssertEqual(RetryPolicy.retryAfter(resp(["Retry-After": "Tue, 14 Nov 2023 22:13:50 GMT"]), now: now) ?? -1, 30, accuracy: 0.5)
        XCTAssertNil(RetryPolicy.retryAfter(resp([:])))
        XCTAssertTrue(RetryPolicy.serverForbidsRetry(resp(["x-should-retry": "false"])))
        XCTAssertFalse(RetryPolicy.serverForbidsRetry(resp(["x-should-retry": "true"])))
    }

    // MARK: Behaviour against a scripted server

    func testBusyServerThatRecoversSucceedsOnTheThirdAttempt() async throws {
        let s = StubProtocol.session([.status(503), .status(529), .status(200, body: #"{"ok":true}"#)])
        let (data, resp) = try await HTTP.send(request(), session: s, policy: fast)
        XCTAssertEqual(status(resp), 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), #"{"ok":true}"#)
        XCTAssertEqual(StubProtocol.requests.count, 3)
    }

    func testGivesUpAfterMaxRetriesAndReturnsTheLastResponse() async throws {
        let s = StubProtocol.session([.status(503), .status(503), .status(503), .status(200)])
        let (_, resp) = try await HTTP.send(request(), session: s, policy: fast)
        XCTAssertEqual(status(resp), 503)
        XCTAssertEqual(StubProtocol.requests.count, 3, "one try plus two retries")
    }

    func testClientErrorsAreNotRetried() async throws {
        let s = StubProtocol.session([.status(400), .status(200)])
        let (_, resp) = try await HTTP.send(request(), session: s, policy: fast)
        XCTAssertEqual(status(resp), 400)
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testCreatingSomethingIsNeverSentTwiceAfterAServerError() async throws {
        // A 500 on "create draft" may mean the draft exists. Retrying could make two.
        var s = StubProtocol.session([.status(500), .status(200)])
        var (_, resp) = try await HTTP.send(request("POST"), session: s, policy: fast)
        XCTAssertEqual(status(resp), 500)
        XCTAssertEqual(StubProtocol.requests.count, 1)

        // A timeout is just as ambiguous.
        s = StubProtocol.session([.fail(.timedOut), .status(200)])
        do { _ = try await HTTP.send(request("POST"), session: s, policy: fast); XCTFail("should throw") } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertEqual(StubProtocol.requests.count, 1)

        // 429 and "could not connect" mean it was not processed: safe to retry.
        s = StubProtocol.session([.status(429), .fail(.cannotConnectToHost), .status(200)])
        (_, resp) = try await HTTP.send(request("POST"), session: s, policy: fast)
        XCTAssertEqual(status(resp), 200)
        XCTAssertEqual(StubProtocol.requests.count, 3)
    }

    func testReadOnlyPostMarkedIdempotentIsRetried() async throws {
        let s = StubProtocol.session([.status(502), .status(200)])
        let (_, resp) = try await HTTP.send(request("POST"), session: s, idempotent: true, policy: fast)
        XCTAssertEqual(status(resp), 200)
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testDroppedConnectionIsRetriedForReads() async throws {
        let s = StubProtocol.session([.fail(.networkConnectionLost), .status(200)])
        let (_, resp) = try await HTTP.send(request(), session: s, policy: fast)
        XCTAssertEqual(status(resp), 200)
    }

    func testOfflineFailsAtOnce() async {
        let s = StubProtocol.session([.fail(.notConnectedToInternet), .status(200)])
        let started = Date()
        do { _ = try await HTTP.send(request(), session: s, policy: fast); XCTFail() } catch {}
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }

    func testServerCanForbidARetry() async throws {
        let s = StubProtocol.session([.status(503, headers: ["x-should-retry": "false"]), .status(200)])
        let (_, resp) = try await HTTP.send(request(), session: s, policy: fast)
        XCTAssertEqual(status(resp), 503)
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testDefaultTimeoutIsAppliedButExplicitOnesAreKept() async throws {
        var p = fast; p.timeout = 15
        var s = StubProtocol.session([.status(200)])
        _ = try await HTTP.send(request(), session: s, policy: p)
        XCTAssertEqual(StubProtocol.requests.last?.timeoutInterval, 15)
        s = StubProtocol.session([.status(200)])
        var explicit = request(); explicit.timeoutInterval = 8
        _ = try await HTTP.send(explicit, session: s, policy: p)
        XCTAssertEqual(StubProtocol.requests.last?.timeoutInterval, 8)
    }
}
