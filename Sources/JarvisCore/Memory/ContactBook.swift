import Contacts
import Foundation

/// A person Jarvis can address.
public struct Contact: Codable, Equatable, Sendable {
    public var name: String
    public var email: String?
    public var phone: String?
    /// How Sam refers to them: "lab partner", "mom", "CSC 120 professor".
    public var relationship: String?
    public var notes: String?
    /// "jarvis" (told to Jarvis) or "mac" (from macOS Contacts).
    public var source: String = "jarvis"

    public init(name: String, email: String? = nil, phone: String? = nil, relationship: String? = nil, notes: String? = nil, source: String = "jarvis") {
        self.name = name; self.email = email; self.phone = phone; self.relationship = relationship; self.notes = notes; self.source = source
    }

    public var line: String {
        var parts = [name]
        if let relationship, !relationship.isEmpty { parts.append("(\(relationship))") }
        if let email, !email.isEmpty { parts.append("email \(email)") }
        if let phone, !phone.isEmpty { parts.append("phone \(phone)") }
        if let notes, !notes.isEmpty { parts.append("note: \(notes)") }
        return parts.joined(separator: " ") + (source == "mac" ? " [macOS Contacts]" : "")
    }
}

/// Looks people up in the Mac's address book. Behind an interface so tests never touch real contacts.
public protocol SystemContactsLookup: Sendable {
    /// Up to `limit` people whose name matches. Asks for Contacts permission on first use.
    func find(name: String, limit: Int) async -> [Contact]
}

/// Long-term local storage for people: `~/Library/Application Support/Jarvis/contacts.json`.
/// Holds what Sam tells Jarvis ("Maya is my lab partner, her email is…"). Lookups fall back to macOS Contacts.
/// Nothing here is synced anywhere, and it never stores anything that looks like a credential.
public final class ContactBook: @unchecked Sendable {
    public enum BookError: LocalizedError, Equatable {
        case empty, secret(String), notFound(String), badEmail(String)
        public var errorDescription: String? {
            switch self {
            case .empty: return "A contact needs a name."
            case .secret(let what): return "That looks like a secret (\(what)). I don't store credentials."
            case .notFound(let n): return "No saved contact matching “\(n)”."
            case .badEmail(let e): return "“\(e)” doesn't look like an email address."
            }
        }
    }

    public let url: URL
    private let system: (any SystemContactsLookup)?
    private let lock = NSLock()
    private var contacts: [Contact] = []

    public init(url: URL = ConfigLocator.userConfigDirectory.deletingLastPathComponent().appendingPathComponent("contacts.json"),
                system: (any SystemContactsLookup)? = nil) {
        self.url = url
        self.system = system
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([Contact].self, from: data) { contacts = saved }
    }

    public var all: [Contact] { lock.lock(); defer { lock.unlock() }; return contacts.sorted { $0.name.lowercased() < $1.name.lowercased() } }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !["my", "the", "a"].contains($0) }
    }

    static func clean(_ s: String?) -> String? {
        guard let t = s?.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(200))
    }

    /// Saved people matching a name or a relationship ("Maya", "my lab partner"). Pure lookup, no permission needed.
    public func findSaved(_ query: String) -> [Contact] {
        let wanted = Self.words(query)
        guard !wanted.isEmpty else { return [] }
        return all.filter { c in
            let hay = Self.words(c.name) + Self.words(c.relationship ?? "")
            return wanted.allSatisfy { w in hay.contains { $0.hasPrefix(w) } }
        }
    }

    /// Saved contacts first; if none, the Mac's address book.
    public func find(_ query: String, limit: Int = 5) async -> [Contact] {
        let saved = findSaved(query)
        if !saved.isEmpty { return Array(saved.prefix(limit)) }
        return await system?.find(name: query, limit: limit) ?? []
    }

    /// Adds a person, or fills in what is new for someone already saved under that name.
    @discardableResult
    public func save(_ contact: Contact) throws -> Contact {
        guard let name = Self.clean(contact.name) else { throw BookError.empty }
        var c = Contact(name: name, email: Self.clean(contact.email), phone: Self.clean(contact.phone),
                        relationship: Self.clean(contact.relationship), notes: Self.clean(contact.notes))
        if let e = c.email, e.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) == nil { throw BookError.badEmail(e) }
        // An email address is not a secret; check everything else.
        if let kind = SecretRedactor.findings(in: [c.name, c.phone, c.relationship, c.notes].compactMap { $0 }.joined(separator: " ")).first { throw BookError.secret(kind) }
        lock.lock()
        if let i = contacts.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            let old = contacts[i]
            c.email = c.email ?? old.email; c.phone = c.phone ?? old.phone
            c.relationship = c.relationship ?? old.relationship; c.notes = c.notes ?? old.notes
            contacts[i] = c
        } else {
            contacts.append(c)
        }
        let snapshot = contacts
        lock.unlock()
        try persist(snapshot)
        return c
    }

    @discardableResult
    public func remove(matching query: String) throws -> Contact {
        guard let hit = findSaved(query).first else { throw BookError.notFound(query) }
        lock.lock()
        contacts.removeAll { $0.name == hit.name }
        let snapshot = contacts
        lock.unlock()
        try persist(snapshot)
        return hit
    }

    private func persist(_ list: [Contact]) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(list).write(to: url, options: .atomic)
    }
}

/// macOS Contacts through CNContactStore. Read-only: name, email addresses, phone numbers. Notes are never read.
public final class MacContacts: SystemContactsLookup, @unchecked Sendable {
    private let store = CNContactStore()
    public init() {}

    public func find(name: String, limit: Int) async -> [Contact] {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        if status == .notDetermined {
            guard (try? await store.requestAccess(for: .contacts)) == true else { return [] }
        } else if status != .authorized {
            return []     // denied or restricted: saved contacts still work
        }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        guard let found = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys) else { return [] }
        return found.prefix(limit).map { c in
            let full = [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            return Contact(name: ContactBook.clean(full.isEmpty ? c.organizationName : full) ?? "(no name)",
                           email: ContactBook.clean(c.emailAddresses.first.map { $0.value as String }),
                           phone: ContactBook.clean(c.phoneNumbers.first?.value.stringValue), source: "mac")
        }
    }
}
