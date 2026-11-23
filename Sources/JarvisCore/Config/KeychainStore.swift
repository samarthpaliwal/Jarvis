import Foundation
import Security

/// Jarvis's saved keys. Everything goes through `SecretVault`, which reads each key once and keeps it in
/// memory. Tools never see this type. Under unit tests nothing touches the real Keychain.
public enum KeychainStore {
    public static let service = "com.samarth.jarvis"
    public static let apiKeyAccount = "ANTHROPIC_API_KEY"

    public enum KeychainError: LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            if case .status(let s) = self {
                return "Keychain error \(s): \((SecCopyErrorMessageString(s, nil) as String?) ?? "")"
            }
            return "Keychain error"
        }
    }

    /// Values used in place of the Keychain while the unit tests run.
    nonisolated(unsafe) static var testValues: [String: String] = [:]

    public static func read(account: String = apiKeyAccount) -> String? {
        if Runtime.isTesting { return testValues[account] }
        return SecretVault.shared.read(account)
    }

    public static func write(_ value: String, account: String = apiKeyAccount) throws {
        if Runtime.isTesting { testValues[account] = value.trimmingCharacters(in: .whitespacesAndNewlines); return }
        try SecretVault.shared.write(value, account: account)
    }

    public static func delete(account: String = apiKeyAccount) {
        if Runtime.isTesting { testValues[account] = nil; return }
        SecretVault.shared.delete(account)
    }

    /// Process env var wins (handy for development), then the vault. Deliberately not read from
    /// jarvis.env: secrets do not belong in a plain-text file.
    public static func apiKey() -> String? {
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        return read()
    }
}
