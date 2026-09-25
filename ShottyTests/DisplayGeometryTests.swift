import CoreGraphics
import XCTest
@testable import Shotty

final class DisplayGeometryTests: XCTestCase {
    func testNegativeOriginRetinaCropAndCoordinateRoundTrip() {
        let display = DisplayGeometry(id: 1, appKitFrame: CGRect(x: -1440, y: 300, width: 1440, height: 900),
                                      captureFrame: CGRect(x: -1440, y: -120, width: 1440, height: 900),
                                      pixelSize: CGSize(width: 2880, height: 1800))
        let point = CGPoint(x: -1300, y: 1100)
        XCTAssertEqual(display.capturePoint(fromAppKit: point), CGPoint(x: -1300, y: -20))
        XCTAssertEqual(display.appKitPoint(fromCapture: display.capturePoint(fromAppKit: point)), point)
        XCTAssertEqual(display.pixelRect(forAppKit: CGRect(x: -1400, y: 1000, width: 200, height: 100)),
                       CGRect(x: 80, y: 200, width: 400, height: 200))
    }

    func testCropClipsAndRoundsOutwardAtFractionalScale() {
        let display = DisplayGeometry(id: 2, appKitFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      captureFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
                                      pixelSize: CGSize(width: 150, height: 150))
        XCTAssertEqual(display.pixelRect(forAppKit: CGRect(x: -1, y: 90.1, width: 10, height: 15)),
                       CGRect(x: 0, y: 0, width: 14, height: 15))
        XCTAssertNil(display.pixelRect(forAppKit: CGRect(x: 200, y: 0, width: 10, height: 10)))
    }

    func testRasterBudgetRejectsOverflowAndOversizedOutput() throws {
        let budget = RasterBudget()
        XCTAssertEqual(try budget.byteCount(width: 5120, height: 2880), 58_982_400)
        XCTAssertThrowsError(try budget.byteCount(width: Int.max, height: 2))
        XCTAssertThrowsError(try budget.byteCount(width: 30_000, height: 30_000))
        XCTAssertThrowsError(try budget.byteCount(width: 0, height: 10))
    }
}
