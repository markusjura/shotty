import XCTest
@testable import Shotty

final class ClipTimeTests: XCTestCase {
    func testRunningTimesRoundDownAndDurationsRoundToTheNearestSecond() {
        XCTAssertEqual(ClipTime.format(7.99, tenths: false), "0:07")
        XCTAssertEqual(ClipTime.format(7.46, tenths: true), "0:07.4")
        XCTAssertEqual(ClipTime.format(3723, tenths: false), "1:02:03")
        XCTAssertEqual(ClipTime.format(-1, tenths: true), "0:00.0")
        XCTAssertEqual(ClipTime.format(.nan, tenths: false), "0:00")
        XCTAssertEqual(ClipTime.duration(9.5), "0:10")
        XCTAssertEqual(ClipTime.duration(0.3), "0:01", "A badge never claims a clip is empty")
    }
}
