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
            // A card fades in and out with a slight scale; the cards around it stay put.
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }
}

private struct ThumbnailImage: NSViewRepresentable {
    let card: ThumbnailCoordinator.Card
    let coordinator: ThumbnailCoordinator
    func makeNSView(context: Context) -> ThumbnailImageView { ThumbnailImageView() }
    func updateNSView(_ view: ThumbnailImageView, context: Context) {
        view.image = card.image
        view.captureID = card.id
        view.clip = card.clip
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
            backdrop = nil
            needsDisplay = true
        }
    }
    var captureID: UUID?
    /// A clip's format, length, and size for the stripe along the bottom; nil for a screenshot.
    var clip: ThumbnailCoordinator.ClipSummary? {
        didSet {
            guard clip != oldValue else { return }
            if (clip == nil) != (oldValue == nil) { describe() }
            // A size that arrives once the clip is rendered, or a new length after an edit, fades in.
            if oldValue != nil { Chrome.crossfade(layer) }
            setAccessibilityValue(clip.map(ClipStripe.spokenSummary))
            needsDisplay = true
        }
    }
    weak var coordinator: ThumbnailCoordinator?
    private let logger = Logger(subsystem: "local.markus.Shotty", category: "ThumbnailDrag")
    private var press: CGPoint?
    private var dragging = false
    private var swipe = ThumbnailSwipe()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var controls: [NSButton] = []
    /// The blurred capture behind the hover controls and in the bottom stripe. Built on first use per
    /// image, so a screenshot card that is never hovered costs nothing.
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
        toolTip = "Click to edit. Drag to Finder or another app. Hold Option when dropping to keep the thumbnail."
        for (title, symbol, action) in [("Dismiss", "xmark", ThumbnailCoordinator.Action.dismiss),
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
        describe()
        updateControls()
    }
    required init?(coder: NSCoder) { nil }

    /// Names the card and its Dismiss button after what it holds, a capture or a clip.
    private func describe() {
        let noun = clip == nil ? "capture" : "clip"
        setAccessibilityLabel(clip == nil ? "Capture thumbnail" : "Clip thumbnail")
        controls[0].setAccessibilityLabel("Dismiss \(noun)")
        controls[0].toolTip = "Dismiss \(noun)"
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === statusLabel ? self : hit
    }

    override func layout() {
        super.layout()
        statusLabel.frame = CGRect(x: 34, y: bounds.height - 25, width: bounds.width - 68, height: 16)
        // Small corner buttons and two compact centered pills.
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
        controls.forEach { $0.isHidden = !visible }
        // One crossfade covers what this view draws, the backdrop or the stripe, and the controls above it.
        Chrome.crossfade(layer)
    }

    private static let ciContext = CIContext(options: [.cacheIntermediates: false])

    /// The capture blurred at card resolution, made on first use.
    private var blurredImage: CGImage? {
        if backdrop == nil { backdrop = makeBackdrop() }
        return backdrop
    }

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
        // About 7 pt of blur hides detail but keeps the capture's colors and light and dark areas.
        let blurred = scaled.cropped(to: extent).clampedToExtent().applyingGaussianBlur(sigma: 7 * backing).cropped(to: extent)
        return Self.ciContext.createCGImage(blurred, from: extent)
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
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        if let image, image.size.width > 0, image.size.height > 0 {
            let rect = ThumbnailLayout.imageRect(imageSize: image.size, bounds: bounds)
            if controlsVisible, let backdrop = blurredImage {
                NSGraphicsContext.current?.cgContext.draw(backdrop, in: rect)
                Chrome.cardScrim.setFill()
                rect.fill(using: .sourceOver)
            } else {
                image.draw(in: rect)
                if !controlsVisible, status != nil || clip != nil { drawStripe(over: rect) }
            }
        }
        // White status text alone is too faint on the scrimmed backdrop of a bright capture.
        if status != nil, controlsVisible {
            Chrome.readoutFill.setFill()
            NSBezierPath(roundedRect: statusLabel.frame.insetBy(dx: -4, dy: -2), xRadius: 6, yRadius: 6).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        // The edge sits on top of the capture, like a macOS window frame. It is stroked unclipped: the clip's
        // antialiasing would thin a one-pixel line wherever it curves, so the corners would look lighter.
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        let edgeWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? Chrome.hairlineWidth : pixel
        strokeCardRing(inset: 0, width: edgeWidth, color: Chrome.cardEdge)
        strokeCardRing(inset: edgeWidth, width: 1, color: Chrome.cardRim)
    }

    /// The stripe along the bottom while the controls are hidden, as on CleanShot X's recordings: a
    /// status if there is one, else a clip's format, length, and file size. It blurs and tints the
    /// capture beneath it, so its white text reads on any capture.
    private func drawStripe(over imageRect: CGRect) {
        let stripe = CGRect(x: 0, y: 0, width: bounds.width, height: ClipStripe.height)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath.clip(stripe)
        if let backdrop = blurredImage { NSGraphicsContext.current?.cgContext.draw(backdrop, in: imageRect) }
        Chrome.cardStripe.setFill()
        stripe.fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
        let inset = ClipStripe.inset
        if let status {
            ClipStripe.drawLine(status, font: ClipStripe.detailFont, color: .white,
                                in: CGRect(x: inset, y: 0, width: stripe.width - 2 * inset, height: stripe.height))
            return
        }
        guard let clip else { return }
        ClipStripe.drawIcon(for: clip.format, centeredAt: ClipStripe.iconCenter)
        var lengthWidth = stripe.width - inset - ClipStripe.textStart
        if let bytes = clip.byteCount {
            let size = ClipStripe.fileSize(bytes)
            let width = ClipStripe.width(of: size, font: ClipStripe.detailFont)
            ClipStripe.drawLine(size, font: ClipStripe.detailFont, color: ClipStripe.secondary,
                                in: CGRect(x: stripe.width - inset - width, y: 0, width: width, height: stripe.height))
            lengthWidth -= width + 8
        }
        ClipStripe.drawLine(ClipTime.compact(clip.duration), font: ClipStripe.lengthFont, color: .white,
                            in: CGRect(x: ClipStripe.textStart, y: 0, width: lengthWidth, height: stripe.height))
    }

    /// Strokes a band `width` wide whose outer side is `inset` from the card edge. The band's path is
    /// concentric with the card's corners, so lines of different widths keep matching curves.
    private func strokeCardRing(inset: CGFloat, width: CGFloat, color: NSColor) {
        let center = inset + width / 2
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: center, dy: center),
                                xRadius: cornerRadius - center, yRadius: cornerRadius - center)
        path.lineWidth = width
        color.setStroke()
        path.stroke()
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
              let captureID, let writer = coordinator?.dragItem?(captureID) else { return false }
        logger.info("Starting thumbnail file drag")
        dragging = true
        coordinator?.setInteraction(.drag, true)
        let item = NSDraggingItem(pasteboardWriter: writer)
        // Snapshot the visible crop so the drag starts under the pointer without jumping
        // to the full source aspect ratio. The file still holds the full image or clip.
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
        let items: [(String, ThumbnailCoordinator.Action)] = [("Open Editor", .open), (clip == nil ? "Copy Image" : "Copy Clip", .copy),
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

/// Metrics and drawing for a card's bottom stripe, measured from CleanShot X's recording thumbnails:
/// 25 pt tall, an 11 pt length beside a video or GIF mark, and the file size dimmed at the right.
@MainActor
private enum ClipStripe {
    static let height: CGFloat = 25
    static let inset: CGFloat = 8
    /// The mark sits a little above the stripe's middle, level with the digits.
    static let iconCenter = CGPoint(x: 18, y: 13)
    static let textStart: CGFloat = 34
    static let lengthFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let detailFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let secondary = NSColor.white.withAlphaComponent(0.7)

    /// What VoiceOver reads for a clip card, such as "GIF, 14s, 1,7 MB".
    static func spokenSummary(_ clip: ThumbnailCoordinator.ClipSummary) -> String {
        [clip.format.title, ClipTime.compact(clip.duration), clip.byteCount.map(fileSize)].compactMap { $0 }.joined(separator: ", ")
    }

    /// A file size as Finder writes it, such as `9,8 MB` in a German locale.
    static func fileSize(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

    static func width(of text: String, font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
    }

    /// One line of `text` in `rect`, its cap height centered vertically, cut off with an ellipsis
    /// when it is too wide.
    static func drawLine(_ text: String, font: NSFont, color: NSColor, in rect: CGRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        // Center the cap height, not the line box, whose descender space digits and capitals never use.
        let baseline = (rect.midY - font.capHeight / 2).rounded()
        let line = (font.ascender - font.descender).rounded(.up)
        (text as NSString).draw(with: CGRect(x: rect.minX, y: baseline + font.ascender - line, width: rect.width, height: line),
                                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    /// A white video camera for an MP4 clip, or a white GIF tag with its letters cut out for a GIF.
    static func drawIcon(for format: ClipFormat, centeredAt center: CGPoint) {
        switch format {
        case .mp4:
            // At 13 pt the camera's ink is 16 × 11 pt, centered in its image.
            guard let camera else { return }
            camera.draw(in: CGRect(x: center.x - camera.size.width / 2, y: center.y - camera.size.height / 2,
                                   width: camera.size.width, height: camera.size.height))
        case .gif:
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let tag = CGRect(x: center.x - 9.5, y: center.y - 6, width: 19, height: 12)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: tag, xRadius: 3, yRadius: 3).fill()
            context.setBlendMode(.destinationOut)
            let font = NSFont.systemFont(ofSize: 8.5, weight: .heavy)
            let width = Self.width(of: "GIF", font: font)
            let baseline = (tag.midY - font.capHeight / 2).rounded()
            ("GIF" as NSString).draw(at: CGPoint(x: tag.midX - width / 2, y: baseline + font.descender),
                                     withAttributes: [.font: font, .foregroundColor: NSColor.black])
            context.endTransparencyLayer()
        }
    }

    private static let camera = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
            .applying(.init(paletteColors: [.white])))
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

/// Dark glyphs sized to their button. Corner icons are heavy; the pill
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
