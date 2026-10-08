import AVFoundation
import AppKit
import SwiftUI

struct PlayerCanvas: NSViewRepresentable {
    let model: ClipEditorModel
    func makeNSView(context: Context) -> PlayerCanvasView {
        let view = PlayerCanvasView(model: model)
        model.canvas = view
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: PlayerCanvasView, context: Context) { view.refresh() }
}

/// The video, cropped as it will export, on the window's under-page background. In crop mode it
/// shows the whole frame with the crop box on top. Clicking the video plays or pauses it. The
/// view takes keyboard focus for playback keys and the editor's plain-key commands.
final class PlayerCanvasView: NSView {
    private unowned let model: ClipEditorModel
    private let shadowLayer = CALayer()
    private let clipLayer = CALayer()
    private let playerLayer: AVPlayerLayer
    private let overlay: CropOverlayView

    init(model: ClipEditorModel) {
        self.model = model
        playerLayer = AVPlayerLayer(player: model.player)
        overlay = CropOverlayView(model: model)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
        shadowLayer.backgroundColor = NSColor.black.cgColor
        shadowLayer.shadowColor = NSColor.black.cgColor
        shadowLayer.shadowOpacity = 0.35
        shadowLayer.shadowRadius = 3
        shadowLayer.shadowOffset = CGSize(width: 0, height: -1)
        clipLayer.masksToBounds = true
        playerLayer.videoGravity = .resize
        clipLayer.addSublayer(playerLayer)
        layer?.addSublayer(shadowLayer)
        layer?.addSublayer(clipLayer)
        overlay.autoresizingMask = [.width, .height]
        addSubview(overlay)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Clip preview. Space plays or pauses. Arrow keys step through frames.")
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.underPageBackgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        refresh()
    }

    /// The part of the frame on screen: the whole frame while cropping, else the committed crop.
    var visible: CGRect {
        model.isCropping ? CGRect(origin: .zero, size: model.document.record.pixelSize)
                         : model.document.edit.cropRect(in: model.document.record.pixelSize)
    }

    /// Where `visible` is drawn, in view points.
    var display: CGRect {
        PlayerLayout.fit(visible.size, in: bounds, maximumScale: 1 / (window?.backingScaleFactor ?? 2))
    }

    func refresh() {
        let display = display
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shadowLayer.frame = display
        clipLayer.frame = display
        let frame = PlayerLayout.frameRect(source: model.document.record.pixelSize, visible: visible, display: display)
        playerLayer.frame = frame.offsetBy(dx: -display.minX, dy: -display.minY)
        CATransaction.commit()
        overlay.needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.isDisjoint(with: [.command, .control, .option])
        if let shortcut = Shortcut(event: event),
           let command = model.commands.command(matching: shortcut, in: [.editorKey, .editor]) {
            model.execute(command)
            return
        }
        switch (Int(event.keyCode), plain) {
        case (49, true): model.togglePlay()
        case (123, true): model.step(by: event.modifierFlags.contains(.shift) ? -10 : -1)
        case (124, true): model.step(by: event.modifierFlags.contains(.shift) ? 10 : 1)
        case (115, _): model.seek(to: model.trimRange.lowerBound)
        case (119, _): model.seek(to: model.trimRange.upperBound)
        case (53, true) where model.isCropping: model.cancelCrop()
        case (36, true) where model.isCropping, (76, true) where model.isCropping: model.applyCrop()
        default: super.keyDown(with: event)
        }
    }
}

/// Dims everything outside the crop box and draws its handles, as the image editor's crop does.
/// Outside crop mode it only turns clicks into play and pause.
private final class CropOverlayView: NSView {
    private unowned let model: ClipEditorModel
    private var gesture: (edges: SelectionEdges?, start: CGRect, moving: Bool, anchor: CGPoint)?
    private var tracking: NSTrackingArea?

    init(model: ClipEditorModel) {
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var canvas: PlayerCanvasView? { superview as? PlayerCanvasView }
    private var sourceBounds: CGRect { CGRect(origin: .zero, size: model.document.record.pixelSize) }

    override func draw(_ dirtyRect: NSRect) {
        guard model.isCropping, let canvas, let crop = model.cropDraft, let context = NSGraphicsContext.current?.cgContext else { return }
        let display = canvas.display
        let box = PlayerLayout.viewRect(crop, visible: canvas.visible, display: display)
        let path = CGMutablePath(); path.addRect(display); path.addRect(box)
        context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
        context.addPath(path); context.fillPath(using: .evenOdd)
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        context.setLineWidth(1)
        context.stroke(box.insetBy(dx: -0.5, dy: -0.5))
        for (_, point) in EditorGeometry.boxHandles(for: box) {
            let ring = CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)
            context.saveGState()
            context.setShadow(offset: .zero, blur: 3, color: NSColor.black.withAlphaComponent(0.35).cgColor)
            context.setFillColor(NSColor.white.cgColor); context.fillEllipse(in: ring)
            context.restoreGState()
            context.setFillColor(NSColor.controlAccentColor.cgColor); context.fillEllipse(in: ring.insetBy(dx: 2.5, dy: 2.5))
        }
    }

    /// Hit bands of 8 points around the box edges, converted to source pixels.
    private func edges(at point: CGPoint) -> SelectionEdges? {
        guard let canvas, let crop = model.cropDraft else { return nil }
        let tolerance = 8 * canvas.visible.width / max(1, canvas.display.width)
        return SelectionGeometry.edges(near: source(point), of: crop, tolerance: tolerance)
    }

    private func source(_ point: CGPoint) -> CGPoint {
        guard let canvas else { return .zero }
        return PlayerLayout.sourcePoint(point, visible: canvas.visible, display: canvas.display)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(canvas)
        let point = convert(event.locationInWindow, from: nil)
        guard model.isCropping, let crop = model.cropDraft else {
            if canvas?.display.contains(point) == true { model.togglePlay() }
            return
        }
        let edges = edges(at: point)
        let anchor = source(point)
        let moving = edges == nil && crop.contains(anchor)
        // Pressing outside the box draws a new one from there.
        gesture = (edges, moving || edges != nil ? crop : CGRect(origin: anchor, size: .zero), moving, anchor)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let gesture, let canvas else { return }
        let point = source(convert(event.locationInWindow, from: nil))
        let snap = 6 * canvas.visible.width / max(1, canvas.display.width)
        model.cropDraft = CropGeometry.dragged(gesture.start, edges: gesture.edges, moving: gesture.moving, from: gesture.anchor,
                                               to: point, aspect: model.cropAspect, within: sourceBounds, snap: snap)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) { gesture = nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { updateCursor(event) }
    override func mouseMoved(with event: NSEvent) { updateCursor(event) }

    private func updateCursor(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard model.isCropping else { return NSCursor.arrow.set() }
        guard let edges = edges(at: point) else {
            return (model.cropDraft?.contains(source(point)) == true ? NSCursor.openHand : NSCursor.crosshair).set()
        }
        // Source frames grow downward, so the minimum-y edge is the visual top.
        let top = edges.contains(.bottom), bottom = edges.contains(.top)
        let left = edges.contains(.left), right = edges.contains(.right)
        let position: NSCursor.FrameResizePosition = switch (top, bottom, left, right) {
        case (true, _, true, _): .topLeft
        case (true, _, _, true): .topRight
        case (_, true, true, _): .bottomLeft
        case (_, true, _, true): .bottomRight
        case (true, _, _, _): .top
        case (_, true, _, _): .bottom
        case (_, _, true, _): .left
        default: .right
        }
        NSCursor.frameResize(position: position, directions: .all).set()
    }
}
