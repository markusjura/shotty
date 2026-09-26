import AppKit
@preconcurrency import ApplicationServices
import SwiftUI

/// One scrolling capture after the selector's Start. Frames stream into a `ScrollStitcher` from
/// the moment the region is confirmed, so any scrolling, manual or automatic and at any speed,
/// extends the image. Cancel and Done sit below the region and Auto Scroll inside it at the
/// bottom. Scrolling by hand removes Auto Scroll. Done renders the image and hands it to the
/// normal output pipeline; Cancel produces nothing.
@MainActor @Observable
final class ScrollingCaptureController {
    enum AutoScroll: Equatable {
        case offered, running
    }

    private(set) var isActive = false
    /// Nil once the user scrolls by hand or the content ends; the button disappears.
    private(set) var autoScroll: AutoScroll?

    @ObservationIgnored private weak var coordinator: AppCoordinator?
    @ObservationIgnored private var session: Session?
    @ObservationIgnored private var panels: [NSPanel] = []
    @ObservationIgnored private var scrollMonitors: [Any] = []
    @ObservationIgnored private var driver: Task<Void, Never>?
    @ObservationIgnored private var lastMovement = ContinuousClock.now

    private struct Session {
        let stream: ScrollCaptureStream
        let settings: CaptureOutputSnapshot
        let ticket: ClipboardWriter.Ticket
        let scale: Double
        /// Region center in global top-left coordinates, where Auto Scroll posts its events.
        let scrollPoint: CGPoint
        /// Region extent along each axis, in points.
        let size: CGSize
    }

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    /// `region` is in global AppKit points, as `CaptureSelector` reports it.
    func start(region: CGRect, displayID: CGDirectDisplayID, settings: CaptureOutputSnapshot, ticket: ClipboardWriter.Ticket) {
        guard !isActive, let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { return }
        let geometry = DisplayGeometry(id: displayID, appKitFrame: screen.frame, captureFrame: CGDisplayBounds(displayID),
                                       pixelSize: CGSize(width: CGDisplayPixelsWide(displayID), height: CGDisplayPixelsHigh(displayID)))
        let topLeft = geometry.capturePoint(fromAppKit: CGPoint(x: region.minX, y: region.maxY))
        let stream = ScrollCaptureStream(limits: settings.scrolling.limits) { [weak self] update in
            Task { @MainActor in self?.handle(update) }
        }
        session = Session(stream: stream, settings: settings, ticket: ticket, scale: screen.backingScaleFactor,
                          scrollPoint: CGPoint(x: topLeft.x + region.width / 2, y: topLeft.y + region.height / 2),
                          size: region.size)
        isActive = true
        autoScroll = .offered
        showPanels(around: region, on: screen)
        observeScrolling()
        let local = CGRect(origin: CGPoint(x: topLeft.x - geometry.captureFrame.minX, y: topLeft.y - geometry.captureFrame.minY),
                           size: region.size)
        Task {
            do { try await stream.start(displayID: displayID, region: local) } catch {
                guard session?.stream === stream else { return }
                await end()
                coordinator?.showError(error, title: "Couldn't start scrolling capture")
            }
        }
    }

    /// Space while capturing.
    func toggleAutoScroll() {
        switch autoScroll {
        case .offered: startAutoScroll()
        case .running: autoScroll = .offered; driver?.cancel()
        case nil: break
        }
    }

    func startAutoScroll() {
        guard autoScroll == .offered, let session else { return }
        guard AXIsProcessTrusted() else {
            // macOS shows its own prompt at most once; Auto Scroll stays offered for after approval.
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
            return
        }
        autoScroll = .running
        lastMovement = .now
        let pace = session.settings.scrolling.pace.viewportsPerSecond
        driver = Task { [weak self] in
            let interval = Duration.milliseconds(16)
            while !Task.isCancelled {
                guard let self, autoScroll == .running else { return }
                // Content that stopped moving has reached its end.
                if ContinuousClock.now - lastMovement > .milliseconds(1_200) { autoScroll = nil; return }
                // Moving the pointer mid-click would cancel it, so a held button pauses scrolling.
                if NSEvent.pressedMouseButtons == 0 {
                    let horizontal = session.stream.axis == .horizontal
                    let extent = horizontal ? session.size.width : session.size.height
                    Self.postScroll(by: max(1, extent * pace / 60), horizontal: horizontal, at: session.scrollPoint)
                } else {
                    lastMovement = .now
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    /// Return while capturing. Stitching needs no further step, so the result goes straight to output.
    func done() {
        guard let session else { return }
        Task {
            let image = await session.stream.finish()
            await end()
            guard let image, let coordinator else { return }
            await coordinator.accept(image, kind: .scrolling, scale: session.scale, settings: session.settings, ticket: session.ticket)
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    /// Escape while capturing.
    func cancel() {
        guard let session else { return }
        Task {
            await session.stream.cancel()
            await end()
        }
    }

    /// For quit and replacement.
    func stop() async {
        await session?.stream.cancel()
        await end()
    }

    private func handle(_ update: ScrollStitcher.Update) {
        switch update {
        case .moved: lastMovement = .now
        case .full: if autoScroll == .running { autoScroll = nil; driver?.cancel() }
        case .unchanged, .unmatched: break
        }
    }

    private func end() async {
        defer {
            // Stitching allocates and frees hundreds of megabytes; hand the emptied pages back
            // instead of leaving them cached in this idle menu bar app.
            malloc_zone_pressure_relief(nil, 0)
        }
        driver?.cancel()
        driver = nil
        scrollMonitors.forEach(NSEvent.removeMonitor)
        scrollMonitors = []
        panels.forEach { $0.orderOut(nil) }
        panels = []
        session = nil
        autoScroll = nil
        isActive = false
    }

    // MARK: - Input

    private static let injectedMarker: Int64 = 0x53484F545459

    /// No local-input suppression, so the user's own mouse and scroll wheel stay responsive.
    private static let eventSource: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    /// Scroll events go to the window under their location, and posting one moves the pointer there.
    /// Events are posted at the region's center and the pointer goes straight back, so the user can
    /// still reach Pause, Cancel, and Done while Auto Scroll runs.
    private static func postScroll(by points: Double, horizontal: Bool, at location: CGPoint) {
        let delta = -Int32(points.rounded())
        guard let event = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: 2,
                                  wheel1: horizontal ? 0 : delta, wheel2: horizontal ? delta : 0, wheel3: 0) else { return }
        let pointer = CGEvent(source: nil)?.location
        event.location = location
        event.setIntegerValueField(.eventSourceUserData, value: injectedMarker)
        event.post(tap: .cghidEventTap)
        guard let pointer, pointer != location else { return }
        CGWarpMouseCursorPosition(pointer)
        // Warping otherwise ignores physical mouse movement for a moment.
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Any scroll that Shotty did not post is the user's; it ends Auto Scroll for this capture.
    /// Mouse monitors need no Accessibility or Input Monitoring permission.
    private func observeScrolling() {
        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Self.injectedMarker else { return }
            MainActor.assumeIsolated {
                guard let self, self.autoScroll != nil else { return }
                self.driver?.cancel()
                self.autoScroll = nil
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel, handler: handler) { scrollMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel, handler: { handler($0); return $0 }) {
            scrollMonitors.append(local)
        }
    }

    // MARK: - Panels

    /// Dims the display around the region, attaches Cancel and Done below it, and places Auto Scroll
    /// inside it at the bottom. Shotty's windows are excluded from the capture stream.
    private func showPanels(around region: CGRect, on screen: NSScreen) {
        let shade = Self.overlayPanel(frame: screen.frame, content: ShadeView(hole: region.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)))
        shade.ignoresMouseEvents = true

        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        let barSize = CGSize(width: 240, height: 50)
        let barOrigin = SelectionGeometry.firstClearOrigin(
            SelectionGeometry.attachedOrigins(size: barSize, to: region, within: visible, gap: 4),
            size: barSize, avoiding: [region], within: visible)
            ?? CGPoint(x: region.midX - barSize.width / 2, y: max(visible.minY, region.minY + 60))
        let bar = Self.overlayPanel(frame: CGRect(origin: barOrigin, size: barSize),
                                    content: NSHostingView(rootView: ScrollingCaptureBar(controller: self)))
        bar.becomesKeyOnlyIfNeeded = false

        let autoSize = CGSize(width: min(200, region.width), height: 44)
        let autoOrigin = CGPoint(x: region.midX - autoSize.width / 2, y: region.minY + min(12, max(0, region.height - autoSize.height)))
        let autoScroll = Self.overlayPanel(frame: CGRect(origin: autoOrigin, size: autoSize),
                                           content: NSHostingView(rootView: AutoScrollControl(controller: self)), canBecomeKey: false)

        panels = [shade, autoScroll, bar]
        panels.forEach { $0.orderFrontRegardless() }
        // Return, Escape, and Space reach the controls while the target app stays active.
        bar.makeKey()
    }

    /// A transparent, nonactivating floating panel; fully transparent areas pass clicks through.
    private static func overlayPanel(frame: CGRect, content: NSView, canBecomeKey: Bool = true) -> NSPanel {
        let panelClass: NSPanel.Type = canBecomeKey ? SelectionPanel.self : NonKeyPanel.self
        let panel = panelClass.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
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

/// Cancel and Done below the region. Return, Escape, and Space work because this panel is key.
private struct ScrollingCaptureBar: View {
    let controller: ScrollingCaptureController

    var body: some View {
        HStack(spacing: 8) {
            Button("Cancel", systemImage: "xmark", action: controller.cancel).keyboardShortcut(.cancelAction)
            Button("Done", systemImage: "checkmark", action: controller.done)
                .keyboardShortcut(.defaultAction).buttonStyle(.overlayCapsuleProminent)
        }
        .buttonStyle(.overlayCapsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Space starts or pauses Auto Scroll, whose button lives in a panel that is never key.
        .background {
            Button("Auto Scroll", action: controller.toggleAutoScroll)
                .keyboardShortcut(.space, modifiers: []).opacity(0).accessibilityHidden(true)
        }
    }
}

/// Sits inside the region at its bottom edge until the user scrolls by hand.
private struct AutoScrollControl: View {
    let controller: ScrollingCaptureController

    var body: some View {
        Group {
            switch controller.autoScroll {
            case .offered: Button("Auto Scroll", systemImage: "arrow.down.circle.fill", action: controller.startAutoScroll)
            case .running: Button("Pause", systemImage: "pause.fill", action: controller.toggleAutoScroll)
            case nil: EmptyView()
            }
        }
        .buttonStyle(.overlayCapsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
