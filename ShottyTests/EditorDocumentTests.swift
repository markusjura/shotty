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

    func testGestureUndoRedoCreatesDurableRevisionsAndReopensWithAnnotations() async throws {
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
        let recovery = try await CaptureSessionStore(directory: directory).load()
        let reopened = EditorDocument(record: try XCTUnwrap(recovery.records.first), store: store)
        XCTAssertEqual(reopened.state, state)
        XCTAssertEqual(reopened.revision, 3)
    }

    func testFailedPersistenceKeepsEditsAndFlushRetries() async throws {
        let (directory, store, record) = try await fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = EditorDocument(record: record, store: store)
        let manifest = directory.appendingPathComponent("session.json")
        let original = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        let state = AnnotationDocument(annotations: [Annotation(content: .counter(center: CGPoint(x: 20, y: 20), number: 1, style: .init()))])
        editor.commit(state, actionName: "Counter")
        do { _ = try await editor.flush(); XCTFail("Failed disk commit must not report success") } catch {}
        XCTAssertEqual(editor.state, state)
        XCTAssertNotNil(editor.persistenceError)
        try FileManager.default.removeItem(at: manifest)
        try original.write(to: manifest)
        let persisted = try await editor.flush()
        XCTAssertEqual(persisted.documentState, state)
        XCTAssertNil(editor.persistenceError)
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

        let restoredStore = CaptureSessionStore(directory: directory)
        let recovery = try await restoredStore.load()
        try await restoredStore.resume()
        let restored = EditorDocument(record: try XCTUnwrap(recovery.records.first), store: restoredStore)
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
}
