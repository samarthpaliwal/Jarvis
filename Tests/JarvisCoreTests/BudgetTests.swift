import XCTest
@testable import JarvisCore

final class BudgetTests: XCTestCase {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 1_800_000_000); func advance(_ s: TimeInterval) { t += s } }

    func makeBudget(cap: Double = 1, clock: Clock = Clock(), url: URL? = nil) -> (Budget, Clock) {
        var l = Budget.Limits(); l.dailyCapUSD = cap; l.warnFraction = 0.8; l.modelRequestsPerMinute = 5
        return (Budget(limits: l, pricing: Pricing(), url: url, now: { clock.t }), clock)
    }

    // MARK: Pricing

    func testCostOfATypicalSonnetTurn() {
        // 190 fresh input, 40 output, 10,405 read from cache at Sonnet 5.5 prices ($2 / $10 / $0.10 per million).
        let usd = Pricing().cost(model: "claude-sonnet-5-5", input: 190, output: 40, cacheRead: 10_405, cacheWrite: 0)
        let expected: Double = (190.0 * 2.0 + 40.0 * 10.0 + 10_405.0 * 0.10) / 1_000_000.0
        XCTAssertEqual(usd, expected, accuracy: 1e-9)
        XCTAssertEqual(usd, 0.00182, accuracy: 0.00001)
        // A cold turn writes the cache instead: about 2.6 cents.
        XCTAssertEqual(Pricing().cost(model: "claude-sonnet-5-5", input: 190, output: 40, cacheRead: 0, cacheWrite: 10_405), 0.0268, accuracy: 0.0001)
        XCTAssertEqual(Pricing().cost(model: "claude-sonnet-5-5", input: 0, output: 0, cacheRead: 0, cacheWrite: 0, webSearches: 3), 0.03, accuracy: 1e-9)
    }

    func testLongestPrefixWinsAndUnknownModelsArePricedHigh() {
        let p = Pricing()
        XCTAssertEqual(p.price(for: "claude-sonnet-5-5").cacheRead, 0.10)
        XCTAssertEqual(p.price(for: "claude-sonnet-5").cacheRead, 0.20, "the 5.5 row must not swallow plain Sonnet 5")
        XCTAssertEqual(p.price(for: "claude-opus-5-5").input, 4)
        XCTAssertEqual(p.price(for: "claude-opus-4-8").input, 5)
        XCTAssertEqual(p.price(for: "some-future-model").output, 40, "unknown: assume the most expensive, so the cap can only come early")
        XCTAssertEqual(p.speechCost(provider: "kokoro", characters: 5000), 0, "the local voice is free")
        XCTAssertEqual(p.speechCost(provider: "elevenlabs", characters: 2000), 0.20, accuracy: 1e-9)
    }

    func testPricingInProfileCanBePartial() throws {
        let p = try JSONDecoder().decode(Pricing.self, from: Data(#"{"webSearchPerCall": 0.02}"#.utf8))
        XCTAssertEqual(p.webSearchPerCall, 0.02)
        XCTAssertEqual(p.models, Pricing().models)
    }

    @MainActor func testRepoPricingMatchesCodeDefaults() {
        let store = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        XCTAssertEqual(store.profile.pricing, Pricing(), "config/profile.json pricing drifted from Net/Budget.swift")
        XCTAssertEqual(store.tuning.budgetLimits.dailyCapUSD, 3)
    }

    // MARK: Cap and warning

    func testWarnsOnceNearTheLimitThenRefusesAtTheCap() {
        let (b, _) = makeBudget(cap: 1)
        var notices: [Budget.Notice] = []
        b.onNotice = { notices.append($0) }

        XCTAssertNoThrow(try b.check("claude"))
        b.record("claude", usd: 0.50)
        XCTAssertTrue(notices.isEmpty)
        b.record("claude", usd: 0.35)                       // 85%
        XCTAssertEqual(notices, [.nearLimit(spent: 0.85, cap: 1)])
        b.record("claude", usd: 0.05)                       // 90%: no second warning
        XCTAssertEqual(notices.count, 1)
        XCTAssertNoThrow(try b.check("claude"), "still under the cap")

        b.record("claude", usd: 0.20)                       // 110%
        XCTAssertEqual(notices.count, 2)
        if case .capReached = notices[1] {} else { XCTFail("expected capReached") }
        XCTAssertThrowsError(try b.check("claude")) { XCTAssertEqual($0 as? BudgetError, .dailyCapReached(spent: 1.10, cap: 1)) }
        XCTAssertThrowsError(try b.check("elevenlabs"), "paid voices stop too")
        XCTAssertTrue(b.isOverCap)
        b.record("claude", usd: 0.01)
        XCTAssertEqual(notices.count, 2, "each notice is spoken once per day")
    }

    func testANewDayStartsFromZero() {
        let (b, clock) = makeBudget(cap: 1)
        b.record("claude", usd: 1.5)
        XCTAssertThrowsError(try b.check("claude"))
        clock.advance(26 * 3600)
        XCTAssertNoThrow(try b.check("claude"))
        XCTAssertEqual(b.spentToday, 0)
    }

    func testZeroCapMeansNoCap() {
        let (b, _) = makeBudget(cap: 0)
        b.record("claude", usd: 500)
        XCTAssertNoThrow(try b.check("claude"))
        XCTAssertFalse(b.isOverCap)
    }

    func testOneBigCallJumpingStraightPastTheCapStillAnnouncesIt() {
        let (b, _) = makeBudget(cap: 1)
        var notices: [Budget.Notice] = []
        b.onNotice = { notices.append($0) }
        b.record("claude", usd: 2)
        XCTAssertEqual(notices.count, 1)
        if case .capReached = notices[0] {} else { XCTFail() }
    }

    // MARK: Rate limit

    func testRunawayLoopIsRefusedAndRecoversAfterAMinute() {
        let (b, clock) = makeBudget(cap: 100)             // 5 model requests a minute in this test
        for _ in 0..<5 { XCTAssertNoThrow(try b.check("claude")); clock.advance(1) }
        XCTAssertThrowsError(try b.check("claude")) { XCTAssertEqual($0 as? BudgetError, .rateLimited(service: "claude", perMinute: 5)) }
        XCTAssertNoThrow(try b.check("openai"), "each service has its own window")
        clock.advance(60)
        XCTAssertNoThrow(try b.check("claude"))
    }

    // MARK: Ledger

    func testSpendSurvivesARestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("spend-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let clock = Clock()
        var (b, _) = makeBudget(cap: 1, clock: clock, url: url)
        b.record("claude", usd: 0.9)
        (b, _) = makeBudget(cap: 1, clock: clock, url: url)       // a crash and a relaunch must not reset the day
        XCTAssertEqual(b.spentToday, 0.9, accuracy: 1e-9)
        XCTAssertEqual(b.today.byService["claude"] ?? 0, 0.9, accuracy: 1e-9)
        b.record("claude", usd: 0.2)
        XCTAssertThrowsError(try b.check("claude"))
    }

    func testSpokenNoticesAreShortAndPlain() {
        XCTAssertEqual(Budget.spoken(.nearLimit(spent: 2.4, cap: 3)), "Heads up: I've used 80 percent of today's 3 dollar budget.")
        XCTAssertEqual(Budget.spoken(.capReached(spent: 3.01, cap: 3)), "I've reached today's 3 dollar budget, so I'm pausing paid requests until midnight.")
        XCTAssertEqual(SpokenFailure.message(for: BudgetError.dailyCapReached(spent: 3, cap: 3)), "I've reached today's 3 dollar budget. I'll be back at midnight, or raise it in settings.")
        XCTAssertEqual(SpokenFailure.message(for: BudgetError.rateLimited(service: "claude", perMinute: 30)), "I'm sending too many requests. Give me a minute.")
    }

    // MARK: Every model call is metered

    func drain(_ s: AsyncThrowingStream<ClaudeClient.Event, Error>) async throws { for try await _ in s {} }

    func testMeteredModelRecordsWhatACallReallyCost() async throws {
        let inner = ScriptedModel(rounds: [[
            .usage(input: 190, output: 0, cacheRead: 10_405, cacheWrite: 0),
            .serverBlock(["type": "server_tool_use", "name": "web_search", "id": "s1"]),
            .textDelta("Done."), .stopReason("end_turn"),
            .usage(input: 190, output: 40, cacheRead: 10_405, cacheWrite: 0),
        ]])
        let (b, _) = makeBudget(cap: 1)
        let model = MeteredModel(inner, budget: b)
        try await drain(model.stream(.init(model: "claude-sonnet-5-5", system: "s", messages: [], tools: [], maxTokens: 100)))
        XCTAssertEqual(b.spentToday, 0.00182 + 0.01, accuracy: 0.00001, "tokens counted once, plus one web search")
        XCTAssertEqual(b.today.calls, 1)
    }

    func testOverTheCapNoRequestLeavesTheMac() async {
        let inner = ScriptedModel(rounds: [[.textDelta("should never be asked for")]])
        let (b, _) = makeBudget(cap: 1)
        b.record("claude", usd: 1.2)
        let model = MeteredModel(inner, budget: b)
        do { try await drain(model.stream(.init(model: "claude-sonnet-5-5", system: "s", messages: [], tools: [], maxTokens: 100))); XCTFail("should refuse") }
        catch { XCTAssertEqual(error as? BudgetError, .dailyCapReached(spent: 1.2, cap: 1)) }
        XCTAssertTrue(inner.requests.isEmpty, "the paid API must not be called")
        do { _ = try await model.prewarm(.init(model: "claude-sonnet-5-5", system: "s", messages: [], tools: [], maxTokens: 0)); XCTFail() } catch {}
        XCTAssertTrue(inner.prewarms.isEmpty)
    }

    func testCacheWarmUpsAreMeteredToo() async throws {
        let inner = ScriptedModel(rounds: [])
        let (b, _) = makeBudget(cap: 1)
        _ = try await MeteredModel(inner, budget: b).prewarm(.init(model: "claude-sonnet-5-5", system: "s", messages: [], tools: [], maxTokens: 0))
        XCTAssertEqual(b.spentToday, 20_000 * 2.5 / 1_000_000, accuracy: 1e-9)   // the fake reports a 20,000-token write
    }
}

@MainActor
final class BudgetPipelineTests: XCTestCase {
    let rig = PipelineStagesTests()

    func testBudgetRefusalIsSpoken() async {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech()
        let c = rig.makeController(wake, stt, intent, speech)
        intent.error = BudgetError.dailyCapReached(spent: 3.02, cap: 3)
        c.ask("what's the weather")
        await rig.wait("the refusal") { speech.isWaitingToFinish && !speech.spoken.isEmpty }
        XCTAssertEqual(speech.spoken.joined(separator: " "), "I've reached today's 3 dollar budget. I'll be back at midnight, or raise it in settings.")
        speech.finishSpeaking()
        await rig.wait("idle") { c.state == .idle }
    }

    func testWarningWaitsForTheReplyThenIsSpoken() async {
        let wake = FakeWake(), stt = FakeTranscriber(), intent = FakeIntent(), speech = FakeSpeech()
        let c = rig.makeController(wake, stt, intent, speech)
        c.ask("status report")
        await rig.wait("the reply") { speech.isWaitingToFinish }
        let warning = Budget.spoken(.nearLimit(spent: 2.4, cap: 3))
        c.announceWhenIdle(warning)                       // arrives mid-reply, as it does in real use
        XCTAssertFalse(speech.spoken.contains(warning), "never talks over its own answer")
        speech.finishSpeaking()
        await rig.wait("the warning") { speech.spoken.contains(warning) }
        XCTAssertEqual(c.state, .speaking)
        speech.finishSpeaking()
        await rig.wait("idle") { c.state == .idle }
        XCTAssertEqual(c.illegalTransitions, 0)
    }
}
