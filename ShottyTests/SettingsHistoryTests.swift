import XCTest
@testable import Shotty

final class SettingsHistoryTests: XCTestCase {
    func testBackAndForwardRetraceVisitsAndANewVisitClearsForward() {
        var history = SettingsHistory()
        XCTAssertNil(history.back(from: .general))

        history.visit(.capture, from: .general)
        history.visit(.capture, from: .capture)
        history.visit(.editor, from: .capture)
        XCTAssertEqual(history.back(from: .editor), .capture)
        XCTAssertEqual(history.back(from: .capture), .general)
        XCTAssertFalse(history.canGoBack)
        XCTAssertEqual(history.forward(from: .general), .capture)

        history.visit(.shortcuts, from: .capture)
        XCTAssertFalse(history.canGoForward)
        XCTAssertEqual(history.back(from: .shortcuts), .capture)
    }
}
