import Sparkle
import XCTest
@testable import Shotty

@MainActor
final class AppUpdaterTests: XCTestCase {
    private var busy = false
    private var secondsSinceInput: TimeInterval = 0
    private var screenLocked = false
    private var now = Date(timeIntervalSince1970: 1_000_000)
    private var installs = 0
    /// Only the updater delegate parameter; these tests never start Sparkle.
    private let sparkle = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil).updater

    /// Sparkle keeps the install setting in the test host's defaults, which Shotty Dev shares.
    private var storedSetting: Any?

    override func setUp() async throws {
        storedSetting = UserDefaults.standard.object(forKey: "SUAutomaticallyUpdate")
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(storedSetting, forKey: "SUAutomaticallyUpdate")
    }

    private func makeUpdater() -> AppUpdater {
        AppUpdater(environment: .init(
            isBusy: { [unowned self] in busy },
            secondsSinceInput: { [unowned self] in secondsSinceInput },
            isScreenLocked: { [unowned self] in screenLocked },
            now: { [unowned self] in now }), startsUpdater: false)
    }

    private func download(into updater: AppUpdater) {
        let handled = updater.updater(sparkle, willInstallUpdateOnQuit: .empty(), immediateInstallationBlock: { [unowned self] in installs += 1 })
        XCTAssertTrue(handled, "Shotty takes over the install, so Sparkle doesn't present the update itself")
    }

    func testDownloadedUpdateRelaunchesOnlyOnceShottyIsIdle() {
        let updater = makeUpdater()
        updater.installsAutomatically = true
        busy = true
        secondsSinceInput = AppUpdater.quietPeriod
        download(into: updater)
        XCTAssertEqual(installs, 0, "A capture in progress or thumbnails on screen block the relaunch")
        XCTAssertFalse(updater.needsAttention, "A silent update shows no dot while it waits")

        busy = false
        secondsSinceInput = AppUpdater.quietPeriod - 1
        updater.checkIdle()
        XCTAssertEqual(installs, 0, "Recent input means the user is at the Mac")

        screenLocked = true
        updater.checkIdle()
        XCTAssertEqual(installs, 1, "A locked screen counts as away")
    }

    func testUpdateThatNeverFindsAnIdleMomentAsksForARelaunch() {
        let updater = makeUpdater()
        updater.installsAutomatically = true
        busy = true
        download(into: updater)

        now += AppUpdater.patience - 1
        updater.checkIdle()
        XCTAssertFalse(updater.needsAttention)

        now += 1
        updater.checkIdle()
        XCTAssertTrue(updater.needsAttention)
        XCTAssertEqual(installs, 0)
    }

    func testTurningOffAutomaticInstallLeavesTheRelaunchToTheUser() {
        let updater = makeUpdater()
        updater.installsAutomatically = false
        secondsSinceInput = AppUpdater.quietPeriod
        download(into: updater)

        XCTAssertEqual(installs, 0)
        XCTAssertTrue(updater.needsAttention, "The update is ready, but only the user starts the relaunch")
        updater.relaunch()
        XCTAssertEqual(installs, 1)
    }

    func testOnlyAFailedCheckNowReportsItsError() {
        let updater = makeUpdater()
        let delegate: SPUUpdaterDelegate = updater
        let offline = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.appcastError.rawValue), userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)])
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))

        delegate.updater?(sparkle, didFinishUpdateCycleFor: .updatesInBackground, error: offline)
        XCTAssertEqual(updater.status, .idle, "A scheduled check fails silently")

        updater.checkForUpdates()
        XCTAssertEqual(updater.status, .checking)
        delegate.updater?(sparkle, didFinishUpdateCycleFor: .updatesInBackground, error: offline)
        XCTAssertEqual(updater.status, .failed(offline: true))

        updater.checkForUpdates()
        delegate.updater?(sparkle, didFinishUpdateCycleFor: .updatesInBackground, error: noUpdate)
        XCTAssertEqual(updater.status, .idle, "Finding no update is a success")
    }

    func testScheduledUpdateShowsADotInsteadOfSparklesAlert() {
        let updater = makeUpdater()
        XCTAssertTrue(updater.supportsGentleScheduledUpdateReminders)
        XCTAssertFalse(updater.standardUserDriverShouldHandleShowingScheduledUpdate(.empty(), andInImmediateFocus: true))
    }
}
