import AppKit

/// Borderless, non-activating panel that floats above everything, on every Space,
/// including over full-screen apps. It never steals focus from the app you're using.
public final class NotchPanel: NSPanel {
    public init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        // Above the menu bar so the expanded shape can grow out of the notch.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        isExcludedFromWindowsMenu = true
    }

    // Allow buttons (Approve / Deny) inside the notch to receive clicks without activating the app.
    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { false }
}
