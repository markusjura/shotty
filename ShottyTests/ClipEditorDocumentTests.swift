import XCTest
@testable import Shotty

@MainActor
final class ClipEditorDocumentTests: XCTestCase {
    func testEveryEditIsAnUndoableRevisionThatReachesTheStore() async throws {
        let folder = try makeTemporaryFolder(self)
        let movie = folder.appendingPathComponent("recording.mp4")
        try await TestMovie.make(at: movie, seconds: 1)
        let store = CaptureSessionStore(directory: folder.appendingPathComponent("Session", isDirectory: true))
        let record = try await store.create(movie: movie, kind: .area, format: .mp4)
        let document = ClipEditorDocument(record: record, store: store)
        var changes = 0
        document.onChange = { changes += 1 }
        // Without a running event loop, each edit gets its own explicit undo group.
        document.undoManager.groupsByEvent = false
        func commit(_ edit: VideoEdit) {
            document.undoManager.beginUndoGrouping()
            document.commit(edit, actionName: "Edit")
            document.undoManager.endUndoGrouping()
        }

        var faster = document.edit; faster.speed = .double
        commit(faster)
        commit(faster)
        var trimmed = faster; trimmed.trimEnd = 0.5
        commit(trimmed)
        XCTAssertEqual(document.revision, 2, "An unchanged edit is not a revision")
        XCTAssertEqual(changes, 2)

        document.undoManager.undo()
        XCTAssertEqual(document.edit, faster)
        XCTAssertEqual(document.revision, 3, "Undo is a new revision, so files rendered from the trim stay valid")
        let flushed = try await document.flush()
        let stored = try await store.clipSnapshot(for: record.id)
        XCTAssertEqual(stored, flushed)
        XCTAssertEqual(stored.edit, faster)

        document.undoManager.redo()
        XCTAssertEqual(document.edit, trimmed)
        let redone = try await document.flush()
        XCTAssertEqual(redone.revision, 4)
    }
}
