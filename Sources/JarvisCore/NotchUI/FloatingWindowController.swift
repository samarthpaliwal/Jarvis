import AppKit
import Combine
import SwiftUI

/// Hosts the Jarvis card on the active screen (under the mouse) or a pinned display.
/// Invisible and click-through while idle: the window is only ordered in while Jarvis is busy.
@MainActor
public final class FloatingWindowController {
    public enum Position: String { case bottom, center, top }

    private let panel: NSPanel
    private let model: NotchViewModel
    private var hosting: NSHostingView<FloatingCardView>?
    private var cancellables: Set<AnyCancellable> = []
    private var hideTask: Task<Void, Never>?
    private var currentScreen: NSScreen?
    public var pinnedDisplay: String?
    public var position: Position = .bottom
    public var onClose: (() -> Void)?

    public init(model: NotchViewModel) {
        self.model = model
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none

        model.$phase.removeDuplicates().sink { [weak self] phase in self?.phaseChanged(phase) }.store(in: &cancellables)
        // Resize to fit the content whenever anything visible changes.
        model.objectWillChange
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] in self?.layout(animated: true) }
            .store(in: &cancellables)
    }

    private func phaseChanged(_ phase: NotchPhase) {
        if phase == .idle {
            hideTask?.cancel()
            hideTask = Task { [weak self] in
                guard let self else { return }
                let panel = self.panel
                NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.2; panel.animator().alphaValue = 0 }, completionHandler: nil)
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, self.model.phase == .idle else { return }
                self.panel.orderOut(nil)
                self.panel.contentView = nil   // stop animations while hidden
                self.hosting = nil
            }
            return
        }
        hideTask?.cancel()
        if !panel.isVisible || hosting == nil {
            currentScreen = ScreenResolver.target(pinned: pinnedDisplay)   // pick the screen when the card appears
            let view = FloatingCardView(model: model) { [weak self] in self?.onClose?() }
            let h = NSHostingView(rootView: view)
            panel.contentView = h
            hosting = h
            layout(animated: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = model.reduceMotion ? 0.1 : 0.22; panel.animator().alphaValue = 1 }
        } else {
            layout(animated: true)
        }
    }

    private func layout(animated: Bool) {
        guard let hosting, let screen = currentScreen ?? ScreenResolver.target(pinned: pinnedDisplay) else { return }
        let size = hosting.fittingSize
        let vf = screen.visibleFrame
        let x = (vf.midX - size.width / 2).rounded()
        let y: CGFloat
        switch position {
        case .bottom: y = vf.minY + 48
        case .center: y = (vf.midY - size.height / 2).rounded()
        case .top: y = vf.maxY - size.height - 48
        }
        let frame = NSRect(x: x, y: y, width: size.width, height: size.height)
        if animated && panel.isVisible && !model.reduceMotion {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().setFrame(frame, display: true) }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}
