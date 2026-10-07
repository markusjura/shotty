import AppKit
import Observation
import Sparkle
import os

/// Keeps Shotty current through Sparkle without alerts Shotty didn't ask for.
///
/// With automatic install on, the default, Sparkle downloads an update in the background and hands its
/// install to Shotty. Shotty relaunches into it once a relaunch interrupts nothing: no capture in
/// progress, no captures or recognized text on screen, and no input for `quietPeriod` or a locked
/// screen. Quitting installs it too. Only an update still waiting after `patience` asks for a relaunch.
///
/// With automatic install off, found updates become gentle reminders: the menu bar icon, its menu,
/// and Settings show the update instead of Sparkle's alert. Sparkle's update window opens only when
/// the user asks to install. Check Now runs the same background check and reports its result inline.
@MainActor @Observable
final class AppUpdater: NSObject {
    /// A newer version and the page that describes it.
    struct Release: Equatable {
        let version: String
        let notesURL: URL?

        init(_ item: SUAppcastItem) {
            version = item.displayVersionString
            notesURL = item.infoURL ?? item.fullReleaseNotesURL
        }
    }

    enum Status: Equatable {
        /// Nothing newer is known. `lastChecked` says how current that is.
        case idle
        /// Check Now is waiting for the feed.
        case checking
        /// Check Now's check or its download failed. Scheduled cycles fail silently and stay idle.
        case failed(offline: Bool)
        /// Sparkle is downloading an update to install automatically.
        case downloading(Release)
        /// An update that Shotty doesn't install by itself.
        case available(Release)
        /// Downloaded and installed on the next relaunch. `asksForRelaunch` is set once Shotty
        /// stops waiting for an idle moment and asks the user instead.
        case ready(Release, asksForRelaunch: Bool)
    }

    /// What Shotty checks before relaunching on its own. Tests replace it.
    struct Environment {
        /// True while a relaunch would interrupt work, such as a capture or thumbnails on screen.
        var isBusy: @MainActor () -> Bool
        var secondsSinceInput: () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        }
        var isScreenLocked: () -> Bool = {
            (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool == true
        }
        var now: () -> Date = Date.init
    }

    /// How long the Mac has to go without keyboard or pointer input before Shotty relaunches.
    static let quietPeriod: TimeInterval = 10 * 60
    /// How long a downloaded update waits for an idle moment before it asks for a relaunch.
    static let patience: TimeInterval = 3 * 24 * 60 * 60
    /// How often a downloaded update looks for an idle moment.
    private static let idleCheckInterval: TimeInterval = 60

    private(set) var status = Status.idle
    /// When Sparkle last checked the feed, by schedule or Check Now.
    private(set) var lastChecked: Date?
    /// False in Shotty Dev unless a test feed is set, so development builds never replace themselves.
    let isRunning: Bool
    /// Sparkle keeps both settings in Shotty's defaults, so they read and write through to it.
    /// `Config/Info.plist` turns both on by default.
    var checksAutomatically: Bool {
        get { access(keyPath: \.checksAutomatically); return updater.automaticallyChecksForUpdates }
        set { withMutation(keyPath: \.checksAutomatically) { updater.automaticallyChecksForUpdates = newValue } }
    }
    var installsAutomatically: Bool {
        get { access(keyPath: \.installsAutomatically); return updater.automaticallyDownloadsUpdates }
        set {
            withMutation(keyPath: \.installsAutomatically) { updater.automaticallyDownloadsUpdates = newValue }
            checkIdle()
        }
    }

    /// Whether the menu bar icon and the General sidebar row show the blue dot.
    var needsAttention: Bool {
        switch status {
        case .idle, .checking, .failed, .downloading: false
        case .available: true
        case .ready(_, let asksForRelaunch): asksForRelaunch
        }
    }

    @ObservationIgnored private let environment: Environment
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var installUpdate: (() -> Void)?
    @ObservationIgnored private var readySince = Date.distantPast
    @ObservationIgnored private var idleTimer: Timer?
    /// Set by Check Now until its update cycle ends, so only that cycle reports an error.
    @ObservationIgnored private var checkingNow = false
    private var updater: SPUUpdater { controller.updater }

    /// Tests pass `startsUpdater: false`, so Sparkle never checks a feed.
    init(environment: Environment, startsUpdater: Bool = AppUpdater.startsByDefault) {
        self.environment = environment
        isRunning = startsUpdater
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        guard startsUpdater else { return }
        controller.startUpdater()
        lastChecked = updater.lastUpdateCheckDate
    }

    #if DEBUG
    /// Shotty Dev checks only a test feed set with `defaults write local.markus.Shotty.dev updateFeedURL <url>`.
    private static let testFeedURL = UserDefaults.standard.string(forKey: "updateFeedURL")
    static let startsByDefault = testFeedURL != nil
    #else
    static let startsByDefault = true
    #endif

    /// Checks now in the background, as a scheduled check does, so a found update downloads silently or
    /// shows as available. The delegate callbacks end `checking`. Sparkle ignores the request while
    /// a scheduled check runs, and that check's end resolves `checking` too. Without a running
    /// Sparkle, as in tests, only the status changes.
    func checkForUpdates() {
        status = .checking
        checkingNow = true
        if isRunning { updater.checkForUpdatesInBackground() }
    }

    /// Opens Sparkle's window for an available update, with its release notes and Install button.
    func showUpdate() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    /// Installs a downloaded update and relaunches Shotty.
    func relaunch() {
        installUpdate?()
    }

    /// Relaunches into a downloaded update when Shotty is idle, or asks for a relaunch after `patience`.
    func checkIdle() {
        guard let installUpdate, case .ready(let release, _) = status else { return }
        let idle = !environment.isBusy() && (environment.isScreenLocked() || environment.secondsSinceInput() >= Self.quietPeriod)
        if installsAutomatically, idle {
            Logger(subsystem: "local.markus.Shotty", category: "Updates").info("Relaunching into \(release.version, privacy: .public)")
            installUpdate()
            return
        }
        let waitedTooLong = environment.now().timeIntervalSince(readySince) >= Self.patience
        status = .ready(release, asksForRelaunch: !installsAutomatically || waitedTooLong)
    }

    /// True when `error`, or an error underneath it, means the Mac has no connection.
    private static func isOffline(_ error: NSError) -> Bool {
        let offlineCodes = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorDataNotAllowed]
        if error.domain == NSURLErrorDomain, offlineCodes.contains(error.code) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isOffline) ?? false
    }
}

extension AppUpdater: SPUUpdaterDelegate {
    /// Takes over the install of a silently downloaded update. Sparkle still installs it on quit.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        installUpdate = immediateInstallHandler
        readySince = environment.now()
        status = .ready(Release(item), asksForRelaunch: false)
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleCheckInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIdle() }
        }
        checkIdle()
        return true
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        status = .downloading(Release(item))
    }

    /// Ends a check or download that didn't leave an update waiting for the user. Only a failed
    /// Check Now, including its download, reports its error; a no-update result and scheduled
    /// failures settle on idle. An available update stays until a check finds no update, as when
    /// its release was withdrawn.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        lastChecked = updater.lastUpdateCheckDate ?? lastChecked
        let checkedNow = checkingNow
        checkingNow = false
        let error = error as NSError?
        let noUpdate = error?.domain == SUSparkleErrorDomain && error?.code == Int(SUError.noUpdateError.rawValue)
        switch status {
        case .checking, .downloading:
            status = if checkedNow, let error, !noUpdate { .failed(offline: Self.isOffline(error)) } else { .idle }
        case .available:
            if noUpdate { status = .idle }
        case .idle, .failed, .ready:
            break
        }
    }

    /// The user chose in Sparkle's window. A skipped update is gone until the user checks again.
    /// A dismissed one, as with Remind Me Later, stays available. Install proceeds in Sparkle.
    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                 state: SPUUserUpdateState) {
        if choice == .skip, case .available = status { status = .idle }
    }

    #if DEBUG
    func feedURLString(for updater: SPUUpdater) -> String? { Self.testFeedURL }
    #endif
}

extension AppUpdater: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// Scheduled updates show as a blue dot instead of Sparkle's alert.
    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard !handleShowingUpdate else { return }
        status = .available(Release(update))
    }
}
