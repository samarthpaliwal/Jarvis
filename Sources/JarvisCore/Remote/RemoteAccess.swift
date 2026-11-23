import Foundation
import Network

/// Runs the remote API: decides where it may listen, starts and stops the server, and follows Tailscale
/// coming and going.
///
/// Off until switched on in the menu. Even when on, it listens only if there is at least one access
/// token and this Mac has a Tailscale address, and then on that one address only.
@MainActor
public final class RemoteAccess {
    public enum State: Equatable, Sendable {
        case off
        case noTokens
        case waitingForTailscale
        case listening(host: String, port: UInt16)
        case failed(String)

        public var line: String {
            switch self {
            case .off: return "Off"
            case .noTokens: return "On, but no device has a token yet"
            case .waitingForTailscale: return "On, waiting for Tailscale"
            case .listening(let host, let port): return "Listening on \(host):\(port)"
            case .failed(let why): return "Could not start: \(why)"
            }
        }
    }

    public static let enabledKey = "jarvis.remote.enabled"

    public private(set) var state: State = .off { didSet { if state != oldValue { JarvisLog.info("Remote access: \(state.line)"); onChange?() } } }
    public var onChange: (() -> Void)?
    public let tokens: RemoteTokenStore
    /// Debug only: listen on this bind mode for the life of this process, whatever the settings say.
    public var bindOverride: String? { didSet { refresh() } }

    private let config: ConfigStore
    private let api: RemoteAPI
    private let addresses: @Sendable () -> [Tailnet.Address]
    private let defaults: UserDefaults
    private var server: HTTPServer?
    private var serving: (host: String, port: UInt16)?
    private var generation = 0
    private var monitor: NWPathMonitor?
    private var timer: Timer?

    public init(config: ConfigStore, tokens: RemoteTokenStore, backend: RemoteBackend, defaults: UserDefaults = .standard,
                addresses: @escaping @Sendable () -> [Tailnet.Address] = { Tailnet.interfaceAddresses() }) {
        self.config = config
        self.tokens = tokens
        self.defaults = defaults
        self.addresses = addresses
        let maxAudio = config.tuning.remoteMaxAudioSeconds
        self.api = RemoteAPI(tokens: tokens, backend: backend, maxAudioSeconds: { maxAudio })
    }

    public var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey); refresh() }
    }

    /// "loopback" or "tailscale". Anything unrecognized means tailscale: there is no value that listens everywhere.
    nonisolated static func bindMode(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased() == "loopback" ? "loopback" : "tailscale"
    }

    /// The one address to listen on, or nil when there is none right now.
    nonisolated static func bindHost(mode: String, addresses: [Tailnet.Address]) -> String? {
        bindMode(mode) == "loopback" ? "127.0.0.1" : Tailnet.pick(from: addresses)?.ip
    }

    /// Who may connect at all: other devices on the tailnet, or this Mac itself in loopback mode.
    nonisolated static func peerAllowed(_ ip: String, mode: String) -> Bool {
        bindMode(mode) == "loopback" ? Tailnet.isLoopback(ip) : Tailnet.isTailscaleIPv4(ip)
    }

    /// Starts following the network. Call once at launch.
    public func start() {
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] _ in
            // Interfaces settle a moment after the path changes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { MainActor.assumeIsolated { self?.refresh() } }
        }
        m.start(queue: DispatchQueue(label: "com.samarth.jarvis.remote.path"))
        monitor = m
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    public func stop() {
        monitor?.cancel(); monitor = nil
        timer?.invalidate(); timer = nil
        generation += 1
        server?.stop(); server = nil; serving = nil
    }

    /// Brings the server in line with the settings and the network: starts, stops, or moves it.
    public func refresh() {
        let mode = Self.bindMode(bindOverride ?? config.tuning.remoteBind)
        var wanted: (host: String, port: UInt16)?
        var idle = State.off
        if !(isEnabled || bindOverride != nil) { idle = .off }
        else if tokens.isEmpty { idle = .noTokens }
        else if !(1024...65535).contains(config.tuning.remotePort) { idle = .failed("remotePort must be between 1024 and 65535") }
        else if let host = Self.bindHost(mode: mode, addresses: addresses()) { wanted = (host, UInt16(config.tuning.remotePort)) }
        else { idle = .waitingForTailscale }

        if let wanted, let serving, serving == wanted, server?.port != nil { return }
        generation += 1
        let gen = generation
        server?.stop(); server = nil; serving = nil
        guard let wanted else { state = idle; return }

        let api = api
        let s = HTTPServer(config: .init(host: wanted.host, port: wanted.port),
                           peerFilter: { ip in RemoteAccess.peerAllowed(ip, mode: mode) },
                           precheck: { head, ip in api.precheck(head, from: ip) },
                           handler: { request, ip in await api.handle(request, from: ip) })
        server = s
        serving = wanted
        Task { [weak self] in
            do {
                try await s.start()
                guard let self, self.generation == gen else { s.stop(); return }
                self.state = .listening(host: wanted.host, port: s.port ?? wanted.port)
            } catch {
                guard let self, self.generation == gen else { return }
                self.server = nil; self.serving = nil
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: Command line

    /// `Jarvis --remote-token <device name> | --remote-revoke <device name> | --remote-tokens`, then exit.
    /// Works whether or not Jarvis is running; the running copy picks the change up by itself.
    public static func handleCommandLine(_ args: [String] = CommandLine.arguments) {
        guard let i = args.firstIndex(where: { $0.hasPrefix("--remote-") }) else { return }
        let store = RemoteTokenStore()
        let value = args.dropFirst(i + 1).joined(separator: " ")
        switch args[i] {
        case "--remote-token":
            do {
                let token = try store.create(name: value)
                FileHandle.standardError.write(Data("Access token for “\(value.trimmingCharacters(in: .whitespaces))”. It is shown once: put it on that device and nowhere else.\n".utf8))
                print(token)
                exit(0)
            } catch { FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8)); exit(1) }
        case "--remote-revoke":
            if store.revoke(name: value) { print("Revoked “\(value)”."); exit(0) }
            FileHandle.standardError.write(Data("No token called “\(value)”.\n".utf8)); exit(1)
        case "--remote-tokens":
            let f = ISO8601DateFormatter()
            if store.all.isEmpty { print("No access tokens.") }
            for t in store.all { print("\(t.name)\tcreated \(f.string(from: t.created))\tlast used \(t.lastUsed.map(f.string(from:)) ?? "never")") }
            exit(0)
        default:
            FileHandle.standardError.write(Data("Unknown option \(args[i]). Use --remote-token <name>, --remote-revoke <name>, or --remote-tokens.\n".utf8)); exit(2)
        }
    }
}

/// The real pipeline behind the remote API.
public final class LiveRemoteBackend: RemoteBackend, @unchecked Sendable {
    private let conversation: ConversationController
    private let config: ConfigStore
    private let modes: ModeManager
    private let router: SpeechRouter
    private let voiceID: SpeakerVerifier?
    private let makeTranscriber: @Sendable () -> Transcriber

    @MainActor
    public init(conversation: ConversationController, config: ConfigStore, modes: ModeManager, router: SpeechRouter,
                voiceID: SpeakerVerifier?, makeTranscriber: @escaping @Sendable () -> Transcriber) {
        self.conversation = conversation; self.config = config; self.modes = modes; self.router = router
        self.voiceID = voiceID; self.makeTranscriber = makeTranscriber
    }

    public func status() async -> RemoteStatus {
        let enrolled = voiceID?.isEnrolled ?? false
        return await MainActor.run {
            RemoteStatus(busy: conversation.state != .idle || conversation.remoteTurnActive,
                         keysUnlocked: !SecretVault.shared.usesHelper || SecretVault.shared.state == .unlocked,
                         voiceIDEnrolled: enrolled, mode: modes.current.id)
        }
    }

    public func transcribe(_ samples: [Float]) async throws -> String {
        try await UtteranceTranscription.transcribe(samples, with: makeTranscriber())
    }

    public func verifyVoice(_ samples: [Float]) async -> VoiceCheck? {
        guard let voiceID else { return nil }
        return await Task.detached(priority: .userInitiated) { voiceID.verify(samples) }.value
    }

    public func ask(_ text: String, voice: VoiceCheck?) async -> RemoteTurnResult {
        await conversation.remoteAsk(text, voice: voice)
    }

    public func decide(_ id: UUID, approved: Bool) async -> RemoteTurnResult? {
        await conversation.remoteDecide(id: id, approved: approved)
    }

    public func render(_ text: String) async throws -> (data: Data, mime: String) {
        let rate = await MainActor.run { Float(config.profile.assistant.speechRate) }
        return try await router.render(text, rate: rate)
    }
}
