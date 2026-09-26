import AppKit
import Observation
import SwiftUI

/// Owns the non-activating thumbnail panel: newest-first cards, display following,
/// interaction locks, overflow, swipe dismissal, and auto-close countdowns.
/// Commands go through `perform`; the app owns documents, outputs, and dismissal.
@MainActor @Observable
final class ThumbnailCoordinator {
    struct Card: Identifiable {
        let id: UUID
        var image: NSImage
        var status: String?
        var copied = false
        var saved = false
    }
    enum Feedback {
        case copied, saved, saving, waitingToSave, message(String)
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
    /// Set while a capture takes its pixels, when the user hides thumbnails during capture.
    var hiddenForCapture = false { didSet { if hiddenForCapture != oldValue { refresh() } } }
    var perform: ((UUID, Action) -> Void)?
    /// Supplies current command bindings; nil falls back to the registry defaults.
    var commands: CommandRegistry?
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

    init(preferences: AppPreferences) {
        self.preferences = preferences
        // Menus open at the pop-up menu level, far below the stack. While any Shotty menu tracks,
        // such as a card's context menu or the editor's zoom menu, the stack drops beneath it.
        for (name, level) in [(NSMenu.didBeginTrackingNotification, NSWindow.Level.floating),
                              (NSMenu.didEndTrackingNotification, Chrome.floatingLevel)] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel?.level = level }
            })
        }
    }
    private var menuObservers: [NSObjectProtocol] = []

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

    func refresh(animated: Bool = false) {
        guard !hidden, !hiddenForCapture, !cards.isEmpty else {
            stopTracking()
            showingOverflow = false
            panel?.orderOut(nil)
            return
        }
        if panel == nil { panel = makePanel() }
        startTracking()
        place(animated: animated)
        panel?.orderFrontRegardless()
    }

    /// Adds a card nearest the anchor without taking keyboard focus.
    func add(_ id: UUID, image: CGImage) {
        cards.removeAll { $0.id == id }
        cards.insert(Card(id: id, image: NSImage(cgImage: image, size: .zero)), at: 0)
        let settings = preferences.thumbnails
        if settings.autoClose != .never { countdown.start(id, seconds: TimeInterval(settings.autoCloseDelaySeconds)) }
        runCountdown()
        refresh(animated: true)
    }

    func update(_ id: UUID, image: CGImage? = nil, feedback: Feedback? = nil) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        if let image { cards[index].image = NSImage(cgImage: image, size: .zero) }
        switch feedback {
        case .copied: cards[index].copied = true; cards[index].status = nil
        case .saved: cards[index].saved = true; cards[index].status = nil
        case .saving: cards[index].status = "Saving…"
        case .waitingToSave: cards[index].status = "Waiting to save…"
        case .message(let message): cards[index].status = message
        case nil: cards[index].status = nil
        }
        place()
    }

    func remove(_ id: UUID) {
        countdown.cancel(id)
        cards.removeAll { $0.id == id }
        if focusRequest == id { focusRequest = nil }
        refresh(animated: true)
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
                let paused = self.hidden || self.hiddenForCapture || self.hovering || self.isLocked
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
        panel.level = Chrome.floatingLevel
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

    private func place(animated: Bool = false) {
        guard let panel, let screen = resolveScreen() else { return }
        targetDisplay = screen.displayID
        // visibleFrame excludes the menu bar, notch area, and Dock. The side and bottom insets match
        // where CleanShot starts its stack (40 pt in, 100 pt up); the top keeps a 12 pt margin.
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.minX + 40, y: visible.minY + 100, width: visible.width - 80, height: visible.height - 112)
        let width = min(self.width, frame.width)
        let heights = Array(repeating: ThumbnailLayout.previewHeight(width: width), count: cards.count)
        visibleCount = ThumbnailLayout.visibleCount(heights: heights, available: frame.height)
        if visibleCount == cards.count { showingOverflow = false }
        var rows = heights.prefix(visibleCount).map { $0 }
        if visibleCount < cards.count { rows.append(ThumbnailLayout.overflowRowHeight) }
        let height = min(frame.height, max(1, rows.reduce(0, +) + ThumbnailLayout.gap * CGFloat(max(0, rows.count - 1))))
        let y: CGFloat = switch placement {
        case .topLeft, .topRight: frame.maxY - height
        case .leftCenter, .rightCenter: frame.midY - height / 2
        case .bottomLeft, .bottomRight: frame.minY
        }
        let x = ThumbnailLayout.anchoredLeft(placement) ? frame.minX : frame.maxX - width
        let destination = CGRect(x: x, y: y, width: width, height: height)
        if animated, panel.isVisible, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Chrome.moveDuration
                panel.animator().setFrame(destination, display: true)
            }
        } else {
            panel.setFrame(destination, display: true)
        }
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

/// Top-to-bottom rows: the newest card sits nearest the anchor; "N more" is farthest.
private struct ThumbnailStack: View {
    @Bindable var coordinator: ThumbnailCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let visible = Array(coordinator.cards.prefix(coordinator.visibleCount))
        let bottom = [.bottomLeft, .bottomRight].contains(coordinator.placement)
        VStack(spacing: ThumbnailLayout.gap) {
            if bottom { overflow }
            ForEach(ThumbnailLayout.displayOrder(visible, placement: coordinator.placement)) { card in
                ThumbnailCard(card: card, coordinator: coordinator)
            }
            if !bottom { overflow }
        }
        .frame(width: coordinator.width)
        .animation(reduceMotion ? nil : .easeInOut(duration: Chrome.moveDuration), value: coordinator.cards.map(\.id))
        .onHover { coordinator.setHovering($0) }
    }

    @ViewBuilder private var overflow: some View {
        let hiddenCards = Array(coordinator.cards.dropFirst(coordinator.visibleCount))
        if !hiddenCards.isEmpty {
            Button("\(hiddenCards.count) more", systemImage: "square.stack") { coordinator.showingOverflow.toggle() }
                .buttonStyle(.overlayCapsule)
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
