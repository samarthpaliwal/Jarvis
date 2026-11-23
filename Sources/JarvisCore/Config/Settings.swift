import Foundation

/// True while the unit tests run, so they never read the user's env file or write the real logs.
public enum Runtime {
    public static let isTesting: Bool = NSClassFromString("XCTestCase") != nil
}

/// Environment variables, from two places:
///  1. the process environment (wins), and
///  2. an env file, because a menu-bar app launched from Finder has no shell environment.
///     `$JARVIS_ENV_FILE`, else `~/Library/Application Support/Jarvis/jarvis.env`.
///
/// The file is for settings only. Anything that looks like a secret is ignored: API keys live in
/// the macOS Keychain (menu → Set API Key…), never in a plain-text file.
public enum Env {
    public static var fileURL: URL {
        if let p = ProcessInfo.processInfo.environment["JARVIS_ENV_FILE"], !p.isEmpty {
            return URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        }
        return ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("jarvis.env")
    }

    /// Loaded once at first use.
    public static let fromFile: [String: String] = {
        guard !Runtime.isTesting, let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [:] }
        let parsed = parse(text)
        if !parsed.ignoredSecrets.isEmpty {
            JarvisLog.warn("jarvis.env: ignored \(parsed.ignoredSecrets.sorted().joined(separator: ", ")). Secrets belong in the Keychain (menu → Set API Key…).")
        }
        if !parsed.values.isEmpty { JarvisLog.info("jarvis.env: loaded \(parsed.values.keys.sorted().joined(separator: ", "))") }
        return parsed.values
    }()

    /// Process environment over the env file.
    public static var all: [String: String] {
        fromFile.merging(ProcessInfo.processInfo.environment) { _, process in process }
    }

    public static func value(_ key: String) -> String? {
        if let v = ProcessInfo.processInfo.environment[key], !v.isEmpty { return v }
        if let v = fromFile[key], !v.isEmpty { return v }
        return nil
    }

    public static func flag(_ key: String) -> Bool { ["1", "true", "yes", "on"].contains(value(key)?.lowercased() ?? "") }

    static func looksSecret(_ key: String) -> Bool {
        let k = key.uppercased()
        return ["KEY", "TOKEN", "SECRET", "PASSWORD", "CREDENTIAL"].contains { k.contains($0) }
    }

    /// `KEY=value` lines; `#` comments, blank lines, optional `export`, optional quotes.
    public static func parse(_ text: String) -> (values: [String: String], ignoredSecrets: [String]) {
        var values: [String: String] = [:]
        var ignored: [String] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let f = value.first, f == value.last, f == "\"" || f == "'" {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)   // trailing comment
            }
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            if looksSecret(key) { ignored.append(key); continue }
            values[key] = value
        }
        return (values, ignored)
    }
}

/// Every threshold, limit, and timeout that used to be a literal in the code.
///
/// Set them in `profile.json → tuning`, or override any one with an environment variable named
/// `JARVIS_` + the field in upper snake case: `wakeThreshold` → `JARVIS_WAKE_THRESHOLD`.
public struct Tuning: Codable, Equatable, Sendable {
    // Wake word
    /// Detection score needed to wake (0…1). Lower wakes more easily and falsely.
    public var wakeThreshold: Double = 0.5
    /// Ignore further detections for this long after a wake.
    public var wakeCooldownSeconds: Double = 2.0

    // Microphone recovery
    public var micSilenceTimeoutSeconds: Double = 6
    public var micRestartDebounceSeconds: Double = 0.5
    public var micMaxBackoffSeconds: Double = 60
    /// Silent rebuilds in a row before Jarvis says it cannot hear.
    public var micDeafAfterRebuilds: Int = 3

    // Language model
    /// `output_config.effort` for voice turns: low | medium | high | xhigh | max.
    public var llmEffort: String = "low"
    public var llmMaxHistoryMessages: Int = 24
    public var llmMaxToolRounds: Int = 10
    /// A conversation is forgotten after this much inactivity.
    public var llmHistoryTimeoutMinutes: Double = 10
    /// Idle timeout between stream packets.
    public var llmRequestTimeoutSeconds: Double = 60
    /// Hard ceiling for one whole request.
    public var llmResourceTimeoutSeconds: Double = 300
    public var anthropicVersion: String = "2026-10-21"

    // Spending
    /// Paid requests (Claude, web search, cloud voices) stop for the day at this many US dollars. 0 = no cap.
    public var dailyBudgetUSD: Double = 3
    /// Jarvis says so once when this share of the budget is used.
    public var budgetWarnFraction: Double = 0.8
    /// More model requests than this in one minute is treated as a runaway loop and refused.
    public var modelRequestsPerMinute: Int = 30
    public var speechRequestsPerMinute: Int = 90

    // Network
    /// Timeout for requests that do not set their own (Gmail, Notion, Spotify, Google sign-in).
    public var httpTimeoutSeconds: Double = 15
    /// Extra attempts after a busy server or a dropped connection. Applies to Claude too.
    public var httpMaxRetries: Int = 2
    public var httpRetryBaseSeconds: Double = 0.5
    public var httpRetryMaxSeconds: Double = 8

    // Tools
    public var toolCallBudgetPerTurn: Int = 16
    public var localToolCallBudgetPerTurn: Int = 6
    public var webFetchMaxContentTokens: Int = 8000
    /// A Tier 2 approval that gets no answer in this long counts as "no".
    public var approvalTimeoutSeconds: Double = 12
    /// One tool call may run this long before Jarvis gives up on it and says so.
    public var toolTimeoutSeconds: Double = 45
    /// One whole request (model rounds plus tools) may run this long. Time spent waiting for an approval counts.
    public var turnTimeoutSeconds: Double = 120
    /// The same spoken error is not repeated within this many seconds (it is still shown).
    public var repeatErrorAfterSeconds: Double = 60

    // Speech out
    public var kokoroPort: Int = 8880
    public var openaiTtsModel: String = "gpt-4o-mini-tts"
    public var ttsRequestTimeoutSeconds: Double = 15

    // Latency
    /// When what was heard already ends a sentence (. ? !), end the turn after this much silence instead
    /// of `speech.silenceEndSeconds`. 0 turns this off.
    public var endpointFastSilenceSeconds: Double = 0.9
    /// The fast silence applies only to utterances with at least this many words.
    public var endpointFastMinWords: Int = 3
    /// Speak the opening clause of a reply as soon as it has this many words, instead of waiting for the
    /// whole first sentence. 0 waits for the sentence.
    public var ttsFirstChunkMinWords: Int = 3
    /// Warm Claude's prompt cache when a request starts and the last one was longer ago than this. 0 turns it off.
    public var cachePrewarmAfterSeconds: Double = 240

    // Echo: Jarvis hearing its own voice
    /// When talking over Jarvis interrupts it: "headphones" (only when the mic cannot hear the speakers),
    /// "always", or "never". Saying "stop" or the wake word always works.
    public var speechBargeIn: String = "headphones"
    /// Pause between Jarvis finishing a reply and listening for a follow-up, so the room goes quiet first.
    public var followUpGuardMilliseconds: Double = 350
    /// For this long after Jarvis speaks, a follow-up that repeats the reply is treated as echo and dropped.
    public var echoWindowSeconds: Double = 20

    // Logs
    /// A log file rotates when it passes this size.
    public var logMaxMegabytes: Double = 5
    /// Rotated files kept per log (jarvis.log.1 … .N).
    public var logKeepFiles: Int = 3

    public init() {}

    public var budgetLimits: Budget.Limits {
        var l = Budget.Limits()
        l.dailyCapUSD = max(0, dailyBudgetUSD); l.warnFraction = min(1, max(0.1, budgetWarnFraction))
        l.modelRequestsPerMinute = modelRequestsPerMinute; l.speechRequestsPerMinute = speechRequestsPerMinute
        return l
    }

    public var retryPolicy: RetryPolicy {
        var p = RetryPolicy()
        p.maxRetries = max(0, httpMaxRetries); p.baseDelay = httpRetryBaseSeconds; p.maxDelay = httpRetryMaxSeconds; p.timeout = httpTimeoutSeconds
        return p
    }

    public init(from decoder: Decoder) throws {
        // Every field is optional in the file; missing ones keep the default above.
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wakeThreshold = try c.decodeIfPresent(Double.self, forKey: .wakeThreshold) ?? wakeThreshold
        wakeCooldownSeconds = try c.decodeIfPresent(Double.self, forKey: .wakeCooldownSeconds) ?? wakeCooldownSeconds
        micSilenceTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .micSilenceTimeoutSeconds) ?? micSilenceTimeoutSeconds
        micRestartDebounceSeconds = try c.decodeIfPresent(Double.self, forKey: .micRestartDebounceSeconds) ?? micRestartDebounceSeconds
        micMaxBackoffSeconds = try c.decodeIfPresent(Double.self, forKey: .micMaxBackoffSeconds) ?? micMaxBackoffSeconds
        micDeafAfterRebuilds = try c.decodeIfPresent(Int.self, forKey: .micDeafAfterRebuilds) ?? micDeafAfterRebuilds
        llmEffort = try c.decodeIfPresent(String.self, forKey: .llmEffort) ?? llmEffort
        llmMaxHistoryMessages = try c.decodeIfPresent(Int.self, forKey: .llmMaxHistoryMessages) ?? llmMaxHistoryMessages
        llmMaxToolRounds = try c.decodeIfPresent(Int.self, forKey: .llmMaxToolRounds) ?? llmMaxToolRounds
        llmHistoryTimeoutMinutes = try c.decodeIfPresent(Double.self, forKey: .llmHistoryTimeoutMinutes) ?? llmHistoryTimeoutMinutes
        llmRequestTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .llmRequestTimeoutSeconds) ?? llmRequestTimeoutSeconds
        llmResourceTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .llmResourceTimeoutSeconds) ?? llmResourceTimeoutSeconds
        anthropicVersion = try c.decodeIfPresent(String.self, forKey: .anthropicVersion) ?? anthropicVersion
        dailyBudgetUSD = try c.decodeIfPresent(Double.self, forKey: .dailyBudgetUSD) ?? dailyBudgetUSD
        budgetWarnFraction = try c.decodeIfPresent(Double.self, forKey: .budgetWarnFraction) ?? budgetWarnFraction
        modelRequestsPerMinute = try c.decodeIfPresent(Int.self, forKey: .modelRequestsPerMinute) ?? modelRequestsPerMinute
        speechRequestsPerMinute = try c.decodeIfPresent(Int.self, forKey: .speechRequestsPerMinute) ?? speechRequestsPerMinute
        httpTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .httpTimeoutSeconds) ?? httpTimeoutSeconds
        httpMaxRetries = try c.decodeIfPresent(Int.self, forKey: .httpMaxRetries) ?? httpMaxRetries
        httpRetryBaseSeconds = try c.decodeIfPresent(Double.self, forKey: .httpRetryBaseSeconds) ?? httpRetryBaseSeconds
        httpRetryMaxSeconds = try c.decodeIfPresent(Double.self, forKey: .httpRetryMaxSeconds) ?? httpRetryMaxSeconds
        toolCallBudgetPerTurn = try c.decodeIfPresent(Int.self, forKey: .toolCallBudgetPerTurn) ?? toolCallBudgetPerTurn
        localToolCallBudgetPerTurn = try c.decodeIfPresent(Int.self, forKey: .localToolCallBudgetPerTurn) ?? localToolCallBudgetPerTurn
        webFetchMaxContentTokens = try c.decodeIfPresent(Int.self, forKey: .webFetchMaxContentTokens) ?? webFetchMaxContentTokens
        approvalTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .approvalTimeoutSeconds) ?? approvalTimeoutSeconds
        toolTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .toolTimeoutSeconds) ?? toolTimeoutSeconds
        turnTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .turnTimeoutSeconds) ?? turnTimeoutSeconds
        repeatErrorAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .repeatErrorAfterSeconds) ?? repeatErrorAfterSeconds
        kokoroPort = try c.decodeIfPresent(Int.self, forKey: .kokoroPort) ?? kokoroPort
        openaiTtsModel = try c.decodeIfPresent(String.self, forKey: .openaiTtsModel) ?? openaiTtsModel
        ttsRequestTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .ttsRequestTimeoutSeconds) ?? ttsRequestTimeoutSeconds
        endpointFastSilenceSeconds = try c.decodeIfPresent(Double.self, forKey: .endpointFastSilenceSeconds) ?? endpointFastSilenceSeconds
        endpointFastMinWords = try c.decodeIfPresent(Int.self, forKey: .endpointFastMinWords) ?? endpointFastMinWords
        ttsFirstChunkMinWords = try c.decodeIfPresent(Int.self, forKey: .ttsFirstChunkMinWords) ?? ttsFirstChunkMinWords
        cachePrewarmAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .cachePrewarmAfterSeconds) ?? cachePrewarmAfterSeconds
        speechBargeIn = try c.decodeIfPresent(String.self, forKey: .speechBargeIn) ?? speechBargeIn
        followUpGuardMilliseconds = try c.decodeIfPresent(Double.self, forKey: .followUpGuardMilliseconds) ?? followUpGuardMilliseconds
        echoWindowSeconds = try c.decodeIfPresent(Double.self, forKey: .echoWindowSeconds) ?? echoWindowSeconds
        logMaxMegabytes = try c.decodeIfPresent(Double.self, forKey: .logMaxMegabytes) ?? logMaxMegabytes
        logKeepFiles = try c.decodeIfPresent(Int.self, forKey: .logKeepFiles) ?? logKeepFiles
    }

    /// Applies `JARVIS_*` overrides. Values that don't parse are skipped and reported.
    public func applying(env: [String: String]) -> (tuning: Tuning, applied: [String], rejected: [String]) {
        guard var dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] else { return (self, [], []) }
        var applied: [String] = [], rejected: [String] = []
        for (field, current) in dict {
            let name = Self.envName(for: field)
            guard let raw = env[name], !raw.isEmpty else { continue }
            if current is String { dict[field] = raw; applied.append(name) }
            else if let n = Double(raw), n.isFinite, n >= 0 { dict[field] = n; applied.append(name) }
            else { rejected.append("\(name)=\(raw)") }
        }
        guard let out = try? Self.build(from: dict) else { return (self, [], applied + rejected) }
        return (out, applied.sorted(), rejected.sorted())
    }

    /// `wakeThreshold` → `JARVIS_WAKE_THRESHOLD`, `openaiTtsModel` → `JARVIS_OPENAI_TTS_MODEL`.
    public static func envName(for field: String) -> String {
        var out = "JARVIS_"
        let chars = Array(field)
        for (i, ch) in chars.enumerated() {
            if ch.isUppercase, i > 0 {
                let prevLower = chars[i - 1].isLowercase || chars[i - 1].isNumber
                let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
                if prevLower || nextLower { out += "_" }
            }
            out += ch.uppercased()
        }
        return out
    }

    /// Field name → env variable, for the docs and `.env.example`.
    public static var envNames: [(field: String, env: String, defaultValue: String)] {
        let dict = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(Tuning()))) as? [String: Any] ?? [:]
        return dict.keys.sorted().map { ($0, envName(for: $0), "\(dict[$0]!)") }
    }

    private static func build(from dict: [String: Any]) throws -> Tuning {
        // Whole numbers must be encoded as integers for the Int fields to decode.
        let normalized = dict.mapValues { v -> Any in
            if let d = v as? Double, d == d.rounded(), abs(d) < 1e15 { return Int(d) }
            return v
        }
        return try JSONDecoder().decode(Tuning.self, from: JSONSerialization.data(withJSONObject: normalized))
    }
}
