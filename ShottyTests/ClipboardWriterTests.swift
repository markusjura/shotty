import AppKit
import XCTest
@testable import Shotty

@MainActor
final class ClipboardWriterTests: XCTestCase {
    func testExternalCopyAndNewInvocationPreventLateOutput() {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let writer = ClipboardWriter(pasteboard: board)
        let first = writer.begin()
        board.clearContents(); board.setString("unrelated", forType: .string)
        XCTAssertFalse(writer.write("late", ticket: first))
        XCTAssertEqual(board.string(forType: .string), "unrelated")
        let second = writer.begin()
        XCTAssertFalse(writer.write("older", ticket: first))
        XCTAssertTrue(writer.write("current", ticket: second))
        XCTAssertTrue(writer.write("second display", ticket: second))
        XCTAssertEqual(board.string(forType: .string), "second display")
    }

    func testPasteHandlerRunsOnCommandVOnlyWhileTheImageIsOnTheClipboard() throws {
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: 9))
        }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let writer = ClipboardWriter(pasteboard: board)
        var pastes = 0
        XCTAssertTrue(writer.write(Data([1, 2, 3]), type: .png, ticket: writer.begin(), onPaste: { pastes += 1 }))
        XCTAssertEqual(board.data(forType: .png), Data([1, 2, 3]), "A clipboard manager reading the copy is not a paste")
        writer.handleKeyDown(try key("v", []))
        writer.handleKeyDown(try key("v", [.command, .shift]))
        XCTAssertEqual(pastes, 0)
        writer.handleKeyDown(try key("v", .command))
        writer.handleKeyDown(try key("v", .command))
        XCTAssertEqual(pastes, 1, "Only the first paste counts")

        XCTAssertTrue(writer.write(Data([4]), type: .png, ticket: writer.begin(), onPaste: { pastes += 1 }))
        board.clearContents(); board.setString("other", forType: .string)
        writer.handleKeyDown(try key("v", .command))
        XCTAssertEqual(pastes, 1, "Pasting something copied later leaves the thumbnail")
    }
}
