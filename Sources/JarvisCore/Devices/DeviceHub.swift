import Foundation

public enum DeviceKind: String, Sendable { case email, mac, phone, tablet }

/// What one connection reports. `summary` is safe to say to anyone; `detail` is personal and is only
/// handed out when the owner lock is open far enough.
public struct DeviceStatus: Equatable, Sendable {
    public var id: String
    public var name: String
    public var kind: DeviceKind
    /// nil: this kind of connection has no "online" (email).
    public var reachable: Bool?
    public var summary: String
    public var detail: String?
    public init(id: String, name: String, kind: DeviceKind, reachable: Bool?, summary: String, detail: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.reachable = reachable; self.summary = summary; self.detail = detail
    }
}

public struct DeviceMessage: Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var from: String
    public var text: String
    public var at: Date
}

public enum DeviceError: LocalizedError, Equatable {
    case unknown(String)
    case cannotReceive(String)
    case notDelivered(String)
    case locked(String)
    case empty
    public var errorDescription: String? {
        switch self {
        case .unknown(let n): return "There is no connected device called \(n)."
        case .cannotReceive(let n): return "\(n) cannot receive messages."
        case .notDelivered(let why): return why
        case .locked(let why): return why
        case .empty: return "The message is empty."
        }
    }
}

/// One thing Jarvis is connected to: an inbox, this Mac, a paired phone or iPad. Adding a kind of device
/// means writing one of these and registering it; nothing else changes.
@MainActor
public protocol ConnectedDevice: AnyObject {
    var id: String { get }
    var name: String { get }
    var kind: DeviceKind { get }
    /// How open the owner lock must be before `detail` is given out.
    var detailNeeds: Access { get }
    var canReceiveMessages: Bool { get }
    func status() async -> DeviceStatus
    func send(_ text: String) async throws
}

public extension ConnectedDevice {
    var detailNeeds: Access { .limited }
    var canReceiveMessages: Bool { false }
    func send(_ text: String) async throws { throw DeviceError.cannotReceive(name) }
}

/// The device layer. Everything that reads from or sends to a connected device goes through here, and
/// every call is checked against the owner lock first.
@MainActor
public final class DeviceHub {
    public nonisolated static let maxMessageLength = 280
    private var devices: [any ConnectedDevice] = []
    /// Extra devices that come and go (one per paired phone or iPad).
    public var dynamicDevices: () -> [any ConnectedDevice] = { [] }
    /// How open the owner lock is for the request being handled. Defaults to open (no lock set up).
    public var access: () async -> Access = { .full }
    /// How open the lock is for whoever is sitting at the Mac (used when a note arrives from a phone).
    public var accessAtMac: () async -> Access = { .full }
    /// A message arrived from a phone. `text` is nil when the lock is closed: say only that one is waiting.
    public var onMessage: ((_ from: String, _ text: String?) -> Void)?
    public private(set) var inbox: [DeviceMessage] = []
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    public func register(_ device: any ConnectedDevice) { devices.append(device) }
    public var all: [any ConnectedDevice] { devices + dynamicDevices() }

    /// Every connection's state. Personal detail is left out unless the lock is open far enough for it.
    public func statuses() async -> [DeviceStatus] {
        let have = await access()
        var out: [DeviceStatus] = []
        for d in all {
            var s = await d.status()
            if have < d.detailNeeds, s.detail != nil { s.detail = nil; s.summary += " Details are locked." }
            out.append(s)
        }
        return out
    }

    public func find(_ query: String) -> (any ConnectedDevice)? {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let list = all
        return list.first { $0.id.lowercased() == q || $0.name.lowercased() == q }
            ?? list.first { $0.name.lowercased().contains(q) || $0.kind.rawValue == q }
    }

    /// One line, trimmed, capped: a note, not a document.
    public nonisolated static func clean(_ text: String) -> String {
        let one = text.components(separatedBy: .newlines).joined(separator: " ").components(separatedBy: .controlCharacters).joined()
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(one.prefix(maxMessageLength))
    }

    /// Mac → device. Needs the lock at least partly open, and never carries anything that looks like a key.
    public func send(to query: String, text raw: String) async throws -> String {
        guard await access() >= .limited else { throw DeviceError.locked("Locked: messages to your devices are only sent when the owner lock is open.") }
        let text = Self.clean(raw)
        guard !text.isEmpty else { throw DeviceError.empty }
        guard SecretRedactor.redact(text).kinds.isEmpty else { throw DeviceError.notDelivered("That message looks like it contains a password or a key, so it was not sent.") }
        guard let device = find(query) else { throw DeviceError.unknown(query) }
        guard device.canReceiveMessages else { throw DeviceError.cannotReceive(device.name) }
        try await device.send(text)
        JarvisLog.info("Devices: message sent to \(device.name) (\(text.count) characters)")
        return device.name
    }

    /// Device → Mac. Always kept; shown and spoken only when the lock is open. Returns what the sender is told.
    @discardableResult
    public func receive(from device: String, text raw: String) async -> String {
        let text = Self.clean(raw)
        guard !text.isEmpty else { return "The message was empty." }
        inbox.append(DeviceMessage(from: device, text: text, at: now()))
        if inbox.count > 20 { inbox.removeFirst(inbox.count - 20) }
        let open = await accessAtMac() >= .limited
        JarvisLog.info("Devices: message from \(device) (\(text.count) characters, \(open ? "shown" : "held: locked"))")
        onMessage?(device, open ? text : nil)
        return open ? "Shown on the Mac." : "Delivered. The Mac is locked, so it will show once you are back."
    }

    /// Messages waiting on the Mac, newest last. Empty when the lock is closed.
    public func messages() async -> [DeviceMessage] { await access() >= .limited ? inbox : [] }
    public func clearInbox() { inbox = [] }
}

// MARK: - The devices that exist today

/// The inbox. Status only: reading and sending mail stay with the email tools.
@MainActor
public final class EmailDevice: ConnectedDevice {
    public let id = "email", name = "Email", kind = DeviceKind.email
    /// Who wrote and how many are unread is personal: both checks, like the email tools.
    public let detailNeeds = Access.full
    private let isConnected: () -> Bool
    private let unread: () async throws -> (count: Int, newestFrom: String?)

    public init(isConnected: @escaping () -> Bool, unread: @escaping () async throws -> (count: Int, newestFrom: String?)) {
        self.isConnected = isConnected; self.unread = unread
    }

    public func status() async -> DeviceStatus {
        guard isConnected() else { return DeviceStatus(id: id, name: name, kind: kind, reachable: nil, summary: "Email is not connected (menu → Connect Google).") }
        do {
            let u = try await unread()
            let count = u.count >= 20 ? "20 or more unread" : u.count == 0 ? "nothing unread" : "\(u.count) unread"
            return DeviceStatus(id: id, name: name, kind: kind, reachable: true, summary: "Email is connected.",
                                detail: count + (u.newestFrom.map { ", the newest from \($0)" } ?? "") + ".")
        } catch {
            return DeviceStatus(id: id, name: name, kind: kind, reachable: false, summary: "Email is connected but did not answer just now.")
        }
    }
}

/// The Mac Jarvis runs on.
@MainActor
public final class ThisMacDevice: ConnectedDevice {
    public let id = "mac", name = "This Mac", kind = DeviceKind.mac
    private let describe: () -> String
    public init(describe: @escaping () -> String) { self.describe = describe }
    public func status() async -> DeviceStatus { DeviceStatus(id: id, name: name, kind: kind, reachable: true, summary: describe()) }
}

/// A phone or iPad paired through the phone app. Messages reach it as a notification.
@MainActor
public final class PairedDevice: ConnectedDevice {
    public let id: String
    public let name: String
    public let kind: DeviceKind
    private let lastUsed: Date?
    private let notificationsOn: Bool
    private let nearby: String?
    private let push: (String) async -> Bool

    public init(name: String, lastUsed: Date?, notificationsOn: Bool, nearby: String?, push: @escaping (String) async -> Bool) {
        self.id = "paired:" + name.lowercased(); self.name = name
        self.kind = name.localizedCaseInsensitiveContains("ipad") ? .tablet : .phone
        self.lastUsed = lastUsed; self.notificationsOn = notificationsOn; self.nearby = nearby; self.push = push
    }

    public var canReceiveMessages: Bool { notificationsOn }

    public func status() async -> DeviceStatus {
        var parts = ["\(name) is paired"]
        parts.append(notificationsOn ? "notifications on" : "notifications off, so it cannot be messaged (in the phone app: ••• → Turn on notifications)")
        var detail: [String] = []
        if let lastUsed {
            let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
            detail.append("last used \(f.localizedString(for: lastUsed, relativeTo: Date()))")
        }
        if let nearby { detail.append(nearby) }
        return DeviceStatus(id: id, name: name, kind: kind, reachable: nil, summary: parts.joined(separator: ", ") + ".",
                            detail: detail.isEmpty ? nil : detail.joined(separator: "; ") + ".")
    }

    public func send(_ text: String) async throws {
        guard notificationsOn else { throw DeviceError.notDelivered("\(name) has notifications off, so the message could not be sent. In the phone app: ••• → Turn on notifications.") }
        guard await push(text) else { throw DeviceError.notDelivered("\(name) did not take the message. It may be offline or have notifications switched off.") }
    }
}
