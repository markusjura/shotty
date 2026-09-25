import AppKit
import XCTest
@testable import Shotty

@MainActor
final class EditorZoomTests: XCTestCase {
    func testFitShowsTheEntireTallCaptureBelowTheManualZoomMinimum() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 30_000, bitsPerComponent: 8,
                                             bytesPerRow: 64, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let record = CaptureRecord(id: UUID(), kind: .scrolling, createdAt: Date(), pixelWidth: 16, pixelHeight: 30_000,
                                   sourceScale: 1, sourceURL: URL(fileURLWithPath: "/unused-zoom-test-source"), revision: 0)
        let suite = "shotty-zoom-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CaptureSessionStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        let canvas = EditorCanvas(document: EditorDocument(record: record, store: store),
                                  source: try XCTUnwrap(context.makeImage()), preferences: AppPreferences(defaults: defaults),
                                  commands: CommandRegistry(defaults: defaults))
        let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: 720, height: 310))
        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        canvas.fit()

        XCTAssertTrue(canvas.isFitting)
        XCTAssertGreaterThan(canvas.zoom, 0)
        XCTAssertLessThan(canvas.zoom, 0.025)
        XCTAssertEqual(canvas.zoom, (scroll.contentSize.height - 2 * EditorCanvas.margin) / 30_000, accuracy: 0.000_001)
        XCTAssertTrue(scroll.contentView.bounds.contains(canvas.frame))

        // Zooming out at a small fitted scale never reverses direction.
        let fittedZoom = canvas.zoom
        canvas.setZoom(fittedZoom / 1.25)
        XCTAssertFalse(canvas.isFitting)
        XCTAssertEqual(canvas.zoom, fittedZoom)
        canvas.setZoom(fittedZoom * 1.1)
        XCTAssertEqual(canvas.zoom, fittedZoom * 1.1, accuracy: 0.000_001)

        // Ordinary explicit zoom keeps its existing limits.
        canvas.setZoom(1)
        canvas.setZoom(0.001)
        XCTAssertFalse(canvas.isFitting)
        XCTAssertEqual(canvas.zoom, 0.025)
    }
}
