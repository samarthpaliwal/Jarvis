import Foundation
import Combine

/// One voice turn: wake → listen (live transcript) → Claude (streaming, tools) → speak sentence by sentence.
/// Also barge-in and Tier 2 approvals (buttons or voice).
@MainActor
public final class ConversationController: ObservableObject {
    public typealias State = PipelineState

    public struct TurnStats: Equatable {
        public var wakeToFirstWordMs: Double?
        public var endOfSpeechToReplyMs: Double?
        public var endReason: String?
        public var transcript: String = ""
        public var toolCalls: [String] = []
        public var tokens: (Int, Int) = (0, 0)
        public static func == (a: TurnStats, b: TurnStats) -> Bool {
            a.wakeToFirstWordMs == b.wakeToFirstWordMs && a.endOfSpeechToReplyMs == b.endOfSpeechToReplyMs && a.transcript == b.transcript
        }
    }

    @Published public private(set) var state: State = .idle
    @Published public private(set) var lastTurn = TurnStats()
    @Published public var voiceMuted: Bool = UserDefaults.standard.bool(forKey: "jarvis.voiceMuted") {
        didSet { UserDefaults.standard.set(voiceMuted, forKey: "jarvis.voiceMuted") }
    }
    /// Keep listening after each reply so the next sentence needs no wake word.
    @Published public var conversationMode: Bool = UserDefaults.standard.object(forKey: "jarvis.conversationMode") as? Bool ?? true {
        didSet { UserDefaults.standard.set(conversationMode, forKey: "jarvis.conversationMode") }
    }
    /// What Jarvis is saying or last said, and when its audio last stopped. Used to recognise its own echo.
    private var currentReply = ""
    private var lastSpokeAt = Date.distantPast
    /// Reports whether the output is headphones. Swappable for tests.
    public var outputIsHeadphones: () -> Bool = { AudioDeviceInfo.outputIsHeadphones() }
    private var lastUserText = ""
    nonisolated static let endWords: Set<String> = ["thanks", "thank", "thankyou", "bye", "goodbye", "later", "done", "nevermind", "never", "cheers", "nothing", "no"]

    /// Set by the app: when a wake arrives while an arrival window is open, run the homecoming scene instead.
    public var homecomingIfArriving: (() -> Bool)?
    /// Extra consumer of the mic stream (phrase spotter). Capture queue.
    public nonisolated(unsafe) var extraAudioTap: (([Float]) -> Void)?
    /// Called when a user turn starts / ends so the spotter can pause.
    public var onTurnActive: ((Bool) -> Void)?

    /// Streams a reply for a transcript. Default: the Brain (Claude). Tests can swap it.
    public var responder: (String, @escaping (String) -> Void) async throws -> Brain.Turn

    private let notch: NotchViewModel
    private let wake: WakeWordService
    private nonisolated(unsafe) let transcriber: Transcriber
    private let speech: SpeechOutput
    private let config: ConfigStore
    private let modes: ModeManager

    private var endpointer = Endpointer()
    private var endpointTimer: Task<Void, Never>?
    private var wakeTime = Date()
    private var firstWordLogged = false
    private var speechEndedAt = Date()
    private var turn = 0
    private var listeningForStopOnly = false
    private var replyTask: Task<Void, Never>?
    /// The request being worked on (nil when idle). One at a time.
    public private(set) var trace: RequestTrace?
    /// Transitions the table did not allow. Zero in a healthy run; shown in the menu and checked by tests.
    public private(set) var illegalTransitions = 0
    /// Strict mode refuses an illegal transition. Off in the app for now: an unexpected transition is
    /// logged and still applied, so the table can prove itself against real use without ever hanging a turn.
    public var strictTransitions = false

    /// The only place `state` changes.
    @discardableResult
    private func transition(_ event: PipelineEvent) -> Bool {
        let from = state
        guard let to = PipelineMachine.next(from, on: event) else {
            illegalTransitions += 1
            JarvisLog.warn("Illegal transition: \(event.rawValue) while \(from.rawValue)" + (strictTransitions ? " (refused)" : " (applied anyway)"), request: trace?.id)
            TraceSink.shared.write(["event": "illegal_transition", "on": event.rawValue, "from": from.rawValue,
                                    "request": trace?.id ?? "-", "applied": !strictTransitions])
            guard !strictTransitions else { return false }
            state = event.target
            return true
        }
        guard to != from else { return true }
        state = to
        TraceSink.shared.write(["event": "state", "from": from.rawValue, "to": to.rawValue, "on": event.rawValue, "request": trace?.id ?? "-"])
        return true
    }

    // Approval
    private var pendingApproval: (request: ApprovalRequest, continuation: CheckedContinuation<Bool, Never>)?
    private var approvalTimeout: Task<Void, Never>?

    public init(notch: NotchViewModel, wake: WakeWordService, transcriber: Transcriber,
                speech: SpeechOutput, config: ConfigStore, modes: ModeManager, brain: Brain?) {
        self.notch = notch
        self.wake = wake
        self.transcriber = transcriber
        self.speech = speech
        self.config = config
        self.modes = modes
        if let brain {
            self.responder = { text, onText in try await brain.respond(to: text, onText: onText) }
        } else {
            let name = config.profile.assistant.addressUserAs
            self.responder = { text, onText in
                let t = "Heard you, \(name): “\(text)”."
                onText(t)
                return Brain.Turn(text: t)
            }
        }
        wake.onWake = { [weak self] date in self?.handleWake(at: date) }
        wake.onLevel = { [weak self] level in self?.notch.pushAudioLevel(level) }
        wake.audioTap = { [weak self] chunk in self?.forwardAudio(chunk) }
        notch.onApprovalDecision = { [weak self] id, ok in self?.resolveApproval(id: id, approved: ok) }
        speech.onAudioStart = { [weak self] engine in
            guard let trace = self?.trace, trace.mark("first_audio") == nil else { return }
            trace.event(.spoken, "first_audio", ["engine": engine])
        }
    }

    /// Starts tracing a new request, closing any previous one that was cut short.
    private func beginRequest(source: String) -> RequestTrace {
        trace?.finish(outcome: "superseded")
        let t = RequestTrace(source: source)
        trace = t
        t.event(.heard, source, ["mode": modes.current.id])
        return t
    }

    // MARK: Wake / stop

    public func handleWake(at date: Date) {
        switch state {
        case .speaking:
            JarvisLog.info("Barge-in: wake word while speaking", request: trace?.id)
            trace?.finish(outcome: "interrupted")
            speech.stop()
            replyTask?.cancel()
        case .listening, .thinking:
            return
        case .awaitingApproval:
            return // the approval listener is already running
        case .idle:
            break
        }
        if let h = homecomingIfArriving, h() { return }
        startListening(at: date)
    }

    public func stopEverything() {
        trace?.finish(outcome: "cancelled")
        speech.stop()
        replyTask?.cancel()
        transcriber.cancel()
        endpointTimer?.cancel()
        if let p = pendingApproval { pendingApproval = nil; p.continuation.resume(returning: false) }
        wake.setPaused(false)
        onTurnActive?(false)
        transition(.stopped)
        notch.collapse()
    }

    // MARK: Listening

    /// `followUp`: no wake word, shorter no-speech timeout, calmer UI.
    /// `seed`: text already heard on a session that keeps running (interrupt-by-speech).
    private func startListening(at date: Date, followUp: Bool = false, seed: String? = nil) {
        turn += 1
        wakeTime = date
        let trace = beginRequest(source: seed != nil ? "barge_in" : followUp ? "follow_up" : "wake")
        firstWordLogged = seed != nil
        listeningForStopOnly = false
        var settings = endpointSettings
        if followUp { settings.noSpeechTimeout = max(2, config.profile.speech?.followUpSeconds ?? 7) }
        endpointer = Endpointer(settings: settings)
        lastTurn = TurnStats()
        transition(seed != nil ? .bargeIn : followUp ? .followUp : .wake)
        notch.isFollowUp = followUp
        notch.listen()
        if let seed { _ = endpointer.update(TranscriptUpdate(text: seed, isFinal: false)); notch.transcript = seed }
        wake.setPaused(true)
        onTurnActive?(true)
        if seed == nil {
            do {
                try transcriber.start(onUpdate: { [weak self] u in self?.handleTranscript(u) },
                                      onError: { [weak self] e in self?.handleTranscriberError(e) })
            } catch {
                handleTranscriberError(error)
                return
            }
        }
        let thisTurn = turn
        endpointTimer?.cancel()
        endpointTimer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self, self.turn == thisTurn, self.state == .listening else { return }
                if let reason = self.endpointer.shouldEnd() {
                    self.endListening(reason: reason)
                    return
                }
            }
        }
    }

    private var endpointSettings: Endpointer.Settings {
        var s = Endpointer.Settings()
        if let sp = config.profile.speech {
            s.silenceAfterSpeech = sp.silenceEndSeconds
            s.noSpeechTimeout = sp.noSpeechTimeoutSeconds
            s.maxDuration = sp.maxUtteranceSeconds
        }
        return s
    }

    private func handleTranscript(_ u: TranscriptUpdate) {
        if state == .awaitingApproval {
            handleApprovalSpeech(u.text)
            return
        }
        if listeningForStopOnly {
            let words = u.text.lowercased().split(separator: " ").prefix(3)
            if words.contains("stop") || words.contains("stop.") {
                JarvisLog.info("Barge-in: “stop” while speaking", request: trace?.id)
                stopEverything()
                return
            }
            // Talking over Jarvis (not an echo of its own voice) interrupts and becomes the next turn.
            if speechBargeInAllowed, state == .speaking,
               Self.isGenuineInterruption(heard: u.text, spoken: currentReply) {
                JarvisLog.info("Barge-in: speech while speaking: “\(u.text)”", request: trace?.id)
                trace?.finish(outcome: "interrupted")
                speech.stop()
                replyTask?.cancel()
                listeningForStopOnly = false
                startListening(at: Date(), followUp: true, seed: u.text)
            }
            return
        }
        guard state == .listening else { return }
        if endpointer.update(u) {
            notch.transcript = endpointer.transcript
            if !firstWordLogged, !endpointer.transcript.isEmpty {
                firstWordLogged = true
                let ms = Date().timeIntervalSince(wakeTime) * 1000
                lastTurn.wakeToFirstWordMs = ms
                trace?.event(.transcribed, "first_word")
                JarvisLog.info(String(format: "Wake → first word %.0f ms", ms), request: trace?.id)
            }
        }
    }

    /// Talking over Jarvis only interrupts when the mic cannot hear Jarvis (headphones), unless configured otherwise.
    private var speechBargeInAllowed: Bool {
        guard config.profile.speech?.interruptOnSpeech ?? true else { return false }
        switch config.tuning.speechBargeIn.lowercased() {
        case "always": return true
        case "never": return false
        default: return outputIsHeadphones()
        }
    }

    private func handleTranscriberError(_ error: Error) {
        JarvisLog.error("Transcriber: \(error.localizedDescription)", request: trace?.id)
        guard state == .listening else { return }
        trace?.event(.transcribed, "error", ["error": error.localizedDescription])
        trace?.finish(outcome: "stt_error")
        endpointTimer?.cancel()
        transcriber.cancel()
        wake.setPaused(false)
        transition(.sttFailed)
        let msg: String
        if case TranscriberError.notAuthorized = error {
            msg = "I need Speech Recognition permission. System Settings → Privacy & Security → Speech Recognition."
        } else {
            msg = "Speech recognition isn’t available right now."
        }
        notch.respond(msg, collapseAfter: 6)
    }

    private func endListening(reason: Endpointer.Reason) {
        endpointTimer?.cancel()
        transcriber.finish()
        speechEndedAt = Date()
        lastTurn.endReason = reason.rawValue
        let text = endpointer.transcript
        lastTurn.transcript = text
        JarvisLog.info("Listening ended (\(reason.rawValue)): “\(text)”", request: trace?.id)
        trace?.event(.transcribed, "speech_end", ["reason": reason.rawValue, "chars": text.count,
                                                   "silence_wait_ms": (endpointer.settings.silenceAfterSpeech * 1000).rounded()])
        wake.setPaused(false)
        onTurnActive?(false)
        guard !text.isEmpty else {
            trace?.finish(outcome: "no_speech")
            transition(.noSpeech)
            notch.isFollowUp = false
            notch.collapse()
            return
        }
        // A follow-up that is really the microphone hearing Jarvis's last reply must never reach Claude:
        // that is how the "hall of mirrors" loops started.
        if notch.isFollowUp, Date().timeIntervalSince(lastSpokeAt) < config.tuning.echoWindowSeconds,
           EchoGuard.isEchoAfterSpeaking(heard: text, spoken: currentReply) {
            let sim = EchoGuard.similarity(heard: text, spoken: currentReply)
            JarvisLog.warn(String(format: "Dropped echo of my own voice (overlap %.2f, in order %.2f): “%@”", sim.overlap, sim.ordered, String(text.prefix(80))), request: trace?.id)
            trace?.event(.transcribed, "echo_discarded", ["overlap": sim.overlap, "ordered": sim.ordered, "chars": text.count])
            trace?.finish(outcome: "echo_discarded")
            transcriber.cancel()
            transition(.echoDiscarded)
            notch.isFollowUp = false
            notch.collapse()
            return
        }
        // "thanks" / "that's all" on a follow-up ends the conversation without a round trip.
        if notch.isFollowUp, Self.isConversationEnd(text) {
            JarvisLog.info("Conversation ended by “\(text)”", request: trace?.id)
            trace?.finish(outcome: "ended_by_user")
            transcriber.cancel()
            transition(.conversationEnded)
            notch.isFollowUp = false
            notch.collapse()
            return
        }
        lastUserText = text
        transition(.transcribed)
        notch.think()
        replyTask?.cancel()
        let request = trace
        replyTask = Task { [weak self] in
            await RequestTrace.$current.withValue(request) {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.state == .thinking, !Task.isCancelled else { return }
                let finalText = self.endpointer.transcript.isEmpty ? text : self.endpointer.transcript
                self.transcriber.cancel()
                await self.respond(to: finalText)
            }
        }
    }

    /// Run a turn from typed text (menu "Ask by Text…", or the ask.txt debug hook). Same path as speech.
    public func ask(_ text: String) {
        switch state {
        case .thinking, .awaitingApproval:
            JarvisLog.info("Text turn ignored: busy (\(state.rawValue))")
            return
        case .speaking:
            trace?.finish(outcome: "interrupted")
            speech.stop(); replyTask?.cancel(); transcriber.cancel(); listeningForStopOnly = false
        case .listening:
            // Typing during a (follow-up) listen replaces the spoken turn.
            endpointTimer?.cancel(); transcriber.cancel(); wake.setPaused(false); onTurnActive?(false)
        case .idle:
            break
        }
        notch.isFollowUp = false
        turn += 1
        lastTurn = TurnStats(transcript: text)
        endpointer = Endpointer()
        _ = endpointer.update(TranscriptUpdate(text: text, isFinal: true))
        notch.listen()
        notch.transcript = text
        speechEndedAt = Date()
        let request = beginRequest(source: "text")
        request.event(.transcribed, "speech_end", ["reason": "typed", "chars": text.count])
        transition(.typed)
        notch.think()
        replyTask?.cancel()
        replyTask = Task { [weak self] in
            await RequestTrace.$current.withValue(request) { await self?.respond(to: text) }
        }
    }

    // MARK: Responding (streaming)

    private func respond(to text: String) async {
        lastUserText = text   // spoken and typed turns both land here
        let mode = modes.current
        let voiceOn = mode.voice.enabled && !voiceMuted
        let volume = Float(mode.voice.volume)
        let rate = Float(config.profile.assistant.speechRate)
        var chunker = SentenceChunker()
        var firstDelta = true
        var spokeSomething = false
        currentReply = ""

        let onText: (String) -> Void = { [weak self] delta in
            guard let self else { return }
            Task { @MainActor in
                if firstDelta {
                    firstDelta = false
                    let ms = Date().timeIntervalSince(self.speechEndedAt) * 1000
                    self.lastTurn.endOfSpeechToReplyMs = ms
                    RequestTrace.current?.event(.intent, "first_token")
                    JarvisLog.info(String(format: "End of speech → first reply token %.0f ms", ms))
                }
                if self.state == .thinking, voiceOn { self.transition(.replyStarted); self.listenForStop() }
                self.notch.appendReply(delta)
                self.currentReply += delta
                self.notch.cancelCollapse()
                if voiceOn {
                    for sentence in chunker.push(delta) {
                        spokeSomething = true
                        self.speech.enqueue(sentence, volume: volume, rate: rate)
                    }
                }
            }
        }

        let request = RequestTrace.current
        var failed = false
        var turn: Brain.Turn
        do {
            turn = try await responder(text, onText)
        } catch is CancellationError {
            request?.finish(outcome: "cancelled")
            return
        } catch {
            turn = Brain.Turn()
            let msg = Self.friendly(error)
            turn.text = msg
            onText(msg)
            failed = true
            request?.event(.intent, "error", ["error": String(describing: type(of: error)), "message": String(error.localizedDescription.prefix(200))])
            JarvisLog.error("Brain: \(error.localizedDescription)")
        }
        request?.event(.intent, "llm_done", ["engine": turn.engine, "chars": turn.text.count])
        request?.set("engine", turn.engine)
        request?.set("tokens", ["in": turn.inputTokens, "out": turn.outputTokens, "cache_read": turn.cacheReadTokens, "cache_write": turn.cacheWriteTokens])
        guard !Task.isCancelled, state != .idle else { request?.finish(outcome: "cancelled"); return }
        lastTurn.toolCalls = turn.toolCalls
        lastTurn.tokens = (turn.inputTokens, turn.outputTokens)
        if !turn.toolCalls.isEmpty || turn.inputTokens > 0 {
            JarvisLog.info("Turn done: engine=\(turn.engine) tools=\(turn.toolCalls) tokens in/out=\(turn.inputTokens)/\(turn.outputTokens) cache read/write=\(turn.cacheReadTokens)/\(turn.cacheWriteTokens)")
        }
        // Make sure the notch shows the final text and cards even if nothing streamed.
        if notch.phase != .responding { notch.respond(turn.text, cards: turn.cards, collapseAfter: voiceOn ? 60 : 10) }
        else { notch.cancelCollapse(); for c in turn.cards { notch.addCard(c) } }
        if turn.text.isEmpty && turn.cards.isEmpty { notch.replyText = "Done." }
        notch.logExchange(you: lastUserText, jarvis: turn.text)
        JarvisLog.conversation(you: lastUserText, jarvis: turn.text, tools: turn.toolCalls)

        guard voiceOn else {
            request?.event(.spoken, "shown", ["voice": false])
            request?.finish(outcome: failed ? "error" : "shown")
            transition(.replyFinished)
            notch.scheduleCollapse(after: 10)
            return
        }
        if let rest = chunker.flush() { spokeSomething = true; speech.enqueue(rest, volume: volume, rate: rate) }
        if !spokeSomething { speech.enqueue(turn.text.isEmpty ? "Done." : turn.text, volume: volume, rate: rate) }
        transition(.replyStarted)
        listenForStop()
        speech.whenQueueDrained { [weak self] completed in
            guard let self else { return }
            request?.event(.spoken, "speech_done", ["completed": completed])
            request?.finish(outcome: failed ? "error" : completed ? "spoken" : "interrupted")
            self.transcriber.cancel()
            self.lastSpokeAt = Date()
            if self.state == .speaking {
                self.transition(.replyFinished)
                if completed, self.conversationMode, (self.config.profile.speech?.followUpSeconds ?? 7) > 0 {
                    // Let the speakers and the room go quiet before the microphone counts as "the user".
                    let after = self.turn
                    let guardMs = max(0, self.config.tuning.followUpGuardMilliseconds)
                    Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(Int(guardMs)))
                        guard let self, self.state == .idle, self.turn == after else { return }
                        self.startListening(at: Date(), followUp: true)
                    }
                } else {
                    self.notch.scheduleCollapse(after: completed ? 2.5 : 0.5)
                }
            }
        }
    }

    /// Words heard while Jarvis talks: a real interruption, or just the mic hearing Jarvis?
    nonisolated static func isGenuineInterruption(heard: String, spoken: String) -> Bool {
        guard EchoGuard.words(heard).count >= 2 else { return false }
        return !EchoGuard.isEchoWhileSpeaking(heard: heard, spoken: spoken)
    }

    nonisolated static func isConversationEnd(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard !words.isEmpty, words.count <= 4 else { return false }
        if words.joined(separator: " ").contains("thats all") || words.joined(separator: " ").contains("that s all") { return true }
        return words.contains { endWords.contains($0) }
    }

    /// Speak + show something outside a user turn (mode changes, timers, Tier 1 summaries).
    public func deliver(_ text: String, cards: [NotchCard] = [], onDone: (() -> Void)? = nil) {
        let mode = modes.current
        let voiceOn = mode.voice.enabled && !voiceMuted
        notch.respond(text, cards: cards, collapseAfter: voiceOn ? 60 : 8)
        guard voiceOn, state == .idle else { onDone?(); return }
        currentReply = text   // so the cut-in listener can tell this announcement from the user
        transition(.announce)
        listenForStop()
        speech.speak(text, volume: Float(mode.voice.volume), rate: Float(config.profile.assistant.speechRate)) { [weak self] completed in
            guard let self else { return }
            self.transcriber.cancel()
            self.lastSpokeAt = Date()
            if self.state == .speaking {
                self.transition(.replyFinished)
                self.notch.scheduleCollapse(after: completed ? 2.5 : 0.5)
            }
            onDone?()
        }
    }

    private func listenForStop() {
        guard !listeningForStopOnly else { return }
        listeningForStopOnly = true
        try? transcriber.start(onUpdate: { [weak self] u in self?.handleTranscript(u) }, onError: { _ in })
    }

    static func friendly(_ error: Error) -> String {
        if let e = error as? ClaudeClient.ClientError { return e.localizedDescription }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain { return "I can't reach Claude right now. Check the connection." }
        return "Something went wrong: \(error.localizedDescription)"
    }

    // MARK: Tier 2 approval

    /// Called by the dispatcher. Shows the card, asks aloud, and listens for yes/no (12 s).
    public func requestApproval(_ request: ApprovalRequest) async -> Bool {
        if let p = pendingApproval { pendingApproval = nil; p.continuation.resume(returning: false) }
        return await withCheckedContinuation { cont in
            pendingApproval = (request, cont)
            transition(.approvalNeeded)
            listeningForStopOnly = false
            notch.cancelCollapse()
            if notch.phase != .responding { notch.respond("", cards: [], collapseAfter: 120) }
            notch.addCard(.approval(request))
            notch.transcript = ""
            let voiceOn = modes.current.voice.enabled && !voiceMuted
            wake.setPaused(true)
            transcriber.cancel()
            approvalTimeout?.cancel()
            // Listen for the answer, and start the clock, only once the prompt is no longer audible.
            // The prompt itself says "yes" and "no"; a microphone that hears it must never count as the answer.
            let listenForAnswer: () -> Void = { [weak self] in
                guard let self, self.pendingApproval?.request.id == request.id else { return }
                try? self.transcriber.start(onUpdate: { [weak self] u in self?.handleTranscript(u) }, onError: { _ in })
                self.approvalTimeout?.cancel()
                self.approvalTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(self?.config.tuning.approvalTimeoutSeconds ?? 12))
                    guard !Task.isCancelled else { return }
                    self?.resolveApproval(id: request.id, approved: false, reason: "timeout")
                }
            }
            if voiceOn {
                let prompt = "Approve: \(Self.spoken(request))? Say yes or no."
                currentReply = prompt
                let guardMs = max(0, config.tuning.followUpGuardMilliseconds)
                speech.speak(prompt, volume: Float(modes.current.voice.volume),
                             rate: Float(config.profile.assistant.speechRate)) { [weak self] _ in
                    self?.lastSpokeAt = Date()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(Int(guardMs)))
                        listenForAnswer()
                    }
                }
            } else {
                listenForAnswer()
            }
        }
    }

    private static func spoken(_ r: ApprovalRequest) -> String {
        let p = r.preview
        return p.count > 140 ? String(p.prefix(140)) + "…" : p
    }

    private func handleApprovalSpeech(_ text: String) {
        // Never take an answer while Jarvis's own voice is in the air.
        guard let p = pendingApproval, !speech.isSpeaking else { return }
        let words = Set(text.lowercased().replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: ".", with: " ").split(separator: " ").map(String.init))
        if !words.isDisjoint(with: ["no", "nope", "deny", "cancel", "don't", "dont", "stop"]) {
            resolveApproval(id: p.request.id, approved: false, reason: "voice")
        } else if !words.isDisjoint(with: ["yes", "yeah", "yep", "approve", "approved", "go", "ok", "okay", "sure", "do"]) {
            resolveApproval(id: p.request.id, approved: true, reason: "voice")
        }
    }

    private func resolveApproval(id: UUID, approved: Bool, reason: String = "button") {
        guard let p = pendingApproval, p.request.id == id else { return }
        pendingApproval = nil
        approvalTimeout?.cancel()
        transcriber.cancel()
        speech.stop()
        wake.setPaused(false)
        notch.removeCard(id: "approval-\(id)")
        JarvisLog.info("Approval \(approved ? "GRANTED" : "DENIED") via \(reason): \(p.request.preview)")
        transition(.approvalResolved)
        p.continuation.resume(returning: approved)
    }

    // MARK: Audio routing (capture queue)

    private nonisolated func forwardAudio(_ chunk: [Float]) {
        transcriber.append(samples: chunk)
        extraAudioTap?(chunk)
    }
}
