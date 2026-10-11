import XCTest
@testable import Shotty

final class SecondsFormatTests: XCTestCase {
    func testReadsCommaAndPeriodAsTheDecimalSeparatorAndRejectsOtherText() throws {
        let format = SecondsFormat()
        XCTAssertEqual(try format.parse("2,5"), 2.5)
        XCTAssertEqual(try format.parse("2.3"), 2.3)
        XCTAssertEqual(try format.parse(" 10 "), 10)
        XCTAssertEqual(try format.parse("1.239"), 1.24, "More than two decimals round to what the field shows")
        XCTAssertEqual(try format.parse(format.format(2.5)), 2.5, "The locale's own spelling reads back")
        XCTAssertThrowsError(try format.parse("soon"))
        XCTAssertThrowsError(try format.parse(""))
    }
}
