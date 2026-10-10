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
        XCTAssertEqual(ClipTime.duration(0.3), "0:01", "A title never claims a clip is empty")
    }

    func testThumbnailLengthsNameOnlyTheUnitsTheyNeed() {
        XCTAssertEqual(ClipTime.compact(14.4), "14s")
        XCTAssertEqual(ClipTime.compact(64.2), "1m 4s")
        XCTAssertEqual(ClipTime.compact(120), "2m")
        XCTAssertEqual(ClipTime.compact(3603), "1h 3s")
        XCTAssertEqual(ClipTime.compact(3723), "1h 2m 3s")
        XCTAssertEqual(ClipTime.compact(0.3), "1s", "A thumbnail never claims a clip is empty")
        XCTAssertEqual(ClipTime.compact(.infinity), "1s")
    }
}
