import Foundation

/// Reversible actions, newest last. "Jarvis, undo that" pops one.
@MainActor
public final class UndoStack: ObservableObject {
    public struct Entry: Identifiable {
        public let id = UUID()
        public let description: String
        public let createdAt = Date()
        let undo: () async throws -> String

        public init(description: String, undo: @escaping () async throws -> String) {
            self.description = description
            self.undo = undo
        }
    }

    @Published public private(set) var entries: [Entry] = []
    private let limit = 50

    public init() {}

    public func push(_ entry: Entry) {
        entries.append(entry)
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
    }

    public var canUndo: Bool { !entries.isEmpty }
    public var lastDescription: String? { entries.last?.description }

    /// Runs the most recent undo. Returns what it did.
    public func undoLast() async throws -> String {
        guard let entry = entries.popLast() else { return "Nothing to undo." }
        return try await entry.undo()
    }
}
