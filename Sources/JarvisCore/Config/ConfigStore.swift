import Foundation
import Combine

/// Loads and holds all four config files. Call `reload()` after editing them.
@MainActor
public final class ConfigStore: ObservableObject {
    @Published public private(set) var profile: Profile = .fallback
    @Published public private(set) var allowedFolders: AllowedFolders = .fallback
    @Published public private(set) var denylist: Denylist = .fallback
    @Published public private(set) var modes: ModesConfig = .fallback
    /// Human-readable list of files that failed to parse (shown in the menu bar).
    @Published public private(set) var errors: [String] = []

    public let directory: URL

    public init(directory: URL = ConfigLocator.resolve()) {
        self.directory = directory
        reload()
    }

    public func reload() {
        var errs: [String] = []
        profile = load("profile.json", fallback: .fallback, errors: &errs)
        allowedFolders = load("allowed-folders.json", fallback: .fallback, errors: &errs)
        // Denylist is a union: whatever the file says PLUS the hard-coded floor.
        let fileDeny: Denylist = load("denylist.json", fallback: .fallback, errors: &errs)
        denylist = Denylist(
            paths: Array(Set(fileDeny.paths + Denylist.fallback.paths)).sorted(),
            filePatterns: Array(Set(fileDeny.filePatterns + Denylist.fallback.filePatterns)).sorted(),
            apps: Array(Set(fileDeny.apps + Denylist.fallback.apps)).sorted(),
            shellPatterns: Array(Set(fileDeny.shellPatterns + Denylist.fallback.shellPatterns)).sorted()
        )
        modes = load("modes.json", fallback: .fallback, errors: &errs)
        errors = errs
        JarvisLog.info("Config loaded from \(directory.path)" + (errs.isEmpty ? "" : " with errors: \(errs.joined(separator: "; "))"))
    }

    /// Writes modes.json (places learned by voice) and reloads.
    public func save(modes newModes: ModesConfig) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(newModes).write(to: directory.appendingPathComponent("modes.json"))
        modes = newModes
        JarvisLog.info("modes.json saved (\(newModes.places.count) places)")
    }

    private func load<T: Decodable>(_ file: String, fallback: T, errors: inout [String]) -> T {
        let url = directory.appendingPathComponent(file)
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            errors.append("\(file): \(Self.describe(error))")
            return fallback
        }
    }

    static func describe(_ error: Error) -> String {
        if let d = error as? DecodingError {
            switch d {
            case .keyNotFound(let k, let c): return "missing key '\(k.stringValue)' at \(path(c))"
            case .typeMismatch(_, let c): return "wrong type at \(path(c))"
            case .valueNotFound(_, let c): return "null at \(path(c))"
            case .dataCorrupted(let c): return "invalid JSON at \(path(c))"
            @unknown default: return "decode error"
            }
        }
        return error.localizedDescription
    }

    private static func path(_ c: DecodingError.Context) -> String {
        c.codingPath.map(\.stringValue).joined(separator: ".").ifEmpty("root")
    }
}

extension String {
    func ifEmpty(_ alt: String) -> String { isEmpty ? alt : self }
}
