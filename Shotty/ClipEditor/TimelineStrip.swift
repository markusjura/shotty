import AppKit
import SwiftUI

struct TimelineStrip: NSViewRepresentable {
    let model: ClipEditorModel
    func makeNSView(context: Context) -> TimelineStripView { TimelineStripView(model: model) }
    func updateNSView(_ view: TimelineStripView, context: Context) {
        // Observed reads, so SwiftUI redraws the strip when they change.
        _ = (model.currentTime, model.document.edit, model.filmstrip.count, model.trimPreview)
        view.needsDisplay = true
    }
}

/// The whole recording as a filmstrip, with the kept part framed in yellow as in QuickTime and
/// Photos. Dragging a yellow handle trims; pressing anywhere else moves the playhead there.
final class TimelineStripView: NSView {
    private unowned let model: ClipEditorModel
    private enum Drag { case start, end, scrub }
    private var drag: Drag?
    private var tracking: NSTrackingArea?
    static let handleWidth: CGFloat = 12
    private static let trimColor = NSColor.systemYellow

    init(model: ClipEditorModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Timeline")
    }
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The filmstrip between the two handles' outer edges.
    private var strip: CGRect { bounds.insetBy(dx: Self.handleWidth, dy: 4) }
    private var scale: TimelineScale { TimelineScale(duration: model.document.record.duration, width: strip.width) }
    private func x(_ time: Double) -> CGFloat { strip.minX + scale.x(for: time) }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let strip = strip
        let range = model.trimPreview ?? model.trimRange
        context.saveGState()
        context.addPath(CGPath(roundedRect: strip, cornerWidth: 5, cornerHeight: 5, transform: nil))
        context.clip()
        NSColor.black.withAlphaComponent(0.5).setFill()
        context.fill(strip)
        drawFilmstrip(in: strip, context: context)
        // The parts that are trimmed away.
        NSColor.black.withAlphaComponent(0.55).setFill()
        context.fill(CGRect(x: strip.minX, y: strip.minY, width: x(range.lowerBound) - strip.minX, height: strip.height))
        context.fill(CGRect(x: x(range.upperBound), y: strip.minY, width: strip.maxX - x(range.upperBound), height: strip.height))
        context.restoreGState()
        drawTrimFrame(from: x(range.lowerBound), to: x(range.upperBound), context: context)
        drawPlayhead(at: x(model.currentTime), context: context)
    }

    /// Frames tile the strip at their own aspect ratio, each showing the moment under its center.
    private func drawFilmstrip(in strip: CGRect, context: CGContext) {
        let frames = model.filmstrip
        guard let first = frames.first, first.height > 0 else { return }
        let tileWidth = max(8, strip.height * CGFloat(first.width) / CGFloat(first.height))
        var x = strip.minX
        while x < strip.maxX {
            let fraction = (x + tileWidth / 2 - strip.minX) / strip.width
            let index = min(frames.count - 1, max(0, Int(fraction * CGFloat(frames.count))))
            context.saveGState()
            // Flipped view: draw images upright.
            context.translateBy(x: x, y: strip.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(frames[index], in: CGRect(x: 0, y: 0, width: tileWidth, height: strip.height))
            context.restoreGState()
            x += tileWidth
        }
    }

    private func drawTrimFrame(from start: CGFloat, to end: CGFloat, context: CGContext) {
        let handle = Self.handleWidth
        let outer = CGRect(x: start - handle, y: bounds.minY + 1, width: end - start + 2 * handle, height: bounds.height - 2)
        let path = CGMutablePath()
        path.addRoundedRect(in: outer, cornerWidth: 6, cornerHeight: 6)
        path.addRect(CGRect(x: start, y: outer.minY + 3, width: max(0, end - start), height: outer.height - 6))
        context.setFillColor(Self.trimColor.cgColor)
        context.addPath(path)
        context.fillPath(using: .evenOdd)
        // Grip marks on the handles.
        context.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        for center in [start - handle / 2, end + handle / 2] {
            context.addPath(CGPath(roundedRect: CGRect(x: center - 1, y: outer.midY - 7, width: 2, height: 14),
                                   cornerWidth: 1, cornerHeight: 1, transform: nil))
        }
        context.fillPath()
    }

    private func drawPlayhead(at x: CGFloat, context: CGContext) {
        let line = CGRect(x: x - 1, y: bounds.minY, width: 2, height: bounds.height)
        context.saveGState()
        context.setShadow(offset: .zero, blur: 2, color: NSColor.black.withAlphaComponent(0.6).cgColor)
        context.setFillColor(NSColor.white.cgColor)
        context.addPath(CGPath(roundedRect: line, cornerWidth: 1, cornerHeight: 1, transform: nil))
        context.fillPath()
        context.restoreGState()
    }

    /// Which handle a press at `x` grabs. Handles sit outside the kept range, so a short clip's
    /// handles stay apart.
    private func handle(at x: CGFloat) -> Drag? {
        let range = model.trimRange
        let start = self.x(range.lowerBound), end = self.x(range.upperBound)
        if x >= start - Self.handleWidth - 4, x <= start + 2 { return .start }
        if x >= end - 2, x <= end + Self.handleWidth + 4 { return .end }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        drag = handle(at: point.x) ?? .scrub
        if drag == .scrub { model.beginScrub() }
        update(point.x)
    }

    override func mouseDragged(with event: NSEvent) { update(convert(event.locationInWindow, from: nil).x) }

    override func mouseUp(with event: NSEvent) {
        switch drag {
        case .start, .end: model.commitTrimPreview()
        case .scrub: model.endScrub()
        case nil: break
        }
        drag = nil
    }

    private func update(_ x: CGFloat) {
        let time = scale.time(at: x - strip.minX)
        switch drag {
        case .start: model.previewTrim(start: time)
        case .end: model.previewTrim(end: time)
        case .scrub: model.seek(to: min(max(time, model.trimRange.lowerBound), model.trimRange.upperBound))
        case nil: break
        }
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        (handle(at: point.x) == nil ? NSCursor.arrow : NSCursor.columnResize(directions: .all)).set()
    }

    override func accessibilityValue() -> Any? {
        "\(ClipTime.format(model.currentTime, tenths: true)) of \(ClipTime.format(model.document.record.duration, tenths: true))"
    }
}
