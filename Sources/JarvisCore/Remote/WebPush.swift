import CryptoKit
import Foundation

enum Base64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func decode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}

/// Where a phone said notifications for it should be sent, and the keys to seal them with.
public struct PushSubscription: Codable, Equatable, Sendable {
    public var device: String
    public var endpoint: String
    public var p256dh: String
    public var auth: String

    /// Only the real push services, over https. The address comes from the phone, so it is checked: Jarvis
    /// must never be talked into posting to some other machine.
    static let allowedHostSuffixes = ["push.apple.com", "fcm.googleapis.com", "push.services.mozilla.com", "notify.windows.com"]
    public var endpointURL: URL? {
        guard endpoint.count <= 2048, let c = URLComponents(string: endpoint), c.scheme == "https", c.user == nil, c.port == nil || c.port == 443,
              let host = c.host?.lowercased(), Self.allowedHostSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) else { return nil }
        return c.url
    }
    public var isValid: Bool {
        endpointURL != nil && Base64URL.decode(p256dh)?.count == 65 && Base64URL.decode(auth)?.count == 16
    }
}

/// Web Push: a short note sealed so that only the phone can read it (RFC 8291), signed so the push service
/// knows it comes from this Jarvis (RFC 8292). The push service carries it but cannot open it.
public enum WebPush {
    public enum PushError: LocalizedError, Equatable {
        case badSubscription, tooLong, rejected(Int), gone
        public var errorDescription: String? {
            switch self {
            case .badSubscription: return "That phone's notification address is not one I can use."
            case .tooLong: return "That note is too long for a notification."
            case .rejected(let c): return "The push service refused the notification (\(c))."
            case .gone: return "That phone has turned notifications off."
            }
        }
    }

    /// Seals `message` for one subscription. `ephemeral` and `salt` are random in real use; tests pass the
    /// values from the standard's worked example.
    public static func encrypt(_ message: Data, p256dh: Data, auth: Data,
                               ephemeral: P256.KeyAgreement.PrivateKey = .init(), salt: Data = Data((0..<16).map { _ in UInt8.random(in: 0...255) })) throws -> Data {
        guard message.count <= 3000, salt.count == 16, auth.count == 16 else { throw PushError.tooLong }
        guard let phone = try? P256.KeyAgreement.PublicKey(x963Representation: p256dh) else { throw PushError.badSubscription }
        let ours = ephemeral.publicKey.x963Representation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: phone)
        let ikm = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: auth, sharedInfo: Data("WebPush: info\0".utf8) + p256dh + ours, outputByteCount: 32)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: aes128gcm\0".utf8), outputByteCount: 16)
        let nonce = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        let sealed = try AES.GCM.seal(message + [0x02], using: key, nonce: AES.GCM.Nonce(data: nonce.withUnsafeBytes { Data($0) }))
        var body = salt
        body.append(contentsOf: [0x00, 0x00, 0x10, 0x00])       // record size 4096
        body.append(UInt8(ours.count))
        body.append(ours)
        body.append(sealed.ciphertext)
        body.append(sealed.tag)
        return body
    }

    /// The signed pass the push service asks for: who is sending, to which service, valid for twelve hours.
    public static func authorization(for endpoint: URL, key: P256.Signing.PrivateKey, contact: String, now: Date = Date()) throws -> String {
        let audience = "\(endpoint.scheme ?? "https")://\(endpoint.host ?? "")"
        let header = Base64URL.encode(Data(#"{"typ":"JWT","alg":"ES256"}"#.utf8))
        let claims = try JSONSerialization.data(withJSONObject: ["aud": audience, "exp": Int(now.timeIntervalSince1970) + 12 * 3600, "sub": contact], options: [.sortedKeys, .withoutEscapingSlashes])
        let signing = header + "." + Base64URL.encode(claims)
        let signature = try key.signature(for: Data(signing.utf8)).rawRepresentation
        return "vapid t=\(signing).\(Base64URL.encode(signature)), k=\(Base64URL.encode(key.publicKey.x963Representation))"
    }

    public static func request(_ message: Data, to sub: PushSubscription, key: P256.Signing.PrivateKey, contact: String, ttl: Int = 600, now: Date = Date()) throws -> URLRequest {
        guard sub.isValid, let url = sub.endpointURL, let p = Base64URL.decode(sub.p256dh), let a = Base64URL.decode(sub.auth) else { throw PushError.badSubscription }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.httpBody = try encrypt(message, p256dh: p, auth: a)
        req.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("\(ttl)", forHTTPHeaderField: "TTL")
        req.setValue("high", forHTTPHeaderField: "Urgency")
        req.setValue(try authorization(for: url, key: key, contact: contact, now: now), forHTTPHeaderField: "Authorization")
        return req
    }
}

/// The phones that asked for notifications, and this Jarvis's signing key. Kept beside the access tokens,
/// in a folder no tool may read.
public final class PushStore: @unchecked Sendable {
    struct File: Codable { var signingKey: String; var subscriptions: [PushSubscription] }
    public typealias Transport = @Sendable (URLRequest) async throws -> Int
    /// Push services want a way to reach the sender. Nothing personal goes here.
    public static let contact = "mailto:noreply@example.com"

    private let url: URL
    private let transport: Transport
    private let lock = NSLock()
    private var file: File

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis/remote/push.json")
    }

    public init(url: URL = PushStore.defaultURL, transport: @escaping Transport = { req in
        let (_, response) = try await URLSession.shared.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }) {
        self.url = url; self.transport = transport
        if let data = try? Data(contentsOf: url), let f = try? JSONDecoder().decode(File.self, from: data), Base64URL.decode(f.signingKey) != nil {
            file = f
        } else {
            file = File(signingKey: Base64URL.encode(P256.Signing.PrivateKey().rawRepresentation), subscriptions: [])
        }
    }

    private var key: P256.Signing.PrivateKey {
        (try? P256.Signing.PrivateKey(rawRepresentation: Base64URL.decode(file.signingKey) ?? Data())) ?? P256.Signing.PrivateKey()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(file) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// What the phone needs to subscribe: the public half of the signing key.
    public var publicKey: String { lock.withLock { let k = Base64URL.encode(key.publicKey.x963Representation); save(); return k } }
    public var devices: [String] { lock.withLock { file.subscriptions.map(\.device) } }

    public func subscribe(_ sub: PushSubscription) -> Bool {
        guard sub.isValid else { return false }
        lock.withLock {
            file.subscriptions.removeAll { $0.device == sub.device || $0.endpoint == sub.endpoint }
            file.subscriptions.append(sub)
            save()
        }
        return true
    }

    public func remove(device: String) { lock.withLock { file.subscriptions.removeAll { $0.device == device }; save() } }

    /// Sends one note to every subscribed phone. Returns how many took it. A phone that has turned
    /// notifications off (404/410) is forgotten.
    @discardableResult
    public func notify(title: String, body: String, tag: String, onlyDevice: String? = nil) async -> Int {
        let (all, key) = lock.withLock { (file.subscriptions, self.key) }
        let subs = all.filter { onlyDevice == nil || $0.device == onlyDevice }
        guard let message = try? JSONSerialization.data(withJSONObject: ["title": title, "body": body, "tag": tag]) else { return 0 }
        var delivered = 0
        for sub in subs {
            do {
                let status = try await transport(try WebPush.request(message, to: sub, key: key, contact: Self.contact))
                if (200..<300).contains(status) { delivered += 1 }
                else if status == 404 || status == 410 { remove(device: sub.device); JarvisLog.info("Push: \(sub.device) is no longer subscribed") }
                else { JarvisLog.warn("Push: \(sub.device) refused with \(status)") }
            } catch { JarvisLog.warn("Push: could not reach the push service for \(sub.device): \(error.localizedDescription)") }
        }
        return delivered
    }
}

/// A question Jarvis put to the phone: which mode, and is anyone there.
public struct CheckIn: Equatable, Sendable {
    public enum Kind: String, Sendable { case left, back }
    public var id: UUID
    public var kind: Kind
    public var askedAt: Date
    public var text: String {
        kind == .left ? "You've left. Which mode should the Mac be in, and is anyone still there?" : "Welcome back. Which mode, and is anyone with you?"
    }
}

/// Holds the one open question. A new one replaces the old; it expires after half an hour.
public struct CheckInBox: Equatable, Sendable {
    public static let lifetime: TimeInterval = 30 * 60
    /// The phone flickering in and out of range must not send a stream of notifications.
    public static let minimumGap: TimeInterval = 10 * 60
    public private(set) var open: CheckIn?
    private var lastAsked: Date?
    public init() {}

    public mutating func ask(_ kind: CheckIn.Kind, at now: Date) -> CheckIn? {
        if let last = lastAsked, now.timeIntervalSince(last) < Self.minimumGap {
            if open?.kind != kind { open = nil }        // he came straight back: the question about leaving is moot
            return nil
        }
        let q = CheckIn(id: UUID(), kind: kind, askedAt: now)
        open = q; lastAsked = now
        return q
    }

    public func current(at now: Date) -> CheckIn? {
        guard let q = open, now.timeIntervalSince(q.askedAt) < Self.lifetime else { return nil }
        return q
    }

    /// True if `id` is the open question (so the answer counts), and closes it.
    public mutating func answer(_ id: UUID, at now: Date) -> Bool {
        guard let q = current(at: now), q.id == id else { return false }
        open = nil
        return true
    }
}
