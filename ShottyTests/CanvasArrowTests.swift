import AppKit
import ImageIO
import XCTest
@testable import Shotty

@MainActor
final class CanvasArrowTests: XCTestCase {
    func testCurvedArrowsFollowTheLargestDragDeviationInEitherDirection() async throws {
        try await withCanvas { canvas, _, _ in
            let paths: [(points: [CGPoint], bend: CGPoint)] = [
                ([CGPoint(x: 100, y: 200), CGPoint(x: 150, y: 230), CGPoint(x: 250, y: 140), CGPoint(x: 400, y: 200)], CGPoint(x: 250, y: 80)),
                ([CGPoint(x: 400, y: 200), CGPoint(x: 250, y: 260), CGPoint(x: 100, y: 200)], CGPoint(x: 250, y: 320)),
                ([CGPoint(x: 250, y: 50), CGPoint(x: 310, y: 200), CGPoint(x: 250, y: 350)], CGPoint(x: 370, y: 200)),
                ([CGPoint(x: 100, y: 200), CGPoint(x: 250, y: 202), CGPoint(x: 400, y: 200)], CGPoint(x: 250, y: 260)),
                ([CGPoint(x: 200, y: 200), CGPoint(x: 250, y: 350), CGPoint(x: 300, y: 200)], CGPoint(x: 250, y: 300))
            ]
            for (points, bend) in paths {
                try draw(points, on: canvas)
                let arrow = try arrow(in: canvas.document.state)
                XCTAssertEqual(arrow.start, points.first)
                XCTAssertEqual(arrow.end, points.last)
                XCTAssertEqual(arrow.bend, bend)
                XCTAssertTrue(canvas.selected.isEmpty)
                canvas.document.undo()
                XCTAssertTrue(canvas.document.state.annotations.isEmpty)
            }
        }
    }

    func testReleaseCommitsTheFinalEndpointAndBendSurvivesUndoReopenAndExport() async throws {
        try await withCanvas { canvas, _, store in
            canvas.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 100, y: 200), on: canvas))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 250, y: 140), on: canvas))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 300, y: 200), on: canvas))
            XCTAssertTrue(canvas.document.state.annotations.isEmpty, "Dragging previews without committing")
            XCTAssertEqual(try arrow(in: canvas.visibleState).end, CGPoint(x: 300, y: 200))
            canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 400, y: 200), on: canvas))
            let state = canvas.document.state
            XCTAssertEqual(try arrow(in: state).end, CGPoint(x: 400, y: 200))
            XCTAssertEqual(try arrow(in: state).bend, CGPoint(x: 250, y: 80))
            XCTAssertEqual(canvas.document.revision, 1)
            canvas.document.undo()
            XCTAssertTrue(canvas.document.state.annotations.isEmpty)
            canvas.document.redo()
            XCTAssertEqual(canvas.document.state, state)
            _ = try await canvas.document.flush()
            let records = await store.records()
            let reopened = EditorDocument(record: try XCTUnwrap(records.first?.image), store: store)
            XCTAssertEqual(reopened.state, state)

            // The stored control point remains an ordinary editable bend handle.
            let annotation = try XCTUnwrap(state.annotations.first)
            XCTAssertEqual(EditorGeometry.handles(for: annotation).last?.1, CGPoint(x: 250, y: 80))
            canvas.selected = [annotation.id]
            try draw([CGPoint(x: 250, y: 80), CGPoint(x: 250, y: 100)], on: canvas)
            XCTAssertEqual(try arrow(in: canvas.document.state).bend, CGPoint(x: 250, y: 100))

            let snapshot = try await canvas.document.flush()
            let receipt = try await ExportService().export(snapshot, to: store.directory)
            let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(receipt.destinationURL as CFURL, nil))
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
            // Away from the head, the shaft bends above the chord in the exported pixels too.
            let bitmap = NSBitmapImageRep(cgImage: image)
            let above = try XCTUnwrap(bitmap.colorAt(x: 245, y: 149)?.usingColorSpace(.deviceRGB))
            let chord = try XCTUnwrap(bitmap.colorAt(x: 245, y: 200)?.usingColorSpace(.deviceRGB))
            XCTAssertGreaterThan(above.redComponent, above.greenComponent + 0.3)
            XCTAssertEqual(chord.greenComponent, 1, accuracy: 0.01)
        }
    }

    func testShiftChangesTheEndpointWithoutDiscardingTheDragPath() async throws {
        try await withCanvas { canvas, _, _ in
            canvas.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 100, y: 200), on: canvas))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 250, y: 140), on: canvas))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 400, y: 220), on: canvas))
            canvas.flagsChanged(with: try event(.flagsChanged, at: CGPoint(x: 400, y: 220), on: canvas, flags: .shift))
            let preview = try arrow(in: canvas.visibleState)
            XCTAssertEqual(preview.end.y, 200, accuracy: 0.001)
            XCTAssertEqual(try XCTUnwrap(preview.bend).y, 80, accuracy: 0.001)
            canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 400, y: 220), on: canvas, flags: .shift))
            XCTAssertEqual(try arrow(in: canvas.document.state).bend, preview.bend)
        }
    }

    func testCancelledAndClickGesturesDoNotLeakIntoTheNextArrow() async throws {
        try await withCanvas { canvas, preferences, _ in
            canvas.mouseDown(with: try event(.leftMouseDown, at: CGPoint(x: 100, y: 200), on: canvas))
            canvas.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 250, y: 50), on: canvas))
            canvas.cancelInteraction()
            canvas.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 400, y: 200), on: canvas))
            try draw([CGPoint(x: 100, y: 200), CGPoint(x: 100, y: 200)], on: canvas)
            XCTAssertTrue(canvas.document.state.annotations.isEmpty)
            XCTAssertFalse(canvas.document.undoManager.canUndo)
            try draw([CGPoint(x: 100, y: 200), CGPoint(x: 400, y: 200)], on: canvas)
            XCTAssertEqual(try arrow(in: canvas.document.state).bend, CGPoint(x: 250, y: 260))
            canvas.document.undo()
            for style in [ArrowStyle.standard, .double] {
                preferences.editor.tools.arrow.style = style
                try draw([CGPoint(x: 100, y: 200), CGPoint(x: 250, y: 50), CGPoint(x: 400, y: 200)], on: canvas)
                XCTAssertNil(try arrow(in: canvas.document.state).bend)
                canvas.document.undo()
            }
        }
    }

    private func arrow(in state: AnnotationDocument) throws -> (start: CGPoint, end: CGPoint, bend: CGPoint?) {
        let annotation = try XCTUnwrap(state.annotations.last)
        guard case .arrow(let start, let end, let bend, _) = annotation.content else {
            throw DocumentRenderer.Failure.invalidDocument
        }
        return (start, end, bend)
    }

    private func draw(_ points: [CGPoint], on canvas: EditorCanvas) throws {
        canvas.mouseDown(with: try event(.leftMouseDown, at: XCTUnwrap(points.first), on: canvas))
        for point in points.dropFirst() { canvas.mouseDragged(with: try event(.leftMouseDragged, at: point, on: canvas)) }
        canvas.mouseUp(with: try event(.leftMouseUp, at: XCTUnwrap(points.last), on: canvas))
    }

    private func event(_ type: NSEvent.EventType, at point: CGPoint, on canvas: EditorCanvas,
                       flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let viewPoint = CGPoint(x: (point.x - canvas.viewport.minX) * canvas.zoom + EditorCanvas.margin,
                                y: (point.y - canvas.viewport.minY) * canvas.zoom + EditorCanvas.margin)
        if type == .flagsChanged {
            return try XCTUnwrap(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: 0,
                                                 windowNumber: canvas.window?.windowNumber ?? 0, context: nil,
                                                 characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 56))
        }
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(viewPoint, to: nil),
                                               modifierFlags: flags, timestamp: 0, windowNumber: canvas.window?.windowNumber ?? 0,
                                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    private func withCanvas(_ body: @MainActor (EditorCanvas, AppPreferences, CaptureSessionStore) async throws -> Void) async throws {
        let suite = "shotty-arrow-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = CaptureSessionStore(directory: directory)
        let context = try XCTUnwrap(CGContext(data: nil, width: 500, height: 400, bitsPerComponent: 8, bytesPerRow: 2000,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 500, height: 400))
        let image = try XCTUnwrap(context.makeImage())
        let record = try await store.create(image: image, kind: .area, scale: 1)
        let preferences = AppPreferences(defaults: defaults)
        preferences.editor.tools.arrow = .init(color: .annotationRed, width: 4, style: .curved)
        let canvas = EditorCanvas(document: EditorDocument(record: record, store: store), source: image,
                                  preferences: preferences, commands: CommandRegistry(defaults: defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 524, height: 424), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        canvas.setZoom(1)
        canvas.tool = .arrow
        defer { window.close() }
        try await body(canvas, preferences, store)
        _ = try await canvas.document.flush()
    }
}
