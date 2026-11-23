import Foundation

/// Tier 3 enforcement: paths, file patterns, apps, shell patterns. Pure functions, unit-tested.
public struct DenylistGuard: Sendable {
    public struct Violation: LocalizedError, Equatable, CustomStringConvertible, Sendable {
        public let kind: String
        public let matched: String
        public var description: String { "Denied (\(kind)): \(matched)" }
        public var errorDescription: String? { description }
    }

    public let denylist: Denylist
    public let allowedFolders: AllowedFolders
    private let home: String

    public init(denylist: Denylist, allowedFolders: AllowedFolders, home: String = NSHomeDirectory()) {
        self.denylist = denylist
        self.allowedFolders = allowedFolders
        self.home = home
    }

    // MARK: Paths

    public func normalize(_ path: String) -> String {
        var p = path
        if p.hasPrefix("~") { p = home + p.dropFirst() }
        if !p.hasPrefix("/") { p = home + "/" + p }
        let url = URL(fileURLWithPath: p)
        // Resolve symlinks when the file exists so `~/x -> ~/.ssh/y` can't sneak through.
        let resolved = (try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath) ?? url.standardizedFileURL.path
        return resolved.hasSuffix("/") && resolved.count > 1 ? String(resolved.dropLast()) : resolved
    }

    private func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// Throws if the path is under a denied folder or its name matches a denied pattern.
    public func checkPath(_ path: String) throws {
        let p = normalize(path)
        for denied in denylist.paths {
            let d = normalize(denied)
            if isInside(p, d) { throw Violation(kind: "path", matched: denied) }
        }
        // Every component is checked so `project/.env/notes.txt` is still denied.
        for component in p.split(separator: "/").map(String.init) {
            for pattern in denylist.filePatterns where Self.glob(pattern, matches: component) {
                throw Violation(kind: "file pattern", matched: pattern)
            }
        }
    }

    /// Throws unless the path is inside one of the allowed folders (read or organize list).
    public func checkAllowedFolder(_ path: String, organize: Bool = false) throws {
        let p = normalize(path)
        let folders = (organize ? allowedFolders.organize : allowedFolders.read).map(normalize)
        guard folders.contains(where: { isInside(p, $0) }) else {
            throw Violation(kind: organize ? "outside organize folders" : "outside allowed folders", matched: path)
        }
    }

    // MARK: Apps

    public func checkApp(_ name: String) throws {
        let n = name.lowercased().replacingOccurrences(of: ".app", with: "").trimmingCharacters(in: .whitespaces)
        for app in denylist.apps where app.lowercased() == n || n.contains(app.lowercased()) {
            throw Violation(kind: "app", matched: app)
        }
    }

    // MARK: Shell

    public func checkShell(_ command: String) throws {
        let normalized = command.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        for pattern in denylist.shellPatterns {
            let pat = pattern.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            if normalized.contains(pat) || normalized.hasPrefix(pat.trimmingCharacters(in: .whitespaces)) {
                throw Violation(kind: "shell", matched: pattern)
            }
        }
        // Any path mentioned in the command is also subject to the path rules.
        for token in command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        where token.hasPrefix("/") || token.hasPrefix("~") || token.hasPrefix("./") {
            try checkPath(token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`;")))
        }
    }

    /// Everything a tool declared, in one go.
    public func check(_ targets: ToolTargets) throws {
        for p in targets.paths { try checkPath(p) }
        for a in targets.apps { try checkApp(a) }
        if let c = targets.shellCommand { try checkShell(c) }
    }

    /// Minimal glob: `*` and `?`, case-insensitive. Enough for `.env.*`, `id_rsa*`, `*.pem`.
    public static func glob(_ pattern: String, matches name: String) -> Bool {
        let p = Array(pattern.lowercased()), s = Array(name.lowercased())
        var pi = 0, si = 0, star = -1, mark = 0
        while si < s.count {
            if pi < p.count, p[pi] == "?" || p[pi] == s[si] { pi += 1; si += 1 }
            else if pi < p.count, p[pi] == "*" { star = pi; mark = si; pi += 1 }
            else if star >= 0 { pi = star + 1; mark += 1; si = mark }
            else { return false }
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }
}
