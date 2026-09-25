import AppKit
import XCTest
@testable import Shotty

@MainActor
final class ScrollAutomationDriverTests: XCTestCase {
    private let target = ScrollAutomationDriver.Target(windowID: 42, processID: 123,
                                                       globalRegion: CGRect(x: -500, y: 80, width: 400, height: 600))

    func testExplicitStartAndSettledAlignmentGateMarkedPixelEvents() throws {
        let rig = Rig()
        let driver = ScrollAutomationDriver(environment: rig.environment)
        driver.handle(.startAutomatic)
        XCTAssertFalse(driver.injectNextStepIfReady())
        XCTAssertTrue(driver.startAutomatic(target: target))
        XCTAssertTrue(rig.events.isEmpty)
        XCTAssertTrue(driver.injectNextStepIfReady())
        XCTAssertFalse(driver.injectNextStepIfReady())
        driver.handle(.toggleAutomaticPause)
        driver.handle(.toggleAutomaticPause)
        XCTAssertFalse(driver.injectNextStepIfReady(), "Resume must not bypass unresolved alignment")
        let event = try XCTUnwrap(rig.events.first)
        XCTAssertEqual(event.location, CGPoint(x: -300, y: 380))
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -120)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 0)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUserData), ScrollInputObserver.injectedEventMarker)
        XCTAssertEqual(event.getIntegerValueField(.eventSourceUnixProcessID), Int64(ProcessInfo.processInfo.processIdentifier))
        driver.handle(.scroll(.shottyInjected))
        driver.didSettleAndAlign(capturedAt: rig.time + 0.1, didMove: true)
        XCTAssertTrue(driver.injectNextStepIfReady())
        XCTAssertEqual(rig.events.count, 2)
    }

    func testPhysicalTakeoverCannotResumeEvenAfterAlignment() {
        let rig = Rig()
        let driver = ScrollAutomationDriver(environment: rig.environment)
        XCTAssertTrue(driver.startAutomatic(target: target))
        XCTAssertTrue(driver.injectNextStepIfReady())
        driver.handle(.scroll(.physical))
        driver.didSettleAndAlign(capturedAt: rig.time + 0.1, didMove: true)
        driver.handle(.toggleAutomaticPause)
        XCTAssertFalse(driver.startAutomatic(target: target))
        XCTAssertFalse(driver.injectNextStepIfReady())
        XCTAssertEqual(driver.inputState.mode, .manualOnly)
        XCTAssertEqual(rig.events.count, 1)
    }

    func testPermissionRevocationAndFocusChangePauseBeforeInjection() {
        for reason: ScrollAutomationDriver.PauseReason in [.accessibilityRequired, .eventPostingPermissionRequired, .focusChanged] {
            let rig = Rig()
            let driver = ScrollAutomationDriver(environment: rig.environment)
            XCTAssertTrue(driver.startAutomatic(target: target))
            if reason == .focusChanged { rig.targetFailure = reason }
            else { rig.permissionFailure = reason }
            XCTAssertFalse(driver.injectNextStepIfReady())
            XCTAssertEqual(driver.inputState.mode, .automaticPaused)
            XCTAssertEqual(driver.pauseReason, reason)
            rig.permissionFailure = nil
            rig.targetFailure = nil
            XCTAssertTrue(driver.validateTarget())
            XCTAssertEqual(driver.pauseReason, reason, "A recovered target must not erase the pause explanation")
            XCTAssertFalse(driver.injectNextStepIfReady(), "Restored permission/focus must not auto-resume")
            XCTAssertTrue(rig.events.isEmpty)
            driver.handle(.toggleAutomaticPause)
            XCTAssertEqual(driver.inputState.mode, .automaticRunning)
            XCTAssertNil(driver.pauseReason)
        }
    }

    func testMovedWindowCannotResumeAndStopDisarmsDriver() {
        let rig = Rig()
        let driver = ScrollAutomationDriver(environment: rig.environment)
        XCTAssertTrue(driver.startAutomatic(target: target))
        rig.bounds.origin.x += 1
        XCTAssertFalse(driver.validateTarget())
        driver.handle(.toggleAutomaticPause)
        XCTAssertFalse(driver.injectNextStepIfReady())
        XCTAssertEqual(driver.pauseReason, .targetChanged)
        driver.stop()
        rig.bounds.origin.x -= 1
        driver.handle(.toggleAutomaticPause)
        XCTAssertFalse(driver.injectNextStepIfReady())
        XCTAssertTrue(driver.isStopped)
        XCTAssertEqual(driver.inputState.mode, .automaticPaused)
        XCTAssertEqual(driver.pauseReason, .targetChanged)
        XCTAssertFalse(driver.startAutomatic(target: target))
    }

    func testStopBeforeStartIsTerminal() {
        let rig = Rig()
        let driver = ScrollAutomationDriver(environment: rig.environment)
        driver.stop()
        XCTAssertTrue(driver.isStopped)
        XCTAssertFalse(driver.startAutomatic(target: target))
        driver.handle(.startAutomatic)
        driver.handle(.toggleAutomaticPause)
        XCTAssertFalse(driver.injectNextStepIfReady())
        XCTAssertTrue(rig.events.isEmpty)
    }

    func testOnlyNewerFrameWithAcceptedMovementReleasesStep() {
        let rig = Rig()
        let driver = ScrollAutomationDriver(environment: rig.environment)
        XCTAssertTrue(driver.startAutomatic(target: target))
        XCTAssertTrue(driver.injectNextStepIfReady())
        XCTAssertEqual(driver.postedAt, rig.time)
        for capturedAt in [rig.time - 1, rig.time, .nan, .infinity] {
            XCTAssertFalse(driver.didSettleAndAlign(capturedAt: capturedAt, didMove: true))
            XCTAssertTrue(driver.isAwaitingSettledFrame)
        }
        XCTAssertFalse(driver.didSettleAndAlign(capturedAt: rig.time + 1, didMove: false))
        XCTAssertFalse(driver.injectNextStepIfReady())
        XCTAssertTrue(driver.didSettleAndAlign(capturedAt: rig.time + 1, didMove: true))
        rig.time += 2
        XCTAssertTrue(driver.injectNextStepIfReady())
        XCTAssertFalse(driver.didSettleAndAlign(capturedAt: rig.time - 1, didMove: true), "An earlier step's frame cannot unlock the current step")
        driver.stop()
    }

    func testDeadlinePausesWithoutRetryAndPreservesOtherPauseReasons() async {
        let rig = Rig()
        let stalled = ScrollAutomationDriver(environment: rig.environment)
        let lostFocus = ScrollAutomationDriver(environment: rig.environment)
        let stopped = ScrollAutomationDriver(environment: rig.environment)
        let manual = ScrollAutomationDriver(environment: rig.environment)
        for driver in [stalled, lostFocus, stopped, manual] {
            XCTAssertTrue(driver.startAutomatic(target: target))
            XCTAssertTrue(driver.injectNextStepIfReady())
        }
        rig.targetFailure = .focusChanged
        XCTAssertFalse(lostFocus.validateTarget())
        XCTAssertFalse(manual.validateTarget())
        manual.handle(.scroll(.physical))
        stopped.stop()
        rig.targetFailure = nil
        let expired = expectation(description: "Unresolved step expires")
        let focusedStepExpired = expectation(description: "Earlier focus pause survives the step deadline")
        stalled.onStateChange = {
            if stalled.pauseReason == .noProgress { expired.fulfill() }
        }
        lostFocus.onStateChange = { focusedStepExpired.fulfill() }
        await fulfillment(of: [expired, focusedStepExpired], timeout: 3)
        stalled.onStateChange = nil
        lostFocus.onStateChange = nil
        XCTAssertEqual(stalled.inputState.mode, .automaticPaused)
        XCTAssertEqual(stalled.pauseReason, .noProgress)
        XCTAssertTrue(stalled.isAwaitingSettledFrame)
        XCTAssertEqual(rig.events.count, 4, "A deadline must not post a retry")
        stalled.handle(.toggleAutomaticPause)
        XCTAssertEqual(stalled.inputState.mode, .automaticPaused, "An expired unresolved step cannot resume")
        XCTAssertFalse(stalled.injectNextStepIfReady())
        XCTAssertTrue(stalled.didSettleAndAlign(capturedAt: rig.time + 1, didMove: true))
        XCTAssertEqual(stalled.pauseReason, .noProgress)
        stalled.handle(.toggleAutomaticPause)
        XCTAssertNil(stalled.pauseReason)
        XCTAssertEqual(stalled.inputState.mode, .automaticRunning)
        XCTAssertEqual(lostFocus.pauseReason, .focusChanged)
        lostFocus.handle(.toggleAutomaticPause)
        XCTAssertEqual(lostFocus.inputState.mode, .automaticPaused)
        XCTAssertEqual(lostFocus.pauseReason, .noProgress, "A rejected resume must explain the expired step")
        XCTAssertEqual(manual.pauseReason, .focusChanged)
        XCTAssertEqual(manual.inputState.mode, .manualOnly)
        XCTAssertTrue(stopped.isStopped)
        XCTAssertNil(stopped.pauseReason)
        for driver in [stalled, lostFocus, manual] { driver.stop() }
    }

    func testHorizontalStepAndInvalidSelection() throws {
        let rig = Rig()
        let driver = ScrollAutomationDriver(axis: .horizontal, environment: rig.environment)
        XCTAssertFalse(driver.startAutomatic(target: .init(windowID: 42, processID: 123, globalRegion: .null)))
        XCTAssertEqual(driver.pauseReason, .targetUnavailable)
        XCTAssertTrue(driver.startAutomatic(target: target))
        XCTAssertTrue(driver.injectNextStepIfReady())
        let event = try XCTUnwrap(rig.events.first)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertEqual(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), -80)
    }

    private final class Rig {
        var permissionFailure: ScrollAutomationDriver.PauseReason?
        var targetFailure: ScrollAutomationDriver.PauseReason?
        var bounds = CGRect(x: -600, y: 0, width: 800, height: 900)
        var events: [CGEvent] = []
        var time: TimeInterval = 1_000

        var environment: ScrollAutomationDriver.Environment {
            .init(permissionFailure: { self.permissionFailure }, windowBounds: { _ in
                if let reason = self.targetFailure { return .failure(reason) }
                return .success(self.bounds)
            }, post: { self.events.append($0) }, now: { self.time })
        }
    }
}
