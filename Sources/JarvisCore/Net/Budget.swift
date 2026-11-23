import Foundation

/// What paid calls cost. Prices change, so they live in `profile.json → pricing`; these defaults are
/// Anthropic's list prices as of 2026-11-03. The speech prices are estimates: set your plan's real rate.
public struct Pricing: Codable, Equatable, Sendable {
    public struct Model: Codable, Equatable, Sendable {
        /// Matches any model ID that starts with this.
        public var prefix: String
        /// US dollars per million tokens.
        public var input: Double
        public var output: Double
        public var cacheRead: Double
        /// Five-minute cache write (1.25 × input).
        public var cacheWrite: Double
        public init(prefix: String, input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
            self.prefix = prefix; self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        }
    }

    public var models: [Model] = [
        Model(prefix: "claude-fable-5-2", input: 8, output: 40, cacheRead: 0.20, cacheWrite: 10),
        Model(prefix: "claude-opus-5-5", input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5),
        Model(prefix: "claude-opus", input: 5, output: 25, cacheRead: 0.50, cacheWrite: 6.25),
        Model(prefix: "claude-sonnet-5-5", input: 2, output: 10, cacheRead: 0.10, cacheWrite: 2.5),
        Model(prefix: "claude-sonnet-5", input: 2, output: 10, cacheRead: 0.20, cacheWrite: 2.5),
        Model(prefix: "claude-sonnet", input: 3, output: 15, cacheRead: 0.30, cacheWrite: 3.75),
        Model(prefix: "claude-haiku-5-5", input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125),
        Model(prefix: "claude-haiku", input: 1, output: 5, cacheRead: 0.10, cacheWrite: 1.25),
    ]
    /// One server-side web search.
    public var webSearchPerCall: Double = 0.01
    /// Estimates per 1,000 characters of speech. Kokoro and Apple voices are free.
    public var elevenLabsPer1kChars: Double = 0.10
    public var openAIPer1kChars: Double = 0.015

    public init() {}

    public init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = try c.decodeIfPresent([Model].self, forKey: .models) ?? models
        webSearchPerCall = try c.decodeIfPresent(Double.self, forKey: .webSearchPerCall) ?? webSearchPerCall
        elevenLabsPer1kChars = try c.decodeIfPresent(Double.self, forKey: .elevenLabsPer1kChars) ?? elevenLabsPer1kChars
        openAIPer1kChars = try c.decodeIfPresent(Double.self, forKey: .openAIPer1kChars) ?? openAIPer1kChars
    }

    /// The longest matching prefix wins. An unknown model is priced like the most expensive one known,
    /// so an unrecognised model can only make the cap arrive early, never late.
    public func price(for model: String) -> Model {
        if let m = models.filter({ model.hasPrefix($0.prefix) }).max(by: { $0.prefix.count < $1.prefix.count }) { return m }
        return models.max(by: { $0.output < $1.output }) ?? Model(prefix: "", input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5)
    }

    public func cost(model: String, input: Int, output: Int, cacheRead: Int, cacheWrite: Int, webSearches: Int = 0) -> Double {
        let p = price(for: model)
        let tokens = Double(input) * p.input + Double(output) * p.output + Double(cacheRead) * p.cacheRead + Double(cacheWrite) * p.cacheWrite
        return tokens / 1_000_000 + Double(webSearches) * webSearchPerCall
    }

    public func speechCost(provider: String, characters: Int) -> Double {
        switch provider {
        case "elevenlabs": return Double(characters) / 1000 * elevenLabsPer1kChars
        case "openai": return Double(characters) / 1000 * openAIPer1kChars
        default: return 0
        }
    }
}

public enum BudgetError: LocalizedError, Equatable {
    case dailyCapReached(spent: Double, cap: Double)
    case rateLimited(service: String, perMinute: Int)

    public var errorDescription: String? {
        switch self {
        case .dailyCapReached(let spent, let cap): return String(format: "Daily budget reached ($%.2f of $%.2f)", spent, cap)
        case .rateLimited(let service, let n): return "Rate limit: more than \(n) \(service) requests in a minute"
        }
    }
}

/// The spend guard every paid call goes through: Claude (replies, cache warm-ups, briefings), web search,
/// and cloud speech.
///
///  - `check` runs before a call. It refuses when today's cap is reached or when calls are arriving too
///    fast (a runaway loop).
///  - `record` runs after, with what the call really cost.
///  - Crossing the warning line (80% by default) and reaching the cap each fire `onNotice` once per day,
///    so Jarvis can say so out loud.
///
/// Spend is kept per local calendar day in `~/Library/Application Support/Jarvis/spend.json`.
public final class Budget: @unchecked Sendable {
    public struct Limits: Equatable, Sendable {
        /// 0 means no cap.
        public var dailyCapUSD: Double = 3
        public var warnFraction: Double = 0.8
        public var modelRequestsPerMinute = 30
        public var speechRequestsPerMinute = 90
        public init() {}
    }

    public struct Day: Codable, Equatable, Sendable {
        public var usd: Double = 0
        public var calls: Int = 0
        public var byService: [String: Double] = [:]
        public var warned = false
        public var capAnnounced = false
    }

    public enum Notice: Equatable { case nearLimit(spent: Double, cap: Double), capReached(spent: Double, cap: Double) }

    public var limits: Limits
    public var pricing: Pricing
    /// Called once per day for each notice, on whatever thread recorded the spend.
    public var onNotice: ((Notice) -> Void)?

    private let url: URL?
    private let now: () -> Date
    private let lock = NSLock()
    private var days: [String: Day] = [:]
    private var recent: [String: [Date]] = [:]

    public init(limits: Limits = Limits(), pricing: Pricing = Pricing(), url: URL? = Budget.defaultURL, now: @escaping () -> Date = Date.init) {
        self.limits = limits
        self.pricing = pricing
        self.url = url
        self.now = now
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String: Day].self, from: data) { days = saved }
    }

    public static var defaultURL: URL? {
        Runtime.isTesting ? nil : ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("spend.json")
    }

    static func key(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar.current; f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public var today: Day { lock.lock(); defer { lock.unlock() }; return days[Self.key(now())] ?? Day() }
    public var spentToday: Double { today.usd }
    public var isOverCap: Bool { limits.dailyCapUSD > 0 && spentToday >= limits.dailyCapUSD }

    /// "$0.42 of $3.00 today"
    public var summary: String {
        limits.dailyCapUSD > 0 ? String(format: "$%.2f of $%.2f today", spentToday, limits.dailyCapUSD)
                               : String(format: "$%.2f today (no cap)", spentToday)
    }

    /// Call before a paid request. `service` is "claude", "elevenlabs", or "openai".
    public func check(_ service: String) throws {
        let t = now()
        lock.lock(); defer { lock.unlock() }
        let spent = days[Self.key(t)]?.usd ?? 0
        if limits.dailyCapUSD > 0, spent >= limits.dailyCapUSD { throw BudgetError.dailyCapReached(spent: spent, cap: limits.dailyCapUSD) }
        let perMinute = service == "claude" ? limits.modelRequestsPerMinute : limits.speechRequestsPerMinute
        var window = (recent[service] ?? []).filter { t.timeIntervalSince($0) < 60 }
        if perMinute > 0, window.count >= perMinute {
            recent[service] = window
            throw BudgetError.rateLimited(service: service, perMinute: perMinute)
        }
        window.append(t)
        recent[service] = window
    }

    /// Call after a paid request with what it cost.
    public func record(_ service: String, usd: Double) {
        guard usd > 0, usd.isFinite else { return }
        let t = now()
        var notices: [Notice] = []
        lock.lock()
        let key = Self.key(t)
        var day = days[key] ?? Day()
        day.usd += usd
        day.calls += 1
        day.byService[service, default: 0] += usd
        let cap = limits.dailyCapUSD
        if cap > 0 {
            if day.usd >= cap, !day.capAnnounced { day.capAnnounced = true; day.warned = true; notices.append(.capReached(spent: day.usd, cap: cap)) }
            else if day.usd >= cap * limits.warnFraction, !day.warned { day.warned = true; notices.append(.nearLimit(spent: day.usd, cap: cap)) }
        }
        days[key] = day
        // Keep two months of history.
        if days.count > 62 { for old in days.keys.sorted().dropLast(62) { days.removeValue(forKey: old) } }
        let snapshot = days
        lock.unlock()
        if let url, let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        for n in notices { onNotice?(n) }
    }

    /// What Jarvis says for a notice or a refusal.
    public static func spoken(_ notice: Notice) -> String {
        switch notice {
        case .nearLimit(let spent, let cap):
            return "Heads up: I've used \(Int((spent / cap * 100).rounded())) percent of today's \(dollars(cap)) budget."
        case .capReached(_, let cap):
            return "I've reached today's \(dollars(cap)) budget, so I'm pausing paid requests until midnight."
        }
    }

    static func dollars(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v)) dollar" : String(format: "%.2f dollar", v)
    }
}

/// Wraps the language model so that every request, whoever makes it, is checked against the budget
/// first and has its real cost recorded afterwards.
public final class MeteredModel: LanguageModel, @unchecked Sendable {
    private let inner: any LanguageModel
    private let budget: Budget

    public init(_ inner: any LanguageModel, budget: Budget) { self.inner = inner; self.budget = budget }

    public func stream(_ request: ClaudeClient.Request) -> AsyncThrowingStream<ClaudeClient.Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [inner, budget] in
                var usage = (0, 0, 0, 0), searches = 0
                // Record what was used before the caller sees the stream end, so the ledger is never
                // behind the reply. This also runs when the stream is cut off or fails part-way.
                func settle() {
                    let usd = budget.pricing.cost(model: request.model, input: usage.0, output: usage.1, cacheRead: usage.2, cacheWrite: usage.3, webSearches: searches)
                    budget.record("claude", usd: usd)
                    RequestTrace.current?.event(.intent, "cost", ["usd": (usd * 10_000).rounded() / 10_000, "today_usd": (budget.spentToday * 100).rounded() / 100])
                }
                do {
                    try budget.check("claude")
                    for try await event in inner.stream(request) {
                        switch event {
                        case .usage(let i, let o, let cr, let cw):
                            usage = (max(usage.0, i), max(usage.1, o), max(usage.2, cr), max(usage.3, cw))   // cumulative: keep the largest
                        case .serverBlock(let block):
                            if block["type"] as? String == "server_tool_use", block["name"] as? String == "web_search" { searches += 1 }
                        default: break
                        }
                        continuation.yield(event)
                    }
                    settle()
                    continuation.finish()
                } catch {
                    settle()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func prewarm(_ request: ClaudeClient.Request) async throws -> (cacheRead: Int, cacheWrite: Int) {
        try budget.check("claude")
        let r = try await inner.prewarm(request)
        budget.record("claude", usd: budget.pricing.cost(model: request.model, input: 0, output: 0, cacheRead: r.cacheRead, cacheWrite: r.cacheWrite))
        return r
    }
}
