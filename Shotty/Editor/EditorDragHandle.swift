import AppKit
import SwiftUI

struct EditorDragHandle: NSViewRepresentable {
    let model: EditorWindowModel
    func makeNSView(context: Context) -> ExportDragView { ExportDragView() }
    func updateNSView(_ view: ExportDragView, context: Context) { view.model = model }
}

/// The Drag Me handle. Dragging hides the editor so the image can go to Finder, a chat, or
/// any window behind it. A completed drop closes the editor; a cancelled drag brings it back.
final class ExportDragView: NSView, NSDraggingSource {
    weak var model: EditorWindowModel?
    private var started = false
    private var isPressed = false { didSet { needsDisplay = true } }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Drag the image to Finder or another app"
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Drag image to export")
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
        guard !started, let model else { return }
        model.canvas.finishText()
        guard let url = model.coordinator.dragFile(model.document.snapshot) else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        // A small picture of the image under the pointer, as the editor itself disappears.
        let preview = model.canvas.dragPreview(maxDimension: 120)
        let size = preview?.size ?? CGSize(width: 32, height: 32)
        let point = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height),
                              contents: preview ?? NSImage(systemSymbolName: "photo", accessibilityDescription: nil))
        started = true
        beginDraggingSession(with: [item], event: event, source: self)
        // Ordered out rather than made transparent, so drops reach the window underneath. The
        // session outlives the hidden window.
        window?.orderOut(nil)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        started = false; isPressed = false
        if operation.contains(.copy), let model { model.close?() } else { window?.makeKeyAndOrderFront(nil) }
    }
}
