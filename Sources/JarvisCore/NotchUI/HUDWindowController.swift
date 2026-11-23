import AppKit
import Combine
import SwiftUI

/// Full-screen HUD panel. Shown for scenes (homecoming) or, when "full screen always" is on,
/// for every conversation. Click or Esc dismisses. Hidden otherwise, so it costs nothing.
@MainActor
public final class HUDWindowController: ObservableObject {
    @Published public private(set) var isShowing = false
    public var readouts: HUDReadouts = .empty { didSet { if hosting != nil { rebuild() } } }
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
    /// Bumped by every show and dismiss, so a fade-out that a new show overtook does not hide the panel.
    private var generation = 0
    private var steppedAside = false
    /// Keep the HUD up after a conversation ends, until a click or Esc (menu toggle).
    @Published public var stayOn: Bool = UserDefaults.standard.bool(forKey: "jarvis.hudStayOn") {
        didSet {
            UserDefaults.standard.set(stayOn, forKey: "jarvis.hudStayOn")
            if !stayOn, isShowing, model.phase == .idle { scheduleDismiss() }
            if stayOn { dismissTask?.cancel() }
        }
    }
    private var dismissAfter: TimeInterval = 8
    /// Display name the HUD should use when connected (e.g. "Odyssey G5"); nil = the notch screen.
    public var preferredDisplay: String?

    public init(model: NotchViewModel, dismissAfter: TimeInterval, preferredDisplay: String? = nil) {
        self.model = model
        self.dismissAfter = dismissAfter
        self.preferredDisplay = preferredDisplay
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        // Follow the conversation when "always" is on.
        model.$phase.removeDuplicates().sink { [weak self] phase in
            guard let self else { return }
            if phase == .idle { self.steppedAside = false }
            if phase != .idle, self.fullScreenAlways, !self.isShowing, !self.steppedAside { self.show(scene: false) }
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
        guard let screen = ScreenResolver.target(pinned: preferredDisplay) else { return }
        generation += 1
        dismissTask?.cancel()
        if hosting == nil { rebuild() }
        panel.setFrame(screen.frame, display: true)
        // Already visible (or fading out): fade back up from where it is, never blink to black.
        if !panel.isVisible { panel.alphaValue = 0 }
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
        JarvisLog.info("HUD shown (\(scene ? "scene" : "conversation")) on \(screen.localizedName)")
    }

    /// Something Sam needs to see just opened underneath (a browser page, an app being controlled): get the
    /// HUD out of the way and keep it away for the rest of this conversation.
    public func stepAside(reason: String) {
        steppedAside = true
        dismiss(reason: reason)
    }

    public func sceneEnded() {
        pinnedForScene = false
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        guard !pinnedForScene, !stayOn else { return }
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.dismissAfter))
            guard !Task.isCancelled, self.model.phase == .idle, !self.stayOn else { return }
            self.dismiss(reason: "idle")
        }
    }

    public func dismiss(reason: String) {
        guard isShowing else { return }
        dismissTask?.cancel()
        pinnedForScene = false
        // Hidden as far as the rest of the app is concerned from this moment: a conversation that
        // starts during the fade must be able to bring the HUD straight back.
        isShowing = false
        generation += 1
        let mine = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = model.reduceMotion ? 0.15 : 0.4
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.panel.orderOut(nil)
                // Tear down the view tree: a hidden TimelineView keeps animating and burns CPU.
                self.panel.contentView = nil
                self.hosting = nil
            }
        })
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        JarvisLog.info("HUD dismissed (\(reason))")
    }
}
