import XCTest
@testable import Shotty

final class SelectionGeometryTests: XCTestCase {
    func testScreenLayoutIgnoresEnumerationOrderButDetectsCaptureGeometryChanges() {
        let main = SelectionScreenLayout.Display(id: 1, frame: CGRect(x: 0, y: 0, width: 2_560, height: 1_440),
                                                 scale: 2, pixelSize: CGSize(width: 5_120, height: 2_880), rotation: 0)
        let second = SelectionScreenLayout.Display(id: 2, frame: CGRect(x: -1_920, y: 0, width: 1_920, height: 1_080),
                                                   scale: 1, pixelSize: CGSize(width: 1_920, height: 1_080), rotation: 0)
        let layout = SelectionScreenLayout(displays: [main, second])
        XCTAssertEqual(layout, SelectionScreenLayout(displays: [second, main]))
        XCTAssertNotEqual(layout, SelectionScreenLayout(displays: [main]))
        var moved = main
        moved.frame.origin.y += 1
        var scaled = main
        scaled.scale = 1
        var resized = main
        resized.pixelSize.width = 3_840
        var rotated = main
        rotated.rotation = 180
        var replaced = main
        replaced.id = 3
        for changed in [moved, scaled, resized, rotated, replaced] {
            XCTAssertNotEqual(layout, SelectionScreenLayout(displays: [changed, second]))
        }
    }

    func testArrowKeysMoveOrResizeWithoutCollapsing() {
        let rect = CGRect(x: 10, y: 20, width: 30, height: 2)
        XCTAssertEqual(SelectionGeometry.nudged(rect, dx: -10, dy: 1, resizes: false), CGRect(x: 0, y: 21, width: 30, height: 2))
        XCTAssertEqual(SelectionGeometry.nudged(rect, dx: -10, dy: -10, resizes: true), CGRect(x: 10, y: 20, width: 20, height: 1))
    }

    func testReverseAndCenteredSquareSelection() {
        XCTAssertEqual(SelectionGeometry.rectangle(from: CGPoint(x: -40, y: 80), to: CGPoint(x: -60, y: 120),
            square: false, centered: false), CGRect(x: -60, y: 80, width: 20, height: 40))
        XCTAssertEqual(SelectionGeometry.rectangle(from: CGPoint(x: -40, y: 80), to: CGPoint(x: -60, y: 120),
            square: true, centered: true), CGRect(x: -80, y: 40, width: 80, height: 80))
    }

    func testEdgeBandsResizeOnlyTheirEdgesAndFlipPastTheOpposite() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        XCTAssertEqual(SelectionGeometry.edges(near: CGPoint(x: 104, y: 25), of: rect, tolerance: 6), .right)
        XCTAssertEqual(SelectionGeometry.edges(near: CGPoint(x: -3, y: 53), of: rect, tolerance: 6), [.left, .top])
        XCTAssertNil(SelectionGeometry.edges(near: CGPoint(x: 50, y: 25), of: rect, tolerance: 6))
        XCTAssertNil(SelectionGeometry.edges(near: CGPoint(x: 120, y: 25), of: rect, tolerance: 6))
        // Both vertical edges are in range of a thin rectangle; the nearer one is chosen.
        XCTAssertEqual(SelectionGeometry.edges(near: CGPoint(x: 7, y: 25), of: CGRect(x: 0, y: 0, width: 8, height: 50),
                                               tolerance: 6), .right)

        var drag = SelectionDrag(at: CGPoint(x: 100, y: 25), adjusting: rect, tolerance: 6)
        drag.update(to: CGPoint(x: 130, y: 90), square: false, centered: false)
        XCTAssertEqual(drag.rect, CGRect(x: 0, y: 0, width: 130, height: 50))
        drag.update(to: CGPoint(x: -20, y: 90), square: false, centered: false)
        XCTAssertEqual(drag.rect, CGRect(x: -20, y: 0, width: 20, height: 50))
    }

    func testAdjustingInsideMovesAndOutsideDrawsANewSelection() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 50)
        var move = SelectionDrag(at: CGPoint(x: 50, y: 25), adjusting: rect, tolerance: 6)
        move.update(to: CGPoint(x: 60, y: 5), square: true, centered: true)
        XCTAssertEqual(move.rect, CGRect(x: 10, y: -20, width: 100, height: 50))
        var draw = SelectionDrag(at: CGPoint(x: 300, y: 300), adjusting: rect, tolerance: 6)
        XCTAssertTrue(draw.isDrawing)
        draw.update(to: CGPoint(x: 320, y: 310), square: false, centered: false)
        XCTAssertEqual(draw.rect, CGRect(x: 300, y: 300, width: 20, height: 10))
    }

    /// Space repositions mid-drag, and releasing it keeps drawing from the moved anchor,
    /// repeatedly and with the centered modifier.
    func testSpaceRepositionsAndResumesDrawingWithinOneDrag() {
        var drag = SelectionDrag(at: CGPoint(x: 10, y: 10), adjusting: nil, tolerance: 6)
        drag.update(to: CGPoint(x: 40, y: 30), square: false, centered: false)
        drag.setSpace(true, at: CGPoint(x: 40, y: 30))
        drag.update(to: CGPoint(x: 140, y: 80), square: false, centered: false)
        XCTAssertEqual(drag.rect, CGRect(x: 110, y: 60, width: 30, height: 20))
        drag.setSpace(false, at: CGPoint(x: 140, y: 80))
        drag.update(to: CGPoint(x: 150, y: 100), square: false, centered: false)
        XCTAssertEqual(drag.rect, CGRect(x: 110, y: 60, width: 40, height: 40))

        drag.update(to: CGPoint(x: 150, y: 100), square: false, centered: true)
        XCTAssertEqual(drag.rect, CGRect(x: 70, y: 20, width: 80, height: 80))
        drag.setSpace(true, at: CGPoint(x: 150, y: 100))
        drag.update(to: CGPoint(x: 160, y: 100), square: false, centered: true)
        drag.setSpace(false, at: CGPoint(x: 160, y: 100))
        drag.update(to: CGPoint(x: 160, y: 100), square: false, centered: true)
        XCTAssertEqual(drag.rect, CGRect(x: 80, y: 20, width: 80, height: 80))
    }

    func testAreaCompositionUsesHighestScaleAndTransparentDesktopGaps() async throws {
        let red = try raster(width: 4, height: 4, color: [255, 0, 0, 255])
        let blue = try raster(width: 8, height: 8, color: [0, 0, 255, 255])
        let displays = [
            SelectionDisplay(id: 1, frame: CGRect(x: -4, y: 0, width: 4, height: 4), scale: 1, image: red),
            SelectionDisplay(id: 2, frame: CGRect(x: 1, y: 0, width: 4, height: 4), scale: 2, image: blue)
        ]
        let image = try await SelectionRenderer().compose(region: CGRect(x: -2, y: 1, width: 5, height: 2), displays: displays)
        XCTAssertEqual(image.width, 10)
        XCTAssertEqual(image.height, 4)
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        for y in 0..<4 {
            for x in 0..<10 {
                let offset = y * image.bytesPerRow + x * 4
                XCTAssertEqual(Array(data[offset..<offset + 4]), x < 4 ? [255, 0, 0, 255] : x < 6 ? [0, 0, 0, 0] : [0, 0, 255, 255])
            }
        }
    }

    /// A recording covers one display: the one under the region's center, else the one it
    /// overlaps most.
    func testRecordingRegionsAreClippedToOneDisplay() {
        let displays: [(id: CGDirectDisplayID, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 1512, height: 982)),
            (2, CGRect(x: 1512, y: 0, width: 2560, height: 1440)),
        ]
        let spanning = SelectionGeometry.recordingRegion(CGRect(x: 1400, y: 100, width: 400.5, height: 300), displays: displays)
        XCTAssertEqual(spanning?.display, 2)
        XCTAssertEqual(spanning?.rect, CGRect(x: 1512, y: 100, width: 289, height: 300))
        let centerInGap = SelectionGeometry.recordingRegion(CGRect(x: 1100, y: 950, width: 800, height: 200), displays: displays)
        XCTAssertEqual(centerInGap?.display, 2, "With its center off every display, the larger overlap wins")
        XCTAssertNil(SelectionGeometry.recordingRegion(CGRect(x: -500, y: 0, width: 100, height: 100), displays: displays))
    }

    func testSelectionOutsideDisplaysCannotCreateAnImage() async throws {
        do {
            _ = try await SelectionRenderer().compose(region: CGRect(x: 30, y: 30, width: 10, height: 10), displays: [])
            XCTFail("Empty desktop must not produce a capture")
        } catch { XCTAssertTrue(error is CaptureFailure) }
    }

    private func raster(width: Int, height: Int, color: [UInt8]) throws -> CGImage {
        let data = Data(Array(repeating: color, count: width * height).flatMap { $0 })
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: data as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Controls attach below the region, move above it near the bottom of the screen, and only
    /// then fall back to other clear positions.
    func testAttachedControlAvoidsRegionAndStaysVisible() {
        let visible = CGRect(x: 0, y: 0, width: 1_000, height: 800)
        let size = CGSize(width: 200, height: 40)
        func origin(for region: CGRect) -> CGPoint? {
            SelectionGeometry.firstClearOrigin(SelectionGeometry.attachedOrigins(size: size, to: region, within: visible, gap: 4),
                                               size: size, avoiding: [region], within: visible)
        }
        XCTAssertEqual(origin(for: CGRect(x: 400, y: 300, width: 200, height: 200)), CGPoint(x: 400, y: 256))
        XCTAssertEqual(origin(for: CGRect(x: 0, y: 10, width: 100, height: 300)), CGPoint(x: 0, y: 314))
        XCTAssertNil(origin(for: visible.insetBy(dx: 0, dy: 20)))
        let inside = SelectionGeometry.firstClearOrigin(
            SelectionGeometry.attachedOrigins(size: size, to: visible, within: visible, gap: 4), size: size, avoiding: [], within: visible)
        XCTAssertEqual(inside, CGPoint(x: 400, y: 4))
    }
}
