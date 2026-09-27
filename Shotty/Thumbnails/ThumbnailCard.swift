import AppKit
import CoreImage
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
        view.setSuccess(card.success)
        if coordinator.focusRequest == card.id, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
            view.focusRingType = .exterior
        }
    }
}

final class ThumbnailImageView: NSView, NSDraggingSource, NSMenuDelegate {
    var image: NSImage? {
        didSet {
            guard image !== oldValue else { return }
            backdrop = controlsVisible ? makeBackdrop() : nil
            needsDisplay = true
        }
    }
    var captureID: UUID?
    weak var coordinator: ThumbnailCoordinator?
    private let logger = Logger(subsystem: "local.markus.Shotty", category: "ThumbnailDrag")
    private var press: CGPoint?
    private var dragging = false
    private var swipe = ThumbnailSwipe()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var controls: [NSButton] = []
    /// The blurred, darkened capture drawn behind the hover controls.
    private var backdrop: CGImage?
    private let statusLabel = NSTextField(labelWithString: "")
    private var success: ThumbnailCoordinator.Action?
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
    private let cornerRadius = Chrome.cardRadius

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
    /// The panel ends at the card edge, so an exterior ring must sit inside it to stay whole.
    private var focusRingRect: NSRect { bounds.insetBy(dx: 3, dy: 3) }
    override var focusRingMaskBounds: NSRect { focusRingRect }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingRect, xRadius: cornerRadius - 3, yRadius: cornerRadius - 3).fill()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        focusRingType = .none
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Capture thumbnail")
        toolTip = "Click to edit. Drag to Finder or another app. Hold Option when dropping to keep the thumbnail."
        for (title, symbol, action) in [("Dismiss capture", "xmark", ThumbnailCoordinator.Action.dismiss),
                                         ("Open editor", "pencil", .open), ("Copy", "", .copy), ("Save", "", .save)] {
            let button = ThumbnailActionButton(title: symbol.isEmpty ? title : "", target: self, action: #selector(activateControl(_:)))
            button.tag = controls.count
            button.actionValue = action
            button.image = symbol.isEmpty ? nil : ThumbnailGlyph.image(symbol)
            button.imagePosition = symbol.isEmpty ? .noImage : .imageOnly
            button.font = Chrome.cardPillFont
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
        controls.forEach { $0.isHidden = true }
        updateControls()
    }
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === statusLabel ? self : hit
    }

    override func layout() {
        super.layout()
        statusLabel.frame = CGRect(x: 34, y: bounds.height - 25, width: bounds.width - 68, height: 16)
        // Proportions follow CleanShot's overlay: small corner buttons, two compact centered pills.
        let inset: CGFloat = 6, diameter = Chrome.iconButtonDiameter
        let pill = Chrome.cardPillSize, gap: CGFloat = 10
        controls[0].frame = CGRect(x: inset, y: bounds.height - inset - diameter, width: diameter, height: diameter)
        controls[1].frame = CGRect(x: bounds.width - inset - diameter, y: bounds.height - inset - diameter, width: diameter, height: diameter)
        controls[2].frame = CGRect(x: bounds.midX - pill.width / 2, y: bounds.midY + gap / 2, width: pill.width, height: pill.height)
        controls[3].frame = CGRect(x: bounds.midX - pill.width / 2, y: bounds.midY - gap / 2 - pill.height, width: pill.width, height: pill.height)
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
        if visible, backdrop == nil { backdrop = makeBackdrop() }
        controls.forEach { $0.isHidden = !visible }
        // One crossfade covers the backdrop drawn by this view and the controls above it.
        Chrome.crossfade(layer)
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// Blurs and darkens the capture at card resolution, like CleanShot's hover background.
    /// Built once per image on first reveal, so cards that are never hovered cost nothing.
    private func makeBackdrop() -> CGImage? {
        guard let image, let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0 else { return nil }
        let backing = window?.backingScaleFactor ?? 2
        let pixels = CGSize(width: bounds.width * backing, height: bounds.height * backing)
        let scale = min(1, max(pixels.width / CGFloat(source.width), pixels.height / CGFloat(source.height)))
        let scaled = CIImage(cgImage: source).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        // Whole pixels only. Core Image rounds the scaled extent up, and the partly covered edge column
        // it adds would smear transparency into the blur.
        let extent = CGRect(x: 0, y: 0, width: (CGFloat(source.width) * scale).rounded(.down),
                            height: (CGFloat(source.height) * scale).rounded(.down))
        // About 7 pt of blur hides detail but keeps light and dark areas; Core Image works in linear
        // light, where 0.1 lowers white to roughly 35% on screen, faint enough for the controls to stand out.
        let blurred = scaled.cropped(to: extent).clampedToExtent().applyingGaussianBlur(sigma: 7 * backing).cropped(to: extent)
        let darkened = blurred.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.1, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.1, w: 0)])
        return Self.ciContext.createCGImage(darkened, from: extent)
    }

    /// The pill of the copy or save that succeeded last shows a checkmark while the coordinator keeps
    /// it current; the other pill keeps its label. Changing a pill never moves the card or adds a status strip.
    func setSuccess(_ success: ThumbnailCoordinator.Action?) {
        for (index, action, title) in [(2, ThumbnailCoordinator.Action.copy, "Copy"), (3, .save, "Save")]
        where (action == success) != (action == self.success) {
            let button = controls[index], done = action == success
            Chrome.crossfade(button.layer)
            button.image = done ? ThumbnailGlyph.image("checkmark") : nil
            button.title = done ? "" : title
            button.setAccessibilityLabel(done ? (index == 2 ? "Copied. Copy again" : "Saved. Save again") : title)
            button.needsDisplay = true
        }
        self.success = success
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
        // The capture ends where the outline begins, so the translucent outline never shows its pixels.
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: cornerRadius - 1, yRadius: cornerRadius - 1).addClip()
        if let image, image.size.width > 0, image.size.height > 0 {
            let rect = ThumbnailLayout.imageRect(imageSize: image.size, bounds: bounds)
            if controlsVisible, let backdrop { NSGraphicsContext.current?.cgContext.draw(backdrop, in: rect) } else { image.draw(in: rect) }
        }
        if let status, !controlsVisible {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium),
                                                           .foregroundColor: NSColor.white]
            let rect = CGRect(x: 10, y: 6, width: bounds.width - 20, height: 16)
            Chrome.readoutFill.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -2), xRadius: 6, yRadius: 6).fill()
            (status as NSString).draw(with: rect, options: [.truncatesLastVisibleLine], attributes: attributes)
        }
        NSGraphicsContext.restoreGraphicsState()
        Chrome.cardOutline.setStroke()
        outline.lineWidth = Chrome.hairlineWidth
        outline.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        focusRingType = .none
        press = event.locationInWindow
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        if let press { _ = drag(from: press, with: event) }
    }

    /// Starts dragging the capture once the pointer is 5 pt from where it was pressed. The hover
    /// buttons call this too, so the whole card is a drag source. Returns true once dragging.
    fileprivate func drag(from press: CGPoint, with event: NSEvent) -> Bool {
        guard !dragging else { return true }
        guard hypot(event.locationInWindow.x - press.x, event.locationInWindow.y - press.y) > 5,
              let captureID, let url = coordinator?.dragFile?(captureID) else { return false }
        logger.info("Starting thumbnail file drag")
        dragging = true
        coordinator?.setInteraction(.drag, true)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        // Snapshot the visible crop so the drag starts under the pointer without jumping
        // to the full source aspect ratio. The file still holds the full image.
        let preview = NSImage(size: bounds.size, flipped: false) { [image, bounds] _ in
            NSBezierPath(roundedRect: bounds, xRadius: Chrome.cardRadius, yRadius: Chrome.cardRadius).addClip()
            if let image { image.draw(in: ThumbnailLayout.imageRect(imageSize: image.size, bounds: bounds)) }
            return true
        }
        item.setDraggingFrame(bounds, contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
        return true
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
                item.keyEquivalentModifierMask = shortcut.modifiers.flags
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
        if let captureID, operation.contains(.copy) { coordinator?.dropped?(captureID, keepCard) }
        dragging = false
        press = nil
    }
}

/// Native buttons keep AppKit hit testing and accessibility while matching the compact
/// light pills of the hover overlay. A press that moves drags the capture, as it does anywhere
/// else on the card; one that doesn't clicks, so the buttons track the mouse themselves.
private final class ThumbnailActionButton: NSButton {
    var actionValue = ThumbnailCoordinator.Action.open
    private var press: CGPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        press = event.locationInWindow
        isHighlighted = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard let press else { return }
        if (superview as? ThumbnailImageView)?.drag(from: press, with: event) == true {
            self.press = nil
            isHighlighted = false
        } else {
            isHighlighted = bounds.contains(convert(event.locationInWindow, from: nil))
        }
    }
    override func mouseUp(with event: NSEvent) {
        if press != nil, bounds.contains(convert(event.locationInWindow, from: nil)) { sendAction(action, to: target) }
        press = nil
        isHighlighted = false
    }
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
        (isHighlighted ? Chrome.controlFillPressed : Chrome.controlFill).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        if let image {
            // Glyphs keep one proportion to their button, so the pill checkmark matches the corner icons.
            let box = bounds.height * ThumbnailGlyph.heightShare, scale = box / max(image.size.width, image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        } else {
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? Chrome.cardPillFont, .foregroundColor: Chrome.controlLabel]
            let size = (title as NSString).size(withAttributes: attributes)
            (title as NSString).draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
        }
    }
}

/// Dark glyphs sized to their button, like CleanShot's overlay icons. Corner icons are heavy; the pill
/// checkmark is one weight lighter, like the Copy and Save labels it replaces. SF Symbols has no solid
/// pencil, so Edit uses a small drawn one with the same weight as the xmark.
@MainActor
private enum ThumbnailGlyph {
    /// Glyph size per point of button height: 8.5 pt in the 22 pt corner buttons, 10.4 pt in the 27 pt pills.
    static let heightShare: CGFloat = 8.5 / 22

    static func image(_ name: String) -> NSImage? {
        if name == "pencil" { return pencil }
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: name == "checkmark" ? .bold : .heavy)
            .applying(.init(paletteColors: [Chrome.controlLabel]))
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }

    /// A solid pencil pointing down-left: tip, body, and a separate eraser cap.
    private static let pencil = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.rotate(byDegrees: 45)
        transform.concat()
        Chrome.controlLabel.setFill()
        let half: CGFloat = 1.6, length: CGFloat = 13.2, start = -length / 2
        let tip = NSBezierPath()
        tip.move(to: CGPoint(x: start, y: 0))
        tip.line(to: CGPoint(x: start + 3, y: half))
        tip.line(to: CGPoint(x: start + 3, y: -half))
        tip.close()
        tip.fill()
        NSBezierPath(rect: CGRect(x: start + 3.5, y: -half, width: 6.4, height: 2 * half)).fill()
        NSBezierPath(roundedRect: CGRect(x: start + 10.6, y: -half, width: 2.6, height: 2 * half), xRadius: 0.8, yRadius: 0.8).fill()
        return true
    }
}
