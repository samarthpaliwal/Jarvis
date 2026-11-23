import Foundation

/// What the remote API tells a caller about Jarvis.
public struct RemoteStatus: Equatable, Sendable {
    public var busy: Bool
    public var keysUnlocked: Bool
    public var voiceIDEnrolled: Bool
    public var mode: String
    public init(busy: Bool, keysUnlocked: Bool, voiceIDEnrolled: Bool, mode: String) {
        self.busy = busy; self.keysUnlocked = keysUnlocked; self.voiceIDEnrolled = voiceIDEnrolled; self.mode = mode
    }
}

/// The pipeline as the remote API sees it: the same five stages, minus the microphone and the speakers.
/// The app implements it with the real stages; tests use a fake.
public protocol RemoteBackend: Sendable {
    func status() async -> RemoteStatus
    /// Stage 2. 16 kHz mono samples to text; "" when nothing was said.
    func transcribe(_ samples: [Float]) async throws -> String
    /// Whose voice it is. Nil when Voice ID is not available at all.
    func verifyVoice(_ samples: [Float]) async -> VoiceCheck?
    /// Stages 3 and 4.
    func ask(_ text: String, voice: VoiceCheck?) async -> RemoteTurnResult
    func decide(_ id: UUID, approved: Bool) async -> RemoteTurnResult?
    /// Stage 5, to data instead of the speakers.
    func render(_ text: String) async throws -> (data: Data, mime: String)
}

/// The remote API: three routes, a token on every one.
///
///     GET  /                              the phone app (static files; the only thing served without a token)
///     POST /v1/pair     {"code": "…"}     trade the six-digit code on the Mac's screen for a token
///     GET  /v1/status                     is Jarvis there, busy, unlocked
///     POST /v1/ask      audio | JSON      a request: a recording, or {"text": "…"}
///     POST /v1/approve  audio | JSON      the answer to an approval: a spoken yes/no, or {"id": "…", "decision": "yes"}
///
/// Every request that reaches the pipeline needs `Authorization: Bearer <token>`. Without a valid one the
/// answer is 401 for every other path, whether or not it exists.
public final class RemoteAPI: @unchecked Sendable {
    private let tokens: RemoteTokenStore
    private let throttle: AuthThrottle
    private let backend: RemoteBackend
    private let maxAudioSeconds: @Sendable () -> Double
    public let pairing: PairingCodes
    /// Called when a device has just paired, with its name.
    public var onPaired: (@Sendable (String) -> Void)?
    public static let maxTextLength = 2000

    public init(tokens: RemoteTokenStore, throttle: AuthThrottle = AuthThrottle(), backend: RemoteBackend,
                pairing: PairingCodes = PairingCodes(), maxAudioSeconds: @escaping @Sendable () -> Double = { 60 }) {
        self.tokens = tokens; self.throttle = throttle; self.backend = backend; self.pairing = pairing; self.maxAudioSeconds = maxAudioSeconds
    }

    /// The two things reachable without a token: the phone app's own static files, and redeeming a pairing
    /// code while the Mac is showing one.
    private static let unauthorized = HTTPResponse.error(401, "unauthorized", "A valid access token is required.", headers: ["WWW-Authenticate": "Bearer"])
    private func isShell(_ r: HTTPRequest) -> Bool { r.method == "GET" && WebApp.isShellPath(r.path) }
    private func isPairing(_ r: HTTPRequest) -> Bool { r.method == "POST" && r.path == "/v1/pair" }

    // MARK: Authentication (runs on the headers, before any body is read)

    public func precheck(_ head: HTTPRequest, from ip: String) -> HTTPResponse? {
        if isShell(head) { return nil }
        if let wait = throttle.retryAfter(ip) {
            return .error(429, "too_many_attempts", "Too many wrong tokens from this device. Try again later.", headers: ["Retry-After": String(wait)])
        }
        if isPairing(head) {
            // Outside the two minutes a code is on the Mac's screen, this route does not exist.
            guard pairing.isActive() else { return Self.unauthorized }
            guard (Int(head.headers["content-length"] ?? "") ?? 0) <= 1024 else { return .error(413, "too_large", "That is not a pairing code.") }
            return nil
        }
        guard let presented = head.bearerToken, tokens.verify(presented) != nil else {
            if throttle.recordFailure(ip) {
                JarvisLog.warn("Remote: \(ip) sent \(throttle.maxFailures) wrong tokens; refusing it for \(Int(throttle.lockout)) s")
            } else {
                JarvisLog.warn("Remote: refused \(head.method) \(head.path.prefix(40)) from \(ip): \(head.bearerToken == nil ? "no token" : "wrong token")")
            }
            return .error(401, "unauthorized", "A valid access token is required.", headers: ["WWW-Authenticate": "Bearer"])
        }
        throttle.recordSuccess(ip)
        return nil
    }

    // MARK: Routes

    public func handle(_ request: HTTPRequest, from ip: String) async -> HTTPResponse {
        if isShell(request) { return WebApp.response(for: request.path) ?? .error(404, "not_found", "The app's files are missing from this build.") }
        if isPairing(request) { return pair(request, from: ip) }
        // Never rely on the precheck having run: no token, no answer.
        guard let presented = request.bearerToken, let device = tokens.verify(presented) else {
            return .error(401, "unauthorized", "A valid access token is required.", headers: ["WWW-Authenticate": "Bearer"])
        }
        let started = Date()
        let response: HTTPResponse
        switch (request.method, request.path) {
        case ("GET", "/v1/status"): response = await status(device: device)
        case ("POST", "/v1/ask"): response = await ask(request)
        case ("POST", "/v1/approve"): response = await approve(request)
        case (_, "/v1/status"), (_, "/v1/ask"), (_, "/v1/approve"): response = .error(405, "method_not_allowed", "That path does not take \(request.method).")
        default: response = .error(404, "not_found", "There is nothing at that path.")
        }
        JarvisLog.info("Remote: \(request.method) \(request.path.prefix(40)) from \(ip) (\(device.name)) → \(response.status) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        return response
    }

    private func pair(_ request: HTTPRequest, from ip: String) -> HTTPResponse {
        if throttle.retryAfter(ip) != nil { return .error(429, "too_many_attempts", "Too many attempts from this device. Try again later.") }
        let code = ((try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any])?["code"] as? String ?? ""
        guard request.body.count <= 1024, let name = pairing.redeem(code) else {
            throttle.recordFailure(ip)
            JarvisLog.warn("Remote: wrong or expired pairing code from \(ip)")
            return Self.unauthorized
        }
        // The name was free when the code was shown; if something took it since, number this one.
        var token: String?
        for candidate in [name] + (2...9).map({ "\(name) \($0)" }) {
            if let t = try? tokens.create(name: candidate) { token = t; JarvisLog.info("Remote: paired “\(candidate)” from \(ip)"); onPaired?(candidate); break }
        }
        guard let token else { return .error(500, "pairing_failed", "Pairing failed. Try again from the Mac.") }
        throttle.recordSuccess(ip)
        return .json(200, ["token": token, "device": name])
    }

    private func status(device: RemoteToken) async -> HTTPResponse {
        let s = await backend.status()
        return .json(200, ["ok": true, "name": "Jarvis", "device": device.name, "busy": s.busy, "keys_unlocked": s.keysUnlocked,
                           "voice_id": s.voiceIDEnrolled, "mode": s.mode])
    }

    private func wantsAudio(_ request: HTTPRequest, json: [String: Any]? = nil) -> Bool {
        if let v = json?["audio"] as? Bool { return v }
        return !["0", "false", "no"].contains((request.query["audio"] ?? "1").lowercased())
    }

    private enum Decoded { case success([Float]), failure(HTTPResponse) }

    private func decodeAudio(_ request: HTTPRequest) -> Decoded {
        do { return .success(try AudioCodec.decode(request.body, maxSeconds: maxAudioSeconds())) }
        catch let e as AudioCodec.CodecError {
            switch e {
            case .empty: return .failure(.error(400, "no_audio", e.localizedDescription))
            case .unsupported: return .failure(.error(415, "unsupported_audio", e.localizedDescription))
            case .tooLong: return .failure(.error(413, "audio_too_long", e.localizedDescription))
            case .unreadable: return .failure(.error(400, "bad_audio", e.localizedDescription))
            }
        } catch { return .failure(.error(400, "bad_audio", error.localizedDescription)) }
    }

    private func ask(_ request: HTTPRequest) async -> HTTPResponse {
        var text: String
        var voice: VoiceCheck?
        var speak = wantsAudio(request)
        var heard = false
        if request.contentType == "application/json" {
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any], let t = json["text"] as? String else {
                return .error(400, "bad_request", "Send {\"text\": \"…\"} or a recording.")
            }
            text = t
            speak = wantsAudio(request, json: json)
        } else {
            let samples: [Float]
            switch decodeAudio(request) {
            case .success(let s): samples = s
            case .failure(let r): return r
            }
            // Recognizing the words and recognizing the voice do not depend on each other.
            async let check = backend.verifyVoice(samples)
            do { text = try await backend.transcribe(samples) }
            catch { _ = await check; return .error(503, "stt_failed", SpokenFailure.message(for: error)) }
            voice = await check
            heard = true
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return heard ? .error(422, "no_speech", "I didn't catch anything.") : .error(400, "bad_request", "The text is empty.")
        }
        guard text.count <= Self.maxTextLength else { return .error(413, "text_too_long", "That request is too long.") }
        let result = await backend.ask(text, voice: voice)
        return await reply(result, transcript: text, voice: voice, speak: speak)
    }

    private func approve(_ request: HTTPRequest) async -> HTTPResponse {
        let idText: String?
        let approved: Bool
        var speak = wantsAudio(request)
        var transcript: String?
        if request.contentType == "application/json" {
            guard let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
                return .error(400, "bad_request", "Send {\"id\": \"…\", \"decision\": \"yes\"} or a recording of yes or no.")
            }
            idText = json["id"] as? String
            switch (json["decision"] as? String)?.lowercased() {
            case "yes", "approve": approved = true
            case "no", "deny": approved = false
            default: return .error(400, "bad_request", "\"decision\" must be \"yes\" or \"no\".")
            }
            speak = wantsAudio(request, json: json)
        } else {
            idText = request.query["id"]
            let samples: [Float]
            switch decodeAudio(request) {
            case .success(let s): samples = s
            case .failure(let r): return r
            }
            let said: String
            do { said = try await backend.transcribe(samples) }
            catch { return .error(503, "stt_failed", SpokenFailure.message(for: error)) }
            guard let answer = ConversationController.approvalAnswer(said) else {
                // Not an answer. The approval stays open until it is answered or times out.
                return .error(422, "unclear", said.isEmpty ? "I didn't catch that. Say yes or no." : "Say yes or no.")
            }
            approved = answer
            transcript = said
        }
        guard let idText, let id = UUID(uuidString: idText) else { return .error(400, "bad_request", "Which approval? Send its id.") }
        guard let result = await backend.decide(id, approved: approved) else {
            return .error(410, "approval_gone", "That approval is no longer waiting. It was answered, or it timed out.")
        }
        return await reply(result, transcript: transcript, voice: nil, speak: speak)
    }

    private func reply(_ result: RemoteTurnResult, transcript: String?, voice: VoiceCheck?, speak: Bool) async -> HTTPResponse {
        if result.status == .busy {
            return .error(409, "busy", "Jarvis is in the middle of something. Try again in a moment.", headers: ["Retry-After": "5"])
        }
        var body: [String: Any] = ["status": result.status.rawValue, "request_id": result.requestID, "text": result.text, "tools": result.tools]
        if result.failed { body["failed"] = true }
        if let transcript { body["transcript"] = transcript }
        if let voice, voice.isEnforced {
            var v: [String: Any] = ["outcome": voice.outcome.rawValue]
            if let s = voice.score { v["score"] = (s * 100).rounded() / 100 }
            body["voice"] = v
        }
        if let id = result.approvalID {
            body["approval"] = ["id": id.uuidString, "prompt": result.approvalPrompt ?? "", "expires_in": result.approvalExpiresIn ?? 0]
        }
        if speak, !result.text.isEmpty {
            do {
                let audio = try await backend.render(result.text)
                body["audio"] = ["mime": audio.mime, "base64": audio.data.base64EncodedString()]
            } catch {
                // The words still go back; only the voice is missing.
                body["audio_error"] = String(error.localizedDescription.prefix(200))
                JarvisLog.warn("Remote: could not render speech: \(error.localizedDescription)")
            }
        }
        return .json(200, body)
    }
}
