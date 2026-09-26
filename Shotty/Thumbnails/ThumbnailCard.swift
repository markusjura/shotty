import AppKit
import OSLog
import SwiftUI

struct ThumbnailCard: View {
    let card: ThumbnailCoordinator.Card
    let coordinator: ThumbnailCoordinator

    var body: some View {
        ThumbnailImage(card: card, coordinator: coordinator)
            .frame(height: ThumbnailLayout.previewHeight(width: coordinator.width))
            .transition(.opacity)
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
        view.status = card.status
        view.setSuccess(copied: card.copied, saved: card.saved)
        if coordinator.focusRequest == card.id, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
            view.focusRingType = .exterior
        }
    }
}

final class ThumbnailImageView: NSView, NSDraggingSource, NSMenuDelegate {
    var image: NSImage? { didSet { needsDisplay = true } }
    var captureID: UUID?
    weak var coordinator: ThumbnailCoordinator?
    private let logger = Logger(subsystem: "local.markus.Shotty", category: "ThumbnailDrag")
    private var press: CGPoint?
    private var dragging = false
    private var swipe = ThumbnailSwipe()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var controls: [NSButton] = []
    private let hoverMaterial = ThumbnailHoverMaterial()
    private let hoverTint = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var copied = false
    private var saved = false
    private var controlsVisible = false
    var status: String? {
        didSet {
            statusLabel.stringValue = status ?? ""
            statusLabel.toolTip = status
            setAccessibilityHelp(status)
            updateControls()
        }
    }
    private var showsControls: Bool {
        hovered || (window?.isKeyWindow == true && (window?.firstResponder as? NSView)?.isDescendant(of: self) == true)
    }
    private let cornerRadius: CGFloat = 20

    // Accept a drag on the first interaction without requiring an activation click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func becomeFirstResponder() -> Bool {
        focusRingType = NSApp.currentEvent?.type == .keyDown ? .exterior : .none
        refreshFocusControls()
        return true
    }
    override func resignFirstResponder() -> Bool { refreshFocusControls(); return true }

    override var acceptsFirstResponder: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).fill() }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture thumbnail")
        hoverMaterial.material = .hudWindow
        hoverMaterial.blendingMode = .withinWindow
        hoverMaterial.state = .active
        hoverMaterial.appearance = NSAppearance(named: .darkAqua)
        hoverMaterial.wantsLayer = true
        hoverMaterial.layer?.cornerRadius = cornerRadius
        hoverMaterial.layer?.masksToBounds = true
        addSubview(hoverMaterial)
        hoverTint.wantsLayer = true
        hoverTint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        hoverTint.layer?.cornerRadius = cornerRadius - 1
        addSubview(hoverTint)
        toolTip = "Click to edit. Drag to Finder or another app. Hold Option when dropping to keep the thumbnail."
        for (title, symbol, action) in [("Dismiss capture", "xmark", ThumbnailCoordinator.Action.dismiss),
                                         ("Open editor", "pencil", .open), ("Copy", "", .copy), ("Save", "", .save)] {
            let button = ThumbnailActionButton(title: symbol.isEmpty ? title : "", target: self, action: #selector(activateControl(_:)))
            button.tag = controls.count
            button.actionValue = action
            button.image = symbol.isEmpty ? nil : NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            button.imagePosition = symbol.isEmpty ? .noImage : .imageOnly
            button.font = .systemFont(ofSize: 13, weight: .semibold)
            button.isBordered = false
            button.wantsLayer = true
            button.setAccessibilityLabel(title)
            button.toolTip = action == .save ? "Save to Folder (Option: Save As…)" : title
            addSubview(button)
            controls.append(button)
        }
        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .white
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        addSubview(statusLabel)
        hoverMaterial.isHidden = true
        hoverMaterial.alphaValue = 0
        hoverTint.isHidden = true
        hoverTint.alphaValue = 0
        controls.forEach { $0.isHidden = true; $0.alphaValue = 0 }
        updateControls()
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === statusLabel || hit === hoverTint ? self : hit
    }

    override func layout() {
        super.layout()
        hoverMaterial.frame = bounds.insetBy(dx: 1, dy: 1)
        hoverTint.frame = hoverMaterial.frame
        statusLabel.frame = CGRect(x: 38, y: bounds.height - 26, width: bounds.width - 48, height: 16)
        let inset: CGFloat = 7, diameter: CGFloat = 24
        controls[0].frame = CGRect(x: inset, y: bounds.height - inset - diameter, width: diameter, height: diameter)
        controls[1].frame = CGRect(x: inset, y: inset, width: diameter, height: diameter)
        controls[2].frame = CGRect(x: bounds.midX - 29, y: bounds.midY + 5, width: 58, height: 30)
        controls[3].frame = CGRect(x: bounds.midX - 29, y: bounds.midY - 35, width: 58, height: 30)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowFocusChanged), name: name, object: window)
            }
        }
        updateControls()
    }

    @objc private func windowFocusChanged() { updateControls() }

    /// First-responder callbacks run before NSWindow assigns the new responder.
    /// Defer the refresh so tabbing to a child button keeps the overlay visible.
    fileprivate func refreshFocusControls() {
        DispatchQueue.main.async { [weak self] in self?.updateControls() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(rect: .zero, options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; updateControls() }
    override func mouseExited(with event: NSEvent) { hovered = false; updateControls() }

    private func updateControls() {
        let visible = showsControls
        statusLabel.isHidden = !visible || status == nil
        needsDisplay = true
        guard controlsVisible != visible else { return }
        controlsVisible = visible
        let views: [NSView] = [hoverMaterial, hoverTint] + controls
        for view in views { view.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.14
            for view in views { view.animator().alphaValue = visible ? 1 : 0 }
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, !self.controlsVisible else { return }
                self.hoverMaterial.isHidden = true
                self.hoverTint.isHidden = true
                self.controls.forEach { $0.isHidden = true }
            }
        }
    }

    /// Success belongs to the action that completed, and stays until this card is removed.
    /// Changing one button never moves the card or adds a status strip over the screenshot.
    func setSuccess(copied: Bool, saved: Bool) {
        for (index, success, previous, title) in [(2, copied, self.copied, "Copy"), (3, saved, self.saved, "Save")] where success != previous {
            let button = controls[index]
            if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                let transition = CATransition()
                transition.type = .fade
                transition.duration = 0.18
                button.layer?.add(transition, forKey: "success")
            }
            button.image = success ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil) : nil
            button.title = success ? "" : title
            button.setAccessibilityLabel(success ? (index == 2 ? "Copied. Copy again" : "Saved. Save again") : title)
            button.needsDisplay = true
        }
        self.copied = copied
        self.saved = saved
    }

    @objc private func activateControl(_ sender: ThumbnailActionButton) {
        guard let captureID else { return }
        var action = sender.actionValue
        if action == .save, NSEvent.modifierFlags.contains(.option) { action = .saveAs }
        coordinator?.perform?(captureID, action)
    }

    override func draw(_ dirtyRect: NSRect) {
        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            let rect = ThumbnailLayout.imageRect(imageSize: image.size, bounds: bounds)
            image.draw(in: rect)
        }
        if let status, !showsControls {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                           .foregroundColor: NSColor.white]
            let rect = CGRect(x: 10, y: 6, width: bounds.width - 20, height: 16)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -2), xRadius: 6, yRadius: 6).fill()
            (status as NSString).draw(with: rect, options: [.truncatesLastVisibleLine], attributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        NSColor(white: 0.6, alpha: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.6).setStroke()
        outline.lineWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        focusRingType = .none
        press = event.locationInWindow
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let press, hypot(event.locationInWindow.x - press.x, event.locationInWindow.y - press.y) > 5,
              let captureID, let provider = coordinator?.makePromise?(captureID) else { return }
        logger.info("Starting thumbnail file-promise drag")
        dragging = true
        coordinator?.setInteraction(.drag, true)
        let item = NSDraggingItem(pasteboardWriter: provider)
        // Snapshot the visible crop so the drag starts under the pointer without jumping
        // to the full source aspect ratio. The promise still exports the full image.
        let preview = NSImage(size: bounds.size, flipped: false) { [image, bounds] _ in
            NSBezierPath(roundedRect: bounds, xRadius: 20, yRadius: 20).addClip()
            if let image { image.draw(in: ThumbnailLayout.imageRect(imageSize: image.size, bounds: bounds)) }
            return true
        }
        item.setDraggingFrame(bounds, contents: preview)
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
        logger.info("Thumbnail drag ended accepted=\(operation.contains(.copy)) keep=\(keepCard)")
        hovered = false
        updateControls()
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

/// Native buttons keep AppKit hit testing and accessibility while matching the compact
/// light pills of the hover overlay. The surrounding image remains the drag source.
private final class ThumbnailActionButton: NSButton {
    var actionValue = ThumbnailCoordinator.Action.open
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        (superview as? ThumbnailImageView)?.refreshFocusControls()
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        (superview as? ThumbnailImageView)?.refreshFocusControls()
        return result
    }
    override func draw(_ dirtyRect: NSRect) {
        let color = isHighlighted ? NSColor(white: 0.65, alpha: 1) : NSColor(white: 0.86, alpha: 1)
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        if let image {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                .applying(.init(paletteColors: [.black]))
            image.withSymbolConfiguration(config)?.draw(in: CGRect(x: bounds.midX - 7, y: bounds.midY - 7, width: 14, height: 14))
        } else {
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

/// Material is visual only; presses between the controls must reach the image's drag source.
private final class ThumbnailHoverMaterial: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
