import Foundation

/// Tier 0: find files by name inside the allowed folders. Skips hidden/build dirs and the denylist.
public final class FileSearchTool: JarvisTool {
    public let name = "file_search"
    public let description = "Find files or folders by name (substring, case-insensitive) inside Sam's allowed folders (Developer, Desktop, Downloads, Documents). Returns up to 30 paths with sizes and modified dates."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "query": ["type": "string", "description": "Name fragment to look for"],
            "folder": ["type": "string", "description": "Optional: limit to one allowed folder, e.g. ~/Developer"],
        ],
        "required": ["query"],
        "additionalProperties": false,
    ]
    private static let skip: Set<String> = ["node_modules", ".build", ".git", "DerivedData", "Pods", ".venv", "venv", "__pycache__", "Library"]

    public init() {}

    public func targets(for input: JSONObject) -> ToolTargets {
        ToolTargets(paths: input.string("folder").map { [$0] } ?? [])
    }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let q = input.string("query")?.lowercased(), !q.isEmpty else { return .error("query is required") }
        let guardian = await context.config.denylist
        let allowed = await context.config.allowedFolders
        let dg = DenylistGuard(denylist: guardian, allowedFolders: allowed)
        let roots: [String]
        if let folder = input.string("folder") {
            try dg.checkAllowedFolder(folder)
            roots = [dg.normalize(folder)]
        } else {
            roots = allowed.read.map(dg.normalize)
        }
        let hits = Self.scan(roots: roots, query: q, guardian: dg)
        if hits.isEmpty { return ToolResult("No files matching “\(q)” in the allowed folders.") }
        return ToolResult(hits.joined(separator: "\n"), card: .info(title: "Files: \(q)", lines: Array(hits.prefix(5))))
    }

    nonisolated static func scan(roots: [String], query q: String, guardian dg: DenylistGuard) -> [String] {
        let deadline = Date().addingTimeInterval(4)
        var hits: [String] = []
        let fm = FileManager.default
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        search: for root in roots {
            guard let e = fm.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if Date() > deadline { hits.append("(search stopped after 4 s)"); break search }
                let name = url.lastPathComponent
                if Self.skip.contains(name) { e.skipDescendants(); continue }
                if e.level > 6 { e.skipDescendants() }
                guard name.lowercased().contains(q) else { continue }
                if (try? dg.checkPath(url.path)) == nil { continue }
                let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let kind = v?.isDirectory == true ? "folder" : "\((v?.fileSize ?? 0) / 1024) KB"
                let date = v?.contentModificationDate.map { df.string(from: $0) } ?? ""
                hits.append("\(Self.tilde(url.path)) · \(kind) · \(date)")
                if hits.count >= 30 { break search }
            }
        }
        return hits
    }

    static func tilde(_ p: String) -> String {
        p.hasPrefix(NSHomeDirectory()) ? "~" + p.dropFirst(NSHomeDirectory().count) : p
    }
}

/// Tier 0: read a text file inside the allowed folders. Content is marked untrusted for Claude.
public final class FileReadTool: JarvisTool {
    public let name = "file_read"
    public let description = "Read a text file (up to 100 KB) from Sam's allowed folders. Returns the content. Binary files are refused."
    public let tier = Tier.auto
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["path": ["type": "string", "description": "Absolute or ~ path"]],
        "required": ["path"],
        "additionalProperties": false,
    ]

    public init() {}

    public func targets(for input: JSONObject) -> ToolTargets { ToolTargets(paths: [input.string("path") ?? ""]) }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        guard let path = input.string("path") else { return .error("path is required") }
        let dg = DenylistGuard(denylist: await context.config.denylist, allowedFolders: await context.config.allowedFolders)
        try dg.checkAllowedFolder(path)
        let url = URL(fileURLWithPath: dg.normalize(path))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int) ?? 0
        guard size <= 100_000 else { return .error("File is \(size / 1024) KB; limit is 100 KB.") }
        let data = try Data(contentsOf: url)
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { return .error("Not a text file.") }
        return ToolResult(Untrusted.wrap(text, source: "file:\(url.lastPathComponent)"))
    }
}
