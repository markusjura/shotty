import AppKit
import Observation
import SwiftUI
import os

/// Picks what to record over the live screen. Every mode ends at the Record bar, which shows the
/// size and the audio switches before anything is recorded, because a recording can't be framed
/// again afterwards the way a screenshot can be cropped. An area stays adjustable after it is
/// drawn. A window or display is highlighted under the pointer and picked with a click, Tab, or
/// Return. Space switches between area and window.
@MainActor @Observable
final class RecordingSelector {
    private(set) var isActive = false
    private(set) var kind: RecordingKind = .area
    private(set) var selection: CGRect?
    private(set) var pointer = NSEvent.mouseLocation
    private(set) var selectedWindowFrame: CGRect?
    private(set) var selectedDisplayID: CGDirectDisplayID?
    var errorMessage: String?
    private var displays: [(id: CGDirectDisplayID, frame: CGRect, scale: CGFloat)] = []
    private var windows: [WindowTarget] = []
    private var selectedWindowID: CGWindowID?
    private var hasPointerInteraction = false
    private var drag: SelectionDrag?
    /// True once the target is fixed and the Record bar shows: a drawn area, a clicked window, or
    /// a clicked display. Until then the window or display highlight follows the pointer.
    private var isTargetPicked = false
    private var panels: [SelectionPanel] = []
    private var recordBar: NSPanel?
    private var operation: Task<Void, Never>?
    private var screenObservation: NSObjectProtocol?
    private var requestID = UUID()
    private var completion: ((Result<RecordingTarget, Error>) -> Void)?
    private let preferences: AppPreferences
    private let logger = Logger(subsystem: "local.markus.Shotty", category: "RecordingSelection")

    init(preferences: AppPreferences) { self.preferences = preferences }

    func begin(kind: RecordingKind, completion: @escaping (Result<RecordingTarget, Error>) -> Void) {
        cancel()
        isActive = true
        self.kind = kind
        self.completion = completion
        let request = UUID()
        requestID = request
        pointer = NSEvent.mouseLocation
        hasPointerInteraction = false
        errorMessage = nil
        let screenLayout = SelectionScreenLayout.current
        screenObservation = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.requestID == request, SelectionScreenLayout.current != screenLayout else { return }
                    self.logger.error("Selection cancelled for changed screen geometry")
                    self.finish(.failure(RecordingFailure.targetUnavailable))
                }
            }
        guard CGPreflightScreenCaptureAccess() else { return finish(.failure(RecordingFailure.permissionRequired)) }
        let screens = NSScreen.screens
        displays = screens.compactMap { screen in screen.displayID.map { ($0, screen.frame, screen.backingScaleFactor) } }
        for display in displays {
            let view = RecordingSelectionView(selector: self, displayFrame: display.frame)
            let panel = SelectionPanel.covering(display.frame, content: view)
            panels.append(panel)
            panel.orderFrontRegardless()
            if NSMouseInRect(pointer, display.frame, false) { panel.makeKey(); panel.makeFirstResponder(view) }
        }
        updateCursor()
        if kind == .screen {
            let main = displays.first { $0.id == CGMainDisplayID() }
            let underPointer = display(at: pointer)
            // The preferred display stays highlighted until the pointer moves.
            selectedDisplayID = ((preferences.recording.screenTarget == .mainDisplay ? main : underPointer) ?? displays.first)?.id
            redraw()
            return
        }
        updatePointer(pointer, modifiers: [])
        operation = Task { [self] in
            do {
                // Tiny windows such as status panels are no recording targets.
                let targets = try await WindowTarget.onScreen(screens, includesShotty: false, minimumSide: 40)
                guard requestID == request, !Task.isCancelled else { return }
                windows = targets
                updatePointer(pointer, modifiers: [])
            } catch is CancellationError { }
            catch { if requestID == request { finish(.failure(error)) } }
        }
    }

    /// A crosshair for drawing an area, before and while dragging; the arrow once the area is drawn
    /// and for picking a window. Set directly as well as through cursor rects, because Shotty is not
    /// the active app.
    var cursor: NSCursor { kind == .area && !isTargetPicked ? .captureCrosshair : .arrow }

    func updateCursor() { cursor.set() }

    private func refreshCursor() {
        panels.forEach { $0.invalidateCursorRects(for: $0.contentView!) }
        updateCursor()
    }

    func changeMode(_ newKind: RecordingKind) {
        guard isActive, drag == nil, kind != .screen, newKind != .screen else { return }
        kind = newKind
        selection = nil
        isTargetPicked = false
        hideRecordBar()
        refreshCursor()
        updatePointer(pointer, modifiers: [])
    }

    func updatePointer(_ point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        pointer = point
        switch kind {
        case .window:
            if !isTargetPicked { highlightWindow(windows.first { $0.frame.contains(point) }) }
        case .screen:
            if !isTargetPicked, let display = display(at: point) { selectedDisplayID = display.id }
        case .area:
            guard var drag else { break }
            drag.update(to: point, square: modifiers.contains(.shift), centered: modifiers.contains(.option))
            self.drag = drag
            selection = drag.rect
        }
        redraw()
    }

    func mouseMoved(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        hasPointerInteraction = true
        updatePointer(point, modifiers: modifiers)
    }

    func modifiersChanged(_ modifiers: NSEvent.ModifierFlags) {
        if kind == .area { updatePointer(pointer, modifiers: modifiers) }
    }

    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        switch kind {
        case .window:
            // A click on no window lets the highlight follow the pointer again.
            pointer = point
            let target = windows.first { $0.frame.contains(point) }
            highlightWindow(target)
            setTargetPicked(target != nil)
            return
        case .screen:
            pointer = point
            guard let display = display(at: point) else { return }
            selectedDisplayID = display.id
            setTargetPicked(true)
            return
        case .area: break
        }
        // A 6-point band on each side of an edge gives handles a 12-point hit area.
        let drag = SelectionDrag(at: point, adjusting: isTargetPicked ? selection : nil, tolerance: 6)
        self.drag = drag
        selection = drag.rect
        errorMessage = nil
        updatePointer(point, modifiers: modifiers)
    }

    func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard drag != nil else { return }
        updatePointer(point, modifiers: modifiers)
        drag = nil
        guard let selection, selection.width >= 8, selection.height >= 8 else {
            // A click without a drag clears the area; drawing again brings the Record bar back.
            self.selection = nil
            setTargetPicked(false)
            return
        }
        setTargetPicked(true)
    }

    func keyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()
        case 36, 76: confirm()
        case 49:
            guard !event.isARepeat else { return }
            if drag != nil { drag?.setSpace(true, at: pointer) } else { changeMode(kind == .window ? .area : .window) }
        case 48 where kind == .screen:
            guard let current = displays.firstIndex(where: { $0.id == selectedDisplayID }) else { return }
            let step = event.modifierFlags.contains(.shift) ? displays.count - 1 : 1
            selectedDisplayID = displays[(current + step) % displays.count].id
            setTargetPicked(true)
        case 48 where kind == .window:
            let underPointer = windows.filter { $0.frame.contains(pointer) }
            let choices = hasPointerInteraction && !underPointer.isEmpty ? underPointer : windows
            guard !choices.isEmpty else { return }
            let current = choices.firstIndex(where: { $0.id == selectedWindowID }) ?? -1
            let index = (current + (event.modifierFlags.contains(.shift) ? choices.count - 1 : 1)) % choices.count
            highlightWindow(choices[max(0, index)])
            setTargetPicked(true)
        case 123...126 where kind == .area:
            if selection == nil { selection = CGRect(x: pointer.x - 320, y: pointer.y - 180, width: 640, height: 360) }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
            // One assignment: mutating the observed property in place conflicts with its own read.
            selection = selection.map { SelectionGeometry.nudged($0, dx: dx, dy: dy, resizes: event.modifierFlags.contains(.option)) }
            setTargetPicked(true)
        default: break
        }
    }

    func keyUp(_ event: NSEvent) {
        guard event.keyCode == 49 else { return }
        drag?.setSpace(false, at: pointer)
    }

    /// Return or Record. Return on a highlighted window or display picks it first, so the Record bar
    /// always shows before a recording starts.
    func confirm() {
        guard isActive else { return }
        switch kind {
        case .window:
            guard let id = selectedWindowID, let frame = selectedWindowFrame else { return }
            if isTargetPicked { finish(.success(.window(id, frame: frame))) } else { setTargetPicked(true) }
            return
        case .screen:
            guard let selectedDisplayID else { return }
            if isTargetPicked { finish(.success(.display(selectedDisplayID))) } else { setTargetPicked(true) }
            return
        case .area: break
        }
        guard let selection else { return }
        guard let region = SelectionGeometry.recordingRegion(selection, displays: displays.map { ($0.id, $0.frame) }),
              region.rect.width >= 8, region.rect.height >= 8 else {
            errorMessage = "Draw the area on a display."
            redraw()
            return
        }
        finish(.success(.region(region.rect, display: region.display)))
    }

    func cancel() {
        guard isActive else { return }
        let callback = completion
        cleanup()
        callback?(.failure(CancellationError()))
    }

    private func finish(_ result: Result<RecordingTarget, Error>) {
        let callback = completion
        cleanup()
        callback?(result)
    }

    private func cleanup() {
        requestID = UUID()
        operation?.cancel()
        operation = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        hideRecordBar()
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
        screenObservation = nil
        displays.removeAll()
        windows.removeAll()
        selectedWindowID = nil
        selectedWindowFrame = nil
        selectedDisplayID = nil
        selection = nil
        drag = nil
        isTargetPicked = false
        isActive = false
        completion = nil
    }

    private func redraw() {
        panels.forEach {
            $0.contentView?.needsDisplay = true
            ($0.contentView as? RecordingSelectionView)?.updateAccessibility()
        }
        layoutRecordBar()
    }

    var accessibleWindowTitle: String? { windows.first { $0.id == selectedWindowID }?.title }

    /// What Record would capture now: the area, the highlighted window, or the picked display.
    var targetFrame: CGRect? {
        switch kind {
        case .area: selection
        case .window: selectedWindowFrame
        case .screen: displays.first { $0.id == selectedDisplayID }?.frame
        }
    }

    private func highlightWindow(_ target: WindowTarget?) {
        selectedWindowID = target?.id
        selectedWindowFrame = target?.frame
    }

    private func display(at point: CGPoint) -> (id: CGDirectDisplayID, frame: CGRect, scale: CGFloat)? {
        displays.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func setTargetPicked(_ picked: Bool) {
        isTargetPicked = picked
        if picked { showRecordBar() } else { hideRecordBar() }
        refreshCursor()
        redraw()
    }

    private func hideRecordBar() {
        recordBar?.close()
        recordBar = nil
    }

    /// The Record bar never takes key focus, so Return and Escape keep reaching the selection.
    private func showRecordBar() {
        guard recordBar == nil else { return layoutRecordBar() }
        let panel = NonKeyPanel(contentRect: CGRect(x: 0, y: 0, width: 420, height: 46),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Clicking a selection panel brings it to the front of its level, so stay one level above.
        panel.level = NSWindow.Level(Chrome.floatingLevel.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        let content = NSHostingView(rootView: RecordBar(selector: self, preferences: preferences))
        // Only report the size; `layoutRecordBar` resizes the panel, keeping it centered as it grows.
        content.sizingOptions = [.intrinsicContentSize]
        panel.contentView = content
        recordBar = panel
        layoutRecordBar()
        panel.orderFrontRegardless()
    }

    /// Fits the Record bar to its content, whose width follows the microphone name,
    /// and places it beside the target.
    func layoutRecordBar() {
        guard let panel = recordBar, let size = panel.contentView?.intrinsicContentSize, let frame = targetFrame else { return }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        // A whole display or a maximized window leaves no room outside it, so the bar sits just
        // inside its visible bottom edge, clear of the Dock.
        let target = frame.intersection(visible).isNull ? frame : frame.intersection(visible)
        let candidates = SelectionGeometry.attachedOrigins(size: size, to: target, within: visible, gap: 6)
        let origin = SelectionGeometry.firstClearOrigin(candidates, size: size, avoiding: [frame], within: visible)
            ?? SelectionGeometry.firstClearOrigin(candidates, size: size, avoiding: [], within: visible)
            ?? candidates[2]
        let placed = CGRect(origin: origin, size: size)
        if panel.frame != placed { panel.setFrame(placed, display: true) }
    }

    /// Pixel dimensions the recording will have at native resolution.
    var pixelDimensions: CGSize {
        guard let frame = targetFrame else { return .zero }
        let scale = displays.filter { $0.frame.intersects(frame) }.map(\.scale).max() ?? 1
        return CGSize(width: ScreenRecorder.evenPixels(frame.width * scale), height: ScreenRecorder.evenPixels(frame.height * scale))
    }

    var drawsHandles: Bool { kind == .area && isTargetPicked }
    /// The pointer readout helps while drawing an area. It stays away once a region exists and while
    /// picking a window, which the tint and record symbol already mark; errors are always shown.
    var showsReadout: Bool { errorMessage != nil || kind == .area && (selection == nil || drag != nil) }
}

/// Cancel, audio toggles, and Record, below the adjustable area.
private struct RecordBar: View {
    let selector: RecordingSelector
    @Bindable var preferences: AppPreferences

    var body: some View {
        HStack(spacing: 8) {
            Button("Cancel", systemImage: "xmark") { selector.cancel() }
                .buttonStyle(.overlayIcon)
                .help("Cancel (Escape)")
            AudioToggles(preferences: preferences)
            Button { selector.confirm() } label: {
                Label { Text("Record") } icon: { Image(systemName: "record.circle.fill").foregroundStyle(.red) }
            }
            .buttonStyle(.overlayCapsuleProminent)
            .help("Start recording (Return)")
        }
        .buttonStyle(.overlayCapsule)
        .fixedSize()
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { _ in selector.layoutRecordBar() }
        // Room for the controls' shadows.
        .padding(9)
    }
}

/// The microphone menu and the system audio switch, white while on. They are the only place to set
/// either, and they persist, so the next recording (also after a relaunch) starts the same way.
struct AudioToggles: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        let isOn = preferences.recording.recordsSystemAudio
        HStack(spacing: 8) {
            MicrophoneButton(preferences: preferences)
            Button("System Audio", systemImage: isOn ? "speaker.wave.2.fill" : "speaker.slash") {
                preferences.recording.recordsSystemAudio.toggle()
            }
            .buttonStyle(isOn ? .overlayIconProminent : .overlayIcon)
            .help("System Audio: \(isOn ? "On" : "Off")")
            .accessibilityValue(isOn ? "On" : "Off")
        }
    }
}

private final class RecordingSelectionView: NSView {
    private unowned let selector: RecordingSelector
    private let displayFrame: CGRect
    private var tracking: NSTrackingArea?

    init(selector: RecordingSelector, displayFrame: CGRect) {
        self.selector = selector
        self.displayFrame = displayFrame
        super.init(frame: CGRect(origin: .zero, size: displayFrame.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    func updateAccessibility() {
        let label = switch selector.kind {
        case .area, .window: "Recording selection. Drag to select an area, or press Space to pick a window. Return records. Escape cancels."
        case .screen: "Recording selection. Click a display or press Tab to pick it. Return picks the highlighted display, then records. Escape cancels."
        }
        if accessibilityLabel() != label { setAccessibilityLabel(label) }
        let value: String
        if selector.kind == .screen {
            let size = selector.pixelDimensions
            value = selector.targetFrame == displayFrame ? "This display, \(Int(size.width)) × \(Int(size.height)) pixels" : "Another display"
        } else if selector.kind == .window {
            value = selector.accessibleWindowTitle ?? "No window selected"
        } else if let rect = selector.selection {
            let size = selector.pixelDimensions
            value = "X \(Int(rect.minX - displayFrame.minX)), Y \(Int(displayFrame.maxY - rect.maxY)), width \(Int(size.width)), height \(Int(size.height)) pixels"
        } else {
            value = "X \(Int(selector.pointer.x - displayFrame.minX)), Y \(Int(displayFrame.maxY - selector.pointer.y)) points"
        }
        guard accessibilityValue() as? String != value else { return }
        setAccessibilityValue(value)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: selector.cursor) }
    override func cursorUpdate(with event: NSEvent) { selector.updateCursor() }
    /// Keyboard focus follows the pointer across displays. Only the key panel of an inactive app
    /// can set the cursor, and Escape and Return must reach the selection.
    override func mouseEntered(with event: NSEvent) {
        takeKeyFocus()
        selector.updateCursor()
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func takeKeyFocus() {
        guard let window, !window.isKeyWindow else { return }
        window.makeKey()
        window.makeFirstResponder(self)
    }

    override func draw(_ dirtyRect: NSRect) {
        let local: (CGRect) -> CGRect = { $0.offsetBy(dx: -self.displayFrame.minX, dy: -self.displayFrame.minY) }
        if let selected = selector.targetFrame {
            let rect = local(selected)
            if selector.kind != .area {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                rect.fill()
            } else {
                Chrome.drawSelection(rect)
            }
            if selector.drawsHandles { SelectionDrawing.drawHandles(around: rect) }
        }
        let point = CGPoint(x: selector.pointer.x - displayFrame.minX, y: selector.pointer.y - displayFrame.minY)
        guard selector.showsReadout, bounds.contains(point) else { return }
        SelectionDrawing.drawReadout(at: point, in: bounds, error: selector.errorMessage,
                                     size: selector.selection == nil ? nil : selector.pixelDimensions)
    }

    private func point(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation }
    override func mouseMoved(with event: NSEvent) {
        selector.updateCursor()
        selector.mouseMoved(at: point(event), modifiers: event.modifierFlags)
    }
    override func mouseDown(with event: NSEvent) {
        takeKeyFocus()
        selector.mouseDown(at: point(event), modifiers: event.modifierFlags)
    }
    override func mouseDragged(with event: NSEvent) { selector.updatePointer(point(event), modifiers: event.modifierFlags) }
    override func mouseUp(with event: NSEvent) { selector.mouseUp(at: point(event), modifiers: event.modifierFlags) }
    override func flagsChanged(with event: NSEvent) { selector.modifiersChanged(event.modifierFlags) }
    override func keyDown(with event: NSEvent) { selector.keyDown(event) }
    override func keyUp(with event: NSEvent) { selector.keyUp(event) }
}
