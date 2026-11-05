import AppKit
import CryptoKit
import Foundation
import Network

/// Google OAuth 2.0 for an installed app: PKCE + loopback redirect. Tokens live in the Keychain.
/// Needs a "Desktop app" OAuth client from Google Cloud Console (client id + client secret;
/// Google treats the desktop secret as non-confidential, but we still keep it in the Keychain).
public final class GoogleAuth: @unchecked Sendable {
    public static let clientIDAccount = "GOOGLE_CLIENT_ID"
    public static let clientSecretAccount = "GOOGLE_CLIENT_SECRET"
    public static let refreshTokenAccount = "GOOGLE_REFRESH_TOKEN"
    public static let scopes = ["https://www.googleapis.com/auth/gmail.readonly", "https://www.googleapis.com/auth/gmail.compose"]

    public enum AuthError: LocalizedError {
        case notConfigured, notConnected, server(String), cancelled
        public var errorDescription: String? {
            switch self {
            case .notConfigured: return "Gmail isn't set up. Use Connect Gmail… in the Jarvis menu."
            case .notConnected: return "Gmail isn't connected yet. Use Connect Gmail… in the Jarvis menu."
            case .server(let m): return "Google sign-in failed: \(m)"
            case .cancelled: return "Google sign-in was cancelled."
            }
        }
    }

    private var accessToken: String?
    private var expiresAt = Date.distantPast
    private let lock = NSLock()

    public init() {}

    public var isConfigured: Bool { KeychainStore.read(account: Self.clientIDAccount) != nil }
    public var isConnected: Bool { isConfigured && KeychainStore.read(account: Self.refreshTokenAccount) != nil }

    /// Valid access token, refreshing when needed.
    public func token() async throws -> String {
        if let t = lock.withLock({ expiresAt > Date().addingTimeInterval(60) ? accessToken : nil }) { return t }
        guard let clientID = KeychainStore.read(account: Self.clientIDAccount) else { throw AuthError.notConfigured }
        guard let refresh = KeychainStore.read(account: Self.refreshTokenAccount) else { throw AuthError.notConnected }
        let secret = KeychainStore.read(account: Self.clientSecretAccount) ?? ""
        let obj = try await Self.tokenRequest(["client_id": clientID, "client_secret": secret, "refresh_token": refresh, "grant_type": "refresh_token"])
        guard let t = obj["access_token"] as? String else { throw AuthError.server(obj["error_description"] as? String ?? "no access token") }
        store(token: t, expiresIn: obj["expires_in"] as? Int)
        return t
    }

    /// Full consent flow: opens the browser, waits for the loopback redirect, stores the refresh token.
    public func connect() async throws {
        guard let clientID = KeychainStore.read(account: Self.clientIDAccount) else { throw AuthError.notConfigured }
        let secret = KeychainStore.read(account: Self.clientSecretAccount) ?? ""
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL()
        let state = Self.randomString(16)
        let listener = try LoopbackListener()
        let redirect = "http://127.0.0.1:\(listener.port)/callback"
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientID), .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"), .init(name: "scope", value: Self.scopes.joined(separator: " ")),
            .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state), .init(name: "access_type", value: "offline"), .init(name: "prompt", value: "consent"),
        ]
        let authURL = comps.url!
        _ = await MainActor.run { NSWorkspace.shared.open(authURL) }
        let params = try await listener.waitForCallback(timeout: 300)
        guard params["state"] == state, let code = params["code"] else { throw AuthError.server(params["error"] ?? "bad callback") }
        let obj = try await Self.tokenRequest(["client_id": clientID, "client_secret": secret, "code": code, "code_verifier": verifier,
                                               "grant_type": "authorization_code", "redirect_uri": redirect])
        guard let refresh = obj["refresh_token"] as? String else { throw AuthError.server(obj["error_description"] as? String ?? "no refresh token") }
        try KeychainStore.write(refresh, account: Self.refreshTokenAccount)
        store(token: obj["access_token"] as? String, expiresIn: obj["expires_in"] as? Int)
        JarvisLog.info("Gmail connected")
    }

    public func disconnect() {
        KeychainStore.delete(account: Self.refreshTokenAccount)
        lock.withLock { accessToken = nil }
    }

    private func store(token: String?, expiresIn: Int?) {
        lock.withLock {
            accessToken = token
            expiresAt = Date().addingTimeInterval(TimeInterval(expiresIn ?? 3000))
        }
    }

    static func tokenRequest(_ form: [String: String]) async throws -> JSONObject {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? JSONObject) ?? [:]
    }

    static func randomString(_ n: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<n).map { _ in chars.randomElement()! })
    }
}

extension Data {
    func base64URL() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL s: String) {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b.count % 4 != 0 { b += "=" }
        self.init(base64Encoded: b)
    }
}

/// One-shot HTTP listener on 127.0.0.1 for the OAuth redirect.
final class LoopbackListener: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let lock = NSLock()

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
        listener.start(queue: .global())
        // Wait briefly for the port assignment.
        var tries = 0
        while listener.port == nil && tries < 50 { usleep(10_000); tries += 1 }
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock(); continuation = cont; lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.finish(.failure(GoogleAuth.AuthError.cancelled))
            }
        }
    }

    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        listener.cancel()
        switch result {
        case .success(let p): c?.resume(returning: p)
        case .failure(let e): c?.resume(throwing: e)
        }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .global())
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let line = text.split(separator: "\r\n").first.map(String.init) ?? ""
            let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            var params: [String: String] = [:]
            if let comps = URLComponents(string: "http://localhost\(path)") {
                for q in comps.queryItems ?? [] { params[q.name] = q.value ?? "" }
            }
            let ok = params["code"] != nil
            let body = "<html><body style='font-family:-apple-system;text-align:center;padding:60px'><h2>\(ok ? "Jarvis is connected to Gmail." : "Sign-in failed.")</h2><p>You can close this tab.</p></body></html>"
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in
                conn.cancel()
                if path.hasPrefix("/callback") { self?.finish(.success(params)) }
            })
        }
    }
}
