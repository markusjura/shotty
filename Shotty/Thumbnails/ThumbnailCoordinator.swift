import AppKit
import Observation
import SwiftUI

/// Owns the non-activating thumbnail panel: newest-first cards, display following,
/// interaction locks, overflow, swipe dismissal, and auto-close countdowns.
/// Commands go through `perform`; the app owns documents, outputs, and dismissal Undo.
@MainActor @Observable
final class ThumbnailCoordinator {
    struct Card: Identifiable {
        let id: UUID
        var image: NSImage
        var status: String?
    }
    enum Action {
        case open, copy, save, saveAs, dismiss

        /// Copy and save share the editor's registry commands, so remapped or cleared bindings apply
        /// to cards as well. Open and Dismiss use the card's fixed Return/Space and Delete keys.
        var command: CommandID? {
            switch self {
            case .copy: .copyImage
            case .save: .save
            case .saveAs: .saveAs
            case .open, .dismiss: nil
            }
        }

        /// The action a focused card runs for `shortcut`, given the current bindings.
        static func matching(_ shortcut: Shortcut, bindings: (CommandID) -> Shortcut?) -> Action? {
            [Action.copy, .save, .saveAs].first { $0.command.flatMap(bindings) == shortcut }
        }
    }

    /// Newest first.
    private(set) var cards: [Card] = []
    var hidden = false
    var undoAvailable = false
    var perform: ((UUID, Action) -> Void)?
    /// Supplies current command bindings; nil falls back to the registry defaults.
    var commands: CommandRegistry?
    var undo: (() -> Void)?
    var makePromise: ((UUID) -> NSFilePromiseProvider?)?
    /// Reports the drag outcome; `keepCard` is true when Option was held at the drop.
    var dragFinished: ((UUID, _ accepted: Bool, _ keepCard: Bool) -> Void)?
    /// Runs a card's expired auto-close action. For `.saveThenDismiss`, dismiss only after the
    /// save succeeds, regardless of the dismiss-after-save preference; a failed save keeps the card.
    var autoClose: ((UUID, ThumbnailAutoClose) -> Void)?
    /// True while an editor session or a failed save must hold that card's countdown.
    var pausesAutoClose: ((UUID) -> Bool)?

    /// Cards shown in the panel; the rest open from the "N more" control.
    private(set) var visibleCount = 0
    var showingOverflow = false { didSet { setInteraction(.overflow, showingOverflow) } }
    private(set) var focusRequest: UUID?

    enum Interaction: Hashable { case press, menu, drag, keyboard, overflow }
    private var interactions = Set<Interaction>()
    private var externalLocks = 0
    private var hovering = false
    private var countdown = ThumbnailCountdown()
    private var countdownTask: Task<Void, Never>?
    private let preferences: AppPreferences
    private var panel: ThumbnailPanel?
    private var monitors: [Any] = []
    private var trackingObservers: [NSObjectProtocol] = []
    private var spaceObserver: NSObjectProtocol?
    private var relocation: Task<Void, Never>?
    private var targetDisplay: CGDirectDisplayID?

    init(preferences: AppPreferences) { self.preferences = preferences }

    /// The binding a card should honour for `action`. Recording suspends every card shortcut.
    func shortcut(for action: Action) -> Shortcut? {
        guard let command = action.command, commands?.recordingCommand == nil else { return nil }
        return commands.map { $0.shortcut(for: command) } ?? command.defaultShortcut
    }

    /// The card action bound to `shortcut`, if any.
    func cardAction(for shortcut: Shortcut) -> Action? {
        guard commands?.recordingCommand == nil else { return nil }
        return Action.matching(shortcut) { command in
            self.commands.map { $0.shortcut(for: command) } ?? command.defaultShortcut
        }
    }

    var isLocked: Bool { !interactions.isEmpty || externalLocks > 0 }
    var placement: ThumbnailPlacement { preferences.thumbnails.placement }
    var width: CGFloat { preferences.thumbnails.size.width }

    func refresh() {
        guard !hidden, !cards.isEmpty || undoAvailable else {
            stopTracking()
            showingOverflow = false
            panel?.orderOut(nil)
            return
        }
        if panel == nil { panel = makePanel() }
        startTracking()
        place()
        panel?.orderFrontRegardless()
    }

    /// Adds a card nearest the anchor without taking keyboard focus.
    func add(_ id: UUID, image: CGImage) {
        cards.removeAll { $0.id == id }
        cards.insert(Card(id: id, image: NSImage(cgImage: image, size: .zero)), at: 0)
        let settings = preferences.thumbnails
        if settings.autoClose != .never { countdown.start(id, seconds: TimeInterval(settings.autoCloseDelaySeconds)) }
        runCountdown()
        refresh()
    }

    func update(_ id: UUID, image: CGImage? = nil, status: String? = nil) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        if let image { cards[index].image = NSImage(cgImage: image, size: .zero) }
        cards[index].status = status
        place()
    }

    func remove(_ id: UUID) {
        countdown.cancel(id)
        cards.removeAll { $0.id == id }
        if focusRequest == id { focusRequest = nil }
        refresh()
    }

    /// Counted lock for app-owned interactions such as a Save As panel.
    func lock(_ active: Bool) {
        externalLocks = max(0, externalLocks + (active ? 1 : -1))
        if !isLocked { place() }
    }

    /// Keyboard entry point for a command: makes the panel key and focuses the newest card.
    func focusStack() {
        guard let newest = cards.first else { return }
        hidden = false
        refresh()
        focusRequest = newest.id
        panel?.makeKey()
    }

    func close() {
        stopTracking()
        countdownTask?.cancel()
        countdownTask = nil
        countdown = ThumbnailCountdown()
        panel?.close()
        panel = nil
    }

    func setInteraction(_ interaction: Interaction, _ active: Bool) {
        let changed = active ? interactions.insert(interaction).inserted : interactions.remove(interaction) != nil
        // Resolve the current pointer display once the last interaction ends.
        if changed, !isLocked { place() }
    }

    func setHovering(_ value: Bool) { hovering = value }

    // MARK: Countdown

    /// Ticks only while a countdown exists; an idle stack schedules no work.
    private func runCountdown() {
        guard countdownTask == nil, !countdown.isEmpty else { return }
        countdownTask = Task { [weak self] in
            var last = ContinuousClock.now
            while true {
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                guard let self, !self.countdown.isEmpty else { break }
                let now = ContinuousClock.now
                let elapsed = now - last
                last = now
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let paused = self.hidden || self.hovering || self.isLocked
                let expired = self.countdown.advance(by: seconds) { id in paused || self.pausesAutoClose?(id) == true }
                let mode = self.preferences.thumbnails.autoClose
                for id in expired where mode != .never && self.cards.contains(where: { $0.id == id }) {
                    if let autoClose = self.autoClose { autoClose(id, mode) }
                    else if mode == .dismiss { self.perform?(id, .dismiss) }
                }
            }
            self?.countdownTask = nil
        }
    }

    // MARK: Placement

    private func makePanel() -> ThumbnailPanel {
        let panel = ThumbnailPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.press = { [weak self] active in self?.setInteraction(.press, active) }
        panel.contentView = NSHostingView(rootView: ThumbnailStack(coordinator: self))
        panel.keyChanged = { [weak self] isKey in self?.setInteraction(.keyboard, isKey) }
        return panel
    }

    /// Pointer following is event-driven: nothing runs while the pointer rests, and the
    /// monitors exist only while the stack is visible. Mouse monitors need no Accessibility access.
    private func startTracking() {
        guard monitors.isEmpty else { return }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) { monitors.append(local) }
        trackingObservers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.place() } })
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.panel?.orderFrontRegardless() } }
    }

    private func stopTracking() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        trackingObservers.forEach(NotificationCenter.default.removeObserver)
        trackingObservers.removeAll()
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        relocation?.cancel()
        relocation = nil
    }

    /// Boundary jitter filter: relocate only if the pointer is still on the new display 100 ms later.
    private func pointerMoved() {
        guard case .followPointer = preferences.thumbnails.display, !isLocked, relocation == nil,
              let screen = Self.screen(containing: NSEvent.mouseLocation), screen.displayID != targetDisplay else { return }
        relocation = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            self?.relocation = nil
            self?.place()
        }
    }

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func resolveScreen() -> NSScreen? {
        let screens = NSScreen.screens
        let current = screens.first { $0.displayID == targetDisplay }
        let main = screens.first { $0.displayID == CGMainDisplayID() } ?? screens.first
        // A locked stack stays where it is; display choice resumes when the interaction ends.
        if isLocked, let current { return current }
        switch preferences.thumbnails.display {
        case .followPointer: return Self.screen(containing: NSEvent.mouseLocation) ?? current ?? main
        case .mainDisplay: return main
        case .display(let uuid, _):
            // A disconnected choice falls back to main; the stored preference restores it on reconnection.
            return screens.first { screen in
                guard let id = screen.displayID, let value = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return false }
                return CFUUIDCreateString(nil, value) as String == uuid
            } ?? main
        }
    }

    private func place() {
        guard let panel, let screen = resolveScreen() else { return }
        targetDisplay = screen.displayID
        // visibleFrame excludes the menu bar, notch area, and Dock; 12 pt edge margin.
        let frame = screen.visibleFrame.insetBy(dx: 12, dy: 12)
        let width = min(self.width, frame.width)
        let heights = cards.map { ThumbnailLayout.cardHeight(width: width, imageSize: $0.image.size, hasStatus: $0.status != nil) }
        visibleCount = ThumbnailLayout.visibleCount(heights: heights, available: frame.height, hasUndo: undoAvailable)
        if visibleCount == cards.count { showingOverflow = false }
        var rows = heights.prefix(visibleCount).map { $0 }
        if undoAvailable { rows.append(ThumbnailLayout.undoRowHeight) }
        if visibleCount < cards.count { rows.append(ThumbnailLayout.overflowRowHeight) }
        let height = min(frame.height, max(1, rows.reduce(0, +) + ThumbnailLayout.gap * CGFloat(max(0, rows.count - 1))))
        let y: CGFloat = switch placement {
        case .topLeft, .topRight: frame.maxY - height
        case .leftCenter, .rightCenter: frame.midY - height / 2
        case .bottomLeft, .bottomRight: frame.minY
        }
        let x = ThumbnailLayout.anchoredLeft(placement) ? frame.minX : frame.maxX - width
        panel.setFrame(CGRect(x: x, y: y, width: width, height: height), display: true)
    }
}

final class ThumbnailPanel: NSPanel {
    var press: ((Bool) -> Void)?
    var keyChanged: ((Bool) -> Void)?
    override func becomeKey() { super.becomeKey(); keyChanged?(true) }
    override func resignKey() { super.resignKey(); keyChanged?(false) }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown: press?(true)
        case .leftMouseUp, .rightMouseUp: press?(false)
        default: break
        }
        super.sendEvent(event)
        // Context menus and drag sessions track the button themselves and swallow its release.
        if [.leftMouseDown, .rightMouseDown].contains(event.type), NSEvent.pressedMouseButtons == 0 { press?(false) }
    }
}

/// Top-to-bottom rows: the newest card and Undo sit nearest the anchor; "N more" is farthest.
private struct ThumbnailStack: View {
    @Bindable var coordinator: ThumbnailCoordinator

    var body: some View {
        let visible = Array(coordinator.cards.prefix(coordinator.visibleCount))
        let bottom = [.bottomLeft, .bottomRight].contains(coordinator.placement)
        VStack(spacing: ThumbnailLayout.gap) {
            if bottom { overflow }
            if !bottom { undo }
            ForEach(ThumbnailLayout.displayOrder(visible, placement: coordinator.placement)) { card in
                ThumbnailCard(card: card, coordinator: coordinator)
            }
            if bottom { undo }
            if !bottom { overflow }
        }
        .frame(width: coordinator.width)
        .onHover { coordinator.setHovering($0) }
    }

    @ViewBuilder private var undo: some View {
        if coordinator.undoAvailable {
            Button("Undo Dismiss") { coordinator.undo?() }
                .keyboardShortcut("z")
                .frame(height: ThumbnailLayout.undoRowHeight)
        }
    }

    @ViewBuilder private var overflow: some View {
        let hiddenCards = Array(coordinator.cards.dropFirst(coordinator.visibleCount))
        if !hiddenCards.isEmpty {
            Button("\(hiddenCards.count) more") { coordinator.showingOverflow.toggle() }
                .frame(height: ThumbnailLayout.overflowRowHeight)
                .accessibilityLabel("Show \(hiddenCards.count) more captures")
                .popover(isPresented: $coordinator.showingOverflow) {
                    ScrollView {
                        VStack(spacing: ThumbnailLayout.gap) {
                            ForEach(hiddenCards) { ThumbnailCard(card: $0, coordinator: coordinator) }
                        }.padding(ThumbnailLayout.gap)
                    }
                    .frame(width: coordinator.width + 2 * ThumbnailLayout.gap, height: 420)
                }
        }
    }
}

private struct ThumbnailCard: View {
    let card: ThumbnailCoordinator.Card
    let coordinator: ThumbnailCoordinator

    var body: some View {
        VStack(spacing: 0) {
            ThumbnailImage(card: card, coordinator: coordinator)
                .frame(height: ThumbnailLayout.previewHeight(width: coordinator.width, imageSize: card.image.size))
            HStack(spacing: 12) {
                Button { coordinator.perform?(card.id, .dismiss) } label: { Image(systemName: "xmark") }
                    .help("Dismiss").accessibilityLabel("Dismiss capture")
                Spacer(minLength: 0)
                Button { coordinator.perform?(card.id, .copy) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy Image").accessibilityLabel("Copy image")
                Button {
                    coordinator.perform?(card.id, NSEvent.modifierFlags.contains(.option) ? .saveAs : .save)
                } label: { Image(systemName: "square.and.arrow.down") }
                    .help("Save to Folder (Option: Save As…)").accessibilityLabel("Save to folder")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .frame(height: ThumbnailLayout.actionRowHeight)
            if let status = card.status {
                Text(status).font(.caption).lineLimit(1).frame(height: ThumbnailLayout.statusHeight)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ThumbnailImage: NSViewRepresentable {
    let card: ThumbnailCoordinator.Card
    let coordinator: ThumbnailCoordinator
    func makeNSView(context: Context) -> ThumbnailImageView { ThumbnailImageView() }
    func updateNSView(_ view: ThumbnailImageView, context: Context) {
        view.image = card.image
        view.captureID = card.id
        view.coordinator = coordinator
        if coordinator.focusRequest == card.id, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }
}

private final class ThumbnailImageView: NSView, NSDraggingSource, NSMenuDelegate {
    var image: NSImage? { didSet { needsDisplay = true } }
    var captureID: UUID?
    weak var coordinator: ThumbnailCoordinator?
    private var press: CGPoint?
    private var dragging = false
    private var swipe = ThumbnailSwipe()

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { bounds.fill() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open capture in editor")
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }

    override func mouseDown(with event: NSEvent) { press = event.locationInWindow; dragging = false }
    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let press, hypot(event.locationInWindow.x - press.x, event.locationInWindow.y - press.y) > 5,
              let captureID, let provider = coordinator?.makePromise?(captureID) else { return }
        dragging = true
        coordinator?.setInteraction(.drag, true)
        let item = NSDraggingItem(pasteboardWriter: provider)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    override func mouseUp(with event: NSEvent) {
        if !dragging, press != nil, let captureID { coordinator?.perform?(captureID, .open) }
        press = nil
    }
    override func accessibilityPerformPress() -> Bool {
        guard let captureID else { return false }
        coordinator?.perform?(captureID, .open)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let captureID, let coordinator else { return super.keyDown(with: event) }
        if let shortcut = Shortcut(event: event), let action = coordinator.cardAction(for: shortcut) {
            coordinator.perform?(captureID, action)
            return
        }
        let plain = event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        switch (event.keyCode, plain) {
        case (36, true), (49, true), (76, true): coordinator.perform?(captureID, .open)
        case (51, true), (117, true): coordinator.perform?(captureID, .dismiss)
        case (53, true): window?.makeFirstResponder(nil)
        default: super.keyDown(with: event)
        }
    }

    /// Command-key equivalents reach a focused card before the main menu handles them.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let captureID, let coordinator, let shortcut = Shortcut(event: event),
              let action = coordinator.cardAction(for: shortcut) else { return super.performKeyEquivalent(with: event) }
        coordinator.perform?(captureID, action)
        return true
    }

    /// Accumulates one trackpad gesture; momentum and mouse wheels never dismiss.
    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty, let captureID, let coordinator else {
            return super.scrollWheel(with: event)
        }
        if event.phase.contains(.began) { swipe.reset() }
        // Physical finger movement: natural scrolling already reports it, classic scrolling inverts it.
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        swipe.add(dx: direction * event.scrollingDeltaX, dy: direction * event.scrollingDeltaY)
        if event.phase.contains(.ended) {
            if swipe.dismisses(anchoredLeft: ThumbnailLayout.anchoredLeft(coordinator.placement)) {
                coordinator.perform?(captureID, .dismiss)
            }
            swipe.reset()
        } else if event.phase.contains(.cancelled) { swipe.reset() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.delegate = self
        let items: [(String, ThumbnailCoordinator.Action)] = [("Open Editor", .open), ("Copy Image", .copy),
            ("Save to Folder", .save), ("Save As…", .saveAs), ("Dismiss", .dismiss)]
        for (tag, (title, action)) in items.enumerated() {
            let item = NSMenuItem(title: title, action: #selector(menuAction(_:)), keyEquivalent: "")
            if let shortcut = coordinator?.shortcut(for: action), let key = shortcut.keyboardShortcut {
                item.keyEquivalent = String(key.key.character)
                item.keyEquivalentModifierMask = shortcut.modifierFlags
            }
            item.target = self
            item.tag = tag
            menu.addItem(item)
            if tag == 0 || tag == 3 { menu.addItem(.separator()) }
        }
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { coordinator?.setInteraction(.menu, true) }
    func menuDidClose(_ menu: NSMenu) { coordinator?.setInteraction(.menu, false) }
    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let captureID else { return }
        coordinator?.perform?(captureID, [.open, .copy, .save, .saveAs, .dismiss][sender.tag])
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let keepCard = NSEvent.modifierFlags.contains(.option)
        coordinator?.setInteraction(.drag, false)
        coordinator?.setInteraction(.press, false)
        if let captureID { coordinator?.dragFinished?(captureID, operation.contains(.copy), keepCard) }
        dragging = false
        press = nil
    }
}

private extension Shortcut {
    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.option) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        if modifiers.contains(.command) { flags.insert(.command) }
        return flags
    }
}
