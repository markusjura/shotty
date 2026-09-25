import XCTest
@testable import Shotty

final class CenteringClipViewTests: XCTestCase {
    func testUndersizedAxesCenterAndLargerAxesKeepTheirScrollPosition() {
        let document = CGRect(x: 0, y: 0, width: 400, height: 2000)
        let bounds = CGRect(x: 0, y: 300, width: 1000, height: 600)
        // Horizontally the image is narrower than the view and centers; vertically it keeps scrolling.
        XCTAssertEqual(CenteringClipView.centered(bounds, document: document), CGRect(x: -300, y: 300, width: 1000, height: 600))
        let fits = CGRect(x: 0, y: 0, width: 400, height: 2000)
        XCTAssertEqual(CenteringClipView.centered(fits, document: document), fits)
    }
}
