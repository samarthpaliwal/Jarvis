import Foundation

/// Where the voice pipeline is right now.
public enum PipelineState: String, CaseIterable, Sendable {
    case idle               // waiting for the wake word
    case listening          // heard: microphone → text
    case thinking           // transcribed: Claude is deciding, or tools are running
    case speaking           // the reply is being spoken
    case awaitingApproval   // a Tier 2 action is waiting for yes / no
}

/// Everything that can move the pipeline from one state to another.
/// Each event has one target state and a fixed set of states it may happen in.
public enum PipelineEvent: String, CaseIterable, Sendable {
    // → listening
    case wake               // wake word
    case followUp           // listening again after a reply, no wake word needed
    case bargeIn            // the user talked over the reply
    // → thinking
    case transcribed        // speech ended with text
    case typed              // text turn (menu, debug hook, remote API later)
    case approvalResolved   // yes / no / timeout
    // → speaking
    case replyStarted       // first sentence of the reply
    case announce           // proactive speech outside a request (briefing, timer, mode change)
    // → awaitingApproval
    case approvalNeeded
    // → idle
    case noSpeech           // nothing was said
    case conversationEnded  // "thanks", "that's all"
    case echoDiscarded      // the microphone heard Jarvis, not the user
    case sttFailed          // the recognizer failed
    case replyFinished      // the reply was spoken (or shown, when voice is off)
    case stopped            // "stop", the close button, the menu

    public var target: PipelineState {
        switch self {
        case .wake, .followUp, .bargeIn: return .listening
        case .transcribed, .typed, .approvalResolved: return .thinking
        case .replyStarted, .announce: return .speaking
        case .approvalNeeded: return .awaitingApproval
        case .noSpeech, .conversationEnded, .echoDiscarded, .sttFailed, .replyFinished, .stopped: return .idle
        }
    }

    public var allowedFrom: Set<PipelineState> {
        switch self {
        case .wake: return [.idle, .speaking]                       // waking while Jarvis talks is a barge-in
        case .followUp: return [.idle]
        case .bargeIn: return [.speaking]
        case .transcribed: return [.listening]
        case .typed: return [.idle, .listening, .speaking]          // typing replaces a listen or a reply
        case .approvalResolved: return [.awaitingApproval]
        case .replyStarted: return [.thinking, .speaking]           // more sentences keep it speaking
        case .announce: return [.idle]
        case .approvalNeeded: return Set(PipelineState.allCases)    // a newer request replaces a pending one
        case .noSpeech, .conversationEnded, .echoDiscarded, .sttFailed: return [.listening]
        case .replyFinished: return [.speaking, .thinking]          // thinking → idle when voice is off
        case .stopped: return Set(PipelineState.allCases)
        }
    }
}

/// The transition table. Pure, so it can be tested exhaustively.
public enum PipelineMachine {
    /// The state after `event`, or nil when the event is not legal in `state`.
    public static func next(_ state: PipelineState, on event: PipelineEvent) -> PipelineState? {
        event.allowedFrom.contains(state) ? event.target : nil
    }

    /// The one happy path every answered voice request follows.
    public static let happyPath: [PipelineEvent] = [.wake, .transcribed, .replyStarted, .replyFinished]

    /// Replays events from `start`. Returns the states visited, or nil at the first illegal step.
    public static func run(_ events: [PipelineEvent], from start: PipelineState = .idle) -> [PipelineState]? {
        var state = start
        var visited = [start]
        for e in events {
            guard let n = next(state, on: e) else { return nil }
            state = n
            visited.append(n)
        }
        return visited
    }
}
