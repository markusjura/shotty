import AppKit
import XCTest
@testable import Shotty

@MainActor
final class CanvasTextUndoTests: XCTestCase {
    func testNativeTypingUndoDoesNotEnterTheDocumentUndoManager() {
        let documentResponder = DocumentResponder()
        let text = CanvasTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 80))
        text.nextResponder = documentResponder
        text.isRichText = false
        text.allowsUndo = true
        text.typingUndoManager.groupsByEvent = false
        text.typingUndoManager.beginUndoGrouping()
        text.insertText("Draft", replacementRange: NSRange(location: 0, length: 0))
        text.breakUndoCoalescing()
        text.typingUndoManager.endUndoGrouping()
        XCTAssertEqual(text.string, "Draft")
        XCTAssertFalse(documentResponder.documentUndo.canUndo)
        XCTAssertTrue(text.typingUndoManager.canUndo)
        text.typingUndoManager.undo()
        XCTAssertEqual(text.string, "")
        text.typingUndoManager.redo()
        XCTAssertEqual(text.string, "Draft")
        text.typingUndoManager.removeAllActions()
    }
}

@MainActor
private final class DocumentResponder: NSResponder {
    let documentUndo = UndoManager()
    override var undoManager: UndoManager? { documentUndo }
}
