import Foundation

// The voice pipeline is five stages. Each one sits behind a small interface, so it can be replaced
// (a different wake engine, a cloud recognizer, another model, a remote speaker) or tested on its own
// with a fake. `ConversationController` wires them together and owns nothing else.
//
//   WakeSource ──▶ Transcriber ──▶ IntentEngine ──▶ ActionRunner ──▶ SpeechOutput
//    (heard)       (transcribed)     (intent)         (action)        (spoken)
//
// Transcriber is declared in STT/Transcriber.swift and SpeechOutput in TTS/SpeechOutput.swift.

/// Stage 1 — wake. Owns the microphone and says when the wake phrase was heard.
/// Implemented by `WakeWordService` (openWakeWord). Later: a phone's mic button over the remote API.
@MainActor
public protocol WakeSource: AnyObject {
    /// Fired when the wake phrase is heard, with the moment of detection.
    var onWake: ((Date) -> Void)? { get set }
    /// Microphone level 0…1, for the waveform.
    var onLevel: ((Float) -> Void)? { get set }
    /// Every 80 ms chunk of 16 kHz mono audio, on the capture queue. Feeds the transcriber.
    nonisolated var audioTap: (([Float]) -> Void)? { get set }
    /// Keep the microphone open but stop detecting (while Jarvis itself is listening to a request).
    func setPaused(_ paused: Bool)
}

/// What stage 3 hands back: the reply, plus what it took to produce it.
public struct Reply {
    public var text = ""
    public var cards: [NotchCard] = []
    public var toolCalls: [String] = []
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
    public var refused = false
    /// "claude", "local", "offline-matcher", or "none".
    public var engine = "claude"

    public init(text: String = "") { self.text = text }
}

/// Stage 3 — intent. Turns what was said into a reply, deciding which actions to run on the way.
/// Implemented by `Brain` (Claude with tools, a local model offline).
@MainActor
public protocol IntentEngine: AnyObject {
    /// `onText` receives the reply as it streams, so speech can start before the reply is complete.
    func respond(to text: String, onText: @escaping (String) -> Void) async throws -> Reply
}

/// The language model behind the intent stage. Implemented by `ClaudeClient`.
public protocol LanguageModel: AnyObject, Sendable {
    func stream(_ request: ClaudeClient.Request) -> AsyncThrowingStream<ClaudeClient.Event, Error>
}

/// Stage 4 — actions. Runs one tool call, after every safety check. Implemented by `ToolDispatcher`.
@MainActor
public protocol ActionRunner: AnyObject {
    /// Tool definitions the model may use in this mode.
    func definitions(for mode: ModeDefinition) -> [JSONObject]
    /// Runs a tool. Never throws: refusals, denials, and failures come back as an error result.
    func call(_ name: String, input: JSONObject, source: ToolCallSource) async -> ToolResult
    /// Logs a tool that ran on the model provider's side (web search).
    func recordServerTool(_ name: String, input: JSONObject)
}

extension WakeWordService: WakeSource {}
extension ClaudeClient: LanguageModel {}
extension ToolDispatcher: ActionRunner {}
extension Brain: IntentEngine {}
