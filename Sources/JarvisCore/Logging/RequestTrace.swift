import Foundation

/// The five stages every request passes through, in order.
public enum Stage: String, CaseIterable, Codable, Sendable {
    case heard          // wake word fired, or text arrived
    case transcribed    // speech became text
    case intent         // Claude decided what to do (text and/or tool calls)
    case action         // tools ran
    case spoken         // the reply reached the speaker (or the screen, when voice is off)
}

/// One request, traced end to end.
///
/// Every request gets a short ID (`r-3fa9c1`). While a request is running, the ID is attached to
/// each line in jarvis.log, and each stage writes a JSON line to trace.jsonl. When the request ends,
/// one summary line records the latency of every stage.
///
///     {"ts":"…","request":"r-3fa9c1","stage":"transcribed","event":"speech_end","t_ms":3120,"reason":"silenceAfterSpeech","chars":41}
///     {"ts":"…","request":"r-3fa9c1","event":"request","outcome":"spoken","ms":{"listen":3120,"llm_first_token":1540,"tools":310,"first_audio":2210,"total":9800},…}
///
/// trace.jsonl never contains what was said, only sizes and timings. The words are in conversations.log.
public final class RequestTrace: @unchecked Sendable {
    /// The request the current Swift task is working on. Set by the pipeline around each turn, so
    /// the brain, the dispatcher, and the logger see it without it being passed to every call.
    @TaskLocal public static var current: RequestTrace?

    public let id: String
    public let source: String
    public let startedAt: Date

    private let sink: TraceSink
    private let now: () -> Date
    private let lock = NSLock()
    private var marks: [String: Double] = [:]
    private var tools: [[String: Any]] = []
    private var extra: [String: Any] = [:]
    private var stagesSeen: [Stage] = []
    private var summary: [String: Any]?
    private var outside: [String] = []

    public init(source: String, sink: TraceSink = .shared, id: String = RequestTrace.newID(), now: @escaping () -> Date = Date.init) {
        self.id = id
        self.source = source
        self.sink = sink
        self.now = now
        self.startedAt = now()
    }

    public static func newID() -> String {
        "r-" + String(UInt32.random(in: 0...0xFFFFFF), radix: 16).leftPadded(to: 6)
    }

    /// Milliseconds since the request started.
    public var elapsedMs: Double { now().timeIntervalSince(startedAt) * 1000 }

    /// Records a named point in time for a stage and writes it to trace.jsonl. The first occurrence
    /// of each name is the one used for latency maths.
    public func event(_ stage: Stage, _ name: String, _ fields: [String: Any] = [:]) {
        let t = elapsedMs
        lock.lock()
        if marks[name] == nil { marks[name] = t }
        if !stagesSeen.contains(stage) { stagesSeen.append(stage) }
        let done = summary != nil
        lock.unlock()
        guard !done else { return }
        var line: [String: Any] = ["request": id, "stage": stage.rawValue, "event": name, "t_ms": t.rounded()]
        for (k, v) in fields { line[k] = v }
        sink.write(line)
    }

    /// One tool call, with how long it took.
    public func tool(_ name: String, ms: Double?, outcome: String, tier: Int? = nil) {
        lock.lock()
        var entry: [String: Any] = ["name": name, "outcome": outcome]
        if let ms { entry["ms"] = ms.rounded() }
        tools.append(entry)
        lock.unlock()
        var fields = entry
        if let tier { fields["tier"] = tier }
        fields.removeValue(forKey: "name")
        fields["tool"] = name
        event(.action, "tool", fields)
    }

    /// Records that content from outside (an email, a web page, a file, a calendar invite) was read while
    /// working on this request. From then on, anything that needs approval says so.
    public func markUntrusted(_ source: String) {
        lock.lock(); if !outside.contains(source) { outside.append(source) }; lock.unlock()
    }

    /// Kinds of outside content read so far in this request, in order.
    public var untrustedSources: [String] { lock.lock(); defer { lock.unlock() }; return outside }

    /// Attaches a value to the summary line (tokens, engine, model…).
    public func set(_ key: String, _ value: Any) {
        lock.lock(); extra[key] = value; lock.unlock()
    }

    public func mark(_ name: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return marks[name]
    }

    public var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return summary != nil }

    /// Ends the request and writes the summary. Safe to call more than once; only the first counts.
    @discardableResult
    public func finish(outcome: String) -> [String: Any] {
        let total = elapsedMs
        lock.lock()
        if let summary { lock.unlock(); return summary }
        var ms: [String: Any] = ["total": total.rounded()]
        func span(_ key: String, from: String?, to: String) {
            guard let end = marks[to] else { return }
            let start = from.flatMap { marks[$0] } ?? 0
            if from != nil, marks[from!] == nil { return }
            ms[key] = max(0, end - start).rounded()
        }
        span("first_word", from: nil, to: "first_word")              // wake → first transcribed word
        span("listen", from: nil, to: "speech_end")                  // wake → end of speech (includes the silence wait)
        span("llm_first_token", from: "speech_end", to: "first_token")
        span("llm_total", from: "speech_end", to: "llm_done")
        span("first_audio", from: "speech_end", to: "first_audio")   // end of speech → Jarvis audibly answering
        span("speech_done", from: "speech_end", to: "speech_done")
        let toolMs = tools.compactMap { $0["ms"] as? Double }.reduce(0, +)
        if !tools.isEmpty { ms["tools"] = toolMs.rounded() }
        var line: [String: Any] = ["request": id, "event": "request", "source": source, "outcome": outcome,
                                   "ms": ms, "stages": stagesSeen.map(\.rawValue)]
        if !tools.isEmpty { line["tools"] = tools }
        for (k, v) in extra { line[k] = v }
        summary = line
        lock.unlock()
        sink.write(line)
        JarvisLog.info("Request \(outcome): " + Self.describe(ms), request: id)
        return line
    }

    static func describe(_ ms: [String: Any]) -> String {
        ["listen", "llm_first_token", "tools", "first_audio", "total"].compactMap { key in
            (ms[key] as? Double).map { "\(key)=\(Int($0))ms" }
        }.joined(separator: " ")
    }
}

/// Where trace lines go: trace.jsonl, plus a short in-memory tail for the menu and the tests.
public final class TraceSink: @unchecked Sendable {
    public static let shared = TraceSink(file: FileLog(name: "trace.jsonl"))

    private let file: FileLog?
    private let lock = NSLock()
    private var tail: [[String: Any]] = []
    private let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public init(file: FileLog?) { self.file = file }

    public func write(_ fields: [String: Any]) {
        var line = fields
        lock.lock()
        line["ts"] = formatter.string(from: Date())
        tail.append(line)
        if tail.count > 200 { tail.removeFirst(tail.count - 200) }
        lock.unlock()
        guard let file, JSONSerialization.isValidJSONObject(line),
              let data = try? JSONSerialization.data(withJSONObject: line, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        file.writeRaw(text)
    }

    /// Most recent lines, oldest first.
    public var recent: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return tail }

    /// Summary lines only (one per finished request).
    public var recentRequests: [[String: Any]] { recent.filter { $0["event"] as? String == "request" } }
}

extension String {
    func leftPadded(to length: Int, with pad: Character = "0") -> String {
        count >= length ? self : String(repeating: pad, count: length - count) + self
    }
}
