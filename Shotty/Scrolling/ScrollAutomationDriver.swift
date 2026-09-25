import AppKit
import ApplicationServices
import CoreMedia

/// Issues one marked step at a time. The capture consumer owns settling, alignment,
/// end detection, and session limits. A deadline pauses a stalled step, but this
/// driver never schedules another step.
@MainActor
final class ScrollAutomationDriver {
    struct Target: Equatable {
        let windowID: CGWindowID
        let processID: pid_t
        /// Selected viewport in global, top-left-origin Core Graphics points.
        let globalRegion: CGRect
    }

    enum PauseReason: String, Error {
        case accessibilityRequired = "Accessibility permission is required for Auto Scroll."
        case eventPostingPermissionRequired = "macOS has not granted permission to post scroll events."
        case focusChanged = "The selected window lost focus."
        case targetUnavailable = "The selected scroll region is unavailable."
        case targetChanged = "The selected window moved or resized."
        case eventCreationFailed = "The scroll event could not be created."
        case noProgress = "No settled movement was accepted. The region may be at its end or still changing."
    }

    /// Dependencies allow tests to exercise the complete gate without posting input.
    struct Environment {
        var permissionFailure: () -> PauseReason?
        var windowBounds: (Target) -> Result<CGRect, PauseReason>
        var post: (CGEvent) -> Void
        var now: () -> TimeInterval = { CMClockGetTime(CMClockGetHostTimeClock()).seconds }

        static var live: Self {
            Self(permissionFailure: {
                guard AXIsProcessTrusted() else { return .accessibilityRequired }
                return CGPreflightPostEventAccess() ? nil : .eventPostingPermissionRequired
            }, windowBounds: { target in
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processID else {
                    return .failure(.focusChanged)
                }
                guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
                      let frontWindow = windows.first(where: {
                          ($0[kCGWindowLayer as String] as? Int) == 0 &&
                          ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0
                      }),
                      frontWindow[kCGWindowNumber as String] as? CGWindowID == target.windowID,
                      frontWindow[kCGWindowOwnerPID as String] as? pid_t == target.processID else {
                    return .failure(.focusChanged)
                }
                guard let dictionary = frontWindow[kCGWindowBounds as String] as? [String: Any],
                      let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                      bounds.contains(target.globalRegion) else { return .failure(.targetUnavailable) }
                return .success(bounds)
            }, post: { $0.post(tap: .cghidEventTap) })
        }
    }

    private(set) var inputState = ScrollInputState()
    private(set) var isStopped = false
    private(set) var postedAt: TimeInterval?
    var isAwaitingSettledFrame: Bool { postedAt != nil }
    private(set) var pauseReason: PauseReason?
    var onStateChange: (() -> Void)?
    private let environment: Environment
    /// Injection direction. Fixed once automation starts; see `startAutomatic(target:axis:)`.
    private var axis: ScrollAxis
    private let stepFraction: CGFloat
    private var target: Target?
    private var originalWindowBounds: CGRect?
    private var focusObservation: FocusObservation?
    private var stepDeadline: Task<Void, Never>?

    /// `stepFraction` is the requested progress per step as a fraction of the region's axis extent.
    init(axis: ScrollAxis = .vertical, stepFraction: CGFloat = 0.2, environment: Environment = .live) {
        self.axis = axis
        self.stepFraction = stepFraction.isFinite ? min(max(stepFraction, 0), 0.5) : 0.2
        self.environment = environment
        focusObservation = FocusObservation { [weak self] in self?.validateTarget() }
    }

    deinit { stepDeadline?.cancel() }

    /// Call only from explicit Auto Scroll activation, after the initial frame exists.
    /// Starting arms the driver; it does not inject input or activate another app.
    @discardableResult
    /// `axis` replaces the initial direction, for a choice made after the driver was created.
    func startAutomatic(target: Target, axis: ScrollAxis? = nil) -> Bool {
        guard !isStopped, inputState.offersAutoScroll else { return false }
        let region = target.globalRegion
        guard [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite),
              region.width >= 2, region.height >= 2 else {
            fail(.targetUnavailable)
            return false
        }
        if let reason = environment.permissionFailure() { fail(reason); return false }
        switch environment.windowBounds(target) {
        case .failure(let reason): fail(reason); return false
        case .success(let bounds): originalWindowBounds = bounds
        }
        self.target = target
        if let axis { self.axis = axis }
        pauseReason = nil
        inputState.handle(.startAutomatic)
        onStateChange?()
        return true
    }

    /// Start must use startAutomatic(target:) so the permission/target gate cannot be bypassed.
    func handle(_ action: ScrollInputAction) {
        guard !isStopped else { return }
        if case .startAutomatic = action { return }
        if case .toggleAutomaticPause = action, inputState.mode == .automaticPaused {
            guard validateTarget() else { return }
            guard !isAwaitingSettledFrame || stepDeadline != nil else {
                // The expired step, not an earlier recovered pause, is now what blocks resume.
                pauseReason = .noProgress
                onStateChange?()
                return
            }
            inputState.handle(action)
            pauseReason = nil
            onStateChange?()
            return
        }
        inputState.handle(action)
        if inputState.mode == .manualOnly { cancelDeadline() }
        onStateChange?()
    }

    /// Check on incoming frames as well as immediately before each event. App activation
    /// changes also call this, so returning focus never automatically resumes scrolling.
    @discardableResult
    func validateTarget() -> Bool {
        guard !isStopped, inputState.mode != .manualOnly, let target else { return false }
        if let reason = environment.permissionFailure() { fail(reason); return false }
        switch environment.windowBounds(target) {
        case .failure(let reason): fail(reason); return false
        case .success(let bounds):
            guard bounds == originalWindowBounds else { fail(.targetChanged); return false }
        }
        return true
    }

    /// Release only for accepted nonzero translation in a frame acquired after the
    /// current event. capturedAt uses the CoreMedia host clock, like postedAt.
    /// Pausing/resuming, unchanged frames, and stale buffered frames cannot release it.
    @discardableResult
    func didSettleAndAlign(capturedAt: TimeInterval, didMove: Bool) -> Bool {
        guard !isStopped, let postedAt, didMove, capturedAt.isFinite, capturedAt > postedAt else { return false }
        self.postedAt = nil
        cancelDeadline()
        return true
    }

    @discardableResult
    func injectNextStepIfReady() -> Bool {
        guard !isStopped, inputState.mayInjectScroll, !isAwaitingSettledFrame,
              validateTarget(), let target else { return false }
        let extent = axis == .vertical ? target.globalRegion.height : target.globalRegion.width
        // Never request more than half, even when rounding a very small selection to a whole pixel unit.
        let distance = Int32(min(CGFloat(Int32.max), max(1, min(floor(extent * stepFraction), floor(extent / 2)))))
        guard let source = CGEventSource(stateID: .privateState) else { fail(.eventCreationFailed); return false }
        // Preserve physical input so manual takeover is not suppressed after posting.
        source.localEventsSuppressionInterval = 0
        guard let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                                  wheel1: axis == .vertical ? -distance : 0,
                                  wheel2: axis == .horizontal ? -distance : 0, wheel3: 0) else {
            fail(.eventCreationFailed)
            return false
        }
        event.location = CGPoint(x: target.globalRegion.midX, y: target.globalRegion.midY)
        event.setIntegerValueField(.eventSourceUserData, value: ScrollInputObserver.injectedEventMarker)
        event.setIntegerValueField(.eventSourceUnixProcessID, value: Int64(ProcessInfo.processInfo.processIdentifier))
        postedAt = environment.now()
        environment.post(event)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(1_500))
        stepDeadline = Task { [weak self] in
            do { try await Task.sleep(until: deadline, clock: .continuous) }
            catch { return }
            guard !Task.isCancelled, let self, !self.isStopped, self.isAwaitingSettledFrame,
                  self.inputState.mode != .manualOnly else { return }
            self.stepDeadline = nil
            self.fail(.noProgress)
        }
        return true
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        inputState.handle(.pauseAutomatic)
        cancelDeadline()
        postedAt = nil
        target = nil
        focusObservation = nil
        onStateChange?()
    }

    private func fail(_ reason: PauseReason) {
        // Keep the first explanation until the user explicitly resumes successfully.
        if pauseReason == nil || inputState.mode == .undecided { pauseReason = reason }
        inputState.handle(.pauseAutomatic)
        onStateChange?()
    }

    private func cancelDeadline() {
        stepDeadline?.cancel()
        stepDeadline = nil
    }
}

/// NotificationCenter supports removing observers from any thread.
private final class FocusObservation {
    private let token: NSObjectProtocol

    @MainActor
    init(onChange: @escaping @MainActor () -> Void) {
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in MainActor.assumeIsolated { onChange() } }
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(token) }
}
