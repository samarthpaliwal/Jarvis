import AppKit
import SwiftUI

/// Owns the panel, keeps it glued to the top-center of the right screen, and re-measures
/// the notch when displays change or the Mac wakes from sleep.
@MainActor
public final class NotchWindowController {
    public let model: NotchViewModel
    public private(set) var geometry: NotchGeometry = .fallback

    private let panel: NotchPanel
    private let hosting: NSHostingView<NotchRootView>
    /// Generous fixed panel size; the SwiftUI content draws only what it needs at the top.
    private static let panelSize = CGSize(width: 820, height: 460)
    private var observers: [Any] = []

    public init(model: NotchViewModel) {
        self.model = model
        panel = NotchPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize))
        hosting = NSHostingView(rootView: NotchRootView(model: model))
        hosting.frame = NSRect(origin: .zero, size: Self.panelSize)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        reposition()
        panel.orderFrontRegardless()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition(reason: "screen parameters changed") }
        })
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(wnc.addObserver(forName: NSWorkspace.didWakeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reposition(reason: "wake from sleep") }
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.panel.orderFrontRegardless() }
        })
    }

    public func reposition(reason: String? = nil) {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        geometry = NotchGeometry.detect(on: screen)
        model.geometry = geometry
        let size = Self.panelSize
        let origin = CGPoint(x: (screen.frame.midX - size.width / 2).rounded(),
                             y: screen.frame.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        if let reason {
            JarvisLog.info("Notch repositioned (\(reason)): notch=\(geometry.hasNotch) w=\(Int(geometry.notchWidth)) h=\(Int(geometry.notchHeight))")
        }
    }

    public var isVisible: Bool { panel.isVisible }
    public func hide() { panel.orderOut(nil) }
    public func show() { panel.orderFrontRegardless() }
}
