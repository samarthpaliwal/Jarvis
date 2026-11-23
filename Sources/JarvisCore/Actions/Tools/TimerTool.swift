import Foundation
@preconcurrency import UserNotifications

/// Tier 1: in-app countdown timers. Fires a notification and a spoken line via `onFire`.
@MainActor
public final class TimerService: ObservableObject {
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let label: String
        public let fireAt: Date
    }
    @Published public private(set) var timers: [Entry] = []
    public var onFire: ((Entry) -> Void)?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init() {}

    @discardableResult
    public func add(seconds: Int, label: String) -> Entry {
        let entry = Entry(id: UUID(), label: label, fireAt: Date().addingTimeInterval(TimeInterval(seconds)))
        timers.append(entry)
        tasks[entry.id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.timers.removeAll { $0.id == entry.id }
            self.tasks[entry.id] = nil
            self.notify(entry)
            self.onFire?(entry)
        }
        return entry
    }

    public func cancel(id: UUID) -> Bool {
        guard let t = tasks[id] else { return false }
        t.cancel()
        tasks[id] = nil
        timers.removeAll { $0.id == id }
        return true
    }

    private func notify(_ entry: Entry) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            guard ok else { return }
            let content = UNMutableNotificationContent()
            content.title = "Jarvis timer"
            content.body = entry.label
            content.sound = .default
            center.add(UNNotificationRequest(identifier: entry.id.uuidString, content: content, trigger: nil))
        }
    }
}

public final class SetTimerTool: JarvisTool {
    public let name = "set_timer"
    public let description = "Start a countdown timer in seconds with a short label. Jarvis announces it when it fires. Also lists or cancels running timers."
    public let tier = Tier.free
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": [
            "seconds": ["type": "integer", "minimum": 1, "maximum": 86400],
            "label": ["type": "string"],
            "action": ["type": "string", "enum": ["start", "list", "cancel_all"], "description": "Default start"],
        ],
        "additionalProperties": false,
    ]
    private let service: TimerService

    public init(service: TimerService) { self.service = service }

    public func preview(for input: JSONObject) -> String { "timer \(input.int("seconds") ?? 0)s \(input.string("label") ?? "")" }

    public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        let action = input.string("action") ?? "start"
        switch action {
        case "list":
            let list = await service.timers
            if list.isEmpty { return ToolResult("No timers running.") }
            let f = RelativeDateTimeFormatter()
            return ToolResult(list.map { "\($0.label): fires \(f.localizedString(for: $0.fireAt, relativeTo: Date()))" }.joined(separator: "\n"))
        case "cancel_all":
            let list = await service.timers
            for t in list { _ = await service.cancel(id: t.id) }
            return ToolResult("Cancelled \(list.count) timer(s).", summary: "Cancelled \(list.count) timer(s)")
        default:
            guard let secs = input.int("seconds"), secs > 0 else { return .error("seconds is required") }
            let label = input.string("label") ?? "Timer"
            let entry = await service.add(seconds: secs, label: label)
            let id = entry.id
            await context.undo.push(.init(description: "timer “\(label)”") { _ = await self.service.cancel(id: id); return "Cancelled the \(label) timer." })
            return ToolResult("Timer “\(label)” set for \(Self.human(secs)).", summary: "Timer: \(label) in \(Self.human(secs))")
        }
    }

    static func human(_ s: Int) -> String {
        if s % 3600 == 0 { return "\(s / 3600) hour\(s == 3600 ? "" : "s")" }
        if s % 60 == 0 { return "\(s / 60) minute\(s == 60 ? "" : "s")" }
        return "\(s) seconds"
    }
}
