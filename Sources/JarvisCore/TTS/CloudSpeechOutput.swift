import AVFoundation
import Foundation

/// Neural text-to-speech from ElevenLabs or OpenAI, played sentence by sentence.
/// The next sentence is fetched while the current one plays, so speech flows without gaps.
public final class CloudSpeechOutput: NSObject, SpeechOutput, AVAudioPlayerDelegate, @unchecked Sendable {
    public enum Provider: String, Sendable { case elevenlabs, openai, kokoro }
    /// Where the local Kokoro server listens (set by the app).
    public static var kokoroBaseURL = URL(string: "http://127.0.0.1:\(Tuning().kokoroPort)")!
    public static var openAIModel = Tuning().openaiTtsModel
    public static var requestTimeout: TimeInterval = Tuning().ttsRequestTimeoutSeconds
    /// Spend guard for the paid voices (ElevenLabs, OpenAI). Kokoro is local and free. When the cap is
    /// reached the request throws, and the router speaks the sentence with the Apple voice instead.
    public nonisolated(unsafe) static var budget: Budget?
    private static let localSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]
        return URLSession(configuration: c)
    }()
    public static let elevenLabsKeyAccount = "ELEVENLABS_API_KEY"
    public static let openAIKeyAccount = "OPENAI_API_KEY"

    public let provider: Provider
    public var voiceSettings: Profile.Voice
    public var name: String {
        switch provider {
        case .elevenlabs: return "ElevenLabs (\(voiceSettings.elevenLabsModel))"
        case .openai: return "OpenAI \(Self.openAIModel) (\(voiceSettings.openAIVoice))"
        case .kokoro: return "Kokoro on-device (\(voiceSettings.kokoroVoice))"
        }
    }
    /// True from the moment a sentence is queued until the last one has finished playing. A sentence
    /// that is still being synthesized counts: it has left the queue but is not audible yet.
    public var isSpeaking: Bool { player?.isPlaying == true || preparing || !queue.isEmpty }
    /// Called (main queue) when a request fails, so the router can fall back to the Apple voice.
    public var onFailure: ((String, Error) -> Void)?
    public var onAudioStart: ((String) -> Void)?

    /// Timings for one spoken chunk: how long synthesis took, how long the finished audio waited for the
    /// main thread or the previous chunk, and how long starting playback took. Main queue.
    public var onChunkTiming: ((_ words: Int, _ synthMs: Double, _ waitMs: Double, _ playMs: Double) -> Void)?

    private struct Item { let text: String; let volume: Float; let audio: Task<(data: Data, synthMs: Double, readyAt: Date), Error> }
    private var queue: [Item] = []
    private var player: AVAudioPlayer?
    private var completion: ((Bool) -> Void)?
    private var generation = 0
    /// A sentence has been taken off the queue and its audio is being fetched.
    private var preparing = false
    /// Replaces the network call in tests.
    var synthesizerOverride: ((String) async throws -> Data)?

    public init(provider: Provider, voice: Profile.Voice) {
        self.provider = provider
        self.voiceSettings = voice
    }

    public static func hasKey(_ p: Provider) -> Bool {
        switch p {
        case .elevenlabs: return KeychainStore.read(account: elevenLabsKeyAccount) != nil
        case .openai: return KeychainStore.read(account: openAIKeyAccount) != nil
        case .kokoro: return true
        }
    }

    // MARK: SpeechOutput

    public func speak(_ text: String, volume: Float, rate: Float, onFinished: @escaping (Bool) -> Void) {
        stop()
        completion = onFinished
        enqueue(text, volume: volume, rate: rate)
    }

    public func enqueue(_ text: String, volume: Float, rate: Float) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let fetch = Task { () -> (data: Data, synthMs: Double, readyAt: Date) in
            let started = Date()
            let data = try await (self.synthesizerOverride ?? { try await self.synthesize($0) })(t)
            return (data, Date().timeIntervalSince(started) * 1000, Date())
        }
        queue.append(Item(text: t, volume: volume, audio: fetch))
        // Start only if nothing is playing AND nothing is being prepared; otherwise two sentences
        // would be fetched and played on top of each other.
        if !preparing, player?.isPlaying != true { playNext() }
    }

    public func whenQueueDrained(_ onFinished: @escaping (Bool) -> Void) {
        if !isSpeaking { DispatchQueue.main.async { onFinished(true) } } else { completion = onFinished }
    }

    public func stop() {
        generation += 1
        preparing = false
        for item in queue { item.audio.cancel() }
        queue.removeAll()
        let wasPlaying = player?.isPlaying == true
        player?.stop()
        player = nil
        if let done = completion, wasPlaying || true {
            completion = nil
            DispatchQueue.main.async { done(false) }
        }
    }

    // MARK: Playback

    private func playNext() {
        guard !queue.isEmpty else {
            player = nil
            preparing = false
            if let done = completion { completion = nil; DispatchQueue.main.async { done(true) } }
            return
        }
        let item = queue.removeFirst()
        let gen = generation
        preparing = true
        Task { @MainActor in
            do {
                let audio = try await item.audio.value
                let data = audio.data
                guard gen == self.generation else { return }
                let playStarted = Date()
                let p = try AVAudioPlayer(data: data)
                p.delegate = self
                p.volume = max(0, min(1, item.volume))
                p.prepareToPlay()
                self.player = p
                self.preparing = false
                guard p.play() else { throw NSError(domain: "Jarvis.TTS", code: 2, userInfo: [NSLocalizedDescriptionKey: "audio player refused to start"]) }
                self.onAudioStart?(self.provider.rawValue)
                self.onChunkTiming?(item.text.split(separator: " ").count, audio.synthMs,
                                    playStarted.timeIntervalSince(audio.readyAt) * 1000, Date().timeIntervalSince(playStarted) * 1000)
            } catch is CancellationError {
                if gen == self.generation { self.preparing = false; self.playNext() }
            } catch {
                guard gen == self.generation else { return }
                self.preparing = false
                JarvisLog.warn("\(self.provider.rawValue) TTS failed: \(error.localizedDescription)")
                self.onFailure?(item.text, error)
                self.playNext()
            }
        }
    }

    public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, player === self.player else { return }
            self.playNext()
        }
    }

    // MARK: Requests

    public func requestBody() -> (URLRequest?, String) {
        switch provider {
        case .elevenlabs:
            guard let key = KeychainStore.read(account: Self.elevenLabsKeyAccount) else { return (nil, "no ElevenLabs key") }
            var r = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceSettings.elevenLabsVoiceId)?output_format=mp3_44100_128")!)
            r.httpMethod = "POST"
            r.setValue(key, forHTTPHeaderField: "xi-api-key")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
            return (r, "")
        case .openai:
            guard let key = KeychainStore.read(account: Self.openAIKeyAccount) else { return (nil, "no OpenAI key") }
            var r = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/speech")!)
            r.httpMethod = "POST"
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return (r, "")
        case .kokoro:
            var r = URLRequest(url: Self.kokoroBaseURL.appendingPathComponent("v1/audio/speech"))
            r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            return (r, "")
        }
    }

    public func payload(for text: String) -> JSONObject {
        switch provider {
        case .elevenlabs:
            return ["text": text, "model_id": voiceSettings.elevenLabsModel,
                    "voice_settings": ["stability": 0.45, "similarity_boost": 0.8, "style": 0.15, "use_speaker_boost": true, "speed": 1.0]]
        case .openai:
            return ["model": Self.openAIModel, "voice": voiceSettings.openAIVoice, "input": text,
                    "instructions": voiceSettings.openAIInstructions, "response_format": "mp3"]
        case .kokoro:
            return ["input": text, "voice": voiceSettings.kokoroVoice, "speed": voiceSettings.kokoroSpeed]
        }
    }

    /// The audio for `text` without playing it (the remote API sends it to the phone instead).
    public func render(_ text: String, timeout: TimeInterval = 45) async throws -> (data: Data, mime: String) {
        let data = try await synthesize(text, timeout: timeout)
        return (data, provider == .kokoro ? "audio/wav" : "audio/mpeg")
    }

    private func synthesize(_ text: String, timeout: TimeInterval? = nil) async throws -> Data {
        if let synthesizerOverride, timeout != nil { return try await synthesizerOverride(text) }
        let paid = provider != .kokoro
        if paid { try Self.budget?.check(provider.rawValue) }
        let (base, why) = requestBody()
        guard var req = base else { throw NSError(domain: "Jarvis.TTS", code: 1, userInfo: [NSLocalizedDescriptionKey: why]) }
        req.timeoutInterval = timeout ?? Self.requestTimeout
        req.httpBody = try JSONSerialization.data(withJSONObject: payload(for: text))
        let (data, resp) = try await (provider == .kokoro ? Self.localSession : URLSession.shared).data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, !data.isEmpty else {
            let msg = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw NSError(domain: "Jarvis.TTS", code: code, userInfo: [NSLocalizedDescriptionKey: "HTTP \(code) \(msg)"])
        }
        if paid, let b = Self.budget { b.record(provider.rawValue, usd: b.pricing.speechCost(provider: provider.rawValue, characters: text.count)) }
        return data
    }
}

/// Picks the voice engine per utterance: cloud when configured and online, the best Apple voice otherwise.
/// If a cloud request fails mid-reply, that sentence (and the rest of the reply) falls back to Apple.
public final class SpeechRouter: SpeechOutput, @unchecked Sendable {
    public let apple: AppleSpeechOutput
    private var cloud: CloudSpeechOutput?
    private var active: SpeechOutput
    private var lastVolume: Float = 1, lastRate: Float = 0.52
    public var isOnline: () -> Bool = { true }
    public var onAudioStart: ((String) -> Void)? {
        didSet { apple.onAudioStart = onAudioStart; cloud?.onAudioStart = onAudioStart }
    }
    public var onChunkTiming: ((Int, Double, Double, Double) -> Void)? {
        didSet { cloud?.onChunkTiming = onChunkTiming }
    }

    public init(apple: AppleSpeechOutput) {
        self.apple = apple
        self.active = apple
    }

    public var name: String { active.name }
    public var isSpeaking: Bool { active.isSpeaking }
    public var engineName: String { cloud?.name ?? apple.name }
    /// "kokoro", "elevenlabs", "openai", or "apple": where reply text is turned into speech.
    public var engineKind: String { cloud?.provider.rawValue ?? "apple" }

    /// Re-reads config + Keychain. Call after keys or settings change.
    /// Whether the local Kokoro server is up (set by the app).
    public var kokoroReady: () -> Bool = { false }

    public func configure(_ v: Profile.Voice?) {
        let voice = v ?? Profile.Voice()
        let provider: CloudSpeechOutput.Provider?
        let kokoro: CloudSpeechOutput.Provider? = kokoroReady() ? .kokoro : nil
        switch voice.engine {
        case "elevenlabs": provider = CloudSpeechOutput.hasKey(.elevenlabs) ? .elevenlabs : kokoro
        case "openai": provider = CloudSpeechOutput.hasKey(.openai) ? .openai : kokoro
        case "kokoro": provider = kokoro
        case "apple": provider = nil
        default: provider = CloudSpeechOutput.hasKey(.elevenlabs) ? .elevenlabs : CloudSpeechOutput.hasKey(.openai) ? .openai : kokoro
        }
        if let provider {
            let c = CloudSpeechOutput(provider: provider, voice: voice)
            c.onFailure = { [weak self] text, _ in
                guard let self else { return }
                // Finish this reply on the Apple voice.
                self.active = self.apple
                self.apple.enqueue(text, volume: self.lastVolume, rate: self.lastRate)
            }
            c.onAudioStart = onAudioStart
            c.onChunkTiming = onChunkTiming
            cloud = c
        } else {
            cloud = nil
        }
        JarvisLog.info("Voice engine: \(engineName)")
    }

    private func pick() -> SpeechOutput {
        if let cloud, cloud.provider == .kokoro || isOnline() { return cloud }   // Kokoro is local: works offline
        return apple
    }

    public func speak(_ text: String, volume: Float, rate: Float, onFinished: @escaping (Bool) -> Void) {
        stop()
        lastVolume = volume; lastRate = rate
        active = pick()
        active.speak(text, volume: volume, rate: rate, onFinished: onFinished)
    }

    public func enqueue(_ text: String, volume: Float, rate: Float) {
        lastVolume = volume; lastRate = rate
        if !active.isSpeaking { active = pick() }
        active.enqueue(text, volume: volume, rate: rate)
    }

    public func whenQueueDrained(_ onFinished: @escaping (Bool) -> Void) {
        // If the cloud failed over mid-reply, Apple may hold the tail; wait for whichever is speaking.
        if apple.isSpeaking && active !== apple { apple.whenQueueDrained(onFinished) } else { active.whenQueueDrained(onFinished) }
    }

    public func stop() {
        cloud?.stop()
        apple.stop()
    }

    /// The reply as audio data instead of sound from the Mac's speakers. Same engine choice as speaking:
    /// the configured voice, and the Apple voice when that fails or is offline.
    public func render(_ text: String, rate: Float) async throws -> (data: Data, mime: String) {
        if let cloud, cloud.provider == .kokoro || isOnline() {
            do { return try await cloud.render(text) }
            catch { JarvisLog.warn("Remote speech: \(cloud.provider.rawValue) failed (\(error.localizedDescription)); using the Apple voice") }
        }
        return try await apple.render(text, rate: rate)
    }
}
