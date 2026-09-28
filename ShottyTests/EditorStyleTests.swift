import XCTest
@testable import Shotty

@MainActor
final class EditorStyleTests: XCTestCase {
    func testEditorReopensWithTheLastDrawingToolAndSharedColorAndWidth() throws {
        let suite = "shotty-style-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        let first = try makeModel(preferences, defaults)
        XCTAssertEqual(first.tool, .rectangle)
        XCTAssertEqual(first.canvas.tool, .rectangle)
        XCTAssertEqual(first.defaults.rectangle, EditorToolDefaults.Rectangle(strokeColor: .annotationBlue, width: 8))
        XCTAssertEqual(first.defaults.counter.size, 57.6, "Counters follow the shared thickness stop")
        XCTAssertEqual(first.defaults.text.size, 36, "So does text")

        first.binding(\.counterSize).wrappedValue = 77
        XCTAssertEqual(first.defaults.width, 14, "A counter size picks the matching thickness stop")
        first.binding(\.textSize).wrappedValue = 24
        XCTAssertEqual(first.defaults.width, 4, "So does a text size")
        XCTAssertEqual(EditorToolDefaults.counterTextSize(forDiameter: EditorToolDefaults().counter.size), 36, accuracy: 0.001,
                       "Counter digits match the stop's text size")

        first.tool = .arrow
        first.binding(\.color).wrappedValue = .annotationRed
        first.binding(\.width).wrappedValue = 6
        first.tool = .select
        first.tool = .crop

        let reopened = try makeModel(AppPreferences(defaults: defaults), defaults)
        XCTAssertEqual(reopened.tool, .arrow, "Select and Crop are not drawing tools")
        let tools = reopened.defaults
        XCTAssertEqual(tools.line, EditorToolDefaults.Line(color: .annotationRed, width: 6))
        XCTAssertEqual(tools.filledRectangle.fillColor, .annotationRed)
        XCTAssertEqual(tools.text.color, .annotationRed)
        XCTAssertEqual(tools.text.size, 32)
        XCTAssertEqual(tools.counter, EditorToolDefaults.Counter(color: .annotationRed, size: 51.2))
    }

    func testAdoptingAnObjectStyleKeepsFilledRectanglesFilled() {
        var tools = EditorToolDefaults()
        tools.filledRectangle = .init(strokeColor: .black, width: 2, fillColor: .black)
        tools.color = .white
        XCTAssertEqual(tools.filledRectangle, .init(strokeColor: .white, width: 2, fillColor: .white))
        XCTAssertEqual(AnnotationContent.rectangle(rect: .zero, style: tools.filledRectangle).tool, .filledRectangle)
        XCTAssertEqual(AnnotationContent.rectangle(rect: .zero, style: tools.rectangle).tool, .rectangle)
    }

    private func makeModel(_ preferences: AppPreferences, _ defaults: UserDefaults) throws -> EditorWindowModel {
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let record = CaptureRecord(id: UUID(), kind: .area, createdAt: Date(), pixelWidth: 8, pixelHeight: 8,
                                   sourceScale: 1, sourceURL: URL(fileURLWithPath: "/unused-style-test-source"), revision: 0)
        return EditorWindowModel(record: record, image: try XCTUnwrap(context.makeImage()),
                                 coordinator: AppCoordinator(preferences: preferences), commands: CommandRegistry(defaults: defaults))
    }
}
