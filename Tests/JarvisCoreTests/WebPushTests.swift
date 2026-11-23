import CryptoKit
import XCTest
@testable import JarvisCore

final class WebPushTests: XCTestCase {
    /// The worked example in RFC 8291, section 5: same keys and salt in, the same bytes out.
    func testEncryptionMatchesTheStandardsExample() throws {
        let ephemeral = try P256.KeyAgreement.PrivateKey(rawRepresentation: XCTUnwrap(Base64URL.decode("yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw")))
        let body = try WebPush.encrypt(Data("When I grow up, I want to be a watermelon".utf8),
                                       p256dh: XCTUnwrap(Base64URL.decode("BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4")),
                                       auth: XCTUnwrap(Base64URL.decode("BTBZMqHH6r4Tts7J_aSIgg")),
                                       ephemeral: ephemeral, salt: XCTUnwrap(Base64URL.decode("DGv6ra1nlYgDCS1FRnbzlw")))
        XCTAssertEqual(Base64URL.encode(body),
                       "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN")
    }

    func testThePassIsSignedForThatPushServiceOnly() throws {
        let key = P256.Signing.PrivateKey()
        let header = try WebPush.authorization(for: URL(string: "https://web.push.apple.com/QAbc123")!, key: key, contact: PushStore.contact, now: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(header.hasPrefix("vapid t="))
        let token = String(header.dropFirst("vapid t=".count).prefix { $0 != "," })
        let parts = token.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 3)
        let claims = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(Base64URL.decode(parts[1]))) as? [String: Any])
        XCTAssertEqual(claims["aud"] as? String, "https://web.push.apple.com")
        XCTAssertEqual(claims["exp"] as? Int, 1_000 + 12 * 3600)
        XCTAssertEqual(claims["sub"] as? String, "mailto:noreply@example.com", "nothing personal in the contact")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: XCTUnwrap(Base64URL.decode(parts[2])))
        XCTAssertTrue(key.publicKey.isValidSignature(signature, for: Data((parts[0] + "." + parts[1]).utf8)))
        XCTAssertTrue(header.hasSuffix("k=" + Base64URL.encode(key.publicKey.x963Representation)))
    }

    static func subscription(_ endpoint: String = "https://web.push.apple.com/QGx", device: String = "phone") -> PushSubscription {
        PushSubscription(device: device, endpoint: endpoint, p256dh: Base64URL.encode(P256.KeyAgreement.PrivateKey().publicKey.x963Representation),
                         auth: Base64URL.encode(Data(repeating: 7, count: 16)))
    }

    func testOnlyRealPushServicesAreAccepted() {
        XCTAssertTrue(Self.subscription().isValid)
        XCTAssertTrue(Self.subscription("https://fcm.googleapis.com/fcm/send/abc").isValid)
        for bad in ["http://web.push.apple.com/x", "https://evil.example/x", "https://push.apple.com.evil.example/x", "https://127.0.0.1/x", "https://localhost:8787/v1/ask",
                    "https://user@web.push.apple.com/x", "https://web.push.apple.com:8443/x", "file:///etc/passwd", ""] {
            XCTAssertFalse(Self.subscription(bad).isValid, bad)
        }
        var short = Self.subscription(); short.auth = Base64URL.encode(Data(repeating: 1, count: 4))
        XCTAssertFalse(short.isValid)
    }

    func testTheStoreSendsSealedNotesAndForgetsAPhoneThatUnsubscribed() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString)/remote/push.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        final class Sent: @unchecked Sendable { var requests: [URLRequest] = []; var status = 201; let lock = NSLock() }
        let sent = Sent()
        let store = PushStore(url: url, transport: { req in sent.lock.withLock { sent.requests.append(req) }; return sent.status })
        let key = store.publicKey
        XCTAssertEqual(Base64URL.decode(key)?.count, 65)
        XCTAssertFalse(store.subscribe(Self.subscription("https://evil.example/x")))
        XCTAssertTrue(store.subscribe(Self.subscription()))
        XCTAssertTrue(store.subscribe(Self.subscription("https://web.push.apple.com/newer")), "the same phone again replaces the old entry")
        XCTAssertEqual(store.devices, ["phone"])

        let delivered = await store.notify(title: "Jarvis", body: "You've left.", tag: "check-in")
        XCTAssertEqual(delivered, 1)
        let req = try XCTUnwrap(sent.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://web.push.apple.com/newer")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Encoding"), "aes128gcm")
        XCTAssertFalse(String(decoding: req.httpBody ?? Data(), as: UTF8.self).contains("You've left"), "the push service cannot read the note")

        XCTAssertEqual(PushStore(url: url).publicKey, key, "the signing key survives a restart")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int), 0o600)
        sent.status = 410
        _ = await store.notify(title: "Jarvis", body: "x", tag: "t")
        XCTAssertTrue(store.devices.isEmpty)
    }
}

final class CheckInBoxTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 4_000_000)

    func testOneQuestionAtATimeAndItExpires() {
        var box = CheckInBox()
        let q = box.ask(.left, at: t0)
        XCTAssertNotNil(q)
        XCTAssertEqual(box.current(at: t0.addingTimeInterval(60))?.id, q?.id)
        XCTAssertNil(box.current(at: t0.addingTimeInterval(31 * 60)))
        XCTAssertFalse(box.answer(UUID(), at: t0), "an answer to some other question does not count")
        XCTAssertTrue(box.answer(q!.id, at: t0.addingTimeInterval(120)))
        XCTAssertFalse(box.answer(q!.id, at: t0.addingTimeInterval(121)), "answered once")
    }

    func testAPhoneFlickeringInAndOutDoesNotSendAStream() {
        var box = CheckInBox()
        XCTAssertNotNil(box.ask(.left, at: t0))
        XCTAssertNil(box.ask(.left, at: t0.addingTimeInterval(120)))
        XCTAssertNil(box.ask(.back, at: t0.addingTimeInterval(180)), "back within ten minutes: no second notification")
        XCTAssertNil(box.current(at: t0.addingTimeInterval(181)), "and the question about leaving is withdrawn")
        XCTAssertNotNil(box.ask(.left, at: t0.addingTimeInterval(11 * 60)))
    }
}

@MainActor
final class PresenceCheckInTests: XCTestCase {
    func testTheAnswerChangesTheModeAndQuietnessAndNothingElse() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("push-\(UUID().uuidString)/remote/push.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
        let config = ConfigStore(directory: ConfigTests.repoConfigDir, env: [:])
        let notch = NotchViewModel()
        let modes = ModeManager(config: config, notch: notch)
        // Both answers are saved settings; put them back so no other test starts in another mode.
        let savedDND = UserDefaults.standard.object(forKey: "jarvis.doNotDisturb"), savedMode = UserDefaults.standard.object(forKey: "jarvis.currentMode")
        defer {
            UserDefaults.standard.set(savedDND, forKey: "jarvis.doNotDisturb")
            UserDefaults.standard.set(savedMode, forKey: "jarvis.currentMode")
        }
        let checkIns = PresenceCheckIns(push: PushStore(url: url, transport: { _ in 201 }), modes: modes, notch: notch)

        XCTAssertNil(checkIns.current())
        checkIns.phoneChanged(to: .near, from: .unknown)
        XCTAssertNil(checkIns.current(), "the first reading after launch is not a change")
        checkIns.phoneChanged(to: .away, from: .near)
        let q = try XCTUnwrap(checkIns.current())
        XCTAssertTrue(q.text.hasPrefix("You've left"))
        XCTAssertTrue(q.modes.count >= 2)
        let other = try XCTUnwrap(q.modes.first { $0[0] != modes.current.id })
        let id = try XCTUnwrap(UUID(uuidString: q.id))

        XCTAssertNil(checkIns.answer(id: id, mode: "no-such-mode", people: true), "an unknown mode is refused and the question stays open")
        XCTAssertNotNil(checkIns.current())
        let said = try XCTUnwrap(checkIns.answer(id: id, mode: other[0], people: true))
        XCTAssertEqual(modes.current.id, other[0])
        XCTAssertTrue(notch.doNotDisturb)
        XCTAssertTrue(said.contains("stay quiet"), said)
        XCTAssertNil(checkIns.answer(id: id, mode: nil, people: false), "one answer per question")
    }
}
