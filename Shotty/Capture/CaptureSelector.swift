import AppKit
import Observation
import ScreenCaptureKit
import SwiftUI
import os

/// Screen-parameter notifications also cover changes that do not invalidate capture geometry.
struct SelectionScreenLayout: Equatable {
    struct Display: Equatable {
        var id: CGDirectDisplayID
        var frame: CGRect
        var scale: CGFloat
        var pixelSize: CGSize
        var rotation: Double
    }

    let displays: [Display]

    init(displays: [Display]) { self.displays = displays.sorted { $0.id < $1.id } }

    @MainActor static var current: SelectionScreenLayout {
        SelectionScreenLayout(displays: NSScreen.screens.compactMap { screen in
            guard let id = screen.displayID else { return nil }
            return Display(id: id, frame: screen.frame, scale: screen.backingScaleFactor,
                           pixelSize: CGSize(width: CGDisplayPixelsWide(id), height: CGDisplayPixelsHigh(id)),
                           rotation: CGDisplayRotation(id))
        })
    }
}

struct SelectionConfiguration {
    var freeze = true
    var shadow = true
    var cursor = false
    var adjust = false
    var crosshair = false
    var magnifier = false
}

enum CaptureSelection {
    case image(CGImage, kind: CaptureKind, scale: Double)
    case scrolling(region: CGRect, windowID: CGWindowID, processID: pid_t, displayID: CGDirectDisplayID)
}

/// One selection owns its snapshots and panels. Completion transfers immutable
/// pixels before releasing those resources; cancelling never produces a result.
@MainActor @Observable
final class CaptureSelector {
    private(set) var isActive = false
    private(set) var kind: CaptureKind = .area
    private(set) var selection: CGRect?
    private(set) var pointer = NSEvent.mouseLocation
    /// Unshadowed frozen pixels of the hovered window, sized to its frame. Output uses
    /// the shadow variant chosen at confirmation; the unshadowed raster maps exactly onto
    /// the window frame, while shadow padding has no reported offset.
    private(set) var selectedWindowPreview: NSImage?
    private(set) var selectedWindowFrame: CGRect?
    private(set) var isPreparing = false
    var errorMessage: String?
    private var configuration = SelectionConfiguration()
    private var displays: [SelectionDisplay] = []
    private var windows: [WindowTarget] = []
    private var windowIndex = 0
    private var selectedWindowID: CGWindowID?
    private var shadowInverted = false
    private var hasPointerInteraction = false
    private var drag: SelectionDrag?
    private var isAdjusting = false
    private var panels: [SelectionPanel] = []
    private var adjustmentPanel: NSPanel?
    private var progressPanel: NSPanel?
    private var frozen: FrozenCaptureSet?
    private var operation: Task<Void, Never>?
    private var hoverOperation: Task<Void, Never>?
    private var screenObservation: NSObjectProtocol?
    private var requestID = UUID()
    private var completion: ((Result<CaptureSelection, Error>) -> Void)?
    private let capture = StillCaptureService()
    private let renderer = SelectionRenderer()
    private let logger = Logger(subsystem: "local.markus.Shotty", category: "CaptureSelection")

    struct WindowTarget {
        let id: CGWindowID
        let processID: pid_t
        let title: String
        let frame: CGRect
    }

    func begin(kind: CaptureKind, configuration: SelectionConfiguration,
               completion: @escaping (Result<CaptureSelection, Error>) -> Void) {
        cancel()
        isActive = true
        self.kind = kind
        self.configuration = configuration
        self.completion = completion
        let request = UUID()
        requestID = request
        pointer = NSEvent.mouseLocation
        hasPointerInteraction = false
        isPreparing = true
        errorMessage = nil
        let screenLayout = SelectionScreenLayout.current
        // Invalidate actual topology/geometry changes, not an unrelated screen-parameter notification.
        screenObservation = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.requestID == request else { return }
                    let current = SelectionScreenLayout.current
                    guard current != screenLayout else {
                        self.logger.info("Ignored screen-parameter notification with unchanged capture geometry")
                        return
                    }
                    self.logger.error("Capture cancelled for screen geometry: before=\(String(describing: screenLayout), privacy: .public) after=\(String(describing: current), privacy: .public)")
                    self.finish(.failure(FrozenCaptureFailure.targetChanged))
                }
            }
        operation = Task { [self] in
            let progress = showPreparation(after: .milliseconds(100), for: request)
            defer { progress.cancel() }
            do {
                guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permissionRequired }
                let screens = NSScreen.screens
                let metadata = screens.compactMap { screen -> SelectionDisplay? in
                    guard let id = screen.displayID else { return nil }
                    return SelectionDisplay(id: id, frame: screen.frame, scale: screen.backingScaleFactor, image: nil)
                }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                let order = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
                let ownPID = ProcessInfo.processInfo.processIdentifier
                windows = content.windows.compactMap { window in
                    guard window.isOnScreen, window.windowLayer == 0,
                          let app = window.owningApplication, app.processID != ownPID,
                          let display = content.displays.first(where: { $0.frame.intersects(window.frame) }),
                          let screen = screens.first(where: { $0.displayID == display.displayID }) else { return nil }
                    let geometry = DisplayGeometry(id: display.displayID, appKitFrame: screen.frame,
                        captureFrame: display.frame, pixelSize: CGSize(width: display.width, height: display.height))
                    let topLeft = geometry.appKitPoint(fromCapture: window.frame.origin)
                    return WindowTarget(id: window.windowID, processID: app.processID,
                        title: [app.applicationName, window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", "),
                        frame: CGRect(x: topLeft.x, y: topLeft.y - window.frame.height,
                                      width: window.frame.width, height: window.frame.height))
                }.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
                if configuration.freeze && kind != .scrolling {
                    let set = try await FrozenCaptureSet.acquire(shadow: configuration.shadow,
                        includeAlternateShadow: true, showsCursor: configuration.cursor)
                    guard requestID == request, !Task.isCancelled else { try? await set.close(); return }
                    frozen = set
                    var loaded: [SelectionDisplay] = []
                    for display in metadata {
                        guard let snapshot = set.displays.first(where: { $0.displayID == display.id }) else {
                            throw CaptureFailure.targetUnavailable
                        }
                        loaded.append(SelectionDisplay(id: display.id, frame: display.frame,
                                                       scale: CGFloat(snapshot.pointPixelScale),
                                                       image: try await set.image(for: snapshot.raster)))
                    }
                    displays = loaded
                    // Only windows with frozen pixels are selectable; others would export live content.
                    windows = windows.filter { target in set.windows.contains { $0.windowID == target.id } }
                } else {
                    displays = metadata
                }
                try Task.checkCancellation()
                guard requestID == request else { return }
                isPreparing = false
                progressPanel?.close()
                progressPanel = nil
                for screen in screens {
                    guard let display = displays.first(where: { $0.id == screen.displayID }) else { continue }
                    let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                               backing: .buffered, defer: false)
                    panel.isReleasedWhenClosed = false
                    panel.isOpaque = false
                    panel.backgroundColor = .clear
                    panel.level = .screenSaver
                    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    panel.acceptsMouseMovedEvents = true
                    let view = SelectionView(selector: self, display: display)
                    panel.contentView = view
                    panels.append(panel)
                    panel.orderFrontRegardless()
                    if screen.frame.contains(pointer) { panel.makeKey(); panel.makeFirstResponder(view) }
                }
                updatePointer(pointer, modifiers: [])
            } catch is CancellationError { }
            catch { if requestID == request { finish(.failure(error)) } }
        }
    }

    func changeMode(_ newKind: CaptureKind) {
        guard isActive, !isPreparing, drag == nil else { return }
        kind = newKind
        selection = nil
        isAdjusting = false
        adjustmentPanel?.close()
        adjustmentPanel = nil
        updatePointer(pointer, modifiers: [])
    }

    func updatePointer(_ point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        pointer = point
        let inverted = modifiers.contains(.option)
        if kind == .window {
            shadowInverted = inverted
            if let target = windows.first(where: { $0.frame.contains(point) }) {
                if target.id != selectedWindowID { selectWindow(target) }
            } else {
                selectedWindowID = nil
                selectedWindowFrame = nil
                selectedWindowPreview = nil
                hoverOperation?.cancel()
            }
        } else if var drag {
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
        // Flags events have no reliable mouse location. Preserve a keyboard-selected window.
        if kind == .window { shadowInverted = modifiers.contains(.option); redraw() }
        else { updatePointer(pointer, modifiers: modifiers) }
    }

    private func selectWindow(_ target: WindowTarget) {
        selectedWindowID = target.id
        selectedWindowFrame = target.frame
        selectedWindowPreview = nil
        errorMessage = nil
        hoverOperation?.cancel()
        guard let frozen,
              let snapshot = frozen.windows.first(where: { $0.windowID == target.id && !$0.includesShadow }) else { redraw(); return }
        let request = requestID
        hoverOperation = Task {
            do {
                let image = try await frozen.image(for: snapshot.raster)
                try Task.checkCancellation()
                guard requestID == request, selectedWindowID == target.id else { return }
                selectedWindowPreview = NSImage(cgImage: image, size: target.frame.size)
                redraw()
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription; redraw() }
        }
    }

    func mouseDown(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard !isPreparing else { return }
        if kind == .window { updatePointer(point, modifiers: modifiers); confirm(); return }
        // 6-point edge bands give the 12-point handle hit areas from the interaction spec.
        let drag = SelectionDrag(at: point, adjusting: isAdjusting ? selection : nil, tolerance: 6)
        self.drag = drag
        selection = drag.rect
        updatePointer(point, modifiers: modifiers)
    }

    func mouseUp(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard drag != nil else { return }
        updatePointer(point, modifiers: modifiers)
        drag = nil
        guard let selection, selection.width >= 2, selection.height >= 2 else {
            self.selection = nil
            redraw()
            return
        }
        // A scrolling region is always adjustable, so sticky headers can be excluded before Start.
        if configuration.adjust || isAdjusting || kind == .scrolling { isAdjusting = true; showAdjustment(); redraw() }
        else { confirm() }
    }

    func keyDown(_ event: NSEvent) {
        switch event.keyCode {
        case 53: cancel()
        case 36, 76: confirm()
        case 49:
            guard !event.isARepeat else { return }
            if drag != nil {
                drag?.setSpace(true, at: pointer)
            } else if kind == .area || kind == .window {
                changeMode(kind == .window ? .area : .window)
            }
        case 48 where kind == .window:
            let underPointer = windows.filter { $0.frame.contains(pointer) }
            let choices = hasPointerInteraction && !underPointer.isEmpty ? underPointer : windows
            guard !choices.isEmpty else { return }
            let current = choices.firstIndex(where: { $0.id == selectedWindowID }) ?? -1
            windowIndex = (current + (event.modifierFlags.contains(.shift) ? choices.count - 1 : 1)) % choices.count
            selectWindow(choices[max(0, windowIndex)])
        case 123...126 where kind != .window:
            if selection == nil {
                selection = CGRect(x: pointer.x, y: pointer.y - 100, width: 100, height: 100)
            }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            let dx: CGFloat = event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0
            let dy: CGFloat = event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0
            if event.modifierFlags.contains(.option) {
                selection?.size.width = max(1, selection!.width + dx)
                selection?.size.height = max(1, selection!.height + dy)
            } else { selection = selection?.offsetBy(dx: dx, dy: dy) }
            isAdjusting = true
            showAdjustment()
            redraw()
        default: break
        }
    }

    func keyUp(_ event: NSEvent) {
        guard event.keyCode == 49 else { return }
        drag?.setSpace(false, at: pointer)
    }

    func setDimension(width: Double?, height: Double?) {
        guard var selection else { return }
        let scale = SelectionGeometry.outputScale(for: selection, displays: displays)
        if let width, width.isFinite { selection.size.width = max(1, min(30_000, width)) / scale }
        if let height, height.isFinite { selection.size.height = max(1, min(30_000, height)) / scale }
        self.selection = selection
        redraw()
    }

    func confirm() {
        guard isActive, !isPreparing else { return }
        if kind == .window {
            guard let id = selectedWindowID, let target = windows.first(where: { $0.id == id }) else { return }
            let shadow = configuration.shadow != shadowInverted
            if let frozen {
                // A window without the chosen frozen variant must not fall back to live pixels.
                guard let snapshot = frozen.windows.first(where: { $0.windowID == id && $0.includesShadow == shadow }) else {
                    finish(.failure(CaptureFailure.targetUnavailable))
                    return
                }
                produce { .image(try await frozen.image(for: snapshot.raster), kind: .window,
                                 scale: Double(snapshot.pointPixelScale)) }
            } else {
                let scale = Double(displays.first(where: { $0.frame.intersects(target.frame) })?.scale ?? 1)
                let cursor = configuration.cursor
                produce { [capture] in
                    .image(try await capture.window(id: id, shadow: shadow, showsCursor: cursor), kind: .window, scale: scale)
                }
            }
            return
        }
        guard let selection, selection.width >= 1, selection.height >= 1,
              displays.contains(where: { $0.frame.intersects(selection) }) else { return }
        if kind == .scrolling {
            guard let display = displays.first(where: { $0.frame.contains(selection) }),
                  let target = windows.first(where: { $0.frame.contains(CGPoint(x: selection.midX, y: selection.midY)) }) else {
                errorMessage = "Select one scrollable region inside one display."
                redraw()
                return
            }
            finish(.success(.scrolling(region: selection, windowID: target.id,
                                       processID: target.processID, displayID: display.id)))
            return
        }
        let (kind, displays, freeze, cursor) = (kind, displays, configuration.freeze, configuration.cursor)
        produce { [capture, renderer] in
            var images = displays
            if !freeze {
                images = []
                for display in displays where display.frame.intersects(selection) {
                    let image = try await capture.display(id: display.id, excluding: ProcessInfo.processInfo.processIdentifier,
                                                          showsCursor: cursor)
                    images.append(SelectionDisplay(id: display.id, frame: display.frame, scale: display.scale, image: image))
                }
            }
            let image = try await renderer.compose(region: selection, displays: images)
            return .image(image, kind: kind, scale: Double(SelectionGeometry.outputScale(for: selection, displays: images)))
        }
    }

    /// Hides the selection surface and finishes with the result of `work`. Slow work shows
    /// the cancellable preparation panel, so Escape stays available until the result exists.
    private func produce(_ work: @escaping @MainActor () async throws -> CaptureSelection) {
        let request = requestID
        hidePanels()
        isPreparing = true
        operation = Task {
            let progress = showPreparation(after: .milliseconds(150), for: request)
            defer { progress.cancel() }
            do {
                let result = try await work()
                guard requestID == request, !Task.isCancelled else { return }
                finish(.success(result))
            } catch is CancellationError { }
            catch { if requestID == request { finish(.failure(error)) } }
        }
    }

    func cancel() {
        guard isActive else { return }
        let callback = completion
        cleanup()
        callback?(.failure(CancellationError()))
    }

    private func finish(_ result: Result<CaptureSelection, Error>) {
        let callback = completion
        cleanup()
        callback?(result)
    }

    private func cleanup() {
        requestID = UUID()
        operation?.cancel()
        operation = nil
        hoverOperation?.cancel()
        hoverOperation = nil
        hidePanels()
        panels.removeAll()
        progressPanel?.close()
        progressPanel = nil
        if let screenObservation { NotificationCenter.default.removeObserver(screenObservation) }
        screenObservation = nil
        let set = frozen
        frozen = nil
        if let set { Task { try? await set.close() } }
        displays.removeAll()
        windows.removeAll()
        selectedWindowPreview = nil
        selectedWindowID = nil
        selectedWindowFrame = nil
        selection = nil
        drag = nil
        shadowInverted = false
        isAdjusting = false
        isActive = false
        isPreparing = false
        completion = nil
    }

    private func hidePanels() {
        panels.forEach { $0.orderOut(nil) }
        adjustmentPanel?.close()
        adjustmentPanel = nil
    }

    private func redraw() {
        panels.forEach {
            $0.contentView?.needsDisplay = true
            ($0.contentView as? SelectionView)?.updateAccessibility()
        }
        positionStartCapture()
    }

    var accessibleWindowTitle: String? { windows.first { $0.id == selectedWindowID }?.title }

    /// Shows the preparation panel after `delay` unless the request finished first. The panel
    /// becomes key so Escape reaches its Cancel button while no selection panel is visible.
    private func showPreparation(after delay: Duration, for request: UUID) -> Task<Void, Never> {
        Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.requestID == request, self.isPreparing, self.progressPanel == nil else { return }
            let panel = SelectionPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panel.isReleasedWhenClosed = false
            panel.level = .screenSaver
            panel.contentView = NSHostingView(rootView: HStack {
                ProgressView().controlSize(.small)
                Text("Preparing capture…")
                Button("Cancel") { [weak self] in self?.cancel() }.keyboardShortcut(.cancelAction)
            }.padding(14))
            panel.setContentSize(NSSize(width: 300, height: 54))
            let frame = NSScreen.screens.first(where: { $0.frame.contains(self.pointer) })?.visibleFrame ?? .zero
            panel.setFrameOrigin(CGPoint(x: frame.midX - 150, y: frame.midY - 27))
            self.progressPanel = panel
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func showAdjustment() {
        guard adjustmentPanel == nil, let selection else { return }
        if kind == .scrolling { return showStartCapture() }
        let panel = SelectionPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "Adjust Selection"
        panel.level = .screenSaver
        panel.contentView = NSHostingView(rootView: SelectionAdjustment(selector: self))
        panel.setContentSize(NSSize(width: 430, height: 70))
        let visible = NSScreen.screens.first(where: { $0.frame.contains(pointer) })?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x: max(visible.minX, min(selection.minX, visible.maxX - 430)),
                                     y: max(visible.minY, selection.minY - 100)))
        adjustmentPanel = panel
        panel.orderFrontRegardless()
    }

    /// Scrolling confirms with a single Start Capture control that follows the region's bottom edge.
    /// Return and Escape still reach the key selection surface.
    private func showStartCapture() {
        let panel = StartCapturePanel(contentRect: CGRect(x: 0, y: 0, width: 170, height: 46),
                                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Clicking a selection panel brings it to the front of its level, so stay one level above.
        panel.level = NSWindow.Level(NSWindow.Level.screenSaver.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: Button { [weak self] in self?.confirm() } label: {
            Label("Start Capture", systemImage: "arrow.down")
        }
        .buttonStyle(.overlayCapsule)
        .help("Drag the edges to exclude fixed headers or footers. Arrow keys move the region; Option-arrow keys resize it.")
        .frame(maxWidth: .infinity, maxHeight: .infinity))
        adjustmentPanel = panel
        positionStartCapture()
        panel.orderFrontRegardless()
    }

    private func positionStartCapture() {
        guard kind == .scrolling, let panel = adjustmentPanel, let selection else { return }
        let center = CGPoint(x: selection.midX, y: selection.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(center) }) else { return }
        let candidates = SelectionGeometry.attachedOrigins(size: panel.frame.size, to: selection, within: screen.frame, gap: 2)
        guard let origin = SelectionGeometry.firstClearOrigin(candidates, size: panel.frame.size, avoiding: [], within: screen.frame),
              panel.frame.origin != origin else { return }
        panel.setFrameOrigin(origin)
    }

    var pixelDimensions: CGSize {
        guard let selection else { return .zero }
        let scale = SelectionGeometry.outputScale(for: selection, displays: displays)
        return CGSize(width: ceil(selection.width * scale), height: ceil(selection.height * scale))
    }

    var showsCrosshair: Bool { configuration.crosshair }
    var showsMagnifier: Bool { configuration.magnifier }
    var drawsHandles: Bool { isAdjusting }
}

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private struct SelectionAdjustment: View {
    @Bindable var selector: CaptureSelector
    var body: some View {
        HStack {
            Text("W")
            TextField("Width in pixels", value: Binding(get: { Double(selector.pixelDimensions.width) },
                set: { selector.setDimension(width: $0, height: nil) }), format: .number).frame(width: 66)
            Text("H")
            TextField("Height in pixels", value: Binding(get: { Double(selector.pixelDimensions.height) },
                set: { selector.setDimension(width: nil, height: $0) }), format: .number).frame(width: 66)
            Button("Cancel") { selector.cancel() }.keyboardShortcut(.cancelAction)
            Button("Capture") { selector.confirm() }.keyboardShortcut(.defaultAction)
        }
        .padding(12)
        .help("Drag the edges or use the arrow keys to adjust. Option-arrow keys resize.")
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class SelectionView: NSView {
    private unowned let selector: CaptureSelector
    private let display: SelectionDisplay
    /// Created once; drawing a fresh wrapper per frame would redecode the snapshot.
    private let displayImage: NSImage?
    private var tracking: NSTrackingArea?

    init(selector: CaptureSelector, display: SelectionDisplay) {
        self.selector = selector
        self.display = display
        displayImage = display.image.map { NSImage(cgImage: $0, size: display.frame.size) }
        super.init(frame: CGRect(origin: .zero, size: display.frame.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(selector.kind == .scrolling
            ? "Scrolling capture. \(Self.scrollingInstruction) Arrow keys adjust. Return starts. Escape cancels."
            : "Capture selection. Drag to select. Arrow keys adjust. Return captures. Escape cancels.")
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    func updateAccessibility() {
        let value: String
        if selector.kind == .window {
            value = selector.accessibleWindowTitle ?? "No window selected"
        } else if let rect = selector.selection {
            let size = selector.pixelDimensions
            value = "X \(Int(rect.minX - display.frame.minX)), Y \(Int(display.frame.maxY - rect.maxY)), width \(Int(size.width)), height \(Int(size.height)) pixels"
        } else {
            value = "X \(Int(selector.pointer.x - display.frame.minX)), Y \(Int(display.frame.maxY - selector.pointer.y)) points"
        }
        guard accessibilityValue() as? String != value else { return }
        setAccessibilityValue(value)
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: selector.kind == .window ? .arrow : .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        displayImage?.draw(in: bounds)
        let local: (CGRect) -> CGRect = { $0.offsetBy(dx: -self.display.frame.minX, dy: -self.display.frame.minY) }
        let selected = selector.kind == .window ? selector.selectedWindowFrame : selector.selection
        if selector.kind == .window, let selected, let preview = selector.selectedWindowPreview {
            // Occluded parts of the frozen target become visible, exactly where the window is.
            preview.draw(in: local(selected))
        }
        let shade = NSBezierPath(rect: bounds)
        if let selected { shade.appendRect(local(selected)) }
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.28).setFill()
        shade.fill()
        if let selected {
            let rect = local(selected)
            if selector.kind == .window {
                NSColor.systemBlue.withAlphaComponent(0.22).setFill()
                rect.fill()
                let symbol = NSImage(systemSymbolName: "camera.fill", accessibilityDescription: "Capture window")
                symbol?.draw(in: CGRect(x: rect.midX - 18, y: rect.midY - 15, width: 36, height: 30))
            }
            if selector.drawsHandles {
                drawHandles(around: rect)
            } else {
                NSColor.systemBlue.setStroke()
                let path = NSBezierPath(rect: rect)
                path.lineWidth = 1
                path.stroke()
            }
        } else if selector.kind == .scrolling {
            drawInstruction()
        }
        let point = CGPoint(x: selector.pointer.x - display.frame.minX, y: selector.pointer.y - display.frame.minY)
        guard bounds.contains(point) else { return }
        if selector.showsCrosshair {
            NSColor.white.withAlphaComponent(0.6).setStroke()
            let lines = NSBezierPath()
            lines.move(to: CGPoint(x: 0, y: point.y)); lines.line(to: CGPoint(x: bounds.maxX, y: point.y))
            lines.move(to: CGPoint(x: point.x, y: 0)); lines.line(to: CGPoint(x: point.x, y: bounds.maxY))
            lines.stroke()
        }
        let dimensions = selector.pixelDimensions
        let message = selector.errorMessage ?? (selector.selection == nil
            ? "X \(Int(point.x))  Y \(Int(bounds.height - point.y))"
            : "\(Int(dimensions.width)) × \(Int(dimensions.height)) px")
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                                         .foregroundColor: NSColor.white]
        let size = (message as NSString).size(withAttributes: attributes)
        let label = CGRect(x: min(bounds.maxX - size.width - 20, max(8, point.x + 16)),
                           y: max(8, point.y - 36), width: size.width + 12, height: size.height + 8)
        NSColor.black.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: label, xRadius: 5, yRadius: 5).fill()
        (message as NSString).draw(at: CGPoint(x: label.minX + 6, y: label.minY + 4), withAttributes: attributes)
        if selector.showsMagnifier, let image = display.image {
            // The snapshot's own pixel density, which need not match the current backing scale.
            let density = CGFloat(image.width) / bounds.width
            let pixels = CGRect(x: point.x * density - 8, y: (bounds.height - point.y) * density - 8,
                                width: 16, height: 16).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let crop = image.cropping(to: pixels) {
                let rect = CGRect(x: min(bounds.width - 88, max(8, point.x + 20)),
                                  y: min(bounds.height - 88, max(8, point.y + 20)), width: 80, height: 80)
                NSGraphicsContext.current?.imageInterpolation = .none
                NSImage(cgImage: crop, size: rect.size).draw(in: rect)
            }
        }
    }

    static let scrollingInstruction = "Drag to capture the scrolling part of the screen."

    /// White corner brackets and edge bars drawn just outside the region, clear of its pixels.
    private func drawHandles(around rect: CGRect) {
        let width: CGFloat = 4
        let edge = rect.insetBy(dx: -width / 2, dy: -width / 2)
        let arm = min(18, edge.width / 2, edge.height / 2)
        let path = NSBezierPath()
        for (x, dx) in [(edge.minX, arm), (edge.maxX, -arm)] {
            for (y, dy) in [(edge.minY, arm), (edge.maxY, -arm)] {
                path.move(to: CGPoint(x: x + dx, y: y))
                path.line(to: CGPoint(x: x, y: y))
                path.line(to: CGPoint(x: x, y: y + dy))
            }
        }
        let bar: CGFloat = 9
        if edge.width > 4 * arm {
            for y in [edge.minY, edge.maxY] {
                path.move(to: CGPoint(x: edge.midX - bar, y: y))
                path.line(to: CGPoint(x: edge.midX + bar, y: y))
            }
        }
        if edge.height > 4 * arm {
            for x in [edge.minX, edge.maxX] {
                path.move(to: CGPoint(x: x, y: edge.midY - bar))
                path.line(to: CGPoint(x: x, y: edge.midY + bar))
            }
        }
        path.lineWidth = width
        path.lineJoinStyle = .miter
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.45)
        shadow.shadowBlurRadius = 2
        shadow.set()
        NSColor.white.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The scrolling prompt, centered on each display until a region is drawn.
    private func drawInstruction() {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 17),
                                                         .foregroundColor: NSColor.black.withAlphaComponent(0.85)]
        let text = Self.scrollingInstruction as NSString
        let size = text.size(withAttributes: attributes)
        let pill = CGRect(x: bounds.midX - size.width / 2 - 28, y: bounds.midY - size.height / 2 - 16,
                          width: size.width + 56, height: size.height + 32)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3)
        shadow.shadowBlurRadius = 10
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.set()
        NSColor(white: 0.9, alpha: 0.96).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        NSGraphicsContext.restoreGraphicsState()
        text.draw(at: CGPoint(x: pill.minX + 28, y: pill.minY + 16), withAttributes: attributes)
    }

    private func point(_ event: NSEvent) -> CGPoint { window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation }
    override func mouseMoved(with event: NSEvent) { selector.mouseMoved(at: point(event), modifiers: event.modifierFlags) }
    override func mouseDown(with event: NSEvent) { selector.mouseDown(at: point(event), modifiers: event.modifierFlags) }
    override func mouseDragged(with event: NSEvent) { selector.updatePointer(point(event), modifiers: event.modifierFlags) }
    override func mouseUp(with event: NSEvent) { selector.mouseUp(at: point(event), modifiers: event.modifierFlags) }
    override func flagsChanged(with event: NSEvent) { selector.modifiersChanged(event.modifierFlags) }
    override func keyDown(with event: NSEvent) { selector.keyDown(event) }
    override func keyUp(with event: NSEvent) { selector.keyUp(event) }
}

/// Clicking Start must leave selection keys on the overlay if validation rejects the region.
private final class StartCapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
