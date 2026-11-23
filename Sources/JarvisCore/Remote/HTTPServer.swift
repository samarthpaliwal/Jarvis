import Foundation
import Network

/// A very small HTTP/1.1 server: one request per connection, bound to exactly one local address.
///
/// It exists so the remote API can live inside Jarvis without a web framework. It is not a general server:
/// no keep-alive, no chunked bodies, no TLS (the tailnet tunnel is already encrypted end to end).
public final class HTTPServer: @unchecked Sendable {
    public struct Config: Equatable, Sendable {
        /// The one local address to listen on. Never a wildcard.
        public var host: String
        /// 0 picks any free port (tests).
        public var port: UInt16
        public var maxBodyBytes = 8 * 1024 * 1024
        /// A client gets this long to deliver its whole request.
        public var requestTimeout: TimeInterval = 30
        public var maxConnections = 16
        public init(host: String, port: UInt16) { self.host = host; self.port = port }
    }

    public enum ServerError: LocalizedError {
        case wildcard(String)
        case failed(String)
        public var errorDescription: String? {
            switch self {
            case .wildcard(let h): return "Refusing to listen on \(h): the remote API binds to one private address only."
            case .failed(let why): return "The remote API could not start: \(why)"
            }
        }
    }

    /// Whether a connection from this address is accepted at all. Checked before a single byte is read.
    public typealias PeerFilter = @Sendable (_ remoteIP: String) -> Bool
    /// Looks at the headers only. Returning a response refuses the request without reading its body.
    public typealias Precheck = @Sendable (_ head: HTTPRequest, _ remoteIP: String) -> HTTPResponse?
    public typealias Handler = @Sendable (_ request: HTTPRequest, _ remoteIP: String) async -> HTTPResponse

    public let config: Config
    private let peerFilter: PeerFilter
    private let precheck: Precheck
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.samarth.jarvis.remote")
    private var listener: NWListener?
    private var open: [ObjectIdentifier: NWConnection] = [:]
    private let stateLock = NSLock()
    private var boundPort: UInt16?

    public init(config: Config, peerFilter: @escaping PeerFilter, precheck: @escaping Precheck, handler: @escaping Handler) {
        self.config = config; self.peerFilter = peerFilter; self.precheck = precheck; self.handler = handler
    }

    /// The port actually bound, once listening.
    public var port: UInt16? { stateLock.lock(); defer { stateLock.unlock() }; return boundPort }

    /// An address that would accept connections from anywhere.
    public static func isWildcard(_ host: String) -> Bool {
        let h = host.trimmingCharacters(in: .whitespaces).lowercased()
        return h.isEmpty || h == "0.0.0.0" || h == "::" || h == "*" || h == "[::]"
    }

    /// Starts listening. Returns once the socket is bound, or throws.
    public func start() async throws {
        guard !Self.isWildcard(config.host), IPv4Address(config.host) != nil else { throw ServerError.wildcard(config.host) }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(config.host), port: NWEndpoint.Port(rawValue: config.port) ?? .any)
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch { throw ServerError.failed(error.localizedDescription) }
        listener.newConnectionHandler = { [weak self] c in self?.accept(c) }
        let done = Once()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.stateLock.lock(); self?.boundPort = listener.port?.rawValue; self?.stateLock.unlock()
                    if done.first() { cont.resume() }
                case .failed(let e):
                    listener.cancel()
                    self?.stateLock.lock(); self?.boundPort = nil; self?.stateLock.unlock()
                    if done.first() { cont.resume(throwing: ServerError.failed(e.localizedDescription)) }
                case .waiting(let e):
                    // The address is not there (Tailscale just went off). Do not sit waiting on it.
                    listener.cancel()
                    if done.first() { cont.resume(throwing: ServerError.failed(e.localizedDescription)) }
                case .cancelled:
                    if done.first() { cont.resume(throwing: ServerError.failed("cancelled")) }
                default: break
                }
            }
            queue.async { self.listener = listener }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            for c in open.values { c.cancel() }
            open.removeAll()
            stateLock.lock(); boundPort = nil; stateLock.unlock()
        }
    }

    static func ip(of endpoint: NWEndpoint) -> String? {
        guard case .hostPort(let host, _) = endpoint else { return nil }
        switch host {
        case .ipv4(let a): return "\(a)".components(separatedBy: "%")[0]
        case .ipv6(let a): return "\(a)".components(separatedBy: "%")[0]
        case .name(let n, _): return n
        @unknown default: return nil
        }
    }

    private func accept(_ connection: NWConnection) {
        guard let remote = Self.ip(of: connection.endpoint), peerFilter(remote), open.count < config.maxConnections else {
            connection.cancel()
            return
        }
        let id = ObjectIdentifier(connection)
        open[id] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.open[id] = nil
            default: break
            }
        }
        connection.start(queue: queue)
        let session = Session(parser: HTTPRequestParser(maxBodyBytes: config.maxBodyBytes))
        queue.asyncAfter(deadline: .now() + config.requestTimeout) { [weak self] in
            guard !session.received else { return }
            self?.send(HTTPResponse.error(408, "timeout", "The request took too long to arrive."), on: connection)
        }
        read(connection, session, remote)
    }

    private final class Session {
        var parser: HTTPRequestParser
        var prechecked = false
        var received = false
        init(parser: HTTPRequestParser) { self.parser = parser }
    }

    private func read(_ connection: NWConnection, _ session: Session, _ remote: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !session.received else { return }
            if let data, !data.isEmpty {
                let progress = session.parser.feed(data)
                if !session.prechecked, let head = session.parser.head {
                    session.prechecked = true
                    if let refusal = self.precheck(head, remote) {
                        session.received = true
                        self.send(refusal, on: connection)
                        return
                    }
                    if head.headers["expect"]?.lowercased() == "100-continue", progress == .needMore {
                        connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    }
                }
                switch progress {
                case .complete(let request):
                    session.received = true
                    let handler = self.handler
                    Task {
                        let response = await handler(request, remote)
                        self.queue.async { self.send(response, on: connection) }
                    }
                    return
                case .failed(let response):
                    session.received = true
                    self.send(response, on: connection)
                    return
                case .needMore:
                    break
                }
            }
            if isComplete || error != nil { connection.cancel(); return }
            self.read(connection, session, remote)
        }
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }
}

/// True exactly once.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var used = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if used { return false }; used = true; return true }
}
