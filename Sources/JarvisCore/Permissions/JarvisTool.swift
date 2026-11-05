import Foundation

/// JSON-ish value passed between Claude and tools.
public typealias JSONObject = [String: Any]

/// What a tool call touches, so the dispatcher can run denylist / allowed-folder checks
/// before anything executes.
public struct ToolTargets: Equatable, Sendable {
    public var paths: [String] = []
    public var apps: [String] = []
    public var shellCommand: String? = nil
    public init(paths: [String] = [], apps: [String] = [], shellCommand: String? = nil) {
        self.paths = paths; self.apps = apps; self.shellCommand = shellCommand
    }
}

public struct ToolResult: Sendable {
    /// Text handed back to Claude.
    public var content: String
    /// One line spoken/shown to Sam after Tier 1 actions ("Moved 14 files…").
    public var summary: String?
    /// Optional card for the notch.
    public var card: NotchCard?
    public var isError: Bool

    public init(_ content: String, summary: String? = nil, card: NotchCard? = nil, isError: Bool = false) {
        self.content = content; self.summary = summary; self.card = card; self.isError = isError
    }
    public static func error(_ message: String) -> ToolResult { ToolResult(message, isError: true) }
}

/// Everything a tool may need. Tools never get the Keychain, the API key, or raw config files.
@MainActor
public struct ToolContext {
    public let config: ConfigStore
    public let modes: ModeManager
    public let undo: UndoStack
    public let notch: NotchViewModel
    public init(config: ConfigStore, modes: ModeManager, undo: UndoStack, notch: NotchViewModel) {
        self.config = config; self.modes = modes; self.undo = undo; self.notch = notch
    }
}

/// One tool = one small file. Declare the tier and schema; the dispatcher does the rest.
public protocol JarvisTool: AnyObject {
    var name: String { get }
    var description: String { get }
    var tier: Tier { get }
    /// JSON Schema for `input` (object). Keep it tight; Claude follows it.
    var inputSchema: JSONObject { get }
    /// What this call will touch, derived from the input. Checked before approval and execution.
    func targets(for input: JSONObject) -> ToolTargets
    /// Human sentence shown in the approval card ("Run `rm -rf ~/Library/Caches/foo`").
    func preview(for input: JSONObject) -> String
    func run(input: JSONObject, context: ToolContext) async throws -> ToolResult
}

public extension JarvisTool {
    func targets(for input: JSONObject) -> ToolTargets { ToolTargets() }
    func preview(for input: JSONObject) -> String {
        let args = input.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", ")
        return "\(name)(\(args))"
    }
    /// Claude-facing definition.
    var definition: JSONObject {
        ["name": name, "description": description, "input_schema": inputSchema]
    }
}

/// Helpers for reading tool input safely.
public extension Dictionary where Key == String, Value == Any {
    func string(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? { (self[k] as? Int) ?? (self[k] as? Double).map(Int.init) ?? (self[k] as? String).flatMap(Int.init) }
    func double(_ k: String) -> Double? { (self[k] as? Double) ?? (self[k] as? Int).map(Double.init) ?? (self[k] as? String).flatMap(Double.init) }
    func bool(_ k: String) -> Bool? { (self[k] as? Bool) ?? (self[k] as? String).map { $0 == "true" } }
    func stringArray(_ k: String) -> [String]? { self[k] as? [String] }
}

/// Wraps text that came from outside (email, web, files, calendar) so Claude treats it as data.
public enum Untrusted {
    public static func wrap(_ text: String, source: String) -> String {
        let clean = text.replacingOccurrences(of: "</untrusted_content>", with: "</untrusted content>")
        return "<untrusted_content source=\"\(source)\">\n\(clean)\n</untrusted_content>"
    }
}
