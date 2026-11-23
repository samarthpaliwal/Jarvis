import Foundation

/// Tier 1: Voice ID status, setup, and removal. Changing or removing an existing voiceprint asks first.
public final class VoiceIDTool: JarvisTool {
    public let name = "voice_id"
    public let description = "Voice ID checks that a spoken request comes from Sam before anything that needs approval. status: whether it is set up and how the last request scored. enroll: start the guided setup (Sam reads five sentences); it begins after you finish speaking. forget: delete the voiceprint and turn Voice ID off. Only when Sam asks."
    public let tier = Tier.free
    public let userOnly = true
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["action": ["type": "string", "enum": ["status", "enroll", "forget"]]],
        "required": ["action"], "additionalProperties": false,
    ]
    private let verifier: SpeakerVerifier
    private let lastCheck: @MainActor () -> VoiceCheck?
    private let startEnrollment: @MainActor () -> Void

    public init(verifier: SpeakerVerifier, lastCheck: @escaping @MainActor () -> VoiceCheck?, startEnrollment: @escaping @MainActor () -> Void) {
        self.verifier = verifier; self.lastCheck = lastCheck; self.startEnrollment = startEnrollment
    }

    public func preview(for input: JSONObject) -> String { "voice ID \(input.string("action") ?? "")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        switch input.string("action") ?? "status" {
        case "status":
            guard let print = verifier.voiceprint else { return ToolResult("Voice ID is not set up. Sam can say \"set up Voice ID\" or use the menu.") }
            var s = String(format: "Voice ID is on: %d recordings, set up %@. A request counts as Sam at a score of %.2f or more.", print.samples,
                           DateFormatter.localizedString(from: print.createdAt, dateStyle: .medium, timeStyle: .none), verifier.threshold)
            if let c = await lastCheck(), let score = c.score { s += String(format: " The last spoken request scored %.2f (%@).", score, c.outcome.rawValue) }
            return ToolResult(s)
        case "enroll":
            // Replacing the voiceprint is how someone else would take over the gate: it needs a yes.
            if verifier.isEnrolled {
                guard await ToolDispatcher.confirm("Replace the Voice ID voiceprint with a new recording") else {
                    return .error("Sam did not approve replacing the voiceprint. Nothing changed.")
                }
            }
            await startEnrollment()
            return ToolResult("The guided setup starts as soon as you finish speaking. Say one short sentence telling Sam to read each line after the tone, then stop.",
                              summary: "Voice ID setup starting")
        case "forget":
            guard verifier.isEnrolled else { return ToolResult("Voice ID is not set up, so there is nothing to forget.") }
            guard await ToolDispatcher.confirm("Delete the Voice ID voiceprint and turn Voice ID off") else {
                return .error("Sam did not approve deleting the voiceprint. Nothing changed.")
            }
            verifier.forget()
            return ToolResult("The voiceprint is deleted and Voice ID is off.", summary: "Voice ID turned off")
        default:
            return .error("action must be status, enroll, or forget")
        }
    }
}
