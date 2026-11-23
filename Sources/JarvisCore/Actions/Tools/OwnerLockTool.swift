import Foundation

/// Tier 1: the owner lock (face recognition). Anything that opens or changes the lock asks for Touch ID
/// itself, so this tool is safe to leave reachable while everything personal is closed.
public final class OwnerLockTool: JarvisTool {
    public let name = "owner_lock"
    public let description = "The owner lock keeps Sam's email, calendar, files, notes and memory closed unless the camera sees Sam's face. status: is it on, who the camera sees, and why a check failed. unlock: open it for a few minutes with Touch ID (when Sam says 'unlock with Touch ID' or the camera is not working). lock: close it now. enroll: start the guided face setup (Touch ID first; it begins after you finish speaking). forget: delete the saved face and turn the lock off (Touch ID first). on / off: switch the face check (off needs Touch ID). phone_on / phone_off: also require Sam's phone to be nearby, or stop requiring it (off needs Touch ID). With both checks on, both must pass for email, files and anything that sends or deletes; with one, only the calendar, reminders, notes and memory work. Only when Sam asks."
    public let tier = Tier.free
    public let userOnly = true
    public let inputSchema: JSONObject = [
        "type": "object",
        "properties": ["action": ["type": "string", "enum": ["status", "unlock", "lock", "enroll", "forget", "on", "off", "phone_on", "phone_off"]]],
        "required": ["action"], "additionalProperties": false,
    ]

    public struct Hooks {
        public var status: @MainActor () -> String
        public var isEnrolled: @MainActor () -> Bool
        public var modelInstalled: @MainActor () -> Bool
        public var startEnrollment: @MainActor () -> Void
        public var forget: @MainActor () throws -> Void
        public var setEnabled: @MainActor (Bool) throws -> Void
        /// Nil when no phone has been chosen yet; otherwise switches the phone check.
        public var setPhoneRequired: (@MainActor (Bool) throws -> Void)? = nil
        public init(status: @escaping @MainActor () -> String, isEnrolled: @escaping @MainActor () -> Bool,
                    modelInstalled: @escaping @MainActor () -> Bool, startEnrollment: @escaping @MainActor () -> Void,
                    forget: @escaping @MainActor () throws -> Void, setEnabled: @escaping @MainActor (Bool) throws -> Void,
                    setPhoneRequired: (@MainActor (Bool) throws -> Void)? = nil) {
            self.status = status; self.isEnrolled = isEnrolled; self.modelInstalled = modelInstalled
            self.startEnrollment = startEnrollment; self.forget = forget; self.setEnabled = setEnabled; self.setPhoneRequired = setPhoneRequired
        }
    }
    private let lock: OwnerLock
    private let hooks: Hooks

    public init(lock: OwnerLock, hooks: Hooks) { self.lock = lock; self.hooks = hooks }

    public func preview(for input: JSONObject) -> String { "owner lock \(input.string("action") ?? "")" }

    @MainActor public func run(input: JSONObject, context: ToolContext) async throws -> ToolResult {
        // From the phone there is no finger on this Mac's sensor: only status makes sense.
        let fromPhone = RequestTrace.current?.source == "remote"
        let action = input.string("action") ?? "status"
        if fromPhone, action != "status", action != "lock" { return .error("That needs Touch ID on the Mac itself, so it cannot be done from the phone.") }
        switch action {
        case "status":
            return ToolResult(await hooks.status())
        case "unlock":
            guard lock.isActive else { return ToolResult("The owner lock is not on, so nothing is locked.") }
            guard await lock.unlockWithTouchID() else { return .error("Touch ID was not confirmed, so the lock stays closed.") }
            return ToolResult("Unlocked with Touch ID for \(Int(lock.settings().overrideMinutes)) minutes.", summary: "Owner lock opened with Touch ID")
        case "lock":
            lock.lockNow()
            return ToolResult(lock.isActive ? "Locked. Personal features need the checks again." : "The owner lock is not on yet; set up face recognition first.",
                              summary: "Owner lock closed")
        case "enroll":
            guard await hooks.modelInstalled() else { return .error("The face model is not installed. Run scripts/setup-faceid.sh, then restart Jarvis.") }
            // Enrolling a face is how someone else would take over the lock: Touch ID, every time.
            guard await lock.confirmOwner("set up face recognition for Jarvis") else { return .error("Touch ID was not confirmed. Nothing changed.") }
            await hooks.startEnrollment()
            return ToolResult("The guided face setup starts as soon as you finish speaking. Say one short sentence telling Sam to look at the camera, then stop.",
                              summary: "Face setup starting")
        case "forget":
            guard await hooks.isEnrolled() else { return ToolResult("No face is saved, so there is nothing to forget.") }
            guard await lock.confirmOwner("delete the saved face and turn the owner lock off") else { return .error("Touch ID was not confirmed. Nothing changed.") }
            try await hooks.forget()
            return ToolResult("The saved face is deleted and the owner lock is off.", summary: "Face deleted, owner lock off")
        case "on":
            guard await hooks.isEnrolled() else { return .error("No face is enrolled yet. Sam can say \"set up face recognition\".") }
            try await hooks.setEnabled(true)
            return ToolResult("The owner lock is on.", summary: "Owner lock on")
        case "off":
            guard await lock.confirmOwner("turn Jarvis's owner lock off") else { return .error("Touch ID was not confirmed. The lock stays on.") }
            try await hooks.setEnabled(false)
            return ToolResult("The owner lock is off. Everything works without a face check until you turn it back on.", summary: "Owner lock off")
        case "phone_on":
            guard let set = hooks.setPhoneRequired else { return .error("No phone has been chosen yet. Sam picks it once in the menu: Phone Radar → Set My Phone.") }
            try set(true)
            return ToolResult("The owner lock now also needs the phone nearby.", summary: "Phone check on")
        case "phone_off":
            guard let set = hooks.setPhoneRequired else { return ToolResult("The phone check is not on.") }
            guard await lock.confirmOwner("stop Jarvis's owner lock from needing your phone") else { return .error("Touch ID was not confirmed. Nothing changed.") }
            try set(false)
            return ToolResult("The owner lock no longer needs the phone.", summary: "Phone check off")
        default:
            return .error("action must be status, unlock, lock, enroll, forget, on, off, phone_on or phone_off")
        }
    }
}
