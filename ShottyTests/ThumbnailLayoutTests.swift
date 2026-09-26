import XCTest
@testable import Shotty

final class ThumbnailLayoutTests: XCTestCase {
    func testOverflowKeepsNewestCardsAndReservesTheMoreRow() {
        let heights: [CGFloat] = [196, 196, 196, 196]
        // Four cards with three gaps need exactly 808.
        XCTAssertEqual(ThumbnailLayout.visibleCount(heights: heights, available: 808), 4)
        // With one card hidden, 3 cards plus the overflow row need 644.
        XCTAssertEqual(ThumbnailLayout.visibleCount(heights: heights, available: 644), 3)
        XCTAssertEqual(ThumbnailLayout.visibleCount(heights: heights, available: 643), 2)
        XCTAssertEqual(ThumbnailLayout.visibleCount(heights: heights, available: 50), 1,
                       "A tiny display still shows the newest capture")
    }

    func testPreviewHeightIsBoundedAndNewestSitsNearestTheAnchor() {
        XCTAssertEqual(ThumbnailLayout.previewHeight(width: 220), 160)
        XCTAssertEqual(ThumbnailLayout.previewHeight(width: 180), 140)
        XCTAssertEqual(ThumbnailLayout.displayOrder([1, 2, 3], placement: .topRight), [1, 2, 3])
        XCTAssertEqual(ThumbnailLayout.displayOrder([1, 2, 3], placement: .leftCenter), [1, 2, 3])
        XCTAssertEqual(ThumbnailLayout.displayOrder([1, 2, 3], placement: .bottomLeft), [3, 2, 1])
    }

    func testImageFillsCardWithoutDistortion() {
        let bounds = CGRect(x: 0, y: 0, width: 220, height: 160)
        let tall = ThumbnailLayout.imageRect(imageSize: CGSize(width: 100, height: 1000), bounds: bounds)
        XCTAssertEqual(tall.minX, 0, accuracy: 0.001)
        XCTAssertEqual(tall.minY, -1020, accuracy: 0.001)
        XCTAssertEqual(tall.width, 220, accuracy: 0.001)
        XCTAssertEqual(tall.height, 2200, accuracy: 0.001)
        let wide = ThumbnailLayout.imageRect(imageSize: CGSize(width: 1000, height: 100), bounds: bounds)
        XCTAssertEqual(wide, CGRect(x: -690, y: 0, width: 1600, height: 160))
    }

    func testSwipeAccumulatesTowardTheAnchoredEdgeWithHorizontalIntent() {
        var swipe = ThumbnailSwipe()
        for _ in 0..<6 { swipe.add(dx: -11, dy: 2) }
        XCTAssertTrue(swipe.dismisses(anchoredLeft: true), "66 pt leftward in small deltas")
        XCTAssertFalse(swipe.dismisses(anchoredLeft: false), "Away from a right anchor")
        swipe.reset()
        swipe.add(dx: -59, dy: 0)
        XCTAssertFalse(swipe.dismisses(anchoredLeft: true))
        swipe.reset()
        swipe.add(dx: 80, dy: 50)
        XCTAssertFalse(swipe.dismisses(anchoredLeft: false), "Diagonal movement is not horizontal intent")
        swipe.reset()
        swipe.add(dx: 90, dy: -30)
        swipe.add(dx: -40, dy: 0)
        XCTAssertFalse(swipe.dismisses(anchoredLeft: false), "Net 50 pt after reversing")
    }

    func testCountdownOnlyElapsesWhileUnpaused() {
        let a = UUID(), b = UUID()
        var countdown = ThumbnailCountdown()
        countdown.start(a, seconds: 3)
        countdown.start(b, seconds: 5)
        XCTAssertEqual(countdown.advance(by: 2) { $0 == b }, [])
        XCTAssertEqual(countdown.advance(by: 2) { $0 == b }, [a])
        XCTAssertEqual(countdown.advance(by: 4.9) { _ in false }, [])
        XCTAssertEqual(countdown.advance(by: 0.1) { _ in false }, [b])
        XCTAssertTrue(countdown.isEmpty)
    }
}
