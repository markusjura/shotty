import AppKit
import SwiftUI

struct EditorDragHandle: NSViewRepresentable {
    let model: EditorWindowModel
    func makeNSView(context: Context) -> ExportDragView { ExportDragView() }
    func updateNSView(_ view: ExportDragView, context: Context) { view.model = model }
}

final class ExportDragView: NSView, NSDraggingSource {
    weak var model: EditorWindowModel?
    private var started = false
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Drag a flattened image to Finder or another app"
        setAccessibilityElement(true); setAccessibilityRole(.image); setAccessibilityLabel("Drag image to export")
    }
    required init?(coder: NSCoder) { nil }
    /// A bordered capsule with grip marks, so the export handle reads as something to grab.
    override func draw(_ dirtyRect: NSRect) {
        let capsule = bounds.insetBy(dx: 0.5, dy: 2.5)
        let path = NSBezierPath(roundedRect: capsule, xRadius: capsule.height / 2, yRadius: capsule.height / 2)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.12).setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.stroke()
        let text = "Drag Image" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium),
                                                         .foregroundColor: NSColor.secondaryLabelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium).applying(.init(paletteColors: [.tertiaryLabelColor]))
        if let grip = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            for x in [capsule.minX + 10, capsule.maxX - 10 - grip.size.width] {
                grip.draw(in: CGRect(x: x, y: bounds.midY - grip.size.height / 2, width: grip.size.width, height: grip.size.height))
            }
        }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { started = false }
    override func mouseDragged(with event: NSEvent) {
        guard !started, let model else { return }
        model.canvas.finishText()
        let provider = model.coordinator.filePromise(snapshot: model.document.snapshot)
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: NSImage(systemSymbolName: "photo", accessibilityDescription: nil))
        started = true
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        started = false
        if let model {
            model.coordinator.thumbnails.dragFinished?(model.document.record.id, operation.contains(.copy), true)
        }
    }
}
