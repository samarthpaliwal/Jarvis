import AppKit
import Combine
import SwiftUI

/// Transparent, click-through panel covering the notch screen. Only ordered in while the
/// glow is visible so it costs nothing when idle.
@MainActor
public final class EdgeGlowWindowController {
    private let panel: NSPanel
    private let model: NotchViewModel
    private var cancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    public init(model: NotchViewModel) {
        self.model = model
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        let hosting = NSHostingView(rootView: EdgeGlowView(model: model))
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        cancellable = model.$edgeGlow
            .removeDuplicates()
            .sink { [weak self] value in self?.update(glow: value) }
    }

    private func update(glow: Double) {
        hideTask?.cancel()
        if glow > 0 {
            if let screen = NotchGeometry.preferredScreen() {
                panel.setFrame(screen.frame, display: false)
            }
            panel.orderFrontRegardless()
        } else {
            // Let the fade-out finish before dropping the window.
            hideTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(0.7))
                guard !Task.isCancelled else { return }
                self?.panel.orderOut(nil)
            }
        }
    }
}
