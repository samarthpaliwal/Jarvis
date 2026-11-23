import AppKit
import ApplicationServices
import ScreenCaptureKit

public enum ControlError: LocalizedError {
    case noScreen
    public var errorDescription: String? {
        "I couldn't take a picture of the screen. Allow Jarvis in System Settings, under Privacy and Security, Screen and System Audio Recording."
    }
}

/// The real mouse, keyboard, and screen. Needs two permissions only the user can give in System Settings:
/// Accessibility (to move the mouse and press keys) and Screen Recording (to see the screen).
@MainActor
public final class LiveHands: ComputerHands {
    /// Marks events Jarvis made, so its own clicks are not mistaken for the user taking over.
    public static let eventTag: Int64 = 0x4A52_5653
    private let source: CGEventSource?

    public init() {
        source = CGEventSource(stateID: .combinedSessionState)
        source?.userData = Self.eventTag
    }

    public var hasPermission: Bool { AXIsProcessTrusted() }

    public func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    // MARK: Reading what is in front

    private func string(_ element: AXUIElement, _ attribute: String) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return "" }
        return value as? String ?? ""
    }

    private func child(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let v = value,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    public func front() -> ScreenTarget {
        guard let app = NSWorkspace.shared.frontmostApplication else { return ScreenTarget(app: "") }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        let title = child(ax, kAXFocusedWindowAttribute).map { string($0, kAXTitleAttribute) } ?? ""
        return ScreenTarget(app: app.localizedName ?? "", windowTitle: title)
    }

    private func info(_ element: AXUIElement) -> ElementInfo {
        var labels: [String] = []
        var current: AXUIElement? = element
        // The thing under the pointer is often a bare label; the button or link around it carries the name.
        for _ in 0..<3 {
            guard let e = current else { break }
            for a in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute] {
                let s = string(e, a)
                if !s.isEmpty { labels.append(s) }
            }
            if string(e, kAXRoleAttribute) == "AXStaticText" { let v = string(e, kAXValueAttribute); if !v.isEmpty { labels.append(String(v.prefix(80))) } }
            current = child(e, kAXParentAttribute)
        }
        return ElementInfo(role: string(element, kAXRoleAttribute), subrole: string(element, kAXSubroleAttribute), label: labels.joined(separator: " · "))
    }

    public func focusedElement() -> ElementInfo? {
        child(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute).map(info)
    }

    public func element(at point: CGPoint) -> ElementInfo? {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &found) == .success, let found else { return nil }
        return info(found)
    }

    // MARK: Seeing

    public func capture(excludingApps: [String]) async throws -> ScreenShot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        // The display the front window is on; the main one if that cannot be told.
        var display = content.displays.first { $0.displayID == CGMainDisplayID() } ?? content.displays.first
        if let app = NSWorkspace.shared.frontmostApplication,
           let w = content.windows.first(where: { $0.owningApplication?.processID == app.processIdentifier && $0.isOnScreen && $0.windowLayer == 0 }),
           let d = content.displays.first(where: { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) }) { display = d }
        guard let display else { throw ControlError.noScreen }
        let own = Bundle.main.bundleIdentifier
        let hidden = excludingApps.map { $0.lowercased() }
        let excluded = content.applications.filter { a in
            a.bundleIdentifier == own || a.processID == ProcessInfo.processInfo.processIdentifier
                || hidden.contains { a.applicationName.lowercased() == $0 || a.applicationName.lowercased().contains($0) }
        }
        let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
        let width = min(1280, display.width)
        let height = Int((Double(display.height) * Double(width) / Double(max(1, display.width))).rounded())
        let cfg = SCStreamConfiguration()
        cfg.width = width; cfg.height = height; cfg.showsCursor = true
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { throw ControlError.noScreen }
        return ScreenShot(jpeg: jpeg, geometry: .init(imageWidth: image.width, imageHeight: image.height, origin: display.frame.origin,
                                                      pointWidth: Double(display.width), pointHeight: Double(display.height)))
    }

    // MARK: Acting

    private func post(_ event: CGEvent?) {
        event?.setIntegerValueField(.eventSourceUserData, value: Self.eventTag)
        event?.post(tap: .cghidEventTap)
    }

    public func click(at point: CGPoint, count: Int) {
        post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left))
        for n in 1...max(1, min(2, count)) {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                post(e)
            }
        }
    }

    public func type(_ text: String) {
        // In small pieces: some apps drop a long burst.
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                e?.flags = []
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                post(e)
            }
            i += 16
            usleep(8_000)
        }
    }

    public func press(_ key: KeyStroke) {
        var flags: CGEventFlags = []
        if key.command { flags.insert(.maskCommand) }
        if key.shift { flags.insert(.maskShift) }
        if key.option { flags.insert(.maskAlternate) }
        if key.control { flags.insert(.maskControl) }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: key.keyCode, keyDown: down)
            e?.flags = flags
            post(e)
        }
    }

    public func scroll(at point: CGPoint?, lines: Int) {
        if let point { post(CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)) }
        post(CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 1, wheel1: Int32(max(-20, min(20, lines))), wheel2: 0, wheel3: 0))
    }
}

/// Watches for the user taking over while computer control is on: Esc always turns it off, and touching
/// the mouse or keyboard right after Jarvis acted does too.
@MainActor
public final class ControlInterruptWatcher {
    private var monitor: Any?
    private let control: ComputerControl
    public init(control: ComputerControl) { self.control = control }

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            // Jarvis's own events carry its tag.
            if event.cgEvent?.getIntegerValueField(.eventSourceUserData) == LiveHands.eventTag { return }
            let isEscape = event.type == .keyDown && event.keyCode == 53
            Task { @MainActor in
                guard let self, self.control.isEnabled else { return }
                let justActed = self.control.lastActionAt.map { Date().timeIntervalSince($0) < 20 } ?? false
                if isEscape { self.control.disable(reason: "Esc") } else if justActed { self.control.disable(reason: "you took over") }
            }
        }
    }

    public func stop() { if let m = monitor { NSEvent.removeMonitor(m); monitor = nil } }
}
