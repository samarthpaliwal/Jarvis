import AppKit

/// A small window in the corner that shows the picture Jarvis last took of the screen, and what it did
/// next, so Sam can watch what it is seeing. Clicks pass straight through it, and because it belongs to
/// Jarvis it is never part of the next picture.
@MainActor
public final class SeeingPreview {
    private var panel: NSPanel?
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()

    public init() {}

    private func build() -> NSPanel {
        let size = NSSize(width: 360, height: 249)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true                       // never in the way of a click, Sam's or Jarvis's
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        let box = NSView(frame: NSRect(origin: .zero, size: size))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        box.layer?.cornerRadius = 10
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.systemTeal.withAlphaComponent(0.8).cgColor
        box.layer?.masksToBounds = true
        imageView.frame = NSRect(x: 4, y: 24, width: size.width - 8, height: size.height - 28)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        caption.frame = NSRect(x: 8, y: 4, width: size.width - 16, height: 16)
        caption.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        caption.textColor = .white
        caption.lineBreakMode = .byTruncatingTail
        box.addSubview(imageView); box.addSubview(caption)
        p.contentView = box
        return p
    }

    private func place(_ p: NSPanel) {
        let visible = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        p.setFrameOrigin(NSPoint(x: visible.maxX - p.frame.width - 16, y: visible.maxY - p.frame.height - 16))
    }

    /// The picture Jarvis just took.
    public func show(jpeg: Data, app: String) {
        guard let image = NSImage(data: jpeg) else { return }
        let p = panel ?? build()
        panel = p
        imageView.image = image
        caption.stringValue = "Jarvis sees \(app) · \(Self.time.string(from: Date())) · Esc stops it"
        if !p.isVisible { place(p); p.orderFrontRegardless() }
    }

    /// What it did after looking ("Clicked", "Typed …").
    public func note(_ text: String) {
        guard panel?.isVisible == true else { return }
        caption.stringValue = "\(text) · \(Self.time.string(from: Date()))"
    }

    public func hide() {
        panel?.orderOut(nil)
        imageView.image = nil          // the picture is not kept once control is off
    }
}
