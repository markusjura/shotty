import AppKit
import SwiftUI

/// The Drag Me handle of both editors.
struct EditorDragHandle: NSViewRepresentable {
    /// "image" or "clip", for the tooltip and VoiceOver.
    let noun: String
    /// Shown under the pointer when `item` has no preview.
    let placeholderSymbol: String
    /// What a drag hands over, with a small picture of it; nil cancels the drag.
    let item: @MainActor () -> (writer: NSPasteboardWriting, preview: NSImage?)?
    /// Runs once a drop completes. The editor closes then.
    let dropped: @MainActor () -> Void

    func makeNSView(context: Context) -> ExportDragView { ExportDragView() }
    func updateNSView(_ view: ExportDragView, context: Context) {
        view.item = item
        view.dropped = dropped
        view.placeholderSymbol = placeholderSymbol
        view.toolTip = "Drag the \(noun) to Finder or another app"
        view.setAccessibilityLabel("Drag \(noun) to export")
    }
}

/// Dragging hides the editor so its image or clip can go to Finder, a chat, or any window behind
/// it. A completed drop closes the editor; a cancelled drag brings it back.
final class ExportDragView: NSView, NSDraggingSource {
    var item: (@MainActor () -> (writer: NSPasteboardWriting, preview: NSImage?)?)?
    var dropped: (@MainActor () -> Void)?
    var placeholderSymbol = "photo"
    private var started = false
    private var isPressed = false { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true); setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { nil }

    /// The bars' tinted capsule with grip marks on both sides of the label, darkened while pressed.
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        EditorBar.buttonTint.setFill(); path.fill()
        let text = "Drag Me" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: EditorBar.nsFont, .foregroundColor: NSColor.labelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular).applying(.init(paletteColors: [.secondaryLabelColor]))
        if let grip = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            for x in [bounds.minX + 12, bounds.maxX - 12 - grip.size.width] {
                grip.draw(in: CGRect(x: x, y: bounds.midY - grip.size.height / 2, width: grip.size.width, height: grip.size.height))
            }
        }
        if isPressed { NSColor.black.withAlphaComponent(EditorBar.pressedDarkening).setFill(); path.fill() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    /// Dragging works even while the editor is not the key window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { started = false; isPressed = true }
    override func mouseUp(with event: NSEvent) { isPressed = false }
    override func mouseDragged(with event: NSEvent) {
        guard !started, let (writer, preview) = item?() else { return }
        let draggingItem = NSDraggingItem(pasteboardWriter: writer)
        // A small picture of the capture under the pointer, as the editor itself disappears.
        let size = preview?.size ?? CGSize(width: 32, height: 32)
        let point = convert(event.locationInWindow, from: nil)
        draggingItem.setDraggingFrame(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                                      contents: preview ?? NSImage(systemSymbolName: placeholderSymbol, accessibilityDescription: nil))
        started = true
        beginDraggingSession(with: [draggingItem], event: event, source: self)
        // Ordered out rather than made transparent, so drops reach the window underneath. The
        // session outlives the hidden window.
        window?.orderOut(nil)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        started = false; isPressed = false
        if operation.contains(.copy), let dropped { dropped() } else { window?.makeKeyAndOrderFront(nil) }
    }
}
