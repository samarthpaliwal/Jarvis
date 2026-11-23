import Foundation

/// Who the camera sees. `checking` is the first moments of a look, before there is enough to decide.
public enum FaceState: String, Sendable, Equatable {
    case idle        // the camera is off; nothing has been checked
    case checking
    case owner       // owner present
    case unknown     // unknown person present
    case noFace      // no face visible
    case error       // camera or model failed: locked
}

/// What one camera frame showed.
public enum FaceFrame: Equatable, Sendable {
    public struct Face: Equatable, Sendable {
        public var score: Double      // how alike this face is to the enrolled one
        public var live: Bool
        public init(score: Double, live: Bool) { self.score = score; self.live = live }
    }
    case faces([Face])
    case failure(String)
}

/// Turns a stream of frames into the three states, erring toward "not the owner".
public struct OwnerPresence: Equatable, Sendable {
    public struct Settings: Equatable, Sendable {
        /// A face must score at least this to count as the owner.
        public var threshold = 0.45
        /// This many matching frames in a row before "owner present".
        public var matchesNeeded = 2
        /// This many non-matching frames in a row before "unknown person present".
        public var mismatchesNeeded = 3
        /// This many empty frames in a row before "no face visible".
        public var emptyNeeded = 3
        /// After the owner was last seen, an empty view keeps things unlocked this long.
        public var noFaceTimeout: TimeInterval = 60
        public var requireLiveness = true
        public init() {}
    }
    public var settings: Settings
    public private(set) var state: FaceState = .idle
    public private(set) var lastOwnerAt: Date?
    public private(set) var lastScore: Double?
    /// Why the last frame did not count as the owner, for the log and for telling the user.
    public private(set) var detail = ""
    private var matches = 0, mismatches = 0, empties = 0

    public init(settings: Settings = Settings()) { self.settings = settings }

    /// A new look begins (the wake word fired). What was known about the owner's last sighting is kept.
    public mutating func begin() -> FaceState? { matches = 0; mismatches = 0; empties = 0; return move(.checking, "looking") }

    /// The look is over and the camera is off.
    public mutating func end() -> FaceState? { matches = 0; mismatches = 0; empties = 0; return move(.idle, "camera off") }

    /// Forget that the owner was ever seen (a stranger appeared, or the lock was asked for).
    public mutating func forgetOwner() { lastOwnerAt = nil }

    @discardableResult
    public mutating func observe(_ frame: FaceFrame, at now: Date) -> FaceState? {
        switch frame {
        case .failure(let why):
            matches = 0; lastOwnerAt = nil
            return move(.error, why)
        case .faces(let faces):
            guard let best = faces.max(by: { $0.score < $1.score }) else {
                matches = 0; mismatches = 0; empties += 1; lastScore = nil
                return empties >= settings.emptyNeeded ? move(.noFace, "no face") : nil
            }
            empties = 0; lastScore = best.score
            if best.score >= settings.threshold {
                mismatches = 0
                if settings.requireLiveness, !best.live {
                    matches = 0
                    // Looks like the owner but has not blinked or moved yet. Never unlocks on its own.
                    return state == .owner ? nil : move(.checking, "matches, waiting for a blink or head movement")
                }
                matches += 1
                guard matches >= settings.matchesNeeded else { return nil }
                lastOwnerAt = now
                return move(.owner, faces.count > 1 ? "owner, with \(faces.count - 1) other face(s)" : "owner")
            }
            matches = 0; mismatches += 1
            guard mismatches >= settings.mismatchesNeeded else { return nil }
            lastOwnerAt = nil      // someone else is here: the "just stepped away" allowance ends
            return move(.unknown, "best score \(String(format: "%.2f", best.score)) is under \(settings.threshold)")
        }
    }

    /// Whether the owner's personal data may be used right now, as far as the camera can tell.
    public func isOwnerPresent(at now: Date) -> Bool {
        switch state {
        case .owner: return true
        case .noFace:
            guard let seen = lastOwnerAt else { return false }
            return now.timeIntervalSince(seen) <= settings.noFaceTimeout
        case .idle, .checking, .unknown, .error: return false
        }
    }

    private mutating func move(_ to: FaceState, _ why: String) -> FaceState? {
        detail = why
        guard to != state else { return nil }
        state = to
        return to
    }
}
