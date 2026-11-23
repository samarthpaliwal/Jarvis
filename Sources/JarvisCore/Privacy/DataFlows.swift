import Foundation

/// One thing Jarvis does with your data, and whether it stays on this Mac.
public struct DataFlow: Equatable, Sendable {
    public enum Kind: String, Sendable { case audio, image, text }
    public var stage: String
    public var kind: Kind
    public var what: String
    /// Where it goes. "This Mac" when it does not leave.
    public var destination: String
    public var leavesMac: Bool
    /// When it happens ("every request", "only when you ask Jarvis to look").
    public var when: String

    public var line: String { leavesMac ? "\(stage): \(what) → \(destination) (\(when))" : "\(stage): \(what) stays on this Mac" }
}

/// The settings and state that decide where data goes.
public struct PrivacySnapshot: Equatable, Sendable {
    public var transcriber: String
    /// The recognizer in use would send audio to Apple's servers.
    public var transcriberUsesServer: Bool
    /// "kokoro", "elevenlabs", "openai", or "apple".
    public var voiceEngine: String
    public var claudeConfigured: Bool
    /// The hosted second brain in use (its model name), or nil when it has no key.
    public var hostedModel: String?
    /// Private Mode: thinking happens on this Mac only.
    public var privateMode: Bool
    public var googleConnected: Bool
    public var notionConnected: Bool
    public var spotifyConnected: Bool
    public var goveeConnected: Bool = false
    public var remoteListening: Bool
    public var voiceIDEnrolled: Bool
    public init(transcriber: String, transcriberUsesServer: Bool, voiceEngine: String, claudeConfigured: Bool, hostedModel: String? = nil, privateMode: Bool = false, googleConnected: Bool,
                notionConnected: Bool, spotifyConnected: Bool, goveeConnected: Bool = false, remoteListening: Bool, voiceIDEnrolled: Bool) {
        self.transcriber = transcriber; self.transcriberUsesServer = transcriberUsesServer; self.voiceEngine = voiceEngine
        self.claudeConfigured = claudeConfigured; self.hostedModel = hostedModel; self.privateMode = privateMode; self.googleConnected = googleConnected; self.notionConnected = notionConnected
        self.spotifyConnected = spotifyConnected; self.goveeConnected = goveeConnected; self.remoteListening = remoteListening; self.voiceIDEnrolled = voiceIDEnrolled
    }
}

/// Local-first, written down: every stage, what it handles, and where that goes with the current settings.
/// The menu (Privacy) and the startup log show this list, so "what leaves my Mac" always has a current answer.
public enum Privacy {
    public static func flows(_ s: PrivacySnapshot) -> [DataFlow] {
        var out: [DataFlow] = [
            DataFlow(stage: "Wake word", kind: .audio, what: "microphone audio", destination: "This Mac", leavesMac: false, when: "always"),
            s.transcriberUsesServer
                ? DataFlow(stage: "Speech recognition", kind: .audio, what: "the audio of each request", destination: "Apple", leavesMac: true, when: "every spoken request")
                : DataFlow(stage: "Speech recognition", kind: .audio, what: "the audio of each request", destination: "This Mac", leavesMac: false, when: "always"),
            DataFlow(stage: "Voice ID", kind: .audio, what: "your voiceprint and each request's audio", destination: "This Mac", leavesMac: false, when: "always"),
        ]
        if s.remoteListening {
            out.append(DataFlow(stage: "Remote access", kind: .audio, what: "recordings from your phone", destination: "This Mac, over your tailnet", leavesMac: false, when: "always"))
        }
        if s.privateMode {
            out.append(DataFlow(stage: "Thinking", kind: .text, what: "your request and the conversation (Private Mode: local model)", destination: "This Mac", leavesMac: false, when: "always"))
        }
        if let model = s.hostedModel, !s.privateMode {
            out.append(DataFlow(stage: "Thinking (\(model))", kind: .text, what: "your request as text, the conversation so far, and what tools returned",
                                destination: "Ollama", leavesMac: true, when: "when it is the chosen brain, or when Claude cannot answer"))
        }
        if s.claudeConfigured, !s.privateMode {
            out.append(DataFlow(stage: "Thinking", kind: .text, what: "your request as text, the conversation so far, and what tools returned (calendar, email, notes you asked about)",
                                destination: "Anthropic", leavesMac: true, when: "every request"))
            out.append(DataFlow(stage: "Looking", kind: .image, what: "one camera frame or screenshot", destination: "Anthropic", leavesMac: true, when: "only when you ask Jarvis to look"))
            out.append(DataFlow(stage: "Web search", kind: .text, what: "search queries and page addresses", destination: "Anthropic", leavesMac: true, when: "only when a request needs the web"))
        }
        switch s.voiceEngine {
        case "elevenlabs": out.append(DataFlow(stage: "Speaking", kind: .text, what: "the text of each reply", destination: "ElevenLabs", leavesMac: true, when: "every spoken reply"))
        case "openai": out.append(DataFlow(stage: "Speaking", kind: .text, what: "the text of each reply", destination: "OpenAI", leavesMac: true, when: "every spoken reply"))
        default: out.append(DataFlow(stage: "Speaking", kind: .text, what: "the text of each reply", destination: "This Mac", leavesMac: false, when: "always"))
        }
        if s.googleConnected { out.append(DataFlow(stage: "Gmail", kind: .text, what: "searches, and drafts or emails you approve", destination: "Google", leavesMac: true, when: "only when you ask about email")) }
        if s.notionConnected { out.append(DataFlow(stage: "Notion", kind: .text, what: "searches and pages you ask for", destination: "Notion", leavesMac: true, when: "only when you ask about notes")) }
        if s.goveeConnected { out.append(DataFlow(stage: "Lights", kind: .text, what: "light commands (on, off, colour)", destination: "Govee", leavesMac: true, when: "only when you ask for the lights")) }
        if s.spotifyConnected { out.append(DataFlow(stage: "Music", kind: .text, what: "song searches", destination: "Spotify", leavesMac: true, when: "only when you ask for music")) }
        out.append(DataFlow(stage: "Weather", kind: .text, what: "your city", destination: "Open-Meteo", leavesMac: true, when: "briefings and weather questions"))
        return out
    }

    /// The question item 21 asks: does any stage send audio off this Mac?
    public static func audioLeavingMac(_ flows: [DataFlow]) -> [DataFlow] { flows.filter { $0.kind == .audio && $0.leavesMac } }

    public static func summary(_ flows: [DataFlow]) -> String {
        let audio = audioLeavingMac(flows)
        let away = flows.filter(\.leavesMac).map(\.destination)
        let places = away.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return (audio.isEmpty ? "No audio leaves this Mac." : "AUDIO LEAVES THIS MAC: \(audio.map(\.stage).joined(separator: ", ")).")
            + (places.isEmpty ? " Nothing else does either." : " Text or images go to: \(places.joined(separator: ", ")).")
    }
}
