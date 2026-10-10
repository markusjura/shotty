import AppKit
import Observation
import SwiftUI

/// One recording from start to finished movie. The controls float beside the target and
/// never take keyboard focus, so typing keeps reaching the recorded app. Shotty's windows are
/// excluded from recordings, so neither the controls nor the outline appear in the clip.
@MainActor @Observable
final class RecordingController {
    enum Phase: Equatable {
        case starting, recording, paused, finishing
    }

    private(set) var phase: Phase?
    /// Recorded time before the current run, which started at `runningSince`.
    private(set) var accumulated: TimeInterval = 0
    private(set) var runningSince: Date?

    var isActive: Bool { phase != nil }
    var isPaused: Bool { phase == .paused }

    /// The recording in progress. Work that outlives it, such as a finisher that resumes after
    /// Discard, checks that its recorder is still this one before touching any state.
    @ObservationIgnored private var recorder: (any Recorder)?
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var panels: [NSPanel] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let makeRecorder: @MainActor (RecordingPreferences) throws -> any Recorder
    /// Hands a finished movie to the output pipeline.
    @ObservationIgnored var finished: ((URL, RecordingKind, CaptureOutputSnapshot, ClipboardWriter.Ticket) async -> Void)?
    @ObservationIgnored var failed: ((Error) -> Void)?

    private struct Session {
        let target: RecordingTarget
        let kind: RecordingKind
        let settings: CaptureOutputSnapshot
        let ticket: ClipboardWriter.Ticket
    }

    /// Tests pass a recorder that records nothing.
    init(makeRecorder: @escaping @MainActor (RecordingPreferences) throws -> any Recorder = { try ScreenRecorder(preferences: $0) }) {
        self.makeRecorder = makeRecorder
    }

    /// Seconds recorded so far at `date`.
    func elapsed(at date: Date) -> TimeInterval {
        accumulated + (runningSince.map { date.timeIntervalSince($0) } ?? 0)
    }

    func start(_ target: RecordingTarget, kind: RecordingKind, settings: CaptureOutputSnapshot, ticket: ClipboardWriter.Ticket) {
        guard phase == nil else { return }
        session = Session(target: target, kind: kind, settings: settings, ticket: ticket)
        accumulated = 0
        runningSince = nil
        phase = .starting
        showPanels(for: target)
        task = Task { [weak self] in await self?.begin() }
    }

    private func begin() async {
        guard let session else { return }
        phase = .starting
        let recorder: any Recorder
        do { recorder = try makeRecorder(session.settings.recording) } catch {
            end()
            failed?(error)
            return
        }
        recorder.stoppedUnexpectedly = { [weak self] in self?.stop() }
        self.recorder = recorder
        do {
            try await recorder.start(session.target)
            // Discarded while the stream was starting.
            guard self.recorder === recorder else { return await recorder.cancel() }
            phase = .recording
            runningSince = .now
        } catch {
            await recorder.cancel()
            // A discarded recording ends quietly; the next one may already be under way.
            guard self.recorder === recorder else { return }
            end()
            failed?(error)
        }
    }

    func togglePause() {
        guard let recorder else { return }
        switch phase {
        case .recording:
            accumulated = elapsed(at: .now)
            runningSince = nil
            phase = .paused
            recorder.pause()
        case .paused:
            do {
                try recorder.resume()
                runningSince = .now
                phase = .recording
            } catch { failed?(error) }
        default: break
        }
    }

    /// Keeps what was recorded and hands it to the outputs. While the stream starts, it discards instead.
    func stop() {
        switch phase {
        case .recording, .paused: break
        case .starting: return cancel()
        case .finishing, nil: return
        }
        guard let session, let recorder else { return }
        accumulated = elapsed(at: .now)
        runningSince = nil
        phase = .finishing
        panels.forEach { $0.orderOut(nil) }
        task = Task {
            let segments = await recorder.stop()
            let movie = recorder.folder.appendingPathComponent("clip.mp4")
            do {
                try await ClipAssembler.assemble(segments, into: movie)
                // Discard and Quit end a finishing recording at once; its recorder removes the movie.
                guard self.recorder === recorder else { return }
                end()
                await finished?(movie, session.kind, session.settings, session.ticket)
            } catch {
                try? FileManager.default.removeItem(at: recorder.folder)
                guard self.recorder === recorder else { return }
                end()
                failed?(error)
            }
        }
    }

    /// Discards the recording at once, even while it finishes.
    func cancel() {
        guard phase != nil else { return }
        task?.cancel()
        let recorder = self.recorder
        end()
        Task { await recorder?.cancel() }
    }

    /// For Quit: discards a recording in progress and waits for its stream to stop.
    func shutdown() async {
        let recorder = self.recorder
        task?.cancel()
        end()
        await recorder?.cancel()
    }

    private func end() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        recorder = nil
        session = nil
        phase = nil
        runningSince = nil
    }

    // MARK: - Panels

    private func showPanels(for target: RecordingTarget) {
        let frame: CGRect
        switch target {
        case .region(let rect, _): frame = rect
        case .window(_, let rect): frame = rect
        case .display(let id): frame = NSScreen.screens.first { $0.displayID == id }?.frame ?? .zero
        }
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) })
                ?? NSScreen.main else { return }
        if case .region(let region, _) = target {
            let outline = Self.overlayPanel(frame: screen.frame,
                content: RegionOutlineView(region: region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)))
            outline.ignoresMouseEvents = true
            panels.append(outline)
        }
        let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let controls = NSHostingView(rootView: RecordingControls(controller: self))
        let size = controls.fittingSize
        let origin: CGPoint
        if case .display = target {
            origin = CGPoint(x: visible.midX - size.width / 2, y: visible.minY)
        } else {
            let candidates = SelectionGeometry.attachedOrigins(size: size, to: frame, within: visible, gap: 8)
            origin = SelectionGeometry.firstClearOrigin(candidates, size: size, avoiding: [frame], within: visible)
                ?? CGPoint(x: visible.midX - size.width / 2, y: visible.minY)
        }
        panels.append(Self.overlayPanel(frame: CGRect(origin: origin, size: size), content: controls))
        panels.forEach { $0.orderFrontRegardless() }
    }

    /// A transparent, nonactivating floating panel that never becomes key. It is dark in both
    /// appearances, as the island it shows.
    private static func overlayPanel(frame: CGRect, content: NSView) -> NSPanel {
        let panel = NonKeyPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Chrome.floatingLevel
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // The outline covers the display; AppKit's window animation would zoom it on show and hide.
        panel.animationBehavior = .none
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = content
        return panel
    }
}

/// Marks the recorded area with the selection border, without the wash, so the content stays
/// true to what is recorded.
private final class RegionOutlineView: NSView {
    private let region: CGRect

    init(region: CGRect) {
        self.region = region
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let outer = NSBezierPath(rect: region.insetBy(dx: -1.5, dy: -1.5))
        outer.lineWidth = 1
        NSColor.black.withAlphaComponent(0.35).setStroke()
        outer.stroke()
        let border = NSBezierPath(rect: region.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        Chrome.selectionBorder.setStroke()
        border.stroke()
    }
}

/// The elapsed time, Pause, Discard, and Stop on one island.
private struct RecordingControls: View {
    let controller: RecordingController

    var body: some View {
        Island {
            RecordingClock(controller: controller)
            IslandDivider()
            Button(controller.isPaused ? "Resume" : "Pause", systemImage: controller.isPaused ? "play.fill" : "pause.fill",
                   action: controller.togglePause)
                .buttonStyle(.islandIcon)
                .help(controller.isPaused ? "Resume" : "Pause")
                .disabled(controller.phase != .recording && controller.phase != .paused)
            Button("Discard Recording", systemImage: "trash", action: controller.cancel)
                .buttonStyle(.islandIcon)
                .help("Discard Recording")
            IslandDivider()
            Button("Stop", systemImage: "stop.fill", action: controller.stop)
                .buttonStyle(.islandRecord)
        }
        .fixedSize()
    }
}

/// The elapsed time behind a dot that pulses red while frames are recorded. Both dim while paused.
private struct RecordingClock: View {
    let controller: RecordingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isLive = controller.phase == .recording
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            HStack(spacing: 6) {
                Circle()
                    .fill(isLive ? Color(nsColor: Chrome.record) : Color(nsColor: Chrome.islandLabel).opacity(0.4))
                    .frame(width: 8, height: 8)
                    // Without a trigger the animator loops; it only shows while recording.
                    .phaseAnimator([1.0, 0.3]) { dot, phase in
                        dot.opacity(isLive && !reduceMotion ? phase : 1)
                    } animation: { _ in .easeInOut(duration: 0.6) }
                Text(ClipTime.format(controller.elapsed(at: context.date), tenths: false))
                    .monospacedDigit()
                    .opacity(isLive ? 1 : 0.5)
            }
            .padding(.horizontal, 10)
            .frame(height: Chrome.islandControlHeight)
        }
    }
}
