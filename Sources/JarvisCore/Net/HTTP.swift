import Foundation

/// When and how long to wait before trying a network call again.
public struct RetryPolicy: Equatable, Sendable {
    /// Extra attempts after the first one.
    public var maxRetries = 2
    /// First wait; doubles each attempt.
    public var baseDelay: TimeInterval = 0.5
    /// No single wait is longer than this, whatever the server asks for.
    public var maxDelay: TimeInterval = 8
    /// Applied to requests that did not set their own timeout.
    public var timeout: TimeInterval = 15

    public init() {}

    /// Statuses worth another try: the server was busy or briefly broken, not the request wrong.
    public static func isRetryable(status: Int) -> Bool {
        [408, 409, 425, 429, 500, 502, 503, 504, 529].contains(status)
    }

    /// Statuses that are safe to retry even for a request that changes something: the server says it did not process it.
    public static func wasNotProcessed(status: Int) -> Bool { status == 429 || status == 503 || status == 529 }

    public enum Transport { case neverSent, maybeSent, permanent }

    /// Sorts a transport error: the request never left, it may have arrived, or retrying cannot help.
    public static func classify(_ error: Error) -> Transport {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return .permanent }
        switch ns.code {
        case NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
             NSURLErrorSecureConnectionFailed:
            return .neverSent
        case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost:
            return .maybeSent
        default:
            return .permanent      // offline, cancelled, bad URL, certificate problems: fail now
        }
    }

    /// The wait before retry number `attempt` (0 is the first retry). A `Retry-After` from the server
    /// wins over the computed backoff, but never beyond `maxDelay`: a voice assistant answers or apologises.
    public func delay(attempt: Int, retryAfter: TimeInterval? = nil, jitter: Double = Double.random(in: 0.75...1.25)) -> TimeInterval {
        if let retryAfter, retryAfter >= 0 { return min(maxDelay, retryAfter) }
        let backoff = baseDelay * pow(2, Double(max(0, min(attempt, 10))))
        return min(maxDelay, backoff * jitter)
    }

    /// `Retry-After` as seconds, from either form: a number of seconds or an HTTP date.
    public static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = TimeInterval(raw) { return max(0, seconds) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: raw).map { max(0, $0.timeIntervalSince(now)) }
    }

    /// `x-should-retry: false` from the server overrides everything else.
    public static func serverForbidsRetry(_ response: HTTPURLResponse) -> Bool {
        response.value(forHTTPHeaderField: "x-should-retry")?.lowercased() == "false"
    }
}

/// One place every outgoing request goes through: a timeout, retries with backoff, and a log line per retry.
///
/// Requests that only read (GET, HEAD, PUT, DELETE, or a POST the caller marks idempotent) are retried on
/// busy or briefly broken servers and on dropped connections. Requests that create something (a Gmail draft,
/// a Notion page) are retried only when the request provably did not go through, so nothing is created twice.
public enum HTTP {
    /// Set from Tuning at launch.
    public nonisolated(unsafe) static var policy = RetryPolicy()

    public static func send(_ request: URLRequest, session: URLSession = .shared, idempotent: Bool? = nil,
                            policy: RetryPolicy = HTTP.policy) async throws -> (Data, URLResponse) {
        var request = request
        if request.timeoutInterval == 60 { request.timeoutInterval = policy.timeout }   // 60 is URLRequest's default
        let method = (request.httpMethod ?? "GET").uppercased()
        let idempotent = idempotent ?? ["GET", "HEAD", "PUT", "DELETE", "OPTIONS"].contains(method)
        let host = request.url?.host ?? "?"
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, RetryPolicy.isRetryable(status: http.statusCode),
                      attempt < policy.maxRetries, !RetryPolicy.serverForbidsRetry(http),
                      idempotent || RetryPolicy.wasNotProcessed(status: http.statusCode) else { return (data, response) }
                let wait = policy.delay(attempt: attempt, retryAfter: RetryPolicy.retryAfter(http))
                note(host, method, "HTTP \(http.statusCode)", attempt, wait)
                try await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            } catch let error where !(error is CancellationError) {
                let kind = RetryPolicy.classify(error)
                guard attempt < policy.maxRetries, kind == .neverSent || (kind == .maybeSent && idempotent) else { throw error }
                let wait = policy.delay(attempt: attempt)
                note(host, method, error.localizedDescription, attempt, wait)
                try await Task.sleep(for: .milliseconds(Int(wait * 1000)))
            }
            attempt += 1
        }
    }

    static func note(_ host: String, _ method: String, _ why: String, _ attempt: Int, _ wait: TimeInterval) {
        JarvisLog.warn(String(format: "Retry %d for %@ %@ in %.1f s: %@", attempt + 1, method, host, wait, String(why.prefix(120))))
        RequestTrace.current?.event(.action, "retry", ["host": host, "attempt": attempt + 1, "wait_ms": (wait * 1000).rounded(), "why": String(why.prefix(80))])
    }
}
