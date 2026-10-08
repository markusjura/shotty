import XCTest
@testable import Shotty

final class PlayerLayoutTests: XCTestCase {
    func testVideoFitsInsideTheMarginWithoutGrowingPastActualSize() {
        let bounds = CGRect(x: 0, y: 0, width: 832, height: 432)
        // A 1600 × 800 pixel Retina frame is 800 × 400 points at actual size.
        XCTAssertEqual(PlayerLayout.fit(CGSize(width: 1600, height: 800), in: bounds, maximumScale: 0.5),
                       CGRect(x: 16, y: 16, width: 800, height: 400))
        XCTAssertEqual(PlayerLayout.fit(CGSize(width: 400, height: 200), in: bounds, maximumScale: 0.5),
                       CGRect(x: 316, y: 166, width: 200, height: 100), "Small clips stay at actual size, centered")
        XCTAssertEqual(PlayerLayout.fit(CGSize(width: 4000, height: 4000), in: bounds, maximumScale: 0.5).height, 400)
    }

    func testCropPointsMapBetweenTheViewAndSourcePixels() {
        let visible = CGRect(x: 100, y: 50, width: 400, height: 200)
        let display = CGRect(x: 10, y: 20, width: 200, height: 100)
        let point = PlayerLayout.sourcePoint(CGPoint(x: 60, y: 45), visible: visible, display: display)
        XCTAssertEqual(point, CGPoint(x: 200, y: 100))
        XCTAssertEqual(PlayerLayout.viewRect(CGRect(x: 200, y: 100, width: 40, height: 20), visible: visible, display: display),
                       CGRect(x: 60, y: 45, width: 20, height: 10))
        // The whole 1000 × 600 frame, positioned so the visible part lands on the display.
        XCTAssertEqual(PlayerLayout.frameRect(source: CGSize(width: 1000, height: 600), visible: visible, display: display),
                       CGRect(x: -40, y: -5, width: 500, height: 300))
    }

    func testTimelineClampsToTheRecording() {
        let scale = TimelineScale(duration: 8, width: 400)
        XCTAssertEqual(scale.x(for: 2), 100)
        XCTAssertEqual(scale.x(for: 20), 400)
        XCTAssertEqual(scale.time(at: -30), 0)
        XCTAssertEqual(scale.time(at: 300), 6)
        XCTAssertEqual(TimelineScale(duration: 8, width: 0).time(at: 10), 0)
    }
}
