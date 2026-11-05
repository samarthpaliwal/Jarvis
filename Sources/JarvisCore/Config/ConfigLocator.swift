import Foundation

/// Finds the live config directory.
///
/// Resolution order:
///  1. `$JARVIS_CONFIG_DIR`
///  2. `~/Library/Application Support/Jarvis/config` (the editable copy, seeded on first launch)
///  3. `Jarvis.app/Contents/Resources/config` (bundled defaults)
///  4. A `config/` folder found by walking up from the executable (handy for `swift run`)
public enum ConfigLocator {
    public static let requiredFiles = ["profile.json", "allowed-folders.json", "denylist.json", "modes.json"]

    public static var userConfigDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("Jarvis/config", isDirectory: true)
    }

    public static var bundledConfigDirectory: URL? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let url = res.appendingPathComponent("config", isDirectory: true)
        return isComplete(url) ? url : nil
    }

    /// Walk up from the running binary looking for a complete `config/` folder (source checkout).
    public static var developmentConfigDirectory: URL? {
        var dir = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = dir.appendingPathComponent("config", isDirectory: true)
            if isComplete(candidate) { return candidate }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    public static func resolve() -> URL {
        if let env = ProcessInfo.processInfo.environment["JARVIS_CONFIG_DIR"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        if isComplete(userConfigDirectory) { return userConfigDirectory }
        if let bundled = bundledConfigDirectory { return bundled }
        if let dev = developmentConfigDirectory { return dev }
        return userConfigDirectory
    }

    /// Copies bundled (or source-tree) defaults into Application Support if any file is missing.
    /// Never overwrites a file the user already has.
    @discardableResult
    public static func seedUserConfigIfNeeded() -> Bool {
        guard let source = bundledConfigDirectory ?? developmentConfigDirectory else { return false }
        let fm = FileManager.default
        var seeded = false
        do {
            try fm.createDirectory(at: userConfigDirectory, withIntermediateDirectories: true)
            for file in requiredFiles {
                let dst = userConfigDirectory.appendingPathComponent(file)
                if !fm.fileExists(atPath: dst.path) {
                    try fm.copyItem(at: source.appendingPathComponent(file), to: dst)
                    seeded = true
                }
            }
        } catch {
            JarvisLog.error("Config seed failed: \(error.localizedDescription)")
        }
        return seeded
    }

    /// Adds keys that exist in the bundled defaults but are missing from the user's copy
    /// (top level and one level deep). Never changes values the user already has.
    @discardableResult
    public static func mergeNewDefaultKeys(file: String = "profile.json") -> [String] {
        guard let source = bundledConfigDirectory ?? developmentConfigDirectory else { return [] }
        let userURL = userConfigDirectory.appendingPathComponent(file)
        guard let dData = try? Data(contentsOf: source.appendingPathComponent(file)),
              let uData = try? Data(contentsOf: userURL),
              let defaults = try? JSONSerialization.jsonObject(with: dData) as? [String: Any],
              var user = try? JSONSerialization.jsonObject(with: uData) as? [String: Any] else { return [] }
        var added: [String] = []
        for (k, v) in defaults {
            if user[k] == nil { user[k] = v; added.append(k); continue }
            if let dv = v as? [String: Any], var uv = user[k] as? [String: Any] {
                for (k2, v2) in dv where uv[k2] == nil { uv[k2] = v2; added.append("\(k).\(k2)") }
                if let dn = dv["notion"] as? [String: Any], var un = uv["notion"] as? [String: Any] {
                    for (k3, v3) in dn where un[k3] == nil { un[k3] = v3; added.append("\(k).notion.\(k3)") }
                    uv["notion"] = un
                }
                user[k] = uv
            }
        }
        if !added.isEmpty, let out = try? JSONSerialization.data(withJSONObject: user, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: userURL)
            JarvisLog.info("Config: added new default keys to \(file): \(added.joined(separator: ", "))")
        }
        return added
    }

    static func isComplete(_ dir: URL) -> Bool {
        requiredFiles.allSatisfy { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }
}
