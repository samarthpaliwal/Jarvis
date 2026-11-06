import Foundation

/// Runs AppleScript in-process (NSAppleScript, main thread). macOS asks once per target app:
/// "Jarvis wants to control Spotify" (System Settings → Privacy & Security → Automation).
public enum AppleScriptRunner {
    public struct ScriptError: LocalizedError {
        public let code: Int
        public let message: String
        public var errorDescription: String? {
            if code == -1743 { return "Jarvis isn't allowed to control that app. System Settings → Privacy & Security → Automation → Jarvis, and turn it on." }
            if code == -600 { return "That app isn't running." }
            return "AppleScript error \(code): \(message)"
        }
    }

    @MainActor
    public static func run(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else { throw ScriptError(code: -1, message: "couldn't compile") }
        var err: NSDictionary?
        let out = script.executeAndReturnError(&err)
        if let err {
            throw ScriptError(code: (err[NSAppleScript.errorNumber] as? Int) ?? -1, message: (err[NSAppleScript.errorMessage] as? String) ?? "")
        }
        return out.stringValue ?? ""
    }

    /// Escapes a value for use inside an AppleScript string literal.
    public static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
