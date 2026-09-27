import CoreGraphics
import Foundation

/// A resize handle: an endpoint or bend of a line/arrow, or edges of a bounding box.
enum EditorHandle: Equatable, Sendable {
    case point(Int)
    case edges(SelectionEdges)
}

enum EditorArrangement: Sendable { case front, forward, backward, back }

/// Pure canvas geometry in source pixels with a top-left origin. In `SelectionEdges`,
/// `.bottom` moves minY and `.top` moves maxY, matching `SelectionGeometry.resize`.
enum EditorGeometry {
    static let boxHandleEdges: [SelectionEdges] = [
        [.left, .bottom], .bottom, [.right, .bottom], .right, [.right, .top], .top, [.left, .top], .left
    ]

    static func point(on rect: CGRect, for edges: SelectionEdges) -> CGPoint {
        CGPoint(x: edges.contains(.left) ? rect.minX : edges.contains(.right) ? rect.maxX : rect.midX,
                y: edges.contains(.bottom) ? rect.minY : edges.contains(.top) ? rect.maxY : rect.midY)
    }

    /// Handles for one selected object. Counters resize their size from four corners.
    static func handles(for annotation: Annotation) -> [(EditorHandle, CGPoint)] {
        switch annotation.content {
        case .line(let a, let b, _): return [(.point(0), a), (.point(1), b)]
        case .arrow(let a, let b, let bend, let style):
            var result: [(EditorHandle, CGPoint)] = [(.point(0), a), (.point(1), b)]
            if style.style == .curved { result.append((.point(2), bend ?? defaultBend(start: a, end: b))) }
            return result
        case .counter:
            return [[.left, .bottom], [.right, .bottom], [.right, .top], [.left, .top]].map {
                (.edges($0), point(on: annotation.bounds, for: $0))
            }
        default: return boxHandles(for: annotation.bounds)
        }
    }

    static func boxHandles(for rect: CGRect) -> [(EditorHandle, CGPoint)] {
        boxHandleEdges.map { (.edges($0), point(on: rect, for: $0)) }
    }

    /// The control point DocumentRenderer uses for a curved arrow without an explicit bend.
    static func defaultBend(start: CGPoint, end: CGPoint) -> CGPoint {
        CGPoint(x: (start.x + end.x) / 2 - (end.y - start.y) * 0.2, y: (start.y + end.y) / 2 + (end.x - start.x) * 0.2)
    }

    // MARK: Hit testing

    /// Distance from `point` to the visible part of an annotation: 0 inside filled interiors,
    /// otherwise to the stroke's outer edge. Hollow shapes and spotlight openings are hit
    /// only near their outline, so they never block objects beneath them.
    static func distance(from point: CGPoint, to annotation: Annotation) -> CGFloat {
        switch annotation.content {
        case .line(let a, let b, let style):
            return max(0, segmentDistance(point, a, b) - style.width / 2)
        case .arrow(let a, let b, let bend, let style):
            if style.style == .curved {
                return max(0, curveDistance(point, a, bend ?? defaultBend(start: a, end: b), b) - style.width / 2)
            }
            return max(0, segmentDistance(point, a, b) - style.width / 2)
        case .rectangle(let rect, let style):
            let rect = rect.standardized
            if style.fillColor != nil, rect.contains(point) { return 0 }
            return max(0, outlineDistance(point, rect) - style.width / 2)
        case .ellipse(let rect, let style):
            return ellipseDistance(point, rect.standardized, filled: style.fillColor != nil, width: style.width)
        case .spotlight(let rect, _):
            return outlineDistance(point, rect.standardized)
        case .counter(let center, _, let style):
            return max(0, hypot(point.x - center.x, point.y - center.y) - style.size / 2)
        case .text(let rect, _, _), .redact(let rect, _):
            return rectDistance(point, rect.standardized)
        }
    }

    /// The annotation with the nearest visible part within `tolerance`. Ties go to the one drawn
    /// on top; counters always render above other annotations.
    static func hit(_ point: CGPoint, in annotations: [Annotation], tolerance: CGFloat) -> Annotation? {
        var best: (annotation: Annotation, distance: CGFloat, z: Int)?
        for (index, annotation) in annotations.enumerated() {
            let distance = distance(from: point, to: annotation)
            guard distance <= tolerance else { continue }
            let z = index + (annotation.tool == .counter ? annotations.count : 0)
            if best == nil || distance < best!.distance || (distance == best!.distance && z > best!.z) {
                best = (annotation, distance, z)
            }
        }
        return best?.annotation
    }

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let t = length == 0 ? 0 : min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - a.x - t * dx, p.y - a.y - t * dy)
    }

    /// Quadratic Bézier distance by 32 chords, well within the 6-point hit tolerance.
    static func curveDistance(_ p: CGPoint, _ a: CGPoint, _ control: CGPoint, _ b: CGPoint) -> CGFloat {
        func at(_ t: CGFloat) -> CGPoint {
            let u = 1 - t
            return CGPoint(x: u * u * a.x + 2 * u * t * control.x + t * t * b.x, y: u * u * a.y + 2 * u * t * control.y + t * t * b.y)
        }
        return (0..<32).map { segmentDistance(p, at(CGFloat($0) / 32), at(CGFloat($0 + 1) / 32)) }.min()!
    }

    static func rectDistance(_ p: CGPoint, _ rect: CGRect) -> CGFloat {
        hypot(max(rect.minX - p.x, 0, p.x - rect.maxX), max(rect.minY - p.y, 0, p.y - rect.maxY))
    }

    static func outlineDistance(_ p: CGPoint, _ rect: CGRect) -> CGFloat {
        rect.contains(p) ? min(p.x - rect.minX, rect.maxX - p.x, p.y - rect.minY, rect.maxY - p.y) : rectDistance(p, rect)
    }

    static func ellipseDistance(_ p: CGPoint, _ rect: CGRect, filled: Bool, width: CGFloat) -> CGFloat {
        let rx = max(0.5, rect.width / 2), ry = max(0.5, rect.height / 2)
        let r = hypot((p.x - rect.midX) / rx, (p.y - rect.midY) / ry)
        if filled, r <= 1 { return 0 }
        // Radial approximation: exact on circles and adequate for hit tolerances on ellipses.
        return max(0, abs(r - 1) * min(rx, ry) - width / 2)
    }

    // MARK: Editing

    /// Marquee selection from its base set, recomputed on every drag so shrinking it deselects.
    static func marqueeSelection(base: Set<UUID>, rect: CGRect, annotations: [Annotation]) -> Set<UUID> {
        base.union(annotations.filter { rect.contains($0.bounds) }.map(\.id))
    }

    /// Limits a move so the moved bounds stay inside `limit` whenever they fit.
    static func clampedOffset(_ offset: CGSize, moving bounds: CGRect, within limit: CGRect) -> CGSize {
        func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat { low <= high ? min(high, max(low, value)) : value }
        return CGSize(width: clamp(offset.width, limit.minX - bounds.minX, limit.maxX - bounds.maxX),
                      height: clamp(offset.height, limit.minY - bounds.minY, limit.maxY - bounds.maxY))
    }

    static func union(_ annotations: [Annotation]) -> CGRect? {
        annotations.map(\.bounds).reduce(nil) { $0?.union($1) ?? $1 }
    }

    /// Resizes one annotation from its gesture-start geometry. Geometry changes; stroke widths and
    /// font sizes stay in image pixels. Counters change their size, clamped to the style range.
    static func resized(_ annotation: Annotation, handle: EditorHandle, delta: CGVector, limit: CGRect,
                        constrained: Bool = false) -> Annotation {
        var result = annotation
        func moved(_ p: CGPoint) -> CGPoint { clamp(CGPoint(x: p.x + delta.dx, y: p.y + delta.dy), to: limit) }
        switch (annotation.content, handle) {
        case (.line(let a, let b, let style), .point(let index)):
            let start = index == 0 ? (constrained ? snappedEndpoint(from: b, toward: moved(a), limit: limit) : moved(a)) : a
            let end = index == 1 ? (constrained ? snappedEndpoint(from: a, toward: moved(b), limit: limit) : moved(b)) : b
            result.content = .line(start: start, end: end, style: style)
        case (.arrow(let a, let b, let bend, let style), .point(let index)):
            let control = bend ?? (style.style == .curved ? defaultBend(start: a, end: b) : nil)
            let start = index == 0 ? (constrained ? snappedEndpoint(from: b, toward: moved(a), limit: limit) : moved(a)) : a
            let end = index == 1 ? (constrained ? snappedEndpoint(from: a, toward: moved(b), limit: limit) : moved(b)) : b
            result.content = .arrow(start: start, end: end,
                                    bend: index == 2 ? control.map(moved) : bend, style: style)
        case (.counter(let center, let number, var style), .edges(let edges)):
            let corner = point(on: annotation.bounds, for: edges)
            let half = max(abs(corner.x + delta.dx - center.x), abs(corner.y + delta.dy - center.y))
            style.size = min(EditorToolDefaults.Counter.sizeRange.upperBound,
                             max(EditorToolDefaults.Counter.sizeRange.lowerBound, (2 * half).rounded()))
            result.content = .counter(center: center, number: number, style: style)
        case (_, .edges(let edges)):
            let old = annotation.bounds
            let rect = resizedBounds(old, edges: edges, delta: delta, limit: limit, constrained: constrained)
            guard !rect.isNull else { return annotation }
            result.content = replacingRect(annotation.content, with: rect)
        default:
            break
        }
        return result
    }

    /// Shift preserves the gesture-start proportions and the opposite edge/corner. At the image
    /// boundary both dimensions stop together rather than clipping away the constrained ratio.
    static func resizedBounds(_ old: CGRect, edges: SelectionEdges, delta: CGVector, limit: CGRect,
                              constrained: Bool) -> CGRect {
        guard constrained, old.width > 0, old.height > 0 else {
            return SelectionGeometry.resize(old, edges: edges, by: delta).intersection(limit)
        }
        let horizontal = !edges.intersection([.left, .right]).isEmpty
        let vertical = !edges.intersection([.bottom, .top]).isEmpty
        let fixed = CGPoint(x: horizontal ? (edges.contains(.left) ? old.maxX : old.minX) : old.midX,
                            y: vertical ? (edges.contains(.bottom) ? old.maxY : old.minY) : old.midY)
        let dx = horizontal ? (edges.contains(.left) ? old.minX : old.maxX) + delta.dx - fixed.x : old.width / 2
        let dy = vertical ? (edges.contains(.bottom) ? old.minY : old.maxY) + delta.dy - fixed.y : old.height / 2
        let xRatio = abs(dx) / old.width, yRatio = abs(dy) / old.height
        var scale = horizontal && vertical ? (abs(xRatio - 1) > abs(yRatio - 1) ? xRatio : yRatio)
            : horizontal ? xRatio : yRatio
        let availableWidth = horizontal ? (dx < 0 ? fixed.x - limit.minX : limit.maxX - fixed.x)
            : 2 * min(fixed.x - limit.minX, limit.maxX - fixed.x)
        let availableHeight = vertical ? (dy < 0 ? fixed.y - limit.minY : limit.maxY - fixed.y)
            : 2 * min(fixed.y - limit.minY, limit.maxY - fixed.y)
        scale = max(0, min(scale, availableWidth / old.width, availableHeight / old.height))
        let width = old.width * scale, height = old.height * scale
        return CGRect(x: horizontal ? (dx < 0 ? fixed.x - width : fixed.x) : fixed.x - width / 2,
                      y: vertical ? (dy < 0 ? fixed.y - height : fixed.y) : fixed.y - height / 2,
                      width: width, height: height)
    }

    private static func snappedEndpoint(from anchor: CGPoint, toward point: CGPoint, limit: CGRect) -> CGPoint {
        let angle = (atan2(point.y - anchor.y, point.x - anchor.x) / (.pi / 4)).rounded() * (.pi / 4)
        let dx = cos(angle), dy = sin(angle)
        var length = hypot(point.x - anchor.x, point.y - anchor.y)
        if abs(dx) > 0.000_001 { length = min(length, (dx > 0 ? limit.maxX - anchor.x : limit.minX - anchor.x) / dx) }
        if abs(dy) > 0.000_001 { length = min(length, (dy > 0 ? limit.maxY - anchor.y : limit.minY - anchor.y) / dy) }
        return CGPoint(x: anchor.x + dx * max(0, length), y: anchor.y + dy * max(0, length))
    }

    /// Scales every annotation from `old` to `new` group bounds. Counters move only their centers.
    static func scaled(_ annotations: [Annotation], from old: CGRect, to new: CGRect) -> [Annotation] {
        guard old.width > 0, old.height > 0 else {
            return annotations.map { $0.translated(by: CGSize(width: new.minX - old.minX, height: new.minY - old.minY)) }
        }
        let transform = CGAffineTransform(translationX: -old.minX, y: -old.minY)
            .concatenating(CGAffineTransform(scaleX: new.width / old.width, y: new.height / old.height))
            .concatenating(CGAffineTransform(translationX: new.minX, y: new.minY))
        return annotations.map { $0.transformed(transform) }
    }

    private static func replacingRect(_ content: AnnotationContent, with rect: CGRect) -> AnnotationContent {
        switch content {
        case .rectangle(_, let style): .rectangle(rect: rect, style: style)
        case .ellipse(_, let style): .ellipse(rect: rect, style: style)
        case .text(_, let text, let style): .text(rect: rect, text: text, style: style)
        case .redact(_, let style): .redact(rect: rect.integral.intersection(rect.insetBy(dx: -1, dy: -1)), style: style)
        case .spotlight(_, let style): .spotlight(rect: rect, style: style)
        default: content
        }
    }

    static func clamp(_ point: CGPoint, to rect: CGRect) -> CGPoint {
        CGPoint(x: min(rect.maxX, max(rect.minX, point.x)), y: min(rect.maxY, max(rect.minY, point.y)))
    }

    /// Moves the selected annotations within the z-order, keeping their relative order.
    static func arranged(_ annotations: [Annotation], selected: Set<UUID>, _ arrangement: EditorArrangement) -> [Annotation] {
        var result = annotations
        switch arrangement {
        case .front: result = result.filter { !selected.contains($0.id) } + result.filter { selected.contains($0.id) }
        case .back: result = result.filter { selected.contains($0.id) } + result.filter { !selected.contains($0.id) }
        case .forward:
            for index in result.indices.dropLast().reversed()
            where selected.contains(result[index].id) && !selected.contains(result[index + 1].id) {
                result.swapAt(index, index + 1)
            }
        case .backward:
            for index in result.indices.dropFirst()
            where selected.contains(result[index].id) && !selected.contains(result[index - 1].id) {
                result.swapAt(index, index - 1)
            }
        }
        return result
    }

    // MARK: Preview invalidation

    /// Source-pixel rectangles whose composition differs between two states. A changed global
    /// spotlight dim invalidates everything; otherwise changed annotations contribute their old and
    /// new bounds, padded for strokes and arrowheads and for nearby effects that sample them.
    static func dirtyRects(from old: [Annotation], to new: [Annotation], bounds: CGRect) -> [CGRect] {
        func dim(_ annotations: [Annotation]) -> Double? {
            annotations.last { $0.tool == .spotlight }.flatMap {
                if case .spotlight(_, let style) = $0.content { style.dimPercent } else { nil }
            }
        }
        if dim(old) != dim(new) { return [bounds] }
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rects: [CGRect] = []
        for id in Set(oldByID.keys).union(newByID.keys) where oldByID[id] != newByID[id] {
            rects += [oldByID[id], newByID[id]].compactMap { $0.map(paddedBounds) }
        }
        // Order changes alone alter overlaps; include both copies of anything that moved in z.
        if rects.isEmpty, old.map(\.id) != new.map(\.id) { rects = new.map(paddedBounds) }
        // An effect also changes when nearby pixels in its sampling halo change. Propagate that
        // influence forward in composition order, including chains of overlapping redactions.
        // Evaluate both stacks because removing/moving an effect can reveal its old dependencies.
        rects = propagated(rects, through: old) + propagated(rects, through: new)
        return merged(rects.map { $0.intersection(bounds).integral }.filter { !$0.isEmpty })
    }

    private static func propagated(_ seeds: [CGRect], through annotations: [Annotation]) -> [CGRect] {
        var dirty = seeds
        for annotation in annotations {
            guard case .redact(let region, let style) = annotation.content, style.style != .solid else { continue }
            let padding = DocumentRenderer.effectPadding(style)
            let affected = dirty.map { $0.insetBy(dx: -padding, dy: -padding).intersection(region.integral) }
                .filter { !$0.isEmpty }
            dirty = merged(dirty + affected)
        }
        return dirty
    }

    private static func paddedBounds(_ annotation: Annotation) -> CGRect {
        let width: CGFloat = switch annotation.content {
        case .arrow(_, _, _, let style): style.width * 4
        case .line(_, _, let style): style.width
        case .rectangle(_, let style): style.width
        case .ellipse(_, let style): style.width
        case .text(_, _, let style): style.size * 0.5
        default: 0
        }
        return annotation.bounds.insetBy(dx: -(width + 2), dy: -(width + 2))
    }

    /// Merges overlapping rectangles; many small ones collapse into their union.
    static func merged(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects {
            var current = rect
            while let index = result.firstIndex(where: { $0.intersects(current) }) { current = current.union(result.remove(at: index)) }
            result.append(current)
        }
        if result.count > 8, let first = result.first { return [result.dropFirst().reduce(first) { $0.union($1) }] }
        return result
    }
}
