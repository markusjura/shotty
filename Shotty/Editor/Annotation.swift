import CoreGraphics
import Foundation

/// All geometry uses source pixels, with the origin at the image's top-left corner.
struct AnnotationDocument: Codable, Equatable, Sendable {
    var annotations: [Annotation] = []
    var crop: CGRect?

    func validated(in bounds: CGRect) throws -> AnnotationDocument {
        guard Set(annotations.map(\.id)).count == annotations.count,
              annotations.allSatisfy({ $0.isValid }),
              crop.map({ $0.isFiniteRectangle && !$0.isEmpty && bounds.contains($0) }) ?? true else {
            throw DocumentRenderer.Failure.invalidDocument
        }
        return self
    }

    /// Migrates older documents in their existing order and assigns new IDs fresh ordinals.
    /// Geometry/z-order edits retain identity; duplicated or pasted IDs are always new creations.
    func preservingCreationOrder(from previous: AnnotationDocument) throws -> AnnotationDocument {
        var result = self
        var next = previous.annotations.compactMap(\.creationOrder).max() ?? -1
        var order: [UUID: Int] = [:]
        func allocate() throws -> Int {
            guard next < Int.max else { throw DocumentRenderer.Failure.invalidDocument }
            next += 1
            return next
        }
        for annotation in previous.annotations {
            order[annotation.id] = try annotation.creationOrder ?? allocate()
        }
        for index in result.annotations.indices {
            let id = result.annotations[index].id
            result.annotations[index].creationOrder = try order[id] ?? allocate()
        }
        return result
    }
}

struct Annotation: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var content: AnnotationContent
    /// Independent of stacking order. Nil is supported for captures saved before this field existed.
    var creationOrder: Int?

    var tool: EditorTool { content.tool }
    var bounds: CGRect { content.bounds }

    func translated(by offset: CGSize) -> Annotation {
        var copy = self
        copy.content = content.transformed(CGAffineTransform(translationX: offset.width, y: offset.height))
        return copy
    }

    /// Transforms geometry only. Styles retain their image-pixel widths and font sizes.
    func transformed(_ transform: CGAffineTransform) -> Annotation {
        var copy = self
        copy.content = content.transformed(transform)
        return copy
    }

    var isValid: Bool {
        guard bounds.isFiniteRectangle, creationOrder.map({ $0 >= 0 }) ?? true else { return false }
        var defaults = EditorToolDefaults()
        switch content {
        case .arrow(let start, let end, let bend, let style):
            guard start.isFinitePoint, end.isFinitePoint, bend?.isFinitePoint ?? true else { return false }
            defaults.arrow = style
        case .rectangle(_, let style):
            guard style.strokeColor.isValid, style.fillColor?.isValid ?? true else { return false }
            defaults.rectangle = style
        case .ellipse(_, let style): defaults.ellipse = style
        case .line(let start, let end, let style):
            guard start.isFinitePoint, end.isFinitePoint else { return false }
            defaults.line = style
        case .text(_, _, let style):
            guard EditorToolDefaults.Text.sizeRange.contains(style.size) else { return false }
            defaults.text = style
        case .redact(_, let style): defaults.redact = style
        case .spotlight(_, let style): defaults.spotlight = style
        case .counter(let center, let number, let style):
            guard center.isFinitePoint, number > 0, EditorToolDefaults.Counter.sizeRange.contains(style.size) else { return false }
            defaults.counter = style
        }
        return defaults.isValid
    }
}

enum AnnotationContent: Codable, Equatable, Sendable {
    case arrow(start: CGPoint, end: CGPoint, bend: CGPoint?, style: EditorToolDefaults.Arrow)
    case rectangle(rect: CGRect, style: EditorToolDefaults.Rectangle)
    case ellipse(rect: CGRect, style: EditorToolDefaults.Ellipse)
    case line(start: CGPoint, end: CGPoint, style: EditorToolDefaults.Line)
    case text(rect: CGRect, text: String, style: EditorToolDefaults.Text)
    case redact(rect: CGRect, style: EditorToolDefaults.Redact)
    case spotlight(rect: CGRect, style: EditorToolDefaults.Spotlight)
    case counter(center: CGPoint, number: Int, style: EditorToolDefaults.Counter)

    var tool: EditorTool {
        switch self {
        case .arrow: .arrow
        case .rectangle(_, let style): style.fillColor == nil ? .rectangle : .filledRectangle
        case .ellipse: .ellipse
        case .line: .line
        case .text: .text
        case .redact: .redact
        case .spotlight: .spotlight
        case .counter: .counter
        }
    }

    var bounds: CGRect {
        switch self {
        case .arrow(let start, let end, let bend, _):
            let points = [start, end] + (bend.map { [$0] } ?? [])
            return CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                          width: points.map(\.x).max()! - points.map(\.x).min()!,
                          height: points.map(\.y).max()! - points.map(\.y).min()!)
        case .line(let start, let end, _):
            return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        case .rectangle(let rect, _), .ellipse(let rect, _), .text(let rect, _, _), .redact(let rect, _), .spotlight(let rect, _):
            return rect.standardized
        case .counter(let center, _, let style):
            return CGRect(x: center.x - style.size / 2, y: center.y - style.size / 2, width: style.size, height: style.size)
        }
    }

    func transformed(_ transform: CGAffineTransform) -> AnnotationContent {
        switch self {
        case .arrow(let a, let b, let bend, let style): .arrow(start: a.applying(transform), end: b.applying(transform), bend: bend?.applying(transform), style: style)
        case .line(let a, let b, let style): .line(start: a.applying(transform), end: b.applying(transform), style: style)
        case .rectangle(let rect, let style): .rectangle(rect: rect.applying(transform), style: style)
        case .ellipse(let rect, let style): .ellipse(rect: rect.applying(transform), style: style)
        case .text(let rect, let text, let style): .text(rect: rect.applying(transform), text: text, style: style)
        case .redact(let rect, let style): .redact(rect: rect.applying(transform), style: style)
        case .spotlight(let rect, let style): .spotlight(rect: rect.applying(transform), style: style)
        case .counter(let center, let number, let style): .counter(center: center.applying(transform), number: number, style: style)
        }
    }
}

extension CGRect {
    var isFiniteRectangle: Bool { [origin.x, origin.y, size.width, size.height].allSatisfy(\.isFinite) && !isNull && !isInfinite }
}

extension CGPoint {
    var isFinitePoint: Bool { x.isFinite && y.isFinite }
}
