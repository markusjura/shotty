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
    override func draw(_ dirtyRect: NSRect) {
        let text = "Drag Image" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
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
