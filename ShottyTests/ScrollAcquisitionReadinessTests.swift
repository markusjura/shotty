import XCTest
@testable import Shotty

final class ScrollAcquisitionReadinessTests: XCTestCase {
    func testInitialSettleDeadlineStartsWithFirstEligibleMovingFrame() {
        var readiness = ScrollAcquisitionReadiness()
        // Arbitrarily slow stream startup does not consume any of the settling interval.
        XCTAssertEqual(readiness.initialFrame(isSettled: false, at: 100), .wait)
        XCTAssertEqual(readiness.initialFrame(isSettled: false, at: 102.99), .wait)
        XCTAssertEqual(readiness.initialFrame(isSettled: false, at: 103), .timedOut)
        XCTAssertEqual(readiness.initialFrame(isSettled: true, at: 104), .accept)
    }

    func testOwnFocusRequiresOneFreshStreamAndResetsInitialSettlement() {
        var readiness = ScrollAcquisitionReadiness()
        XCTAssertFalse(readiness.resumeValidatedTarget(), "Initial target focus needs no extra restart")
        XCTAssertEqual(readiness.initialFrame(isSettled: false, at: 1), .wait)
        readiness.suspendForOwnApplication()
        readiness.suspendForOwnApplication()
        XCTAssertTrue(readiness.resumeValidatedTarget())
        XCTAssertFalse(readiness.resumeValidatedTarget(), "Repeated target checks must not keep restarting")
        XCTAssertEqual(readiness.initialFrame(isSettled: false, at: 100), .wait)
        XCTAssertEqual(readiness.initialFrame(isSettled: true, at: 100.15), .accept)
        readiness.suspendForOwnApplication()
        XCTAssertTrue(readiness.resumeValidatedTarget(), "A later own-app focus interval needs fresh pixels again")
    }
}
