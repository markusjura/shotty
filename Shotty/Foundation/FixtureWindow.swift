import AppKit

/// Synthetic pixels only. This fixture is deliberately capturable by the foundation harness.
@MainActor
final class FixtureWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    private let canvas = FixtureView(frame: CGRect(x: 0, y: 0, width: 640, height: 420))
    private var timer: Timer?

    override init() {
        window = NSWindow(contentRect: canvas.frame, styleMask: [.titled, .closable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        window.title = "Shotty synthetic capture fixture"
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        window.setFrameOrigin(CGPoint(x: 80, y: 140))
    }

    func show() {
        window.orderFront(nil)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.canvas.tick += 1
                self?.canvas.needsDisplay = true
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) { stop() }
}

@MainActor
private final class FixtureView: NSView {
    var tick = 0
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        bounds.fill()
        for row in 0..<14 {
            NSColor(calibratedHue: CGFloat(row) / 14, saturation: 0.45, brightness: 0.95, alpha: 1).setFill()
            CGRect(x: 0, y: CGFloat(row * 30), width: bounds.width, height: 30).fill()
            ("Synthetic row \(row) • ABCDEFG 0123456789" as NSString).draw(
                at: CGPoint(x: 14, y: CGFloat(row * 30 + 6)),
                withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .medium), .foregroundColor: NSColor.black])
        }
        NSColor.white.setFill()
        CGRect(x: 300, y: 155, width: 300, height: 94).fill()
        ("LIVE FRAME \(tick)" as NSString).draw(at: CGPoint(x: 314, y: 172), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.black])
        NSColor.systemBlue.setFill()
        CGRect(x: 314 + CGFloat(tick % 20) * 10, y: 214, width: 30, height: 18).fill()
    }
}
