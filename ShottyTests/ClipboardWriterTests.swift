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

    func testPasteHandlerRunsOnceWhenTheImageIsRead() async {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let writer = ClipboardWriter(pasteboard: board)
        let data = Data([1, 2, 3])
        var pastes = 0
        XCTAssertTrue(writer.write(data, type: .png, ticket: writer.begin(), onPaste: { pastes += 1 }))
        await Task.yield()
        XCTAssertEqual(pastes, 0, "Writing alone is not a paste")

        XCTAssertEqual(board.data(forType: .png), data)
        XCTAssertEqual(board.data(forType: .png), data)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(pastes, 1)
    }
}
