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
        /// The copy or save that succeeded last. Its pill shows a checkmark: a copy's for a moment,
        /// a save's until the card goes away.
        var success: Action?
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
    /// Exports a card's capture to a file as its drag starts; nil cancels the drag.
    var dragFile: ((UUID) -> URL?)?
    /// Reports an accepted drop; `keepCard` is true when Option was held at the drop.
    var dropped: ((UUID, _ keepCard: Bool) -> Void)?
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
    private var copyResets: [UUID: Task<Void, Never>] = [:]
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

    func refresh() {
        guard !hidden, !hiddenForCapture, !cards.isEmpty else {
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

    /// Adds a card at the top of the stack without taking keyboard focus.
    func add(_ id: UUID, image: CGImage) {
        cards.removeAll { $0.id == id }
        cards.insert(Card(id: id, image: NSImage(cgImage: image, size: .zero)), at: 0)
        let settings = preferences.thumbnails
        if settings.autoClose != .never { countdown.start(id, seconds: TimeInterval(settings.autoCloseDelaySeconds)) }
        runCountdown()
        refresh()
    }

    func update(_ id: UUID, feedback: Feedback) {
        guard let index = cards.firstIndex(where: { $0.id == id }) else { return }
        switch feedback {
        case .copied:
            cards[index].success = .copy; cards[index].status = nil
            showCopyReset(for: id)
        case .saved: cards[index].success = .save; cards[index].status = nil
        case .saving: cards[index].status = "Saving…"
        case .waitingToSave: cards[index].status = "Waiting to save…"
        case .message(let message): cards[index].status = message
        }
        place()
    }

    /// A copy's checkmark confirms it for 1.5 s, then the pill reads Copy again. Another copy
    /// restarts the wait; a save in the meantime keeps its own checkmark.
    private func showCopyReset(for id: UUID) {
        copyResets[id]?.cancel()
        copyResets[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            guard let self else { return }
            copyResets[id] = nil
            if let index = cards.firstIndex(where: { $0.id == id }), cards[index].success == .copy { cards[index].success = nil }
        }
    }

    func remove(_ id: UUID) {
        copyResets.removeValue(forKey: id)?.cancel()
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
        panel?.acceptsKey = true
        panel?.makeKey()
    }

    func close() {
        stopTracking()
        countdownTask?.cancel()
        countdownTask = nil
        copyResets.values.forEach { $0.cancel() }
        copyResets.removeAll()
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
                    self.autoClose?(id, mode)
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
        // Cards animate themselves; AppKit's window animation would zoom the whole stack.
        panel.animationBehavior = .none
        panel.press = { [weak self] active in self?.setInteraction(.press, active) }
        let content = NSHostingView(rootView: ThumbnailStack(coordinator: self))
        // `place` alone sizes the panel; the stack pins itself to the anchored edge inside it.
        content.sizingOptions = []
        panel.contentView = content
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
            return screens.first { $0.displayUUID == uuid } ?? main
        }
    }

    private func place() {
        guard let panel, let screen = resolveScreen() else { return }
        targetDisplay = screen.displayID
        // visibleFrame excludes the menu bar, notch area, and Dock. The stack starts 40 pt in and
        // 100 pt up from the bottom corner; the top keeps a 12 pt margin.
        let visible = screen.visibleFrame
        let frame = CGRect(x: visible.minX + 40, y: visible.minY + 100, width: visible.width - 80, height: visible.height - 112)
        let width = min(self.width, frame.width)
        let heights = Array(repeating: ThumbnailLayout.previewHeight(width: width), count: cards.count)
        visibleCount = ThumbnailLayout.visibleCount(heights: heights, available: frame.height)
        if visibleCount == cards.count { showingOverflow = false }
        let x = ThumbnailLayout.anchoredLeft(placement) ? frame.minX : frame.maxX - width
        // The panel spans the whole column and keeps its size as cards come and go; its transparent
        // part passes clicks through. Resizing it per card would move the cards under it.
        panel.setFrame(CGRect(x: x, y: frame.minY, width: width, height: frame.height), display: true)
    }
}

final class ThumbnailPanel: NSPanel {
    var press: ((Bool) -> Void)?
    var keyChanged: ((Bool) -> Void)?
    /// Set by `focusStack` until the panel resigns key. Otherwise AppKit would pass key status to the
    /// stack when a capture overlay closes, and typing meant for the frontmost app would land here.
    var acceptsKey = false
    override func becomeKey() { super.becomeKey(); keyChanged?(true) }
    override func resignKey() { super.resignKey(); acceptsKey = false; keyChanged?(false) }
    override var canBecomeKey: Bool { acceptsKey }
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

/// Top-to-bottom rows, newest first at every anchor, with "N more" last.
private struct ThumbnailStack: View {
    @Bindable var coordinator: ThumbnailCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: ThumbnailLayout.gap) {
            ForEach(coordinator.cards.prefix(coordinator.visibleCount)) { card in
                ThumbnailCard(card: card, coordinator: coordinator)
            }
            overflow
        }
        .frame(width: coordinator.width)
        .animation(reduceMotion ? nil : .smooth(duration: Chrome.moveDuration), value: coordinator.cards.map(\.id))
        .onHover { coordinator.setHovering($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }

    /// Cards hug the anchored edge of the full-height panel, so existing cards never move when one is added.
    private var alignment: Alignment {
        switch coordinator.placement {
        case .topLeft, .topRight: .top
        case .leftCenter, .rightCenter: .center
        case .bottomLeft, .bottomRight: .bottom
        }
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
