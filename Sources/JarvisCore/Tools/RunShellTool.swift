@preconcurrency import Dispatch
import Foundation

/// Tier 2: run one shell command after Sam approves the exact text. No sudo, ever.
public final class RunShellTool: JarvisTool {
    public let name = "run_shell"
    public let description = "Run a shell command in Sam's home folder (zsh, 30 s timeout, output capped). Sam must approve the exact command first. sudo and destructive commands are refused."
    public let tier = Tier.approve
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "command": ["type": "string"],
            "why": ["type": "string", "description": "One short sentence for the approval card"],
        ],
        "required": ["command"],
        "additionalProperties": false,
    ]

    public init() {}

    public func targets(for input: JSONObject) -> ToolTargets { ToolTargets(shellCommand: input.string("command") ?? "") }

    public func preview(for input: JSONObject) -> String {
        let cmd = input.string("command") ?? ""
        let why = input.string("why").map { " — \($0)" } ?? ""
        return "Run: \(cmd)\(why)"
    }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let cmd = input.string("command"), !cmd.isEmpty else { return .error("command is required") }
        let result = await Sandbox.run(cmd, timeout: 30)
        var text = result.output
        if text.count > 6000 { text = String(text.prefix(6000)) + "\n…(truncated)" }
        let status = result.timedOut ? "timed out after 30 s" : "exit \(result.exitCode)"
        return ToolResult("[\(status)]\n\(text)", summary: "Ran `\(cmd.prefix(60))` (\(status))", isError: result.exitCode != 0 && !result.timedOut)
    }
}

/// Runs commands with a minimal environment, a timeout, and no TTY. Denylist is checked by the dispatcher first.
public enum Sandbox {
    public struct Outcome { public var output: String; public var exitCode: Int32; public var timedOut: Bool }

    public static func run(_ command: String, timeout: TimeInterval, cwd: String = NSHomeDirectory()) async -> Outcome {
        await withCheckedContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", command]
            p.currentDirectoryURL = URL(fileURLWithPath: cwd)
            p.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                             "HOME": NSHomeDirectory(), "LANG": "en_US.UTF-8", "TERM": "dumb", "SUDO_ASKPASS": "/usr/bin/false"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            p.standardInput = FileHandle.nullDevice
            var timedOut = false
            do { try p.run() } catch {
                cont.resume(returning: Outcome(output: error.localizedDescription, exitCode: -1, timedOut: false)); return
            }
            let timer = DispatchWorkItem { if p.isRunning { timedOut = true; p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                timer.cancel()
                cont.resume(returning: Outcome(output: String(decoding: data, as: UTF8.self), exitCode: p.terminationStatus, timedOut: timedOut))
            }
        }
    }
}
