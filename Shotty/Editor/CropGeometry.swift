import CoreGraphics

/// Crop constraints share one anchored sizing path, so bounds never clip away an aspect lock.
enum CropGeometry {
    static func applyingAspect(_ aspect: CGFloat?, to rect: CGRect, within bounds: CGRect) -> CGRect {
        var size = rect.size
        if let aspect { size.width = min(size.width, size.height * aspect); size.height = size.width / aspect }
        return fitted(size, aspect: aspect, anchor: CGPoint(x: rect.midX, y: rect.midY),
                      unitAnchor: CGPoint(x: 0.5, y: 0.5), within: bounds)
    }

    static func resized(_ rect: CGRect, width: CGFloat? = nil, height: CGFloat? = nil,
                        aspect: CGFloat?, within bounds: CGRect) -> CGRect {
        var size = rect.size
        if let width, width.isFinite {
            size.width = max(1, width)
            if let aspect { size.height = size.width / aspect }
        }
        if let height, height.isFinite {
            size.height = max(1, height)
            if let aspect { size.width = size.height * aspect }
        }
        return fitted(size, aspect: aspect, anchor: rect.origin, unitAnchor: .zero, within: bounds)
    }

    /// A pointer drag that moves the crop, resizes it from `edges`, or draws a new one without edges.
    /// `constrained` is Shift: it keeps a move on one axis, a resize at the crop's starting
    /// proportions, and a drawn crop square. A chosen `aspect` takes precedence.
    static func dragged(_ rect: CGRect, edges: SelectionEdges?, moving: Bool, from start: CGPoint, to point: CGPoint,
                        aspect: CGFloat?, constrained: Bool = false, within bounds: CGRect, snap: CGFloat) -> CGRect {
        var delta = CGVector(dx: point.x - start.x, dy: point.y - start.y)
        if moving {
            if constrained { if abs(delta.dx) >= abs(delta.dy) { delta.dy = 0 } else { delta.dx = 0 } }
            var origin = CGPoint(x: rect.minX + delta.dx, y: rect.minY + delta.dy)
            origin.x = min(max(origin.x, bounds.minX), bounds.maxX - rect.width)
            origin.y = min(max(origin.y, bounds.minY), bounds.maxY - rect.height)
            if abs(origin.x - bounds.minX) < snap { origin.x = bounds.minX }
            if abs(origin.x + rect.width - bounds.maxX) < snap { origin.x = bounds.maxX - rect.width }
            if abs(origin.y - bounds.minY) < snap { origin.y = bounds.minY }
            if abs(origin.y + rect.height - bounds.maxY) < snap { origin.y = bounds.maxY - rect.height }
            return CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: rect.width, height: rect.height)
        }

        let aspect = aspect ?? (constrained ? (edges == nil ? 1 : rect.width / rect.height) : nil)
        let activeEdges = edges ?? []
        let horizontal = edges == nil || !activeEdges.intersection([.left, .right]).isEmpty
        let vertical = edges == nil || !activeEdges.intersection([.bottom, .top]).isEmpty
        let anchor: CGPoint
        var end: CGPoint
        if let edges {
            anchor = CGPoint(x: edges.contains(.left) ? rect.maxX : edges.contains(.right) ? rect.minX : rect.midX,
                             y: edges.contains(.bottom) ? rect.maxY : edges.contains(.top) ? rect.minY : rect.midY)
            end = CGPoint(x: edges.contains(.left) ? rect.minX + delta.dx : rect.maxX + delta.dx,
                          y: edges.contains(.bottom) ? rect.minY + delta.dy : rect.maxY + delta.dy)
        } else { anchor = start; end = point }
        if abs(end.x - bounds.minX) < snap { end.x = bounds.minX }
        if abs(end.x - bounds.maxX) < snap { end.x = bounds.maxX }
        if abs(end.y - bounds.minY) < snap { end.y = bounds.minY }
        if abs(end.y - bounds.maxY) < snap { end.y = bounds.maxY }
        var size = CGSize(width: horizontal ? abs(end.x - anchor.x) : rect.width,
                          height: vertical ? abs(end.y - anchor.y) : rect.height)
        if let aspect {
            let useWidth = !vertical || (horizontal && (edges == nil
                ? size.width >= size.height * aspect
                : abs(delta.dx) >= abs(delta.dy) * aspect))
            if useWidth { size.height = size.width / aspect } else { size.width = size.height * aspect }
        }
        let unitAnchor = CGPoint(x: horizontal ? (end.x < anchor.x ? 1 : 0) : 0.5,
                                 y: vertical ? (end.y < anchor.y ? 1 : 0) : 0.5)
        return fitted(size, aspect: aspect, anchor: anchor, unitAnchor: unitAnchor, within: bounds)
    }

    private static func fitted(_ requested: CGSize, aspect: CGFloat?, anchor: CGPoint,
                               unitAnchor: CGPoint, within bounds: CGRect) -> CGRect {
        let anchor = CGPoint(x: min(max(anchor.x, bounds.minX), bounds.maxX),
                             y: min(max(anchor.y, bounds.minY), bounds.maxY))
        func capacity(_ point: CGFloat, _ low: CGFloat, _ high: CGFloat, _ unit: CGFloat) -> CGFloat {
            min(unit > 0 ? (point - low) / unit : .infinity,
                unit < 1 ? (high - point) / (1 - unit) : .infinity)
        }
        let maxWidth = capacity(anchor.x, bounds.minX, bounds.maxX, unitAnchor.x)
        let maxHeight = capacity(anchor.y, bounds.minY, bounds.maxY, unitAnchor.y)
        var size = CGSize(width: min(max(1, requested.width), maxWidth),
                          height: min(max(1, requested.height), maxHeight))
        if let aspect {
            size.width = min(max(max(1, aspect), requested.width), maxWidth, maxHeight * aspect)
            size.height = size.width / aspect
        }
        // Export crops on whole pixels. Keep the same dimensions in the preview; a locked
        // ratio may differ by less than one pixel because raster dimensions are integral.
        size.width = min(bounds.width, max(1, size.width.rounded()))
        size.height = min(bounds.height, max(1, size.height.rounded()))
        let x = min(max((anchor.x - size.width * unitAnchor.x).rounded(), bounds.minX), bounds.maxX - size.width)
        let y = min(max((anchor.y - size.height * unitAnchor.y).rounded(), bounds.minY), bounds.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }
}
