import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

/// Initial settling counts only eligible frames. Returning from Shotty requires one fresh stream,
/// because the previous stream may already have delivered and discarded its sole settled frame.
struct ScrollAcquisitionReadiness {
    enum InitialFrameDecision { case wait, accept, timedOut }

    private var firstMovingFrameAt: TimeInterval?
    private var needsFreshStream = false

    mutating func suspendForOwnApplication() {
        needsFreshStream = true
        firstMovingFrameAt = nil
    }

    /// Call only after checking the target's focus and geometry. Consumes the transition once.
    mutating func resumeValidatedTarget() -> Bool {
        guard needsFreshStream else { return false }
        needsFreshStream = false
        return true
    }

    mutating func initialFrame(isSettled: Bool, at now: TimeInterval) -> InitialFrameDecision {
        if isSettled { return .accept }
        let first = firstMovingFrameAt ?? now
        firstMovingFrameAt = first
        return now - first >= 3 ? .timedOut : .wait
    }
}

/// Product scrolling session after area selection. It composes the verified engine pieces:
/// `LiveCaptureSource` frames, `ScrollAccumulator` alignment and disk tiles,
/// `ScrollAutomationDriver` for explicit Auto Scroll, and `ScrollInputObserver` for manual takeover.
///
/// Flow: the selector's Start confirms an adjustable region; acquisition then begins as soon as the
/// target window is frontmost, with Start as the fallback if it is not. Cancel and Done sit below the
/// region and Auto Scroll inside it, at the bottom. The first manual scroll makes the capture
/// manual-only and removes Auto Scroll. The first accepted movement decides whether the capture
/// grows vertically or horizontally. Limits and interruptions keep accepted pixels. Done hands a
/// complete result to the ordinary output pipeline directly; a partial result needs Keep Partial
/// Capture. A failed hand-off keeps the accepted pixels for another attempt. Cancel produces no output.
@MainActor @Observable
final class ScrollingCaptureController {
    enum Phase: Equatable {
        case ready
        case capturing
        /// Acquisition stopped; accepted pixels remain. Continue restarts acquisition when possible.
        case interrupted(reason: String, canContinue: Bool)
        /// Output in progress, or a partial result waiting for Keep Partial Capture or Discard.
        case review
    }

    private(set) var phase: Phase?
    /// Something the user must know or act on; nil while the capture runs normally.
    private(set) var notice: String?
    private(set) var automaticMode = ScrollInputState.Mode.undecided
    private(set) var hasAcceptedFrame = false
    /// Why the result is partial; nil means the capture ended normally.
    private(set) var incompleteReason: String?
    /// Inferred from the first accepted movement. Auto Scroll goes down until then.
    private var establishedAxis: ScrollAxis?
    private(set) var isKeeping = false

    /// Auto Scroll, then Pause or Resume once started, shows until the user scrolls by hand.
    var showsAutoScroll: Bool { phase == .capturing && automaticMode != .manualOnly }

    var isActive: Bool { phase != nil }

    @ObservationIgnored private weak var coordinator: AppCoordinator?
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private let live = LiveCaptureSource()
    @ObservationIgnored private let inputObserver = ScrollInputObserver()
    @ObservationIgnored private var accumulator: ScrollAccumulator?
    @ObservationIgnored private var driver: ScrollAutomationDriver?
    @ObservationIgnored private var acquisition: Task<Void, Never>?
    @ObservationIgnored private var acquisitionID = UUID()
    @ObservationIgnored private var acquisitionReadiness = ScrollAcquisitionReadiness()
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    @ObservationIgnored private var timeLimit: Task<Void, Never>?
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var shadePanel: NSPanel?
    @ObservationIgnored private var controlsPanel: NSPanel?
    @ObservationIgnored private var autoScrollPanel: NSPanel?
    @ObservationIgnored private var outputTask: Task<Bool, Never>?
    /// Invalidates follow-up work from an ended session.
    @ObservationIgnored private var sessionID = UUID()
    /// The status currently asks the user to return to the target after Shotty came forward.
    @ObservationIgnored private var showsReturnHint = false

    private struct Session {
        let appKitRegion: CGRect
        let target: ScrollAutomationDriver.Target
        let displayID: CGDirectDisplayID
        let displayLocalRegion: CGRect
        let scale: Double
        let settings: CaptureOutputSnapshot
        let ticket: ClipboardWriter.Ticket
        var windowBounds: CGRect?
    }

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    /// `region` is in global AppKit points, as `CaptureSelector` reports it.
    func start(region: CGRect, windowID: CGWindowID, processID: pid_t, displayID: CGDirectDisplayID,
               settings: CaptureOutputSnapshot, ticket: ClipboardWriter.Ticket) {
        guard phase == nil else { return }
        guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else {
            coordinator?.showError(CaptureFailure.targetUnavailable, title: "Couldn't start scrolling capture")
            return
        }
        let captureFrame = CGDisplayBounds(displayID)
        let geometry = DisplayGeometry(id: displayID, appKitFrame: screen.frame, captureFrame: captureFrame,
                                       pixelSize: CGSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID)))
        let topLeft = geometry.capturePoint(fromAppKit: CGPoint(x: region.minX, y: region.maxY))
        let globalRegion = CGRect(origin: topLeft, size: region.size)
        session = Session(appKitRegion: region,
                          target: .init(windowID: windowID, processID: processID, globalRegion: globalRegion),
                          displayID: displayID,
                          displayLocalRegion: globalRegion.offsetBy(dx: -captureFrame.minX, dy: -captureFrame.minY),
                          scale: screen.backingScaleFactor, settings: settings, ticket: ticket)
        hasAcceptedFrame = false
        incompleteReason = nil
        automaticMode = .undecided
        establishedAxis = nil
        notice = nil
        phase = .ready
        isKeeping = false
        showsReturnHint = false
        sessionID = UUID()
        // Frames are skipped while Shotty is frontmost, so return focus to the target first.
        NSRunningApplication(processIdentifier: processID)?.activate()
        showPanels(around: region, on: screen, targetProcess: processID)
        beginWhenTargetIsFrontmost(processID)
    }

    /// The selector's Start already confirmed the region, so begin without a second Start once the
    /// target is frontmost. If it never becomes available, the ready phase explains and offers Start.
    private func beginWhenTargetIsFrontmost(_ processID: pid_t) {
        let token = sessionID
        Task { [weak self] in
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != processID {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, sessionID == token, phase == .ready else { return }
            beginCapture()
        }
    }

    /// Return in the ready phase.
    func beginCapture() {
        guard phase == .ready, var session else { return }
        switch ScrollAutomationDriver.Environment.live.windowBounds(session.target) {
        case .failure(let reason):
            notice = "\(reason.rawValue) Bring the window to the front, then press Start."
            controlsPanel?.makeKey()
            return
        case .success(let bounds):
            session.windowBounds = bounds
            self.session = session
        }
        let settings = session.settings.scrolling
        accumulator = ScrollAccumulator(limits: settings.limits, makesPreviews: false)
        let driver = ScrollAutomationDriver(stepFraction: settings.pace.stepFraction)
        driver.onStateChange = { [weak self, weak driver] in
            guard let self, let driver, self.driver === driver else { return }
            automaticMode = driver.inputState.mode
            if driver.pauseReason == .noProgress {
                notice = "Nothing new appeared. The end may be reached."
            } else if let reason = driver.pauseReason {
                notice = reason.rawValue
            }
        }
        self.driver = driver
        inputObserver.start { [weak driver] source in driver?.handle(.scroll(source)) }
        timeLimit = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(settings.maximumDurationSeconds)) } catch { return }
            await self?.finishAtLimit("Time limit reached")
        }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.interrupt("The display arrangement changed.", canContinue: false) }
        }
        notice = nil
        phase = .capturing
        runAcquisition(after: nil)
    }

    func startAutoScroll() {
        guard phase == .capturing, hasAcceptedFrame, let driver, let session, driver.inputState.offersAutoScroll else { return }
        guard AXIsProcessTrusted() else {
            // Prompts at most once per macOS policy; later presses only explain.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            notice = "Auto Scroll needs Accessibility access. Allow Shotty in System Settings, then return and press Continue."
            return
        }
        guard driver.startAutomatic(target: session.target, axis: establishedAxis ?? .vertical) else { return }
        notice = nil
        driver.injectNextStepIfReady()
    }

    /// Space while Auto Scroll has started.
    func toggleAutoScrollPause() {
        guard phase == .capturing, let driver, driver.inputState.mode != .undecided, driver.inputState.mode != .manualOnly else { return }
        driver.handle(.toggleAutomaticPause)
        if driver.inputState.mode == .automaticRunning {
            notice = nil
            driver.injectNextStepIfReady()
        }
    }

    func continueCapture() {
        guard case .interrupted(_, true) = phase, let session else { return }
        if let reason = targetFailure(session) {
            notice = "\(reason.rawValue) Return to the window, then press Continue."
            return
        }
        notice = nil
        phase = .capturing
        runAcquisition(after: acquisition)
    }

    /// Return while capturing or interrupted. A complete result goes straight to the output
    /// pipeline; a partial one is shown with its reason first.
    func done() {
        guard phase == .capturing || isInterrupted else { return }
        guard hasAcceptedFrame else { return cancel() }
        let running = stopAcquisition()
        let token = sessionID
        phase = .review
        isKeeping = incompleteReason == nil
        notice = incompleteReason.map { "Partial capture: \($0)" }
        Task { [weak self] in
            await running?.value
            guard let self, sessionID == token, phase == .review, incompleteReason == nil else { return }
            isKeeping = false
            output()
        }
    }

    /// Return in review: explicitly keeps a partial result, or retries a failed hand-off.
    func keep() {
        guard phase == .review else { return }
        output()
    }

    /// Hands the full-resolution image to the coordinator. If it is not retained, the accepted
    /// pixels stay here so the user can retry or discard.
    private func output() {
        guard !isKeeping, let accumulator, let session, let coordinator else { return }
        isKeeping = true
        let token = sessionID
        let task = Task { () -> Bool in
            guard let image = try? await accumulator.renderImage() else { return false }
            return await coordinator.accept(image, kind: .scrolling, scale: session.scale, settings: session.settings,
                                            ticket: session.ticket)
        }
        outputTask = task
        Task { [weak self] in
            let retained = await task.value
            guard let self, sessionID == token else { return }
            outputTask = nil
            if retained {
                await endSession()
            } else {
                isKeeping = false
                notice = "The capture couldn't be kept. Press Keep to try again, or Discard."
            }
        }
    }

    /// Escape in any phase; nothing is output. An output already in progress finishes first.
    func cancel() {
        guard !isKeeping else { return }
        Task { await endSession() }
    }

    /// For quit and replacement: stops input, streams, timers, and removes accepted pixels.
    func stop() async { await endSession() }

    // MARK: - Acquisition

    private var isInterrupted: Bool {
        if case .interrupted = phase { true } else { false }
    }

    /// Waits for any previous loop so the accumulator never sees overlapping frames.
    private func runAcquisition(after previous: Task<Void, Never>?) {
        let id = UUID()
        acquisitionID = id
        acquisitionReadiness = ScrollAcquisitionReadiness()
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self, acquisitionID == id, phase == .capturing, let session else { return }
                // Frames are ignored while Shotty is frontmost; say so rather than appear frozen.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    acquisitionReadiness.suspendForOwnApplication()
                    showReturnHint()
                    continue
                }
                if let reason = targetFailure(session) {
                    interrupt(reason.rawValue, canContinue: reason == .focusChanged)
                    return
                }
                if restartAfterReturningToTarget() { return }
                clearReturnHint()
            }
        }
        acquisition = Task { [weak self, live] in
            await previous?.value
            guard let self, acquisitionID == id, let session, let accumulator, let driver else { return }
            do {
                let frames = try await live.start(displayID: session.displayID, displayLocalRegion: session.displayLocalRegion,
                                                  excluding: ProcessInfo.processInfo.processIdentifier)
                for try await frame in frames {
                    try Task.checkCancellation()
                    guard acquisitionID == id, phase == .capturing else { return }
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                        acquisitionReadiness.suspendForOwnApplication()
                        driver.handle(.pauseAutomatic)
                        showReturnHint()
                        continue
                    }
                    if let reason = targetFailure(session) {
                        interrupt(reason.rawValue, canContinue: reason == .focusChanged)
                        return
                    }
                    if restartAfterReturningToTarget() { return }
                    if !hasAcceptedFrame {
                        switch acquisitionReadiness.initialFrame(isSettled: frame.isSettled, at: CapturedScrollFrame.monotonicNow) {
                        case .wait: continue
                        case .timedOut:
                            interrupt("The region kept changing. Pause animations or select a smaller region.", canContinue: true)
                            return
                        case .accept: break
                        }
                    }
                    if driver.inputState.mode == .automaticRunning ||
                        (driver.inputState.mode == .automaticPaused && driver.isAwaitingSettledFrame) {
                        driver.validateTarget()
                        guard frame.isSettled else { continue }
                    }
                    let result = try await accumulator.accept(frame.image)
                    try Task.checkCancellation()
                    guard acquisitionID == id, phase == .capturing else { return }
                    if result.paused && !frame.isSettled { continue }
                    hasAcceptedFrame = true
                    clearReturnHint()
                    if let axis = result.axis { establishedAxis = axis }
                    if let rejection = result.rejection {
                        if rejection.isLimit {
                            await finishAtLimit(rejection.explanation)
                            return
                        }
                        incompleteReason = rejection.explanation
                        notice = "\(rejection.explanation) Scroll back, or press Done."
                        continue
                    }
                    if result.didMove {
                        incompleteReason = nil
                        notice = nil
                    }
                    if frame.isSettled, driver.didSettleAndAlign(capturedAt: frame.capturedAt, didMove: result.didMove) {
                        driver.injectNextStepIfReady()
                    }
                }
                if acquisitionID == id, phase == .capturing { interrupt("Screen capture stopped.", canContinue: true) }
            } catch is CancellationError {
            } catch {
                if acquisitionID == id, phase == .capturing { interrupt(error.localizedDescription, canContinue: false) }
            }
        }
    }

    /// A new stream reacquires current target pixels; never replay a frame skipped during own-app focus.
    private func restartAfterReturningToTarget() -> Bool {
        guard acquisitionReadiness.resumeValidatedTarget() else { return false }
        clearReturnHint()
        driver?.handle(.pauseAutomatic)
        let previous = acquisition
        previous?.cancel()
        // start() stops its previous stream using generation checks. An unscoped asynchronous
        // stop here could race with the new start and shut down the replacement stream.
        runAcquisition(after: previous)
        return true
    }

    private func showReturnHint() {
        guard !showsReturnHint else { return }
        showsReturnHint = true
        notice = "Return to the captured window to continue."
    }

    private func clearReturnHint() {
        guard showsReturnHint else { return }
        showsReturnHint = false
        notice = nil
    }

    /// Returns the loop so callers outside it can wait for the accumulator to settle.
    @discardableResult
    private func stopAcquisition() -> Task<Void, Never>? {
        acquisitionID = UUID()
        watchdog?.cancel()
        watchdog = nil
        driver?.handle(.pauseAutomatic)
        let running = acquisition
        running?.cancel()
        Task { [live] in await live.stop() }
        return running
    }

    private func interrupt(_ reason: String, canContinue: Bool) {
        guard phase == .capturing else { return }
        stopAcquisition()
        incompleteReason = reason
        notice = reason
        phase = .interrupted(reason: reason, canContinue: canContinue)
    }

    private func finishAtLimit(_ reason: String) async {
        guard phase == .capturing || isInterrupted, hasAcceptedFrame else {
            if phase == .capturing { interrupt(reason, canContinue: false) }
            return
        }
        incompleteReason = reason
        done()
    }

    private func targetFailure(_ session: Session) -> ScrollAutomationDriver.PauseReason? {
        // Clicking Shotty's own controls must not end the capture.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return nil }
        switch ScrollAutomationDriver.Environment.live.windowBounds(session.target) {
        case .failure(let reason): return reason
        case .success(let bounds): return bounds == session.windowBounds ? nil : .targetChanged
        }
    }

    private func endSession() async {
        sessionID = UUID()
        let running = stopAcquisition()
        timeLimit?.cancel()
        timeLimit = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        inputObserver.stop()
        driver?.stop()
        driver = nil
        await live.stop()
        await running?.value
        // A hand-off in progress must finish before its source pixels are removed.
        _ = await outputTask?.value
        outputTask = nil
        await accumulator?.discard()
        accumulator = nil
        session = nil
        for panel in [shadePanel, controlsPanel, autoScrollPanel] { panel?.orderOut(nil) }
        shadePanel = nil
        controlsPanel = nil
        autoScrollPanel = nil
        notice = nil
        phase = nil
    }

    // MARK: - Panels

    /// Return, Escape, and Space need the controls to be key. A nonactivating panel can be key
    /// while the target stays the active app, but activating the target afterwards would take key
    /// status back, so wait briefly for that activation first.
    private func makeControlsKey(after processID: pid_t) {
        let token = sessionID
        Task { [weak self] in
            for _ in 0..<10 where NSWorkspace.shared.frontmostApplication?.processIdentifier != processID {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let self, sessionID == token else { return }
            controlsPanel?.makeKey()
        }
    }

    /// Dims the display around the region, attaches Cancel and Done below it, and places Auto Scroll
    /// inside it at the bottom. Shotty's windows are always excluded from the capture stream.
    private func showPanels(around region: CGRect, on screen: NSScreen, targetProcess pid: pid_t) {
        let hole = region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let shade = Self.overlayPanel(frame: screen.frame, content: ShadeView(hole: hole))
        shade.ignoresMouseEvents = true
        shadePanel = shade

        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let barSize = CGSize(width: 520, height: 50)
        let barOrigin = SelectionGeometry.firstClearOrigin(
            SelectionGeometry.attachedOrigins(size: barSize, to: region, within: visible, gap: 4) + Self.corners(of: visible, size: barSize),
            size: barSize, avoiding: [region], within: visible) ?? CGPoint(x: visible.midX - barSize.width / 2, y: visible.minY)
        let bar = Self.overlayPanel(frame: CGRect(origin: barOrigin, size: barSize),
                                    content: NSHostingView(rootView: ScrollingCaptureBar(controller: self)))
        bar.becomesKeyOnlyIfNeeded = false
        controlsPanel = bar

        let autoSize = CGSize(width: min(200, region.width), height: 44)
        let autoOrigin = CGPoint(x: region.midX - autoSize.width / 2, y: region.minY + min(12, max(0, region.height - autoSize.height)))
        let autoScroll = Self.overlayPanel(frame: CGRect(origin: autoOrigin, size: autoSize),
                                           content: NSHostingView(rootView: AutoScrollControl(controller: self)))
        autoScrollPanel = autoScroll

        for panel in [shade, autoScroll, bar] { panel.orderFrontRegardless() }
        makeControlsKey(after: pid)
    }

    private static func corners(of visible: CGRect, size: CGSize) -> [CGPoint] {
        [CGPoint(x: visible.maxX - size.width, y: visible.maxY - size.height), CGPoint(x: visible.minX, y: visible.maxY - size.height),
         CGPoint(x: visible.maxX - size.width, y: visible.minY), CGPoint(x: visible.minX, y: visible.minY)]
    }

    /// A transparent, nonactivating floating panel; fully transparent areas pass clicks through.
    private static func overlayPanel(frame: CGRect, content: NSView) -> NSPanel {
        let panel = SelectionPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = content
        return panel
    }
}

/// Dims the display outside the captured region and outlines it just outside its edge.
private final class ShadeView: NSView {
    private let hole: CGRect

    init(hole: CGRect) {
        self.hole = hole
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let shade = NSBezierPath(rect: bounds)
        shade.appendRect(hole)
        shade.windingRule = .evenOdd
        Chrome.scrim.setFill()
        shade.fill()
        NSColor.white.withAlphaComponent(0.7).setStroke()
        let outline = NSBezierPath(rect: hole.insetBy(dx: -1, dy: -1))
        outline.lineWidth = 1
        outline.stroke()
    }
}

/// Compact capsule controls attached below the region, with any notice beside them. Return,
/// Escape, and Space keep working because this panel is key.
private struct ScrollingCaptureBar: View {
    let controller: ScrollingCaptureController

    var body: some View {
        HStack(spacing: 8) {
            if let notice = controller.notice {
                Text(notice)
                    .font(.caption.weight(.medium)).lineLimit(2)
                    .foregroundStyle(Color(nsColor: Chrome.controlLabel))
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .frame(maxWidth: 280, minHeight: Chrome.pillHeight)
                    .overlayCapsuleBackground()
            }
            controls
        }
        .buttonStyle(.overlayCapsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Space pauses and resumes Auto Scroll, whose button lives in a panel that is never key.
        .background {
            Button("Pause or Resume Auto Scroll", action: controller.toggleAutoScrollPause)
                .keyboardShortcut(.space, modifiers: []).opacity(0).accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch controller.phase {
        case .ready:
            cancelButton
            Button("Start", systemImage: "arrow.down", action: controller.beginCapture)
                .keyboardShortcut(.defaultAction).buttonStyle(.overlayCapsuleProminent)
        case .capturing:
            cancelButton
            doneButton
        case .interrupted(_, let canContinue):
            cancelButton
            if canContinue { Button("Continue", systemImage: "play.fill", action: controller.continueCapture) }
            doneButton.disabled(!controller.hasAcceptedFrame)
        case .review:
            Button("Discard", systemImage: "xmark", action: controller.cancel).keyboardShortcut(.cancelAction)
            Button(controller.incompleteReason == nil ? "Keep" : "Keep Partial Capture", systemImage: "checkmark", action: controller.keep)
                .keyboardShortcut(.defaultAction).buttonStyle(.overlayCapsuleProminent)
                .disabled(controller.isKeeping)
        case nil:
            EmptyView()
        }
    }

    private var cancelButton: some View {
        Button("Cancel", systemImage: "xmark", action: controller.cancel).keyboardShortcut(.cancelAction)
    }

    private var doneButton: some View {
        Button("Done", systemImage: "checkmark", action: controller.done)
            .keyboardShortcut(.defaultAction).buttonStyle(.overlayCapsuleProminent)
    }
}

/// Sits inside the region at its bottom edge. Scrolling by hand removes it.
private struct AutoScrollControl: View {
    let controller: ScrollingCaptureController

    var body: some View {
        Group {
            if controller.showsAutoScroll {
                switch controller.automaticMode {
                case .automaticRunning:
                    Button("Pause", systemImage: "pause.fill", action: controller.toggleAutoScrollPause)
                case .automaticPaused:
                    Button("Resume", systemImage: "play.fill", action: controller.toggleAutoScrollPause)
                default:
                    Button("Auto Scroll", systemImage: "arrow.down.circle.fill", action: controller.startAutoScroll)
                        .disabled(!controller.hasAcceptedFrame)
                }
            }
        }
        .buttonStyle(.overlayCapsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension ScrollRejection {
    var isLimit: Bool { self == .lengthLimit || self == .memoryLimit || self == .timeLimit }

    var explanation: String {
        switch self {
        case .changedDimensions: "The region changed size."
        case .insufficientOverlap: "The content moved too far between frames. Scroll more slowly."
        case .ambiguousContent: "Repeated content made the position ambiguous."
        case .unstableContent: "The content changed while scrolling."
        case .axisChanged: "Scrolling switched direction. Only one direction is supported per capture."
        case .stationaryBandsChanged: "A fixed header or footer changed."
        case .lengthLimit: "Length limit reached."
        case .memoryLimit: "Size limit reached."
        case .timeLimit: "Time limit reached."
        }
    }
}
