import AppKit

/// Where the notch is (or where the fallback pill should go) on a given screen.
public struct NotchGeometry: Equatable {
    public var hasNotch: Bool
    /// Width of the physical notch, or of the fallback pill.
    public var notchWidth: CGFloat
    /// Height of the physical notch (== top safe area), or the menu bar height for the fallback pill.
    public var notchHeight: CGFloat
    public var screenFrame: CGRect

    public static let fallbackPillWidth: CGFloat = 160
    public static let fallbackPillHeight: CGFloat = 24

    public static let fallback = NotchGeometry(hasNotch: false, notchWidth: fallbackPillWidth,
                                               notchHeight: fallbackPillHeight, screenFrame: .zero)

    public init(hasNotch: Bool, notchWidth: CGFloat, notchHeight: CGFloat, screenFrame: CGRect) {
        self.hasNotch = hasNotch
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.screenFrame = screenFrame
    }

    /// Reads the notch from AppKit's safe-area API. Falls back to a pill the height of the menu bar.
    public static func detect(on screen: NSScreen) -> NotchGeometry {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            let width = right.minX - left.maxX
            if width > 0 {
                return NotchGeometry(hasNotch: true, notchWidth: width, notchHeight: top, screenFrame: screen.frame)
            }
        }
        let menuBar = screen.frame.maxY - screen.visibleFrame.maxY
        return NotchGeometry(hasNotch: false, notchWidth: fallbackPillWidth,
                             notchHeight: max(menuBar, fallbackPillHeight), screenFrame: screen.frame)
    }

    /// A connected display whose name contains `name` (case-insensitive), e.g. "Odyssey G5".
    public static func screen(named name: String?) -> NSScreen? {
        guard let name, !name.isEmpty else { return nil }
        return NSScreen.screens.first { $0.localizedName.localizedCaseInsensitiveContains(name) }
    }

    /// Prefer the built-in display with a notch; otherwise whatever screen is main.
    public static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens.first
    }
}
