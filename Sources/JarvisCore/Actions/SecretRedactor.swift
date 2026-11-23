import Foundation

/// Redacts credentials from any text before it reaches Claude, the logs, or memory.
/// Patterns adapted from OpenJarvis's SecretScanner / credential_stripper.
public enum SecretRedactor {
    static let patterns: [(String, NSRegularExpression)] = [
        ("anthropic_key", #"sk-ant-[A-Za-z0-9_\-]{20,}"#),
        ("openai_key", #"sk-(?:proj-)?[A-Za-z0-9_\-]{20,}"#),
        ("aws_access_key", #"AKIA[0-9A-Z]{16}"#),
        ("github_token", #"(?:ghp|gho|ghs|ghr|github_pat)_[A-Za-z0-9_]{36,}"#),
        ("slack_token", #"xox[bpors]-[A-Za-z0-9\-]{10,}"#),
        ("stripe_key", #"(?:sk|pk|rk)_(?:test|live)_[A-Za-z0-9]{20,}"#),
        ("google_api_key", #"AIza[0-9A-Za-z_\-]{35}"#),
        ("notion_token", #"(?:secret|ntn)_[A-Za-z0-9]{40,}"#),
        ("bearer_token", #"(?i)bearer\s+[A-Za-z0-9_\-\.=]{20,}"#),
        ("private_key", #"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----[\s\S]*?(?:-----END (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----|$)"#),
        ("password_assignment", #"(?i)(?:password|passwd|pwd)\s*[=:]\s*['"]?[^\s'"]{4,}"#),
        ("generic_secret", #"(?i)(?:api[_-]?key|secret[_-]?key|auth[_-]?token|access[_-]?token|client[_-]?secret)\s*[=:]\s*['"]?[A-Za-z0-9_\-\./+=]{8,}"#),
        ("db_connection_string", #"(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis)://[^\s'"]{10,}"#),
        ("credit_card", #"\b(?:4\d{3}|5[1-5]\d{2}|3[47]\d{2})[\s-]?\d{4}[\s-]?\d{4}[\s-]?\d{3,4}\b"#),
    ].compactMap { name, pattern in (try? NSRegularExpression(pattern: pattern)).map { (name, $0) } }

    public static func findings(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.filter { $0.1.firstMatch(in: text, range: range) != nil }.map(\.0)
    }

    public static func redact(_ text: String) -> (text: String, kinds: [String]) {
        var out = text
        var kinds: [String] = []
        for (name, re) in patterns {
            let range = NSRange(out.startIndex..., in: out)
            if re.firstMatch(in: out, range: range) != nil {
                out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "[REDACTED:\(name)]")
                kinds.append(name)
            }
        }
        return (out, kinds)
    }
}

/// Flags likely prompt injection inside untrusted content (adapted from OpenJarvis InjectionScanner).
/// Content is never blocked, only labelled, so Claude sees the warning and Sam gets told.
public enum InjectionScanner {
    static let patterns: [(String, NSRegularExpression)] = [
        ("ignore_instructions", #"(?i)ignore\s+(?:all\s+)?(?:previous|prior|above|earlier)\s+(?:instructions?|prompts?|rules?)"#),
        ("disregard_instructions", #"(?i)disregard\s+(?:all\s+)?(?:previous|prior|your)\s+(?:instructions?|programming|rules?)"#),
        ("role_override", #"(?i)you\s+are\s+now\s+(?:a\s+)?(?:different|new|my|an?\s+unrestricted)"#),
        ("new_system_prompt", #"(?i)(?:new|updated)\s+system\s+(?:prompt|instructions?)"#),
        ("jailbreak", #"(?i)(?:DAN|do\s+anything\s+now)\s+(?:mode|prompt|jailbreak)|pretend\s+(?:you\s+)?(?:have\s+)?no\s+(?:restrictions?|limitations?|rules?|filters?)"#),
        ("exfiltration", #"(?i)(?:send|post|upload|exfiltrate|transmit|forward)\s+(?:(?:to|data|all|everything|the|your|this)\s+)*(?:to\s+)?(?:https?://|my\s+server|this\s+(?:email|address))"#),
        ("shell_chain", #"(?:;|\||&&)\s*(?:rm|curl|wget|nc|ncat|bash|sh|python3?|perl|osascript)\s"#),
        ("chat_markup", #"<\|(?:im_start|im_end|system|assistant)\|>|```(?:system|assistant)\b|</?(?:system|untrusted_content)>"#),
        ("tool_directive", #"(?i)(?:call|use|invoke|run)\s+the\s+(?:run_shell|email_draft|clear_caches|restart_app|organize_folder)\s+tool"#),
    ].compactMap { name, pattern in (try? NSRegularExpression(pattern: pattern)).map { (name, $0) } }

    public static func scan(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return patterns.filter { $0.1.firstMatch(in: text, range: range) != nil }.map(\.0)
    }
}

/// Stops the model from calling the same tool with the same input twice, ping-ponging between
/// two tools, or blowing through a per-turn budget (adapted from OpenJarvis LoopGuard).
public struct LoopGuard {
    private var seen: Set<String> = []
    private var recent: [String] = []
    private var calls = 0
    public let budget: Int

    public init(budget: Int = 12) { self.budget = budget }

    public mutating func check(tool: String, input: JSONObject) -> String? {
        let canon = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "\(input)"
        let key = tool + "|" + canon
        if seen.contains(key) {
            return "Loop detected: you already called \(tool) with exactly these arguments this turn. Use the earlier result."
        }
        seen.insert(key)
        recent.append(tool)
        if recent.count > 8 { recent.removeFirst() }
        let n = recent.count
        if n >= 6, recent[n - 1] == recent[n - 3], recent[n - 3] == recent[n - 5],
           recent[n - 2] == recent[n - 4], recent[n - 4] == recent[n - 6], recent[n - 1] != recent[n - 2] {
            return "Ping-pong loop detected between \(recent[n - 1]) and \(recent[n - 2]). Stop and answer with what you have."
        }
        calls += 1
        if calls > budget { return "Tool budget exceeded (\(budget) calls this turn). Answer with what you have." }
        return nil
    }
}
