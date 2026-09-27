import CoreGraphics
import XCTest
@testable import Shotty

final class DisplayGeometryTests: XCTestCase {
    func testNegativeOriginCoordinateRoundTrip() {
        let display = DisplayGeometry(appKitFrame: CGRect(x: -1440, y: 300, width: 1440, height: 900),
                                      captureFrame: CGRect(x: -1440, y: -120, width: 1440, height: 900))
        let point = CGPoint(x: -1300, y: 1100)
        XCTAssertEqual(display.capturePoint(fromAppKit: point), CGPoint(x: -1300, y: -20))
        XCTAssertEqual(display.appKitPoint(fromCapture: display.capturePoint(fromAppKit: point)), point)
    }

    func testRasterBudgetRejectsOverflowAndOversizedOutput() throws {
        let budget = RasterBudget()
        XCTAssertEqual(try budget.byteCount(width: 5120, height: 2880), 58_982_400)
        XCTAssertThrowsError(try budget.byteCount(width: Int.max, height: 2))
        XCTAssertThrowsError(try budget.byteCount(width: 30_000, height: 30_000))
        XCTAssertThrowsError(try budget.byteCount(width: 0, height: 10))
    }
}
