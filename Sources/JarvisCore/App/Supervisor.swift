import AppKit
import Foundation

/// Keeps Jarvis running: a launchd agent that starts it at login and restarts it after a crash.
///
/// The agent lives at `~/Library/LaunchAgents/com.samarth.jarvis.plist`. launchd restarts the process only
/// when it exits abnormally (a crash, a kill). Quitting from the menu, or `kill` without `-9`, is a clean
/// exit and stays quit. A crash loop is stopped from inside: after too many starts in a short time, Jarvis
/// exits cleanly so launchd leaves it alone.
public enum Supervisor {
    public static let label = "com.samarth.jarvis"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    public static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    /// The agent definition. Pure, so the tests can check every key.
    public static func plist(executable: String, logDirectory: String, throttleSeconds: Int = 10) -> [String: Any] {
        [
            "Label": label,
            "ProgramArguments": [executable],
            // Start at login.
            "RunAtLoad": true,
            // Restart after a crash or a kill, but not after a normal quit (exit code 0).
            "KeepAlive": ["SuccessfulExit": false],
            // Never restart more often than this.
            "ThrottleInterval": throttleSeconds,
            // A foreground app with a UI: only in the logged-in graphical session, at normal priority.
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "AssociatedBundleIdentifiers": [label],
            // Anything printed before logging starts (a crash at launch) lands here.
            "StandardOutPath": logDirectory + "/launchd.out.log",
            "StandardErrorPath": logDirectory + "/launchd.err.log",
        ]
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        p.waitUntilExit()
        return (p.terminationStatus, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }

    static var domain: String { "gui/\(getuid())" }

    /// True when launchd currently knows the agent.
    public static var isLoaded: Bool { launchctl(["print", "\(domain)/\(label)"]).status == 0 }

    /// What launchd says about the agent right now.
    public struct AgentState: Equatable, Sendable {
        public var loaded: Bool
        /// The process launchd is running for the agent, if it is running one.
        public var pid: Int32?
        /// The program the agent starts.
        public var program: String?
        public init(loaded: Bool, pid: Int32? = nil, program: String? = nil) { self.loaded = loaded; self.pid = pid; self.program = program }
    }

    public static var agentState: AgentState {
        let r = launchctl(["print", "\(domain)/\(label)"])
        return r.status == 0 ? parseAgentState(r.output) : AgentState(loaded: false)
    }

    /// Reads the top-level `pid = …` and `program = …` lines of `launchctl print`.
    static func parseAgentState(_ output: String) -> AgentState {
        var state = AgentState(loaded: true)
        for line in output.split(separator: "\n") where line.hasPrefix("\t") && !line.hasPrefix("\t\t") {
            let parts = line.dropFirst().components(separatedBy: " = ")
            guard parts.count == 2 else { continue }
            if parts[0] == "pid" { state.pid = Int32(parts[1]) }
            if parts[0] == "program" { state.program = parts[1] }
        }
        return state
    }

    /// A copy opened by hand (double-click, `open`) while the agent is loaded but running nothing is not
    /// supervised: launchd would neither restart it after a crash nor replace it on `scripts/run.sh`.
    /// Such a copy should step aside and let launchd start the agent's copy instead.
    public static func shouldHandOver(agent: AgentState, myProgram: String) -> Bool {
        guard agent.loaded, agent.pid == nil, let program = agent.program else { return false }
        return URL(fileURLWithPath: program).resolvingSymlinksInPath().path == URL(fileURLWithPath: myProgram).resolvingSymlinksInPath().path
    }

    /// Asks launchd to start the agent a moment from now, after this copy has exited.
    static func startAgentSoon() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /bin/launchctl kickstart \(domain)/\(label)"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    /// Writes the agent and hands it to launchd. `executable` is the binary inside Jarvis.app.
    public static func install(executable: String, start: Bool) throws {
        let logs = FileLog.directory.path
        let data = try PropertyListSerialization.data(fromPropertyList: plist(executable: executable, logDirectory: logs), format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if isLoaded { launchctl(["bootout", "\(domain)/\(label)"]) }
        try data.write(to: plistURL, options: .atomic)
        guard start else { return }
        let r = launchctl(["bootstrap", domain, plistURL.path])
        guard r.status == 0 else {
            throw NSError(domain: "Jarvis.Supervisor", code: Int(r.status), userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(r.output.trimmingCharacters(in: .whitespacesAndNewlines))"])
        }
    }

    public static func uninstall() {
        if isLoaded { launchctl(["bootout", "\(domain)/\(label)"]) }
        try? FileManager.default.removeItem(at: plistURL)
    }

    // MARK: Inside the running app

    /// More than `limit` starts within `window` seconds means Jarvis is crashing at launch.
    public static func isCrashLooping(launches: [Date], now: Date = Date(), limit: Int = 5, window: TimeInterval = 120) -> Bool {
        launches.filter { now.timeIntervalSince($0) < window }.count > limit
    }

    private static let launchesKey = "jarvis.supervisor.launches"
    private static let cleanExitKey = "jarvis.supervisor.cleanExit"

    /// Call first thing at launch. Returns what the app should know about how it got here.
    public static func noteLaunch(defaults: UserDefaults = .standard, now: Date = Date()) -> (crashLooping: Bool, afterUncleanExit: Bool) {
        var launches = (defaults.array(forKey: launchesKey) as? [Date] ?? []).filter { now.timeIntervalSince($0) < 600 }
        launches.append(now)
        defaults.set(launches, forKey: launchesKey)
        // The key is absent on the very first launch: that is not a crash.
        let unclean = defaults.object(forKey: cleanExitKey) != nil && !defaults.bool(forKey: cleanExitKey)
        defaults.set(false, forKey: cleanExitKey)
        return (isCrashLooping(launches: launches, now: now), unclean)
    }

    /// Call when quitting normally.
    public static func noteCleanExit(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: cleanExitKey)
        defaults.synchronize()
    }

    /// Another copy of Jarvis is already running (the login item and the agent can both start one).
    public static var anotherInstanceIsRunning: Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: label).contains { $0.processIdentifier != me && !$0.isTerminated }
    }

    /// Handles `Jarvis --install-agent | --uninstall-agent | --agent-status` and exits. No UI, no permissions.
    public static func handleCommandLine(_ args: [String] = CommandLine.arguments) {
        guard let command = args.dropFirst().first(where: { $0.hasPrefix("--") && $0.contains("agent") }) else { return }
        let executable = URL(fileURLWithPath: args[0]).standardizedFileURL.resolvingSymlinksInPath().path
        switch command {
        case "--install-agent", "--install-agent-no-start":
            do {
                try install(executable: executable, start: command == "--install-agent")
                print("Installed \(plistURL.path)\n  program: \(executable)")
                exit(0)
            } catch { print("Install failed: \(error.localizedDescription)"); exit(1) }
        case "--uninstall-agent":
            uninstall(); print("Removed \(plistURL.path)"); exit(0)
        case "--agent-status":
            print("installed: \(isInstalled)  loaded: \(isLoaded)  plist: \(plistURL.path)"); exit(0)
        default:
            print("Unknown option \(command). Use --install-agent, --uninstall-agent, or --agent-status."); exit(2)
        }
    }
}
