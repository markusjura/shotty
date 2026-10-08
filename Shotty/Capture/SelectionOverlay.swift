import AppKit
import ScreenCaptureKit

// Pieces the screenshot and recording selections share: their panels, the crosshair, the windows
// they can pick, and how they draw handles and the pointer readout.

/// Screen-parameter notifications also cover changes that do not invalidate selection geometry.
struct SelectionScreenLayout: Equatable {
    struct Display: Equatable {
        var id: CGDirectDisplayID
        var frame: CGRect
        var scale: CGFloat
        var pixelSize: CGSize
        var rotation: Double
    }

    let displays: [Display]

    init(displays: [Display]) { self.displays = displays.sorted { $0.id < $1.id } }

    @MainActor static var current: SelectionScreenLayout {
        SelectionScreenLayout(displays: NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return Display(id: id, frame: screen.frame, scale: screen.backingScaleFactor,
                           pixelSize: CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id)),
                           rotation: CGDisplayRotation(id))
        })
    }
}

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The selection surface over one display. It takes clicks and keys without activating Shotty.
    static func covering(_ frame: CGRect, content: NSView) -> SelectionPanel {
        let panel = SelectionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Transparent areas would otherwise pass clicks through to the app underneath.
        panel.ignoresMouseEvents = false
        panel.level = Chrome.floatingLevel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Display-sized surfaces must appear and vanish at once. AppKit's default window animation
        // would briefly zoom and blur the frozen screen over the live one on every display.
        panel.animationBehavior = .none
        panel.contentView = content
        return panel
    }
}

/// A clickable overlay control that never takes keyboard focus, so typing keeps reaching the app
/// underneath and Return and Escape keep reaching the panel that handles them.
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    /// Stable across reconnection and rearrangement; matches `ThumbnailDisplayPolicy.display(uuid:)`.
    var displayUUID: String? {
        guard let displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

extension NSCursor {
    /// Area crosshair: a one-point black plus inside a white outline with a faint dark rim, so it
    /// reads on light and dark content alike.
    @MainActor static let captureCrosshair: NSCursor = {
        let size: CGFloat = 23
        let mid = size / 2
        let image = NSImage(size: CGSize(width: size, height: size), flipped: false) { _ in
            let plus = NSBezierPath()
            plus.move(to: CGPoint(x: 3, y: mid)); plus.line(to: CGPoint(x: size - 3, y: mid))
            plus.move(to: CGPoint(x: mid, y: 3)); plus.line(to: CGPoint(x: mid, y: size - 3))
            plus.lineCapStyle = .round
            plus.lineWidth = 4
            NSColor.black.withAlphaComponent(0.3).setStroke()
            plus.stroke()
            plus.lineWidth = 3
            NSColor.white.setStroke()
            plus.stroke()
            plus.lineCapStyle = .butt
            plus.lineWidth = 1
            NSColor.black.setStroke()
            plus.stroke()
            return true
        }
        return NSCursor(image: image, hotSpot: CGPoint(x: mid, y: mid))
    }()
}

/// A window a selection can pick, in AppKit coordinates.
struct WindowTarget {
    let id: CGWindowID
    let title: String
    let frame: CGRect

    /// On-screen normal windows, frontmost first. Screenshots include Shotty's own windows, such as
    /// Settings; recordings leave them out, because recordings never show them. Windows narrower or
    /// shorter than `minimumSide` points are skipped.
    @MainActor static func onScreen(_ screens: [NSScreen], includesShotty: Bool, minimumSide: CGFloat = 0) async throws -> [WindowTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        let own = ProcessInfo.processInfo.processIdentifier
        let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        return content.windows.compactMap { window in
            guard window.isOnScreen, window.windowLayer == 0,
                  window.frame.width >= minimumSide, window.frame.height >= minimumSide,
                  let app = window.owningApplication, includesShotty || app.processID != own,
                  let display = content.displays.first(where: { $0.frame.intersects(window.frame) }),
                  let screen = screens.first(where: { $0.displayID == display.displayID }) else { return nil }
            let geometry = DisplayGeometry(appKitFrame: screen.frame, captureFrame: display.frame)
            let topLeft = geometry.appKitPoint(fromCapture: window.frame.origin)
            return WindowTarget(id: window.windowID,
                title: [app.applicationName, window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
                frame: CGRect(x: topLeft.x, y: topLeft.y - window.frame.height,
                              width: window.frame.width, height: window.frame.height))
        }.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }
}

/// Drawing shared by the selection views, in view coordinates.
@MainActor
enum SelectionDrawing {
    /// White corner brackets and edge bars drawn just outside the region, clear of its pixels.
    static func drawHandles(around rect: CGRect) {
        let width: CGFloat = 4
        let edge = rect.insetBy(dx: -width / 2, dy: -width / 2)
        let arm = min(18, edge.width / 2, edge.height / 2)
        let path = NSBezierPath()
        for (x, dx) in [(edge.minX, arm), (edge.maxX, -arm)] {
            for (y, dy) in [(edge.minY, arm), (edge.maxY, -arm)] {
                path.move(to: CGPoint(x: x + dx, y: y))
                path.line(to: CGPoint(x: x, y: y))
                path.line(to: CGPoint(x: x, y: y + dy))
            }
        }
        let bar: CGFloat = 9
        if edge.width > 4 * arm {
            for y in [edge.minY, edge.maxY] {
                path.move(to: CGPoint(x: edge.midX - bar, y: y))
                path.line(to: CGPoint(x: edge.midX + bar, y: y))
            }
        }
        if edge.height > 4 * arm {
            for x in [edge.minX, edge.maxX] {
                path.move(to: CGPoint(x: x, y: edge.midY - bar))
                path.line(to: CGPoint(x: x, y: edge.midY + bar))
            }
        }
        path.lineWidth = width
        path.lineJoinStyle = .miter
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 2
        shadow.set()
        NSColor.white.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The readout beside the pointer at `point`: an error, else the pointer position before a
    /// region exists and its size in pixels once it does.
    static func drawReadout(at point: CGPoint, in bounds: CGRect, error: String?, size: CGSize?) {
        let message = error ?? size.map { "\(Int($0.width)) × \(Int($0.height)) px" }
            ?? "X \(Int(point.x))  Y \(Int(bounds.height - point.y))"
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                         .foregroundColor: NSColor.white]
        let textSize = (message as NSString).size(withAttributes: attributes)
        let label = CGRect(x: min(bounds.maxX - textSize.width - 20, max(8, point.x + 16)),
                           y: max(8, point.y - 36), width: textSize.width + 12, height: textSize.height + 8)
        Chrome.readoutFill.setFill()
        NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
        (message as NSString).draw(at: CGPoint(x: label.minX + 6, y: label.minY + 4), withAttributes: attributes)
    }
}
