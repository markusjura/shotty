import CoreGraphics
import Foundation

/// Selection coordinates stay in the global AppKit desktop space, including gaps
/// and negative screen origins. Raster composition uses one scale for the result.
enum SelectionGeometry {
    static func rectangle(from anchor: CGPoint, to point: CGPoint, square: Bool, centered: Bool) -> CGRect {
        var dx = point.x - anchor.x
        var dy = point.y - anchor.y
        if square {
            let side = max(abs(dx), abs(dy))
            dx = dx < 0 ? -side : side
            dy = dy < 0 ? -side : side
        }
        if centered {
            return CGRect(x: anchor.x - abs(dx), y: anchor.y - abs(dy),
                          width: abs(dx) * 2, height: abs(dy) * 2)
        }
        return CGRect(x: min(anchor.x, anchor.x + dx), y: min(anchor.y, anchor.y + dy),
                      width: abs(dx), height: abs(dy))
    }

    /// Arrow-key adjustment: moves `rect`, or with `resizes` grows or shrinks it from its origin,
    /// never below one point.
    static func nudged(_ rect: CGRect, dx: CGFloat, dy: CGFloat, resizes: Bool) -> CGRect {
        guard resizes else { return rect.offsetBy(dx: dx, dy: dy) }
        return CGRect(origin: rect.origin, size: CGSize(width: max(1, rect.width + dx), height: max(1, rect.height + dy)))
    }

    static func outputScale(for selection: CGRect, displays: [SelectionDisplay]) -> CGFloat {
        displays.filter { $0.frame.intersects(selection) }.map(\.scale).max() ?? 1
    }

    /// A recording covers one display. The region is clipped to the display under its center,
    /// or the one it overlaps most; nil when it overlaps none.
    static func recordingRegion(_ region: CGRect, displays: [(id: CGDirectDisplayID, frame: CGRect)])
        -> (rect: CGRect, display: CGDirectDisplayID)? {
        let center = CGPoint(x: region.midX, y: region.midY)
        let area: (CGRect) -> CGFloat = { let overlap = $0.intersection(region); return overlap.isNull ? 0 : overlap.width * overlap.height }
        guard let display = displays.first(where: { $0.frame.contains(center) }) ?? displays.max(by: { area($0.frame) < area($1.frame) }),
              area(display.frame) > 0 else { return nil }
        return (region.intersection(display.frame).integral.intersection(display.frame), display.id)
    }

    /// Edges whose hit band of `tolerance` contains `point`; a corner yields two edges.
    /// When a thin rectangle puts both opposite edges in range, the nearer one wins.
    static func edges(near point: CGPoint, of rect: CGRect, tolerance: CGFloat) -> SelectionEdges? {
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return nil }
        func nearer(_ low: CGFloat, _ high: CGFloat, _ value: CGFloat,
                    _ lowEdge: SelectionEdges, _ highEdge: SelectionEdges) -> SelectionEdges {
            let toLow = abs(value - low), toHigh = abs(value - high)
            if toLow <= tolerance, toLow <= toHigh { return lowEdge }
            return toHigh <= tolerance ? highEdge : []
        }
        let edges = nearer(rect.minX, rect.maxX, point.x, .left, .right)
            .union(nearer(rect.minY, rect.maxY, point.y, .bottom, .top))
        return edges.isEmpty ? nil : edges
    }

    /// Moves only the given edges; dragging an edge past its opposite flips the rectangle.
    static func resize(_ rect: CGRect, edges: SelectionEdges, by delta: CGVector) -> CGRect {
        let minX = rect.minX + (edges.contains(.left) ? delta.dx : 0)
        let maxX = rect.maxX + (edges.contains(.right) ? delta.dx : 0)
        let minY = rect.minY + (edges.contains(.bottom) ? delta.dy : 0)
        let maxY = rect.maxY + (edges.contains(.top) ? delta.dy : 0)
        return CGRect(x: min(minX, maxX), y: min(minY, maxY), width: abs(maxX - minX), height: abs(maxY - minY))
    }

    /// Origins for a control of `size` centered below `region`, then above it, then just inside
    /// its bottom edge, each clamped horizontally into `visible`.
    static func attachedOrigins(size: CGSize, to region: CGRect, within visible: CGRect, gap: CGFloat) -> [CGPoint] {
        let x = min(max(region.midX - size.width / 2, visible.minX), visible.maxX - size.width)
        return [region.minY - gap - size.height, region.maxY + gap, region.minY + gap].map { CGPoint(x: x, y: $0) }
    }

    /// The first origin whose frame lies inside `visible` without touching any `avoiding` rectangle.
    static func firstClearOrigin(_ candidates: [CGPoint], size: CGSize, avoiding: [CGRect], within visible: CGRect) -> CGPoint? {
        candidates.first { origin in
            let frame = CGRect(origin: origin, size: size)
            return visible.contains(frame) && !avoiding.contains { $0.intersects(frame) }
        }
    }
}

/// Rectangle edges in AppKit orientation, where top has the larger y.
struct SelectionEdges: OptionSet, Sendable {
    let rawValue: Int
    static let left = SelectionEdges(rawValue: 1)
    static let right = SelectionEdges(rawValue: 2)
    static let bottom = SelectionEdges(rawValue: 4)
    static let top = SelectionEdges(rawValue: 8)
}

/// One pointer gesture on the area selection, independent of AppKit events.
/// Holding Space while drawing moves the rectangle; releasing it resumes drawing
/// from the moved anchor, so drawing and moving can alternate within one drag.
struct SelectionDrag: Sendable {
    private enum Mode: Sendable {
        case drawing(anchor: CGPoint)
        case moving(original: CGRect, from: CGPoint, resumeAnchor: CGPoint?)
        case resizing(original: CGRect, edges: SelectionEdges, from: CGPoint)
    }

    private var mode: Mode
    private(set) var rect: CGRect

    /// With an adjustable `existing` selection, pressing its edge band resizes those edges,
    /// pressing inside moves it, and pressing elsewhere draws a new rectangle.
    init(at point: CGPoint, adjusting existing: CGRect?, tolerance: CGFloat) {
        if let existing, let edges = SelectionGeometry.edges(near: point, of: existing, tolerance: tolerance) {
            mode = .resizing(original: existing, edges: edges, from: point)
            rect = existing
        } else if let existing, existing.contains(point) {
            mode = .moving(original: existing, from: point, resumeAnchor: nil)
            rect = existing
        } else {
            mode = .drawing(anchor: point)
            rect = CGRect(origin: point, size: .zero)
        }
    }

    var isDrawing: Bool { if case .drawing = mode { true } else { false } }

    mutating func update(to point: CGPoint, square: Bool, centered: Bool) {
        switch mode {
        case .drawing(let anchor):
            rect = SelectionGeometry.rectangle(from: anchor, to: point, square: square, centered: centered)
        case .moving(let original, let from, _):
            rect = original.offsetBy(dx: point.x - from.x, dy: point.y - from.y)
        case .resizing(let original, let edges, let from):
            rect = SelectionGeometry.resize(original, edges: edges, by: CGVector(dx: point.x - from.x, dy: point.y - from.y))
        }
    }

    /// Space only affects drawing; moves and edge resizes ignore it.
    mutating func setSpace(_ down: Bool, at point: CGPoint) {
        switch mode {
        case .drawing(let anchor) where down:
            mode = .moving(original: rect, from: point, resumeAnchor: anchor)
        case .moving(_, let from, let anchor?) where !down:
            mode = .drawing(anchor: CGPoint(x: anchor.x + point.x - from.x, y: anchor.y + point.y - from.y))
        default:
            break
        }
    }
}

struct SelectionDisplay: Sendable {
    let id: CGDirectDisplayID
    let frame: CGRect
    let scale: CGFloat
    let image: CGImage?
}

/// One background worker for area composition. The output profile is the primary
/// participating display's profile; Core Graphics converts other displays into it.
actor SelectionRenderer {
    func compose(region: CGRect, displays: [SelectionDisplay]) throws -> CGImage {
        let participating = displays.filter { $0.frame.intersects(region) }
        guard let first = participating.first, let firstImage = first.image else { throw CaptureFailure.noImage }
        let scale = SelectionGeometry.outputScale(for: region, displays: participating)
        let width = Int(ceil(region.width * scale)), height = Int(ceil(region.height * scale))
        _ = try RasterBudget().byteCount(width: width, height: height)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4,
                                      space: firstImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CaptureFailure.noImage
        }
        context.interpolationQuality = .high
        for display in participating {
            try Task.checkCancellation()
            guard let image = display.image else { throw CaptureFailure.noImage }
            let destination = CGRect(x: (display.frame.minX - region.minX) * scale,
                                     y: (display.frame.minY - region.minY) * scale,
                                     width: display.frame.width * scale, height: display.frame.height * scale)
            context.draw(image, in: destination)
        }
        guard let image = context.makeImage() else { throw CaptureFailure.noImage }
        return image
    }
}
