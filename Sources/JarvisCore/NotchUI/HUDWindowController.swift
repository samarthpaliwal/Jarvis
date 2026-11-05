import AppKit
import Combine
import SwiftUI

/// Full-screen HUD panel. Shown for scenes (homecoming) or, when "full screen always" is on,
/// for every conversation. Click or Esc dismisses. Hidden otherwise, so it costs nothing.
@MainActor
public final class HUDWindowController: ObservableObject {
    @Published public private(set) var isShowing = false
    public var readouts: HUDReadouts = .empty { didSet { rebuild() } }
    /// Whether every conversation should take the whole screen (menu toggle / voice).
    @Published public var fullScreenAlways: Bool = UserDefaults.standard.bool(forKey: "jarvis.hudAlways") {
        didSet { UserDefaults.standard.set(fullScreenAlways, forKey: "jarvis.hudAlways") }
    }

    private let panel: NSPanel
    private let model: NotchViewModel
    private var hosting: NSHostingView<HUDView>?
    private var cancellables: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    private var dismissTask: Task<Void, Never>?
    private var pinnedForScene = false
    private var dismissAfter: TimeInterval = 8

    public init(model: NotchViewModel, dismissAfter: TimeInterval) {
        self.model = model
        self.dismissAfter = dismissAfter
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        rebuild()

        // Follow the conversation when "always" is on.
        model.$phase.removeDuplicates().sink { [weak self] phase in
            guard let self else { return }
            if phase != .idle, self.fullScreenAlways, !self.isShowing { self.show(scene: false) }
            if phase == .idle, self.isShowing { self.scheduleDismiss() }
            if phase != .idle { self.dismissTask?.cancel() }
        }.store(in: &cancellables)
    }

    private func rebuild() {
        let view = HUDView(model: model, readouts: readouts) { [weak self] in self?.dismiss(reason: "tap") }
        if let hosting { hosting.rootView = view } else {
            let h = NSHostingView(rootView: view)
            h.autoresizingMask = [.width, .height]
            panel.contentView = h
            hosting = h
        }
    }

    /// Show the HUD. `scene` keeps it up until the scene ends (plus the dismiss delay).
    public func show(scene: Bool) {
        pinnedForScene = scene || pinnedForScene
        guard let screen = NotchGeometry.preferredScreen() else { return }
        panel.setFrame(screen.frame, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isShowing = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = model.reduceMotion ? 0.2 : 0.6
            panel.animator().alphaValue = 1
        }
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                if e.keyCode == 53 { self?.dismiss(reason: "esc"); return nil }
                return e
            }
        }
        JarvisLog.info("HUD shown (\(scene ? "scene" : "conversation"))")
    }

    public func sceneEnded() {
        pinnedForScene = false
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        guard !pinnedForScene else { return }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.dismissAfter))
            guard !Task.isCancelled, self.model.phase == .idle else { return }
            self.dismiss(reason: "idle")
        }
    }

    public func dismiss(reason: String) {
        guard isShowing else { return }
        dismissTask?.cancel()
        pinnedForScene = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = model.reduceMotion ? 0.15 : 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel.orderOut(nil)
                self?.isShowing = false
            }
        })
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        JarvisLog.info("HUD dismissed (\(reason))")
    }
}
