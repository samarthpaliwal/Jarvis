import AppKit

/// "The screen I'm looking at": the one under the mouse pointer, unless a display is pinned by name.
public enum ScreenResolver {
    @MainActor
    public static func target(pinned: String?) -> NSScreen? {
        if let pinned, !pinned.isEmpty, pinned.lowercased() != "active", let s = NotchGeometry.screen(named: pinned) { return s }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
