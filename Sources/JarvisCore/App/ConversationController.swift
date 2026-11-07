import Foundation
import Combine

/// One voice turn: wake → listen (live transcript) → Claude (streaming, tools) → speak sentence by sentence.
/// Also barge-in and Tier 2 approvals (buttons or voice).
@MainActor
public final class ConversationController: ObservableObject {
    public enum State: String, Equatable { case idle, listening, thinking, speaking, awaitingApproval }

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
    private var currentReply = ""
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
    }

    // MARK: Wake / stop

    public func handleWake(at date: Date) {
        switch state {
        case .speaking:
            JarvisLog.info("Barge-in: wake word while speaking")
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
        speech.stop()
        replyTask?.cancel()
        transcriber.cancel()
        endpointTimer?.cancel()
        if let p = pendingApproval { pendingApproval = nil; p.continuation.resume(returning: false) }
        wake.setPaused(false)
        onTurnActive?(false)
        state = .idle
        notch.collapse()
    }

    // MARK: Listening

    /// `followUp`: no wake word, shorter no-speech timeout, calmer UI.
    /// `seed`: text already heard on a session that keeps running (interrupt-by-speech).
    private func startListening(at date: Date, followUp: Bool = false, seed: String? = nil) {
        turn += 1
        wakeTime = date
        firstWordLogged = seed != nil
        listeningForStopOnly = false
        var settings = endpointSettings
        if followUp { settings.noSpeechTimeout = max(2, config.profile.speech?.followUpSeconds ?? 7) }
        endpointer = Endpointer(settings: settings)
        lastTurn = TurnStats()
        state = .listening
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
                JarvisLog.info("Barge-in: “stop” while speaking")
                stopEverything()
                return
            }
            // Talking over Jarvis (not an echo of its own voice) interrupts and becomes the next turn.
            if config.profile.speech?.interruptOnSpeech ?? true, state == .speaking,
               Self.isGenuineInterruption(heard: u.text, spoken: currentReply) {
                JarvisLog.info("Barge-in: speech while speaking: “\(u.text)”")
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
                JarvisLog.info(String(format: "Wake → first word %.0f ms", ms))
            }
        }
    }

    private func handleTranscriberError(_ error: Error) {
        JarvisLog.error("Transcriber: \(error.localizedDescription)")
        guard state == .listening else { return }
        endpointTimer?.cancel()
        transcriber.cancel()
        wake.setPaused(false)
        state = .idle
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
        JarvisLog.info("Listening ended (\(reason.rawValue)): “\(text)”")
        wake.setPaused(false)
        onTurnActive?(false)
        guard !text.isEmpty else {
            state = .idle
            notch.isFollowUp = false
            notch.collapse()
            return
        }
        // "thanks" / "that's all" on a follow-up ends the conversation without a round trip.
        if notch.isFollowUp, Self.isConversationEnd(text) {
            JarvisLog.info("Conversation ended by “\(text)”")
            transcriber.cancel()
            state = .idle
            notch.isFollowUp = false
            notch.collapse()
            return
        }
        lastUserText = text
        state = .thinking
        notch.think()
        replyTask?.cancel()
        replyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, self.state == .thinking, !Task.isCancelled else { return }
            let finalText = self.endpointer.transcript.isEmpty ? text : self.endpointer.transcript
            self.transcriber.cancel()
            await self.respond(to: finalText)
        }
    }

    /// Run a turn from typed text (menu "Ask by Text…", or the ask.txt debug hook). Same path as speech.
    public func ask(_ text: String) {
        switch state {
        case .thinking, .awaitingApproval:
            JarvisLog.info("Text turn ignored: busy (\(state.rawValue))")
            return
        case .speaking:
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
        state = .thinking
        notch.think()
        replyTask?.cancel()
        replyTask = Task { [weak self] in await self?.respond(to: text) }
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
                    JarvisLog.info(String(format: "End of speech → first reply token %.0f ms", ms))
                }
                if self.state == .thinking { self.state = voiceOn ? .speaking : .thinking; if voiceOn { self.listenForStop() } }
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

        var turn: Brain.Turn
        do {
            turn = try await responder(text, onText)
        } catch is CancellationError {
            return
        } catch {
            turn = Brain.Turn()
            let msg = Self.friendly(error)
            turn.text = msg
            onText(msg)
            JarvisLog.error("Brain: \(error.localizedDescription)")
        }
        guard !Task.isCancelled, state != .idle else { return }
        lastTurn.toolCalls = turn.toolCalls
        lastTurn.tokens = (turn.inputTokens, turn.outputTokens)
        if !turn.toolCalls.isEmpty || turn.inputTokens > 0 {
            JarvisLog.info("Turn done: tools=\(turn.toolCalls) tokens in/out=\(turn.inputTokens)/\(turn.outputTokens) cache read/write=\(turn.cacheReadTokens)/\(turn.cacheWriteTokens)")
        }
        // Make sure the notch shows the final text and cards even if nothing streamed.
        if notch.phase != .responding { notch.respond(turn.text, cards: turn.cards, collapseAfter: voiceOn ? 60 : 10) }
        else { notch.cancelCollapse(); for c in turn.cards { notch.addCard(c) } }
        if turn.text.isEmpty && turn.cards.isEmpty { notch.replyText = "Done." }
        notch.logExchange(you: lastUserText, jarvis: turn.text)
        JarvisLog.conversation(you: lastUserText, jarvis: turn.text, tools: turn.toolCalls)

        guard voiceOn else {
            state = .idle
            notch.scheduleCollapse(after: 10)
            return
        }
        if let rest = chunker.flush() { spokeSomething = true; speech.enqueue(rest, volume: volume, rate: rate) }
        if !spokeSomething { speech.enqueue(turn.text.isEmpty ? "Done." : turn.text, volume: volume, rate: rate) }
        state = .speaking
        listenForStop()
        speech.whenQueueDrained { [weak self] completed in
            guard let self else { return }
            self.transcriber.cancel()
            if self.state == .speaking {
                self.state = .idle
                if completed, self.conversationMode, (self.config.profile.speech?.followUpSeconds ?? 7) > 0 {
                    self.startListening(at: Date(), followUp: true)
                } else {
                    self.notch.scheduleCollapse(after: completed ? 2.5 : 0.5)
                }
            }
        }
    }

    /// Words heard while Jarvis talks: a real interruption, or just the mic hearing Jarvis?
    nonisolated static func isGenuineInterruption(heard: String, spoken: String) -> Bool {
        let words = heard.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.count >= 2 else { return false }
        let spokenWords = Set(spoken.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !spokenWords.isEmpty else { return true }
        let overlap = Double(words.filter { spokenWords.contains($0) }.count) / Double(words.count)
        return overlap < 0.5
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
        state = .speaking
        listenForStop()
        speech.speak(text, volume: Float(mode.voice.volume), rate: Float(config.profile.assistant.speechRate)) { [weak self] completed in
            guard let self else { return }
            self.transcriber.cancel()
            if self.state == .speaking {
                self.state = .idle
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
            state = .awaitingApproval
            listeningForStopOnly = false
            notch.cancelCollapse()
            if notch.phase != .responding { notch.respond("", cards: [], collapseAfter: 120) }
            notch.addCard(.approval(request))
            notch.transcript = ""
            let voiceOn = modes.current.voice.enabled && !voiceMuted
            if voiceOn {
                speech.speak("Approve: \(Self.spoken(request))? Say yes or no.", volume: Float(modes.current.voice.volume),
                             rate: Float(config.profile.assistant.speechRate)) { _ in }
            }
            try? transcriber.start(onUpdate: { [weak self] u in self?.handleTranscript(u) }, onError: { _ in })
            wake.setPaused(true)
            approvalTimeout?.cancel()
            approvalTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(12))
                guard !Task.isCancelled else { return }
                self?.resolveApproval(id: request.id, approved: false, reason: "timeout")
            }
        }
    }

    private static func spoken(_ r: ApprovalRequest) -> String {
        let p = r.preview
        return p.count > 140 ? String(p.prefix(140)) + "…" : p
    }

    private func handleApprovalSpeech(_ text: String) {
        guard let p = pendingApproval else { return }
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
        state = .thinking
        p.continuation.resume(returning: approved)
    }

    // MARK: Audio routing (capture queue)

    private nonisolated func forwardAudio(_ chunk: [Float]) {
        transcriber.append(samples: chunk)
        extraAudioTap?(chunk)
    }
}
