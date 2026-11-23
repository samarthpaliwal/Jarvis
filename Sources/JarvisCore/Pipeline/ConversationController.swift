import AppKit
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
    private var errorSpeech = SpeechRateLimit()
    private var pendingAnnouncements: [String] = []

    // Voice ID
    /// Checks whose voice made each request. Nil when the voice model is not installed.
    public var voiceID: SpeakerVerifier?
    private let utterance = UtteranceRecorder()
    /// The voice check for the request in progress. Nil for a typed request.
    private var currentVoiceCheck: Task<VoiceCheck, Never>?
    @Published public private(set) var lastVoiceCheck: VoiceCheck?
    private var approvalGate = VoiceGate.voiceOrButton
    private var toldAboutButton = false
    public private(set) var isEnrolling = false
    private nonisolated(unsafe) var enrollmentTap: (@Sendable ([Float]) -> Void)?
    private var lastUserText = ""
    nonisolated static let endWords: Set<String> = ["thanks", "thank", "thankyou", "bye", "goodbye", "later", "done", "nevermind", "never", "cheers", "nothing", "no"]

    /// Set by the app: when a wake arrives while an arrival window is open, run the homecoming scene instead.
    public var homecomingIfArriving: (() -> Bool)?
    /// Extra consumer of the mic stream (phrase spotter). Capture queue.
    public nonisolated(unsafe) var extraAudioTap: (([Float]) -> Void)?
    /// Called when a user turn starts / ends so the spotter can pause.
    public var onTurnActive: ((Bool) -> Void)?
    /// Called when the first word of a spoken request is transcribed.
    public var onFirstWord: (() -> Void)?
    /// Called when a request failed because the saved keys are locked, so the app can ask for Touch ID.
    public var onKeysNeeded: (() -> Void)?

    /// Streams a reply for a transcript. Default: the Brain (Claude). Tests can swap it.
    public var responder: (String, @escaping (String) -> Void) async throws -> Brain.Turn

    private let notch: NotchViewModel
    private let wake: any WakeSource
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
        if to == .idle, !pendingAnnouncements.isEmpty {
            // Something had to wait for the current reply to finish (a budget warning, say).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state == .idle, !self.pendingAnnouncements.isEmpty else { return }
                self.deliver(self.pendingAnnouncements.removeFirst())
            }
        }
        TraceSink.shared.write(["event": "state", "from": from.rawValue, "to": to.rawValue, "on": event.rawValue, "request": trace?.id ?? "-"])
        return true
    }

    // Approval
    private var pendingApproval: (request: ApprovalRequest, continuation: CheckedContinuation<Bool, Never>)?
    private var approvalTimeout: Task<Void, Never>?

    public init(notch: NotchViewModel, wake: any WakeSource, transcriber: Transcriber,
                speech: SpeechOutput, config: ConfigStore, modes: ModeManager, brain: (any IntentEngine)?) {
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
                return Reply(text: t)
            }
        }
        wake.onWake = { [weak self] date in self?.handleWake(at: date) }
        wake.onLevel = { [weak self] level in self?.notch.pushAudioLevel(level) }
        wake.audioTap = { [weak self] chunk in self?.forwardAudio(chunk) }
        notch.onApprovalDecision = { [weak self] id, ok in self?.resolveApproval(id: id, approved: ok) }
        (speech as? SpeechRouter)?.onChunkTiming = { [weak self] words, synthMs, waitMs, playMs in
            self?.trace?.event(.spoken, "tts_chunk", ["words": words, "synth_ms": synthMs.rounded(), "wait_ms": waitMs.rounded(), "play_ms": playMs.rounded()])
        }
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
        guard !isEnrolling else { return }      // enrollment has the microphone
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
        utterance.discard()
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
        // Keep this request's audio for the voice check. "Hey Jarvis" is included for a wake; for a follow-up
        // what came just before is Jarvis's own voice, so that is left out.
        utterance.begin(includePreRoll: !followUp && seed == nil)
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
        s.silenceAfterSentence = config.tuning.endpointFastSilenceSeconds
        s.sentenceMinWords = config.tuning.endpointFastMinWords
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
               Self.isGenuineInterruption(heard: u.text, spoken: currentReply, minimumWords: outputIsHeadphones() ? 2 : 3) {
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
                onFirstWord?()   // a real request is under way: a good moment to warm the model's cache
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
        onTurnActive?(false)
        notch.isFollowUp = false
        reportFailure(SpokenFailure.message(for: error))
    }

    /// Says something as soon as Jarvis is idle: now, or right after the reply in progress.
    public func announceWhenIdle(_ text: String) {
        if state == .idle { deliver(text) } else { pendingAnnouncements.append(text) }
    }

    /// Says a failure aloud (and shows it). Used for failures outside a reply: recognizer, microphone.
    /// The same message is spoken once per `tuning.repeatErrorAfterSeconds`; repeats are shown only.
    public func reportFailure(_ message: String) {
        errorSpeech.window = config.tuning.repeatErrorAfterSeconds
        JarvisLog.warn("Failure reported: \(message)", request: trace?.id)
        if errorSpeech.shouldSpeak(message), state == .idle {
            deliver(message)
        } else {
            notch.respond(message, collapseAfter: 6)
        }
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
                                                   "silence_wait_ms": (endpointer.requiredSilence * 1000).rounded()])
        wake.setPaused(false)
        onTurnActive?(false)
        guard !text.isEmpty else {
            trace?.finish(outcome: "no_speech")
            utterance.discard()
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
            utterance.discard()
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
            utterance.discard()
            transcriber.cancel()
            transition(.conversationEnded)
            notch.isFollowUp = false
            notch.collapse()
            return
        }
        lastUserText = text
        startVoiceCheck(utterance.end())
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
        guard !isEnrolling else { JarvisLog.info("Text turn ignored: Voice ID enrollment in progress"); return }
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
        utterance.discard()
        currentVoiceCheck = nil            // typed: there is no voice to check
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
        var chunker = SentenceChunker(firstChunkMinWords: config.tuning.ttsFirstChunkMinWords)
        var firstDelta = true
        var spokeSomething = false
        currentReply = ""

        let request = RequestTrace.current
        // Reply text must be applied in the order it arrives, and before `respond` decides what is
        // left to say. It used to hop through a deferred task, so a fast reply (or an error message)
        // could be checked before it had been applied, and was then spoken twice or out of order.
        let apply: @MainActor (String) -> Void = { [weak self] delta in
            guard let self else { return }
            if firstDelta {
                firstDelta = false
                let ms = Date().timeIntervalSince(self.speechEndedAt) * 1000
                self.lastTurn.endOfSpeechToReplyMs = ms
                request?.event(.intent, "first_token")
                JarvisLog.info(String(format: "End of speech → first reply token %.0f ms", ms), request: request?.id)
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
        let onText: (String) -> Void = { delta in
            if Thread.isMainThread { MainActor.assumeIsolated { apply(delta) } }
            else { DispatchQueue.main.async { MainActor.assumeIsolated { apply(delta) } } }   // the local model streams off the main thread
        }

        var failed = false
        var turn: Brain.Turn
        do {
            // A deadline on the whole request: a stuck model stream or tool can never hang the pipeline.
            let responder = responder
            turn = try await withDeadline("The request", seconds: config.tuning.turnTimeoutSeconds) { @MainActor in
                try await responder(text, onText)
            }
        } catch is CancellationError {
            request?.finish(outcome: "cancelled")
            return
        } catch {
            turn = Brain.Turn()
            let msg = Self.friendly(error)
            turn.text = msg
            // After a timeout, anything already said stays said; add the failure as its own sentence.
            onText(currentReply.isEmpty ? msg : " " + msg)
            failed = true
            if case ClaudeClient.ClientError.noAPIKey = error, SecretVault.shared.usesHelper, SecretVault.shared.state != .unlocked { onKeysNeeded?() }
            request?.event(SpokenFailure.stage(of: error), "error", ["error": String(describing: type(of: error)), "message": String(error.localizedDescription.prefix(200))])
            JarvisLog.error("Brain: \(error.localizedDescription)")
        }
        // Anything streamed from another thread is queued on the main queue; let it land first.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
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
    /// Through the speakers the mic also hears Jarvis, so a little more is needed before it counts.
    nonisolated static func isGenuineInterruption(heard: String, spoken: String, minimumWords: Int = 2) -> Bool {
        guard EchoGuard.words(heard).count >= minimumWords else { return false }
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
        SpokenFailure.message(for: error)
    }

    // MARK: Tier 2 approval

    /// Called by the dispatcher. Shows the card, asks aloud, and listens for yes/no (12 s).
    public func requestApproval(_ request: ApprovalRequest) async -> Bool {
        if let p = pendingApproval { pendingApproval = nil; p.continuation.resume(returning: false) }
        if remote != nil { return await requestRemoteApproval(request) }
        // Whose voice asked for this? With Voice ID on, a spoken "yes" only counts from the enrolled voice.
        let gate = await voiceGate()
        if case .refuse(let why) = gate {
            JarvisLog.warn("Approval refused, voice not verified: \(request.preview)", request: trace?.id)
            trace?.event(.action, "approval_refused", ["reason": "voice_not_verified"])
            if modes.current.voice.enabled && !voiceMuted {
                speech.enqueue(why, volume: Float(modes.current.voice.volume), rate: Float(config.profile.assistant.speechRate))
            }
            notch.appendReply(" " + why)
            return false
        }
        approvalGate = gate
        toldAboutButton = false
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
                let prompt: String
                if case .buttonOnly(let why) = gate { prompt = "\(why): \(Self.spoken(request))." }
                else { prompt = "Approve: \(Self.spoken(request))? Say yes or no." }
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
        guard let answer = Self.approvalAnswer(text) else { return }
        if !answer {
            resolveApproval(id: p.request.id, approved: false, reason: "voice")
        } else {
            guard approvalGate.acceptsSpokenYes else {
                // Voice ID is on and this request was not verified: a spoken yes is not enough.
                if !toldAboutButton {
                    toldAboutButton = true
                    JarvisLog.info("Spoken yes ignored: voice not verified", request: trace?.id)
                    notch.transcript = "Voice not verified. Use the Approve button."
                }
                return
            }
            resolveApproval(id: p.request.id, approved: true, reason: "voice")
        }
    }

    /// Reads a spoken answer to an approval: true for yes, false for no, nil when it is neither.
    /// Any "no" word wins over a "yes" word in the same breath.
    nonisolated static func approvalAnswer(_ text: String) -> Bool? {
        let cleaned = text.lowercased().map { $0.isLetter || $0 == "'" || $0 == "’" ? $0 : " " }
        let words = Set(String(cleaned).replacingOccurrences(of: "’", with: "'").split(separator: " ").map(String.init))
        if !words.isDisjoint(with: ["no", "nope", "deny", "cancel", "don't", "dont", "stop"]) { return false }
        if !words.isDisjoint(with: ["yes", "yeah", "yep", "approve", "approved", "go", "ok", "okay", "sure", "do"]) { return true }
        return nil
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

    // MARK: Remote turns (no screen, no speaker)

    /// A request that came in over the remote API. It runs through the same intent and action stages as a
    /// spoken one, but nothing is shown or said on the Mac: the reply goes back to the caller.
    ///
    /// One request at a time, shared with the local pipeline: if Jarvis is busy at the Mac, a remote
    /// request is told so, and the wake word is ignored while a remote request is running.
    public func remoteAsk(_ text: String, voice: VoiceCheck?) async -> RemoteTurnResult {
        guard state == .idle, !isEnrolling, remote == nil else { return RemoteTurnResult(status: .busy) }
        turn += 1
        lastTurn = TurnStats(transcript: text)
        speechEndedAt = Date()
        let request = beginRequest(source: "remote")
        request.event(.transcribed, "speech_end", ["reason": voice == nil ? "remote_typed" : "remote_audio", "chars": text.count])
        if let voice, voice.isEnforced {
            var fields: [String: Any] = ["outcome": voice.outcome.rawValue, "seconds": (voice.seconds * 10).rounded() / 10]
            if let s = voice.score { fields["score"] = (s * 100).rounded() / 100 }
            request.event(.transcribed, "voice_id", fields)
            request.set("speaker", fields)
        }
        utterance.discard()
        currentVoiceCheck = nil
        transition(.typed)
        remote = RemoteTurn(request: request, voice: voice)
        return await withCheckedContinuation { cont in
            remote?.waiter = cont
            replyTask?.cancel()
            replyTask = Task { [weak self] in
                await RequestTrace.$current.withValue(request) { await self?.respondRemote(to: text) }
            }
        }
    }

    /// Answers the approval a remote request is waiting on. Nil when nothing is waiting under that id
    /// (it was answered, it timed out, or the request was stopped at the Mac).
    public func remoteDecide(id: UUID, approved: Bool) async -> RemoteTurnResult? {
        guard remote != nil, remote?.waiter == nil, let p = pendingApproval, p.request.id == id else { return nil }
        return await withCheckedContinuation { cont in
            remote?.waiter = cont
            resolveApproval(id: id, approved: approved, reason: "remote")
        }
    }

    /// True while a remote request is running or waiting for its approval.
    public var remoteTurnActive: Bool { remote != nil }

    private struct RemoteTurn {
        let request: RequestTrace
        let voice: VoiceCheck?
        var streamed = ""
        var notes: [String] = []
        var waiter: CheckedContinuation<RemoteTurnResult, Never>?
    }
    private var remote: RemoteTurn?

    private func respondRemote(to text: String) async {
        lastUserText = text
        guard let request = remote?.request else { return }
        var firstDelta = true
        let apply: @MainActor (String) -> Void = { [weak self] delta in
            guard let self, self.remote?.request === request else { return }
            if firstDelta {
                firstDelta = false
                request.event(.intent, "first_token")
            }
            self.remote?.streamed += delta
        }
        let onText: (String) -> Void = { delta in
            if Thread.isMainThread { MainActor.assumeIsolated { apply(delta) } }
            else { DispatchQueue.main.async { MainActor.assumeIsolated { apply(delta) } } }
        }
        var failed = false
        var cancelled = false
        var turn = Brain.Turn()
        do {
            let responder = responder
            turn = try await withDeadline("The request", seconds: config.tuning.turnTimeoutSeconds) { @MainActor in
                try await responder(text, onText)
            }
        } catch is CancellationError {
            cancelled = true
        } catch {
            turn.text = Self.friendly(error)
            failed = true
            if case ClaudeClient.ClientError.noAPIKey = error, SecretVault.shared.usesHelper, SecretVault.shared.state != .unlocked { onKeysNeeded?() }
            request.event(SpokenFailure.stage(of: error), "error", ["error": String(describing: type(of: error)), "message": String(error.localizedDescription.prefix(200))])
            JarvisLog.error("Brain (remote): \(error.localizedDescription)", request: request.id)
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { c.resume() } }
        guard remote?.request === request else { return }
        // Stopped at the Mac (the menu, the close button) while it was running.
        if Task.isCancelled || state == .idle { cancelled = true }
        var reply = turn.text.isEmpty ? (remote?.streamed ?? "") : turn.text
        if failed, let said = remote?.streamed, !said.isEmpty, said != reply { reply = said + " " + reply }
        for note in remote?.notes ?? [] where !reply.contains(note) { reply += (reply.isEmpty ? "" : " ") + note }
        if reply.isEmpty, !cancelled { reply = "Done." }
        if !cancelled {
            request.event(.intent, "llm_done", ["engine": turn.engine, "chars": reply.count])
            request.set("engine", turn.engine)
            request.set("tokens", ["in": turn.inputTokens, "out": turn.outputTokens, "cache_read": turn.cacheReadTokens, "cache_write": turn.cacheWriteTokens])
            lastTurn.toolCalls = turn.toolCalls
            lastTurn.tokens = (turn.inputTokens, turn.outputTokens)
            JarvisLog.info("Remote turn done: engine=\(turn.engine) tools=\(turn.toolCalls) tokens in/out=\(turn.inputTokens)/\(turn.outputTokens)", request: request.id)
            notch.logExchange(you: text, jarvis: reply)
            JarvisLog.conversation(you: text, jarvis: reply, tools: turn.toolCalls)
            request.event(.spoken, "returned", ["voice": false])
        }
        request.finish(outcome: cancelled ? "cancelled" : failed ? "error" : "returned")
        let waiter = remote?.waiter
        remote = nil
        if state != .idle { transition(.replyFinished) }
        waiter?.resume(returning: RemoteTurnResult(status: cancelled ? .cancelled : .done, requestID: request.id, text: reply, tools: turn.toolCalls, failed: failed))
    }

    /// Why a remote request may not go ahead with something that needs approval, or nil when it may ask.
    /// Nobody is at the Mac to press the button, so the voice is the only proof of who is asking: Voice ID
    /// must be set up and the request itself must have been spoken in the enrolled voice.
    nonisolated static func remoteApprovalRefusal(enrolled: Bool, voice: VoiceCheck?) -> String? {
        guard enrolled else { return "I only do that remotely for a voice I can verify, and Voice ID isn't set up yet. Ask me again at the Mac." }
        guard let voice else { return "That was typed, and I only do that remotely when I can verify your voice." }
        if voice.isVerified { return nil }
        switch voice.outcome {
        case .tooShort: return "I didn't hear enough to be sure it's you, so I won't do that remotely."
        case .unavailable: return "I can't check your voice right now, so I won't do that remotely."
        default: return "I couldn't verify your voice, so I won't do that remotely."
        }
    }

    private func requestRemoteApproval(_ request: ApprovalRequest) async -> Bool {
        if let why = Self.remoteApprovalRefusal(enrolled: voiceID?.isEnrolled ?? false, voice: remote?.voice) {
            JarvisLog.warn("Remote approval refused: \(request.preview) (\(why))", request: trace?.id)
            trace?.event(.action, "approval_refused", ["reason": "remote_voice_not_verified"])
            remote?.notes.append(why)
            return false
        }
        let timeout = max(5, config.tuning.remoteApprovalTimeoutSeconds)
        return await withCheckedContinuation { cont in
            pendingApproval = (request, cont)
            transition(.approvalNeeded)
            approvalGate = .voiceOrButton
            approvalTimeout?.cancel()
            approvalTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.resolveApproval(id: request.id, approved: false, reason: "timeout")
            }
            trace?.event(.action, "approval_asked", ["where": "remote"])
            // Hand the caller its answer now. The request itself stays parked until `remoteDecide`.
            let said = remote?.streamed.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt = "Approve: \(Self.spoken(request))? Say yes or no."
            let waiter = remote?.waiter
            remote?.waiter = nil
            waiter?.resume(returning: RemoteTurnResult(status: .needsApproval, requestID: trace?.id ?? "", text: said.isEmpty ? prompt : said + " " + prompt,
                                                       approvalID: request.id, approvalPrompt: request.preview, approvalExpiresIn: timeout))
        }
    }

    // MARK: Audio routing (capture queue)

    private nonisolated func forwardAudio(_ chunk: [Float]) {
        transcriber.append(samples: chunk)
        extraAudioTap?(chunk)
        utterance.feed(chunk)
        enrollmentTap?(chunk)
    }

    // MARK: Voice ID

    /// Checks the request's audio against the enrolled voice, off the main thread. The audio is dropped afterwards.
    private func startVoiceCheck(_ audio: [Float]) {
        guard let voiceID else { currentVoiceCheck = nil; return }
        let request = trace
        currentVoiceCheck = Task.detached(priority: .userInitiated) { [weak self] in
            let started = Date()
            let check = voiceID.verify(audio)
            let ms = (Date().timeIntervalSince(started) * 1000).rounded()
            if check.isEnforced {
                var fields: [String: Any] = ["outcome": check.outcome.rawValue, "seconds": (check.seconds * 10).rounded() / 10, "ms": ms]
                if let s = check.score { fields["score"] = (s * 100).rounded() / 100 }
                request?.event(.transcribed, "voice_id", fields)
                request?.set("speaker", fields)
                JarvisLog.info("Voice ID: \(check.outcome.rawValue)" + (check.score.map { String(format: " (score %.2f)", $0) } ?? "") + String(format: ", %.1f s of speech", check.seconds), request: request?.id)
            }
            await self?.noteVoiceCheck(check)
            return check
        }
    }

    private func noteVoiceCheck(_ check: VoiceCheck) { lastVoiceCheck = check }

    private func voiceGate() async -> VoiceGate {
        guard let voiceID, voiceID.isEnrolled else { return .voiceOrButton }
        let check = await currentVoiceCheck?.value
        return VoiceGate.decide(check: check, enrolled: true, policy: config.tuning.unverifiedVoiceApproval)
    }
}

extension ConversationController: EnrollmentHost {
    public func beginEnrollment() -> Bool {
        guard state == .idle, !isEnrolling else { return false }
        isEnrolling = true
        transcriber.cancel()
        wake.setPaused(true)
        notch.cancelCollapse()
        return true
    }

    public func endEnrollment() {
        enrollmentTap = nil
        isEnrolling = false
        wake.setPaused(false)
        notch.scheduleCollapse(after: 5)
    }

    public func say(_ text: String) async {
        notch.respond(text, cards: [], collapseAfter: 180)
        let voiceOn = modes.current.voice.enabled && !voiceMuted
        guard voiceOn else { try? await Task.sleep(for: .seconds(1.5)); return }
        currentReply = text
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            speech.speak(text, volume: Float(modes.current.voice.volume), rate: Float(config.profile.assistant.speechRate)) { _ in cont.resume() }
        }
        lastSpokeAt = Date()
        // Let the room go quiet, so Jarvis's own voice never ends up in the voiceprint.
        try? await Task.sleep(for: .milliseconds(Int(max(350, config.tuning.followUpGuardMilliseconds))))
    }

    public func show(title: String, text: String) {
        notch.respond("\(title)\n\(text)", cards: [], collapseAfter: 180)
    }

    public func tone() async {
        NSSound(named: "Tink")?.play()
        try? await Task.sleep(for: .milliseconds(350))     // the tone itself must not be recorded
    }

    public func listen(_ onChunk: @escaping @Sendable ([Float]) -> Void) -> () -> Void {
        enrollmentTap = onChunk
        return { [weak self] in self?.enrollmentTap = nil }
    }
}

/// What a remote request came to.
public struct RemoteTurnResult: Equatable, Sendable {
    public enum Status: String, Sendable {
        case done
        /// Something needs a yes first. The request is parked until it is answered or times out.
        case needsApproval = "needs_approval"
        /// Jarvis is in the middle of another request.
        case busy
        /// Stopped at the Mac before it finished.
        case cancelled
    }
    public var status: Status
    public var requestID = ""
    public var text = ""
    public var tools: [String] = []
    /// The reply is an error message.
    public var failed = false
    public var approvalID: UUID?
    public var approvalPrompt: String?
    public var approvalExpiresIn: Double?

    public init(status: Status, requestID: String = "", text: String = "", tools: [String] = [], failed: Bool = false,
                approvalID: UUID? = nil, approvalPrompt: String? = nil, approvalExpiresIn: Double? = nil) {
        self.status = status; self.requestID = requestID; self.text = text; self.tools = tools; self.failed = failed
        self.approvalID = approvalID; self.approvalPrompt = approvalPrompt; self.approvalExpiresIn = approvalExpiresIn
    }
}
