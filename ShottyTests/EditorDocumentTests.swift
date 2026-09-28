import CoreGraphics
import ImageIO
import XCTest
@testable import Shotty

@MainActor
final class EditorDocumentTests: XCTestCase {
    private func fixture() async throws -> (URL, CaptureSessionStore, CaptureRecord) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-editor-tests-\(UUID())")
        let store = CaptureSessionStore(directory: directory)
        let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8,
                                             bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(RGBAColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let record = try await store.create(image: XCTUnwrap(context.makeImage()), kind: .area, scale: 2)
        return (directory, store, record)
    }

    func testGestureUndoRedoCreatesRevisionsAndReopensWithAnnotations() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sourceBytes = try Data(contentsOf: record.sourceURL)
        let editor = EditorDocument(record: record, store: store)
        let annotation = Annotation(content: .rectangle(rect: CGRect(x: 4, y: 5, width: 30, height: 20), style: .init()))
        let state = AnnotationDocument(annotations: [annotation], crop: CGRect(x: 1, y: 2, width: 60, height: 60))
        editor.commit(state, actionName: "Rectangle")
        XCTAssertEqual(editor.revision, 1)
        editor.undo()
        XCTAssertEqual(editor.state, AnnotationDocument())
        XCTAssertEqual(editor.revision, 2)
        editor.redo()
        XCTAssertEqual(editor.state, state)
        let snapshot = try await editor.flush()
        XCTAssertEqual(snapshot.revision, 3)
        XCTAssertEqual(snapshot.documentState, state)
        XCTAssertFalse(editor.isPersisting)
        XCTAssertEqual(try Data(contentsOf: record.sourceURL), sourceBytes)
        let kept = await store.records()
        let reopened = EditorDocument(record: try XCTUnwrap(kept.first), store: store)
        XCTAssertEqual(reopened.state, state)
        XCTAssertEqual(reopened.revision, 3)
    }

    func testFailedPersistenceKeepsEdits() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditorDocument(record: record, store: store)
        try await store.remove(record.id)
        let state = AnnotationDocument(annotations: [Annotation(content: .counter(center: CGPoint(x: 20, y: 20), number: 1, style: .init()))])
        editor.commit(state, actionName: "Counter")
        do { _ = try await editor.flush(); XCTFail("An edit of a removed capture must not report success") } catch {}
        XCTAssertEqual(editor.state, state)
        XCTAssertNotNil(editor.persistenceError)
    }

    func testExportKeepsRequestedRevisionAndLaterEditRemainsUnsaved() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditorDocument(record: record, store: store)
        let first = AnnotationDocument(crop: CGRect(x: 0, y: 0, width: 32, height: 40))
        editor.commit(first, actionName: "Crop")
        let snapshot = try await editor.flush()
        editor.commit(AnnotationDocument(crop: CGRect(x: 5, y: 5, width: 20, height: 10)), actionName: "Crop")
        _ = try await editor.flush()
        let receipt = try await ExportService().export(snapshot, to: directory)
        try await store.markSaved(receipt)
        let currentRecords = await store.records()
        let current = try XCTUnwrap(currentRecords.first)
        XCTAssertEqual(current.revision, 2)
        XCTAssertEqual(current.savedRevision, 1)
        XCTAssertFalse(current.isSaved)
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(receipt.destinationURL as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        XCTAssertEqual(image.width, 32)
        XCTAssertEqual(image.height, 40)
        let thumbnail = try await store.thumbnail(for: record.id)
        XCTAssertEqual(thumbnail.width, 20)
        XCTAssertEqual(thumbnail.height, 10)
    }

    func testInvalidCropDoesNotChangeDocumentOrRegisterUndo() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditorDocument(record: record, store: store)
        editor.commit(AnnotationDocument(crop: CGRect(x: -1, y: 0, width: 65, height: 64)), actionName: "Crop")
        XCTAssertEqual(editor.state, AnnotationDocument())
        XCTAssertFalse(editor.undoManager.canUndo)
        XCTAssertNotNil(editor.persistenceError)
    }

    func testRenumberUsesChosenStartingNumberAsOneUndoableEdit() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "shotty-renumber-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(record: record, store: store)
        let original = AnnotationDocument(annotations: [
            Annotation(content: .counter(center: CGPoint(x: 15, y: 15), number: 2, style: .init())),
            Annotation(content: .rectangle(rect: CGRect(x: 5, y: 5, width: 30, height: 20), style: .init())),
            Annotation(content: .counter(center: CGPoint(x: 40, y: 40), number: 7, style: .init()))
        ])
        document.commit(original, actionName: "Counters")
        let canvas = EditorCanvas(document: document, source: try await store.image(for: record.id),
                                  preferences: AppPreferences(defaults: defaults), commands: CommandRegistry(defaults: defaults))
        canvas.nextCounter = 12
        canvas.renumber()
        let numbers = document.state.annotations.compactMap { annotation -> Int? in
            if case .counter(_, let number, _) = annotation.content { return number }
            return nil
        }
        XCTAssertEqual(numbers, [12, 13])
        XCTAssertEqual(canvas.nextCounter, 14)
        XCTAssertEqual(document.state.annotations[1].id, original.annotations[1].id)
        XCTAssertEqual(document.state.annotations[1].content, original.annotations[1].content)
        document.undo()
        XCTAssertEqual(document.state, original)
        _ = try await document.flush()
    }

    func testCounterCreationOrderSurvivesArrangeReopenAndRenumber() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "shotty-counter-order-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = AnnotationDocument(annotations: [
            Annotation(content: .counter(center: CGPoint(x: 15, y: 15), number: 7, style: .init())),
            Annotation(content: .counter(center: CGPoint(x: 40, y: 40), number: 2, style: .init()))
        ])
        // Optional ordinals keep older saved annotation JSON readable.
        let legacy = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(legacy.annotations.allSatisfy { $0.creationOrder == nil })
        let document = EditorDocument(record: record, store: store)
        document.commit(legacy, actionName: "Counters")
        let source = try await store.image(for: record.id)
        let preferences = AppPreferences(defaults: defaults), commands = CommandRegistry(defaults: defaults)
        let canvas = EditorCanvas(document: document, source: source, preferences: preferences, commands: commands)
        canvas.selected = [original.annotations[0].id]
        canvas.arrange(.front)
        XCTAssertEqual(document.state.annotations.map(\.id), original.annotations.reversed().map(\.id))
        _ = try await document.flush()

        let kept = await store.records()
        let restored = EditorDocument(record: try XCTUnwrap(kept.first), store: store)
        let reopenedCanvas = EditorCanvas(document: restored, source: source, preferences: preferences, commands: commands)
        reopenedCanvas.nextCounter = 42
        reopenedCanvas.renumber()
        let byID = Dictionary(uniqueKeysWithValues: restored.state.annotations.map { ($0.id, $0) })
        guard case .counter(_, let firstNumber, _) = byID[original.annotations[0].id]?.content,
              case .counter(_, let secondNumber, _) = byID[original.annotations[1].id]?.content else { return XCTFail("Counters preserved") }
        XCTAssertEqual(firstNumber, 42)
        XCTAssertEqual(secondNumber, 43)
        XCTAssertEqual(restored.state.annotations.map(\.id), document.state.annotations.map(\.id), "Renumber cannot rearrange layers")
        _ = try await restored.flush()
    }

    func testDuplicatedAndPastedIDsReceiveNewCreationOrdinals() throws {
        let existing = Annotation(content: .counter(center: .zero, number: 1, style: .init()), creationOrder: 10)
        var duplicate = existing; duplicate.id = UUID()
        let previous = AnnotationDocument(annotations: [existing])
        let next = try AnnotationDocument(annotations: [duplicate, existing]).preservingCreationOrder(from: previous)
        XCTAssertEqual(next.annotations[0].creationOrder, 11)
        XCTAssertEqual(next.annotations[1].creationOrder, 10)
        let encoded = try JSONEncoder().encode(next)
        XCTAssertEqual(try JSONDecoder().decode(AnnotationDocument.self, from: encoded), next)
    }

    func testCanonicalPreviewAndExportContainIdenticalFlattenedPixels() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let state = AnnotationDocument(annotations: [
            Annotation(content: .rectangle(rect: CGRect(x: 4, y: 5, width: 40, height: 30), style: .init(fillColor: .annotationRed))),
            Annotation(content: .redact(rect: CGRect(x: 9, y: 12, width: 24, height: 22), style: .init(style: .solid)))
        ], crop: CGRect(x: 2, y: 3, width: 55, height: 52))
        _ = try await store.updateDocument(for: record.id, state: state, revision: 1)
        let snapshot = try await store.snapshot(for: record.id)
        let source = try await store.image(for: record.id)
        let preview = try DocumentRenderer().render(source: source, state: state)
        let receipt = try await ExportService().export(snapshot, to: directory)
        let encoded = try XCTUnwrap(CGImageSourceCreateWithURL(receipt.destinationURL as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(encoded), 1)
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        XCTAssertEqual(try pixels(preview), try pixels(output))
        XCTAssertEqual(output.width, 55)
        XCTAssertEqual(output.height, 52)
    }

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(success)
        return bytes
    }

    /// CleanShot's model: drawing leaves the new object unselected (redactions and spotlights stay selected), a
    /// press on an object picks it up without leaving the drawing tool, and a click on empty
    /// canvas only deselects.
    func testDrawingToolDrawsUnselectedAndPicksUpExistingObjects() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "shotty-canvas-pointer-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(record: record, store: store)
        let canvas = EditorCanvas(document: document, source: try await store.image(for: record.id),
                                  preferences: AppPreferences(defaults: defaults), commands: CommandRegistry(defaults: defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(canvas)
        canvas.tool = .rectangle
        // Image pixels to window points at the canvas's initial 50% zoom and 12-point margin.
        func press(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
            let point = canvas.convert(CGPoint(x: x / 2 + EditorCanvas.margin, y: y / 2 + EditorCanvas.margin), to: nil)
            return NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: press(.leftMouseDown, 4, 4))
        canvas.mouseDragged(with: press(.leftMouseDragged, 24, 24))
        canvas.mouseUp(with: press(.leftMouseUp, 24, 24))
        let drawn = try XCTUnwrap(document.state.annotations.first)
        XCTAssertTrue(canvas.selected.isEmpty)

        canvas.mouseDown(with: press(.leftMouseDown, 4, 4))
        XCTAssertEqual(canvas.selected, [drawn.id])
        canvas.mouseDragged(with: press(.leftMouseDragged, 14, 4))
        canvas.mouseUp(with: press(.leftMouseUp, 14, 4))
        XCTAssertEqual(document.state.annotations.map(\.bounds), [drawn.translated(by: CGSize(width: 10, height: 0)).bounds])
        XCTAssertEqual(canvas.tool, .rectangle)

        canvas.mouseDown(with: press(.leftMouseDown, 58, 58))
        canvas.mouseUp(with: press(.leftMouseUp, 58, 58))
        XCTAssertTrue(canvas.selected.isEmpty)
        XCTAssertEqual(document.state.annotations.count, 1)

        // A new redaction stays selected, so its corner handles resize it right away.
        canvas.tool = .redact
        canvas.mouseDown(with: press(.leftMouseDown, 44, 44))
        canvas.mouseDragged(with: press(.leftMouseDragged, 62, 62))
        canvas.mouseUp(with: press(.leftMouseUp, 62, 62))
        XCTAssertEqual(document.state.annotations.count, 2)
        let redaction = try XCTUnwrap(document.state.annotations.last)
        XCTAssertEqual(canvas.selected, [redaction.id])
        canvas.mouseDown(with: press(.leftMouseDown, 44, 44))
        canvas.mouseDragged(with: press(.leftMouseDragged, 38, 38))
        canvas.mouseUp(with: press(.leftMouseUp, 38, 38))
        XCTAssertEqual(document.state.annotations.last?.bounds, CGRect(x: 38, y: 38, width: 24, height: 24))

        // So does a new spotlight.
        canvas.tool = .spotlight
        canvas.mouseDown(with: press(.leftMouseDown, 4, 40))
        canvas.mouseDragged(with: press(.leftMouseDragged, 30, 62))
        canvas.mouseUp(with: press(.leftMouseUp, 30, 62))
        XCTAssertEqual(canvas.selected, [try XCTUnwrap(document.state.annotations.last).id])
        _ = try await document.flush()
    }

    /// The next number follows the highest counter in the image; a picked number continues until
    /// it meets that default again.
    func testNextCounterFollowsTheHighestNumberUnlessPicked() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "shotty-next-counter-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let two = Annotation(content: .counter(center: CGPoint(x: 15, y: 15), number: 2, style: .init()))
        let seven = Annotation(content: .counter(center: CGPoint(x: 40, y: 40), number: 7, style: .init()))
        let document = EditorDocument(record: record, store: store)
        document.commit(AnnotationDocument(annotations: [two, seven]), actionName: "Counters")
        let preferences = AppPreferences(defaults: defaults)
        let canvas = EditorCanvas(document: document, source: try await store.image(for: record.id),
                                  preferences: preferences, commands: CommandRegistry(defaults: defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(canvas)
        canvas.tool = .counter
        // Small counters on empty spots of the 64-pixel image; a press on one would select it.
        preferences.editor.tools.width = 4
        var spots = [CGPoint(x: 52, y: 52), CGPoint(x: 15, y: 56)]
        func place() {
            let image = spots.removeFirst()
            let point = canvas.convert(CGPoint(x: image.x / 2 + EditorCanvas.margin, y: image.y / 2 + EditorCanvas.margin), to: nil)
            canvas.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                      clickCount: 1, pressure: 1)!)
        }
        XCTAssertEqual(canvas.nextCounter, 8)
        document.commit(AnnotationDocument(annotations: [two]), actionName: "Delete")
        XCTAssertEqual(canvas.nextCounter, 3, "Deleting the highest counter lowers the next number")

        canvas.nextCounter = 1
        place()
        XCTAssertEqual(canvas.nextCounter, 2, "A picked number continues below the highest")
        place()
        XCTAssertEqual(canvas.nextCounter, 3)
        document.commit(AnnotationDocument(annotations: [two]), actionName: "Delete")
        XCTAssertEqual(canvas.nextCounter, 3, "Once the picked number met the default, it follows the image again")
        _ = try await document.flush()
    }

    /// Before the background render of a redaction arrives, the canvas must not show what it hides.
    func testRedactionHidesContentBeforeItsRenderArrives() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-redact-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureSessionStore(directory: directory)
        // Black and white 4-pixel stripes: legible detail that pixelation must flatten.
        let stripes = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        stripes.setFillColor(RGBAColor.white.cgColor); stripes.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        stripes.setFillColor(RGBAColor.black.cgColor)
        for x in stride(from: 0, to: 64, by: 8) { stripes.fill(CGRect(x: x, y: 0, width: 4, height: 64)) }
        let record = try await store.create(image: XCTUnwrap(stripes.makeImage()), kind: .area, scale: 2)
        let suite = "shotty-redact-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(record: record, store: store)
        let canvas = EditorCanvas(document: document, source: try await store.image(for: record.id),
                                  preferences: AppPreferences(defaults: defaults), commands: CommandRegistry(defaults: defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(canvas)
        document.commit(AnnotationDocument(annotations: [Annotation(content: .redact(rect: CGRect(x: 0, y: 0, width: 64, height: 64),
                                                                                     style: .init()))]))
        canvas.documentChanged()  // Starts the background render, which cannot finish before the draw below.

        let image = CGRect(x: EditorCanvas.margin, y: EditorCanvas.margin, width: 32, height: 32).insetBy(dx: 2, dy: 2)
        let bitmap = try XCTUnwrap(canvas.bitmapImageRepForCachingDisplay(in: image))
        canvas.cacheDisplay(in: image, to: bitmap)
        let row = bitmap.pixelsHigh / 2
        let levels = (0..<bitmap.pixelsWide).compactMap { bitmap.colorAt(x: $0, y: row)?.usingColorSpace(.sRGB)?.brightnessComponent }
        XCTAssertLessThan((levels.max() ?? 1) - (levels.min() ?? 0), 0.5, "The stripes under the redaction show through")
        _ = try await document.flush()
    }

    /// While typing, presses on the text box's handles reach the canvas, not the text view, so
    /// they resize the text instead of moving the caret.
    func testEditingTextHandlesReceivePresses() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "shotty-text-handles-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let document = EditorDocument(record: record, store: store)
        let preferences = AppPreferences(defaults: defaults)
        preferences.editor.tools.width = 4  // The smallest text, so a word fits the 64-pixel image.
        let canvas = EditorCanvas(document: document, source: try await store.image(for: record.id),
                                  preferences: preferences, commands: CommandRegistry(defaults: defaults))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.contentView?.addSubview(canvas)
        canvas.tool = .text
        let start = canvas.convert(CGPoint(x: 1 + EditorCanvas.margin, y: 1 + EditorCanvas.margin), to: nil)
        func press(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: start, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: press(.leftMouseDown)); canvas.mouseUp(with: press(.leftMouseUp))
        let textView = try XCTUnwrap(canvas.subviews.compactMap { $0 as? CanvasTextView }.first)
        textView.insertText("Hi", replacementRange: NSRange(location: 0, length: 0))
        // The right side handle sits 14 points outside the typed text, halfway down. Image pixels
        // map to view points at the initial 50% zoom.
        let box = DocumentRenderer.textSize("Hi", style: preferences.editor.tools.text, width: .greatestFiniteMagnitude)
        let right = CGPoint(x: EditorCanvas.margin + (1 + box.width) / 2 + 14, y: EditorCanvas.margin + (1 + box.height / 2) / 2)
        XCTAssertTrue(window.contentView?.hitTest(canvas.convert(right, to: window.contentView)) === canvas)
        _ = try await document.flush()
    }

    /// Pastes land below and to the right of the copy, cascade when repeated, and stay inside the image.
    func testPasteOffsetsAndCascadesInsideTheImage() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "shotty-paste-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Annotation(content: .rectangle(rect: CGRect(x: 4, y: 4, width: 10, height: 10), style: .init()))
        let document = EditorDocument(record: record, store: store)
        document.commit(AnnotationDocument(annotations: [original]))
        let canvas = EditorCanvas(document: document, source: try await store.image(for: record.id),
                                  preferences: AppPreferences(defaults: defaults), commands: CommandRegistry(defaults: defaults))
        canvas.pasteboard = NSPasteboard(name: NSPasteboard.Name(suite))
        defer { canvas.pasteboard.releaseGlobally() }
        canvas.selected = [original.id]
        canvas.copy(nil)
        canvas.paste(nil); canvas.paste(nil)
        // 16 points per step at the initial 50% zoom is 32 image pixels; the second paste stops at the edge.
        XCTAssertEqual(document.state.annotations.map(\.bounds.origin), [CGPoint(x: 4, y: 4), CGPoint(x: 36, y: 36), CGPoint(x: 54, y: 54)])
        XCTAssertEqual(canvas.selected, [document.state.annotations[2].id])
        _ = try await document.flush()
    }
}
