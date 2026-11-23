import AppKit
import Foundation

// MARK: - organize_folder (Tier 1: move only, logged to moves.json, fully undoable)

/// Pure planner: decides where each file goes. Unit-tested.
public enum OrganizePlanner {
    public struct Move: Equatable, Sendable { public var from: String; public var to: String }

    public static let categories: [(folder: String, exts: Set<String>)] = [
        ("Images", ["png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp"]),
        ("Screenshots", []),
        ("Documents", ["pdf", "doc", "docx", "txt", "rtf", "pages", "md", "epub"]),
        ("Spreadsheets", ["xls", "xlsx", "csv", "numbers"]),
        ("Slides", ["ppt", "pptx", "key"]),
        ("Archives", ["zip", "tar", "gz", "7z", "rar", "dmg", "pkg"]),
        ("Code", ["swift", "py", "js", "ts", "java", "c", "cpp", "h", "json", "yaml", "yml", "sh", "ipynb", "html", "css"]),
        ("Audio", ["mp3", "m4a", "wav", "aac", "flac"]),
        ("Video", ["mp4", "mov", "mkv", "avi"]),
        ("Installers", ["app"]),
    ]

    public static func category(for name: String) -> String {
        if name.lowercased().hasPrefix("screenshot") || name.lowercased().hasPrefix("screen recording") { return "Screenshots" }
        let ext = (name as NSString).pathExtension.lowercased()
        return categories.first { $0.exts.contains(ext) }?.folder ?? "Other"
    }

    /// `byDate` puts files in Sorted/<yyyy-MM>/<Category>/ instead of Sorted/<Category>/.
    public static func plan(entries: [(name: String, isDirectory: Bool, modified: Date)], folder: String, sortedName: String, byDate: Bool) -> [Move] {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM"
        return entries.compactMap { e in
            guard !e.isDirectory || e.name.hasSuffix(".app"), !e.name.hasPrefix("."), e.name != sortedName else { return nil }
            let cat = category(for: e.name)
            let dest = byDate ? "\(folder)/\(sortedName)/\(df.string(from: e.modified))/\(cat)/\(e.name)" : "\(folder)/\(sortedName)/\(cat)/\(e.name)"
            return Move(from: "\(folder)/\(e.name)", to: dest)
        }
    }
}

/// Append-only JSON log of every move so "undo that" and the README's audit trail work.
public final class MoveLog: @unchecked Sendable {
    public struct Batch: Codable, Equatable { public var id: String; public var timestamp: Date; public var folder: String; public var moves: [[String]] }
    public let url: URL
    private let q = DispatchQueue(label: "com.samarth.jarvis.movelog")
    public init(url: URL = FileLog.directory.appendingPathComponent("moves.json")) { self.url = url }

    public func append(_ batch: Batch) {
        q.sync {
            var all = (try? JSONDecoder.iso.decode([Batch].self, from: Data(contentsOf: url))) ?? []
            all.append(batch)
            if let data = try? JSONEncoder.iso.encode(all) { try? data.write(to: url) }
        }
    }
}

extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }
extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = .prettyPrinted; return e } }

public final class OrganizeFolderTool: JarvisTool {
    public let name = "organize_folder"
    public let description = "Tidy the Desktop or Downloads: move loose files into <folder>/Sorted/<Category>/ (or by month with by_date). Never deletes. dry_run=true previews. Also flags very large or very old files in Downloads for Sam to review."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["folder": ["type": "string", "description": "~/Desktop or ~/Downloads"], "dry_run": ["type": "boolean"], "by_date": ["type": "boolean"]],
        "required": ["folder"], "additionalProperties": false,
    ]
    private let log: MoveLog
    public init(log: MoveLog) { self.log = log }

    public func targets(for input: JSONObject) -> ToolTargets { ToolTargets(paths: [input.string("folder") ?? ""]) }
    public func preview(for input: JSONObject) -> String { "organize \(input.string("folder") ?? "")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let folderIn = input.string("folder") else { return .error("folder is required") }
        let allowed = await context.config.allowedFolders
        let dg = DenylistGuard(denylist: await context.config.denylist, allowedFolders: allowed)
        try dg.checkAllowedFolder(folderIn, organize: true)
        let folder = dg.normalize(folderIn)
        let fm = FileManager.default
        let urls = try fm.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
        var entries: [(name: String, isDirectory: Bool, modified: Date)] = []
        var flags: [String] = []
        for u in urls {
            let v = try u.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey])
            if (try? dg.checkPath(u.path)) == nil { continue }
            entries.append((u.lastPathComponent, v.isDirectory ?? false, v.contentModificationDate ?? Date()))
            let mb = (v.fileSize ?? 0) / 1_048_576
            let ageDays = Int(Date().timeIntervalSince(v.contentModificationDate ?? Date()) / 86400)
            if mb >= allowed.largeFileMB { flags.append("\(u.lastPathComponent) is \(mb) MB") }
            else if ageDays >= allowed.oldFileDays, !(v.isDirectory ?? false) { flags.append("\(u.lastPathComponent) is \(ageDays) days old") }
        }
        let moves = OrganizePlanner.plan(entries: entries, folder: folder, sortedName: allowed.sortedFolderName, byDate: input.bool("by_date") ?? false)
        let short = moves.prefix(8).map { "\(($0.from as NSString).lastPathComponent) → \(($0.to as NSString).deletingLastPathComponent.replacingOccurrences(of: folder + "/", with: ""))" }
        if input.bool("dry_run") ?? false || moves.isEmpty {
            var text = moves.isEmpty ? "Nothing loose to organize in \(FileSearchTool.tilde(folder))." : "Would move \(moves.count) item(s):\n" + short.joined(separator: "\n")
            if !flags.isEmpty { text += "\nWorth a look: " + flags.prefix(5).joined(separator: "; ") }
            return ToolResult(text, card: .info(title: "Preview", lines: Array(short.prefix(6))))
        }
        var done: [[String]] = []
        for m in moves {
            let dst = URL(fileURLWithPath: m.to)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            var target = dst
            var n = 1
            while fm.fileExists(atPath: target.path) {
                target = dst.deletingLastPathComponent().appendingPathComponent("\(dst.deletingPathExtension().lastPathComponent) \(n).\(dst.pathExtension)")
                n += 1
            }
            do { try fm.moveItem(atPath: m.from, toPath: target.path); done.append([m.from, target.path]) }
            catch { JarvisLog.warn("organize: couldn't move \(m.from): \(error.localizedDescription)") }
        }
        let batch = MoveLog.Batch(id: UUID().uuidString, timestamp: Date(), folder: folder, moves: done)
        log.append(batch)
        let movesDone = done
        await context.undo.push(.init(description: "organized \(FileSearchTool.tilde(folder)) (\(done.count) files)") {
            var back = 0
            for pair in movesDone.reversed() where fm.fileExists(atPath: pair[1]) {
                if (try? fm.moveItem(atPath: pair[1], toPath: pair[0])) != nil { back += 1 }
            }
            return "Put \(back) file(s) back."
        })
        var text = "Moved \(done.count) item(s) into \(allowed.sortedFolderName)/."
        if !flags.isEmpty { text += " Worth a look: " + flags.prefix(5).joined(separator: "; ") + "." }
        return ToolResult(text + " Say undo to put them back.", summary: "Organized \(FileSearchTool.tilde(folder)): \(done.count) files moved",
                          card: .info(title: "Organized", lines: Array(short.prefix(6))))
    }
}

// MARK: - app_health (Tier 0) / restart_app (Tier 2)

public final class AppHealthTool: JarvisTool {
    public let name = "app_health"
    public let description = "Check whether an app or one of Sam's own widgets/apps is running, how much memory it uses, and the last lines of its log file if one exists under ~/Library/Logs/<name>/ or ~/Library/Logs/<name>.log."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"], "additionalProperties": false]
    public init() {}
    public func targets(for input: JSONObject) -> ToolTargets { ToolTargets(apps: [input.string("name") ?? ""]) }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let name = input.string("name") else { return .error("name is required") }
        let running = NSWorkspace.shared.runningApplications.filter { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }
        var lines: [String] = []
        if running.isEmpty { lines.append("\(name) is not running.") }
        for app in running {
            let mem = SystemInfo.topApps(limit: 100).first { $0.pid == app.processIdentifier }?.memoryMB
            lines.append("\(app.localizedName ?? name) running (pid \(app.processIdentifier)\(mem.map { ", \($0) MB" } ?? "")\(app.isFinishedLaunching ? "" : ", still launching"))")
        }
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        for candidate in [logs.appendingPathComponent(name).appendingPathComponent("\(name.lowercased()).log"), logs.appendingPathComponent("\(name).log"), logs.appendingPathComponent(name).appendingPathComponent("stdout.log")] {
            if let text = try? String(contentsOf: candidate, encoding: .utf8) {
                let tail = text.split(separator: "\n").suffix(15).joined(separator: "\n")
                lines.append("Recent log (\(candidate.lastPathComponent)):\n" + Untrusted.wrap(tail, source: "log:\(name)"))
                break
            }
        }
        return ToolResult(lines.joined(separator: "\n"))
    }
}

public final class RestartAppTool: JarvisTool {
    public let name = "restart_app"
    public let description = "Quit and relaunch one named app (e.g. a broken widget). Needs Sam's approval."
    public let tier = Tier.approve
    public let inputSchema: JSONObject = ["type": "object", "properties": ["name": ["type": "string"]], "required": ["name"], "additionalProperties": false]
    public init() {}
    public func targets(for input: JSONObject) -> ToolTargets { ToolTargets(apps: [input.string("name") ?? ""]) }
    public func preview(for input: JSONObject) -> String { "Quit and relaunch \(input.string("name") ?? "?")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let name = input.string("name") else { return .error("name is required") }
        let app = NSWorkspace.shared.runningApplications.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
        let url = app?.bundleURL ?? OpenAppTool.findApp(named: name)
        guard let url else { return .error("Can't find \(name).") }
        if let app {
            app.terminate()
            for _ in 0..<20 where !app.isTerminated { try? await Task.sleep(for: .milliseconds(250)) }
            if !app.isTerminated { app.forceTerminate() }
        }
        try? await Task.sleep(for: .milliseconds(500))
        try await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        return ToolResult("Restarted \(name).", summary: "Restarted \(name)")
    }
}

// MARK: - performance_report (Tier 0) / clear_caches (Tier 2)

public final class PerformanceReportTool: JarvisTool {
    public let name = "performance_report"
    public let description = "Read-only 'fix my laptop' check: memory pressure, top apps by memory and CPU, free disk, biggest cache folders, user login items. Proposes actions; never changes anything."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = ["type": "object", "properties": [:], "additionalProperties": false]
    public init() {}

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let snap = SystemInfo.snapshot()
        let cpu = Shell.readOnly("/bin/ps", ["-arcwwxo", "pcpu=,comm="]).split(separator: "\n").prefix(5)
            .map { line -> String in
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
                let name = parts.count > 1 ? (String(parts[1]) as NSString).lastPathComponent : "?"
                return "\(name) \(parts.first ?? "0")%"
            }
        let caches = CacheScanner.largest(limit: 6)
        let agents = (try? FileManager.default.contentsOfDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents"))?.filter { $0.hasSuffix(".plist") } ?? []
        var lines = [
            "Memory pressure: \(snap.memoryPressure) (\(snap.usedMemoryGB)/\(snap.totalMemoryGB) GB)",
            "Top memory: " + snap.topApps.prefix(5).map { "\($0.name) \($0.memoryMB) MB" }.joined(separator: ", "),
            "Top CPU: " + cpu.joined(separator: ", "),
            "Free disk: \(snap.diskFreeGB) GB",
            "Biggest caches: " + caches.map { "\($0.name) \($0.mb) MB" }.joined(separator: ", "),
            "User login items (LaunchAgents): " + (agents.isEmpty ? "none" : agents.joined(separator: ", ")),
        ]
        var suggestions: [String] = []
        if snap.memoryPressure != "normal", let top = snap.topApps.first { suggestions.append("quit \(top.name) (\(top.memoryMB) MB)") }
        if let big = caches.first, big.mb > 500 { suggestions.append("clear \(big.name) cache (\(big.mb) MB) with clear_caches") }
        if snap.diskFreeGB < 20 { suggestions.append("disk is low; organize Downloads and review large files") }
        lines.append("Suggested (each needs approval): " + (suggestions.isEmpty ? "nothing urgent" : suggestions.joined(separator: "; ")))
        return ToolResult(lines.joined(separator: "\n"), card: .info(title: "Performance", lines: Array(lines.prefix(5))))
    }
}

public enum CacheScanner {
    public struct Entry: Equatable { public var name: String; public var mb: Int; public var path: String }
    public static func largest(limit: Int) -> [Entry] {
        let root = NSHomeDirectory() + "/Library/Caches"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.map { n in Entry(name: n, mb: Int(size(of: root + "/" + n) / 1_048_576), path: root + "/" + n) }
            .sorted { $0.mb > $1.mb }.prefix(limit).map { $0 }
    }
    static func size(of path: String) -> UInt64 {
        guard let e = FileManager.default.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        var total: UInt64 = 0
        var n = 0
        for case let u as URL in e {
            n += 1; if n > 20_000 { break }
            total += UInt64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

public final class ClearCachesTool: JarvisTool {
    public let name = "clear_caches"
    public let description = "Move named cache folders under ~/Library/Caches to the Trash (recoverable). Give the folder names from performance_report. Needs Sam's approval."
    public let tier = Tier.approve
    public let inputSchema: JSONObject = ["type": "object", "properties": ["names": ["type": "array", "items": ["type": "string"]]], "required": ["names"], "additionalProperties": false]
    public init() {}
    public func targets(for input: JSONObject) -> ToolTargets { ToolTargets(paths: (input.stringArray("names") ?? []).map { "~/Library/Caches/\($0)" }) }
    public func preview(for input: JSONObject) -> String { "Move to Trash: " + (input.stringArray("names") ?? []).map { "~/Library/Caches/\($0)" }.joined(separator: ", ") }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let names = input.stringArray("names") ?? []
        guard !names.isEmpty else { return .error("names is required") }
        var freed = 0
        var moved: [String] = []
        for n in names where !n.contains("/") && !n.hasPrefix(".") {
            let path = NSHomeDirectory() + "/Library/Caches/" + n
            guard FileManager.default.fileExists(atPath: path) else { continue }
            let mb = Int(CacheScanner.size(of: path) / 1_048_576)
            do { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil); freed += mb; moved.append(n) }
            catch { JarvisLog.warn("clear_caches: \(n): \(error.localizedDescription)") }
        }
        return ToolResult("Moved \(moved.count) cache folder(s) to the Trash, about \(freed) MB. Empty the Trash yourself when you're sure.",
                          summary: "Trashed caches: \(moved.joined(separator: ", ")) (~\(freed) MB)")
    }
}
