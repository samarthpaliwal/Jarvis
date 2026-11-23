import Foundation

/// Thrown when a stage did not finish in time.
public struct TimeoutError: LocalizedError, Equatable {
    public var what: String
    public var seconds: Double
    public var errorDescription: String? { "\(what) timed out after \(Int(seconds)) s" }
}

/// Runs `operation` with a deadline. If the deadline passes first, the caller gets `TimeoutError`
/// at once and the operation is cancelled. A stage that ignores cancellation keeps running in the
/// background, but it can no longer hold the pipeline: this is what turns a silent hang into an answer.
public func withDeadline<T: Sendable>(_ what: String, seconds: Double,
                                      operation: @escaping @Sendable () async throws -> T) async throws -> T {
    guard seconds > 0, seconds.isFinite else { return try await operation() }
    let gate = OnceGate()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            let request = RequestTrace.current
            let work = Task {
                await RequestTrace.$current.withValue(request) {
                    do {
                        let value = try await operation()
                        if gate.claim() { cont.resume(returning: value) }
                    } catch {
                        if gate.claim() { cont.resume(throwing: error) }
                    }
                }
            }
            gate.onCancel = { work.cancel() }
            Task {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                if gate.claim() {
                    work.cancel()
                    cont.resume(throwing: TimeoutError(what: what, seconds: seconds))
                }
            }
        }
    } onCancel: {
        gate.cancel()
    }
}

/// Lets exactly one of several racing tasks resume a continuation.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    private var cancelHandler: (() -> Void)?
    private var cancelled = false

    var onCancel: (() -> Void)? {
        get { nil }
        set {
            lock.lock()
            let fireNow = cancelled
            cancelHandler = newValue
            lock.unlock()
            if fireNow { newValue?() }
        }
    }

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let h = cancelHandler
        lock.unlock()
        h?()
    }
}

/// What Jarvis says when something fails. One short sentence, no jargon, and a next step where there is one.
/// Rule: every failure in any stage is spoken (or shown, when voice is off). Nothing fails silently.
public enum SpokenFailure {
    public static func message(for error: Error) -> String {
        if let t = error as? TimeoutError {
            return t.what == "The request" ? "That took too long, so I stopped. Try again." : "\(t.what) took too long, so I stopped it."
        }
        if let e = error as? ClaudeClient.ClientError {
            switch e {
            case .noAPIKey: return "I don't have an API key yet. Add one from the Jarvis menu."
            case .http(let code, _):
                switch code {
                case 401, 403: return "The API key was rejected. Check it in the Jarvis menu."
                case 429: return "I'm being rate limited. Give me a moment and try again."
                case 500...599: return "Claude is having trouble right now. Try again in a moment."
                default: return "Claude rejected that request. Try saying it another way."
                }
            case .malformed: return "I got a garbled answer back. Try again."
            }
        }
        if let e = error as? TranscriberError {
            switch e {
            case .notAuthorized: return "I need Speech Recognition permission. It's in System Settings, under Privacy and Security."
            case .unavailable: return "Speech recognition isn't available right now."
            }
        }
        if error is AudioCaptureError { return "I can't find a microphone." }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorTimedOut: return "The network timed out. Try again."
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed:
                return "I'm offline right now."
            default: return "I can't reach the network right now."
            }
        }
        return "Something went wrong on my end. Try again."
    }

    /// Microphone health, announced once when it changes.
    public static let microphoneSilent = "I'm not getting any sound from the microphone. Check the input device."
    public static let microphoneBack = "The microphone is working again."
    public static let microphoneDenied = "I don't have microphone access. Turn it on in System Settings, under Privacy and Security."
    public static let wakeFailed = "I couldn't start listening for the wake word."

    /// The stage a failure belongs to, for the trace.
    public static func stage(of error: Error) -> Stage {
        if error is TranscriberError || error is AudioCaptureError { return .transcribed }
        return .intent
    }
}

/// Stops the same failure being spoken over and over (a dead recognizer fails on every wake).
/// The first one is spoken; repeats inside the window are shown on screen only.
public struct SpeechRateLimit {
    public var window: TimeInterval
    private var last: [String: Date] = [:]
    public init(window: TimeInterval = 60) { self.window = window }

    public mutating func shouldSpeak(_ message: String, at now: Date = Date()) -> Bool {
        if let t = last[message], now.timeIntervalSince(t) < window { return false }
        last[message] = now
        return true
    }
}
