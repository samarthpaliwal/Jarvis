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
    public var llmMaxToolRounds: Int = 6
    /// A conversation is forgotten after this much inactivity.
    public var llmHistoryTimeoutMinutes: Double = 10
    /// Idle timeout between stream packets.
    public var llmRequestTimeoutSeconds: Double = 60
    /// Hard ceiling for one whole request.
    public var llmResourceTimeoutSeconds: Double = 300
    public var anthropicVersion: String = "2026-10-21"

    // Tools
    public var toolCallBudgetPerTurn: Int = 12
    public var localToolCallBudgetPerTurn: Int = 6
    public var webFetchMaxContentTokens: Int = 8000
    /// A Tier 2 approval that gets no answer in this long counts as "no".
    public var approvalTimeoutSeconds: Double = 12

    // Speech out
    public var kokoroPort: Int = 8880
    public var openaiTtsModel: String = "gpt-4o-mini-tts"
    public var ttsRequestTimeoutSeconds: Double = 15

    // Logs
    /// A log file rotates when it passes this size.
    public var logMaxMegabytes: Double = 5
    /// Rotated files kept per log (jarvis.log.1 … .N).
    public var logKeepFiles: Int = 3

    public init() {}

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
        toolCallBudgetPerTurn = try c.decodeIfPresent(Int.self, forKey: .toolCallBudgetPerTurn) ?? toolCallBudgetPerTurn
        localToolCallBudgetPerTurn = try c.decodeIfPresent(Int.self, forKey: .localToolCallBudgetPerTurn) ?? localToolCallBudgetPerTurn
        webFetchMaxContentTokens = try c.decodeIfPresent(Int.self, forKey: .webFetchMaxContentTokens) ?? webFetchMaxContentTokens
        approvalTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .approvalTimeoutSeconds) ?? approvalTimeoutSeconds
        kokoroPort = try c.decodeIfPresent(Int.self, forKey: .kokoroPort) ?? kokoroPort
        openaiTtsModel = try c.decodeIfPresent(String.self, forKey: .openaiTtsModel) ?? openaiTtsModel
        ttsRequestTimeoutSeconds = try c.decodeIfPresent(Double.self, forKey: .ttsRequestTimeoutSeconds) ?? ttsRequestTimeoutSeconds
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
