import AppKit
import ScreenCaptureKit
import SwiftUI

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
        // A borderless window casts a shadow around whatever it draws, which would outline every
        // highlight with a dark rim.
        panel.hasShadow = false
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

extension SelectionReadout {
    /// The readout for a selection's state: any error; else, while drawing a region, the position
    /// until the region exists and its size while it is dragged, as far as this setting allows.
    func content(error: String?, isDrawing: Bool, hasRegion: Bool, isDragging: Bool,
                 size: @autoclosure () -> CGSize) -> SelectionDrawing.Readout? {
        if let error { return .error(error) }
        guard isDrawing else { return nil }
        if !hasRegion { return showsPosition ? .position : nil }
        return isDragging && showsSize ? .size(size()) : nil
    }
}

/// Drawing shared by the selection views, in view coordinates.
@MainActor
enum SelectionDrawing {
    /// The blue tint over a hovered window. Covers the window's edge as well: macOS draws a dark
    /// rim one device pixel wide just outside the frame, which would otherwise outline the tint.
    /// The corners match a standard window's on macOS 27; there is no public API for another
    /// app's corner radius.
    static func drawWindowHighlight(_ frame: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rim = context.convertToUserSpace(CGSize(width: 1, height: 1)).width
        context.addPath(RoundedRectangle(cornerRadius: 16 + rim, style: .continuous)
            .path(in: frame.insetBy(dx: -rim, dy: -rim)).cgPath)
        targetTint.setFill()
        context.fillPath()
    }

    /// The blue tint over a highlighted display.
    static func drawDisplayHighlight(_ bounds: CGRect) {
        targetTint.setFill()
        bounds.fill()
    }

    private static var targetTint: NSColor { .controlAccentColor.withAlphaComponent(0.22) }

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

    /// What the readout beside the pointer says.
    enum Readout: Equatable {
        /// The pointer's position on its display, in pixels from the top left.
        case position
        /// A region's size in output pixels.
        case size(CGSize)
        case error(String)
    }

    /// Draws `readout` in a small island capsule 12 pt below and right of the pointer at `point`,
    /// flipping to the other side near an edge of `bounds`. `scale` turns points into pixels.
    static func drawReadout(_ readout: Readout, at point: CGPoint, in bounds: CGRect, scale: CGFloat) {
        let text: NSAttributedString = switch readout {
        case .position: labeledValues(("X", Int(point.x * scale)), ("Y", Int((bounds.height - point.y) * scale)))
        case .size(let size): labeledValues(("W", Int(size.width)), ("H", Int(size.height)))
        case .error(let message): warning(message)
        }
        let textSize = text.size()
        let size = CGSize(width: ceil(textSize.width) + 2 * readoutPadding, height: Chrome.readoutHeight)
        let offset: CGFloat = 12, margin: CGFloat = 4
        var origin = CGPoint(x: point.x + offset, y: point.y - offset - size.height)
        if origin.x + size.width > bounds.maxX - margin { origin.x = point.x - offset - size.width }
        if origin.y < bounds.minY + margin { origin.y = point.y + offset }
        origin.x = min(max(origin.x, bounds.minX + margin), bounds.maxX - margin - size.width)
        let pill = CGRect(origin: origin, size: size)
        let capsule = NSBezierPath(roundedRect: pill, xRadius: size.height / 2, yRadius: size.height / 2)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.4)
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        shadow.shadowBlurRadius = 3
        shadow.set()
        Chrome.islandFill.setFill()
        capsule.fill()
        NSGraphicsContext.restoreGraphicsState()
        let rim = NSBezierPath(roundedRect: pill.insetBy(dx: 0.25, dy: 0.25), xRadius: size.height / 2 - 0.25, yRadius: size.height / 2 - 0.25)
        rim.lineWidth = 0.5
        Chrome.islandRim.setStroke()
        rim.stroke()
        text.draw(at: CGPoint(x: pill.minX + readoutPadding, y: pill.minY + (size.height - textSize.height) / 2))
    }

    private static let readoutPadding: CGFloat = 6
    private static let readoutValueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let readoutKeyFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    /// Dimmed letters before tabular values, such as "X 1628  Y 996", so the numbers lead.
    private static func labeledValues(_ pairs: (key: String, value: Int)...) -> NSAttributedString {
        let text = NSMutableAttributedString()
        for (index, pair) in pairs.enumerated() {
            text.append(NSAttributedString(string: pair.key, attributes: [
                .font: readoutKeyFont, .foregroundColor: Chrome.islandLabel.withAlphaComponent(0.5), .kern: 3]))
            text.append(NSAttributedString(string: "\(pair.value)", attributes: [
                .font: readoutValueFont, .foregroundColor: Chrome.islandLabel]))
            // Kerning the value's last digit opens the gap before the next letter.
            if index < pairs.count - 1 { text.addAttribute(.kern, value: 7, range: NSRange(location: text.length - 1, length: 1)) }
        }
        return text
    }

    /// A yellow warning sign before `message`.
    private static func warning(_ message: String) -> NSAttributedString {
        let text = NSMutableAttributedString()
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            // The mark, then the triangle around it.
            .applying(NSImage.SymbolConfiguration(paletteColors: [.black, .systemYellow]))
        if let symbol = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) {
            let attachment = NSTextAttachment()
            attachment.image = symbol
            attachment.bounds = CGRect(x: 0, y: -1, width: symbol.size.width, height: symbol.size.height)
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " ", attributes: [.font: readoutValueFont, .kern: 1]))
        }
        text.append(NSAttributedString(string: message, attributes: [.font: readoutValueFont, .foregroundColor: Chrome.islandLabel]))
        return text
    }
}
