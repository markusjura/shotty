import CoreGraphics

/// Pure geometry for the video editor's player. Frames use a top-left origin, as video does, and the
/// player view is flipped to match.
enum PlayerLayout {
    /// Space around the video inside the player area.
    static let margin: CGFloat = 16

    /// Where a `visible`-sized part of the frame shows in `bounds`: centered, as large as fits
    /// inside the margin, and never larger than `maximumScale` points per pixel.
    static func fit(_ visible: CGSize, in bounds: CGRect, maximumScale: CGFloat) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return .zero }
        let available = bounds.insetBy(dx: margin, dy: margin)
        let scale = max(0, min(available.width / visible.width, available.height / visible.height, maximumScale))
        let size = CGSize(width: (visible.width * scale).rounded(), height: (visible.height * scale).rounded())
        return CGRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// The whole frame's rect when the `visible` part of a `source`-sized frame lands on `display`.
    static func frameRect(source: CGSize, visible: CGRect, display: CGRect) -> CGRect {
        guard visible.width > 0, visible.height > 0 else { return display }
        let scaleX = display.width / visible.width, scaleY = display.height / visible.height
        return CGRect(x: display.minX - visible.minX * scaleX, y: display.minY - visible.minY * scaleY,
                      width: source.width * scaleX, height: source.height * scaleY)
    }

    /// Converts a view point to source pixels, given where the `visible` part is displayed.
    static func sourcePoint(_ point: CGPoint, visible: CGRect, display: CGRect) -> CGPoint {
        guard display.width > 0, display.height > 0 else { return .zero }
        return CGPoint(x: visible.minX + (point.x - display.minX) * visible.width / display.width,
                       y: visible.minY + (point.y - display.minY) * visible.height / display.height)
    }

    /// Converts a source-pixel rect to view points.
    static func viewRect(_ rect: CGRect, visible: CGRect, display: CGRect) -> CGRect {
        let scaleX = display.width / visible.width, scaleY = display.height / visible.height
        return CGRect(x: display.minX + (rect.minX - visible.minX) * scaleX, y: display.minY + (rect.minY - visible.minY) * scaleY,
                      width: rect.width * scaleX, height: rect.height * scaleY)
    }
}

/// Pure geometry for the timeline strip: source seconds along its width.
struct TimelineScale {
    let duration: Double
    let width: CGFloat

    func x(for time: Double) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1)) * width
    }

    func time(at x: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(max(x / width, 0), 1)) * duration
    }
}
