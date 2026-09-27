import AppKit
import XCTest
@testable import Shotty

final class CropGeometryTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)

    func testAspectSelectionImmediatelyFitsTheCurrentCrop() {
        let crop = CropGeometry.applyingAspect(1, to: bounds, within: bounds)
        XCTAssertEqual(crop, CGRect(x: 100, y: 0, width: 600, height: 600))
    }

    func testNumericWidthAndHeightPreserveAspectAndStopAtBounds() {
        let crop = CGRect(x: 100, y: 100, width: 200, height: 100)
        XCTAssertEqual(CropGeometry.resized(crop, width: 300, aspect: 2, within: bounds),
                       CGRect(x: 100, y: 100, width: 300, height: 150))
        XCTAssertEqual(CropGeometry.resized(crop, height: 1_000, aspect: 2, within: bounds),
                       CGRect(x: 100, y: 100, width: 700, height: 350))
        XCTAssertEqual(CropGeometry.resized(crop, height: -4, aspect: 2, within: bounds).size,
                       CGSize(width: 2, height: 1))
        XCTAssertEqual(CropGeometry.resized(crop, width: .nan, aspect: 2, within: bounds), crop)
    }

    func testEachEdgeResizesWithAspectAroundTheOppositeEdge() {
        let crop = CGRect(x: 200, y: 200, width: 200, height: 100)
        let cases: [(SelectionEdges, CGPoint, CGRect)] = [
            (.top, CGPoint(x: 0, y: 30), CGRect(x: 170, y: 200, width: 260, height: 130)),
            (.bottom, CGPoint(x: 0, y: -30), CGRect(x: 170, y: 170, width: 260, height: 130)),
            (.right, CGPoint(x: 60, y: 0), CGRect(x: 200, y: 185, width: 260, height: 130)),
            (.left, CGPoint(x: -60, y: 0), CGRect(x: 140, y: 185, width: 260, height: 130)),
        ]
        for (edge, movement, expected) in cases {
            let result = CropGeometry.dragged(crop, edges: edge, moving: false, from: .zero,
                                              to: movement, aspect: 2, within: bounds, snap: 0)
            XCTAssertEqual(result, expected)
        }
    }

    func testCornerResizeAndSnappingPreserveRatioAtImageBounds() {
        let crop = CGRect(x: 100, y: 100, width: 320, height: 180)
        for movement in [CGPoint(x: 900, y: 900), CGPoint(x: 377, y: 415)] {
            let result = CropGeometry.dragged(crop, edges: [.right, .top], moving: false, from: .zero,
                                              to: movement, aspect: 16 / 9, within: bounds, snap: 6)
            XCTAssertEqual(result.minX, crop.minX)
            XCTAssertEqual(result.minY, crop.minY)
            XCTAssertLessThanOrEqual(result.maxX, bounds.maxX)
            XCTAssertLessThanOrEqual(result.maxY, bounds.maxY)
            XCTAssertEqual(result.height, result.width / (16 / 9), accuracy: 1)
            XCTAssertEqual(result, result.integral)
        }
    }

    func testDrawingInEveryDirectionFitsWithoutBreakingTheRatio() {
        let anchor = CGPoint(x: 400, y: 300)
        for point in [CGPoint(x: -200, y: -200), CGPoint(x: 1_000, y: -200),
                      CGPoint(x: -200, y: 900), CGPoint(x: 1_000, y: 900)] {
            let result = CropGeometry.dragged(bounds, edges: nil, moving: false, from: anchor,
                                              to: point, aspect: 4 / 3, within: bounds, snap: 0)
            XCTAssertTrue(bounds.contains(result))
            XCTAssertEqual(result.height, result.width / (4 / 3), accuracy: 1)
            XCTAssertEqual(result, result.integral)
            XCTAssertEqual(point.x < anchor.x ? result.maxX : result.minX, anchor.x)
            XCTAssertEqual(point.y < anchor.y ? result.maxY : result.minY, anchor.y)
        }
    }

    func testMovingNearAnEdgeSnapsPositionWithoutResizing() {
        let crop = CGRect(x: 100, y: 100, width: 200, height: 100)
        let result = CropGeometry.dragged(crop, edges: nil, moving: true, from: .zero,
                                          to: CGPoint(x: 497, y: 397), aspect: 2, within: bounds, snap: 6)
        XCTAssertEqual(result, CGRect(x: 600, y: 500, width: 200, height: 100))
    }

    func testFractionalPointerAndNumericInputProduceWholePixelCrops() {
        let crop = CGRect(x: 100, y: 100, width: 200, height: 100)
        let results = [
            CropGeometry.resized(crop, width: 303.4, aspect: 16 / 9, within: bounds),
            CropGeometry.dragged(crop, edges: [.left, .bottom], moving: false, from: .zero,
                                 to: CGPoint(x: -12.4, y: -35.7), aspect: nil, within: bounds, snap: 0),
            CropGeometry.dragged(crop, edges: nil, moving: true, from: .zero,
                                 to: CGPoint(x: 12.4, y: 35.7), aspect: nil, within: bounds, snap: 0),
        ]
        for result in results { XCTAssertEqual(result, result.integral); XCTAssertTrue(bounds.contains(result)) }
    }
}

@MainActor
final class CropKeyboardTests: XCTestCase {
    func testEscapeAndReturnSynchronizeTheToolbarWithTheCanvas() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 80, height: 60, bitsPerComponent: 8,
                                             bytesPerRow: 320, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let record = CaptureRecord(id: UUID(), kind: .area, createdAt: Date(), pixelWidth: 80, pixelHeight: 60,
                                   sourceScale: 1, sourceURL: URL(fileURLWithPath: "/unused-crop-test-source"), revision: 0)
        let suite = "shotty-crop-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = EditorWindowModel(record: record, image: try XCTUnwrap(context.makeImage()),
                                      coordinator: AppCoordinator(preferences: AppPreferences(defaults: defaults)),
                                      commands: CommandRegistry(defaults: defaults))
        for key: UInt16 in [53, 36] {
            model.tool = .crop
            XCTAssertNotNil(model.canvas.cropDraft)
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                      windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                                                      isARepeat: false, keyCode: key))
            model.canvas.keyDown(with: event)
            XCTAssertEqual(model.canvas.tool, .select)
            XCTAssertEqual(model.tool, .select)
            XCTAssertNil(model.canvas.cropDraft)
        }
        XCTAssertEqual(model.document.revision, 0)
        model.tool = .crop
        model.canvas.setCropAspect(1)
        XCTAssertEqual(model.canvas.cropDraft?.size, CGSize(width: 60, height: 60))
        model.canvas.cancelCrop()
        model.tool = .crop
        XCTAssertNil(model.canvas.cropAspect)
        XCTAssertEqual(model.canvas.cropDraft, model.document.sourceBounds)
    }
}
