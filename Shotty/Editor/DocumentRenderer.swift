import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Preview and output call the same full-resolution renderer. Each owner, such as ExportService,
/// the session store, or the editor's preview actor, keeps its own instance and uses it serially.
final class DocumentRenderer {
    enum Failure: LocalizedError {
        case invalidDocument, rendering
        var errorDescription: String? {
            switch self {
            case .invalidDocument: "This document contains invalid annotation geometry or styles."
            case .rendering: "The edited image could not be rendered. The document has been kept."
            }
        }
    }

    private let imageContext = CIContext(options: [.cacheIntermediates: false])

    func render(source: CGImage, state document: AnnotationDocument) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        return try render(source: source, state: document, region: document.crop ?? bounds)
    }

    /// Region preview uses global source coordinates and ignores the document crop. Effect halos
    /// are propagated backwards through the stack, so overlapping effects match the full output.
    func render(source: CGImage, state document: AnnotationDocument, region: CGRect) throws -> CGImage {
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        _ = try document.validated(in: bounds)
        guard region.isFiniteRectangle else { throw Failure.invalidDocument }
        let requested = region.standardized.integral.intersection(bounds)
        guard !requested.isEmpty else { throw Failure.invalidDocument }
        try Task.checkCancellation()
        if document.annotations.isEmpty {
            if requested == bounds { return source }
            guard let image = source.cropping(to: requested) else { throw Failure.rendering }
            return image
        }
        var working = requested
        for annotation in document.annotations.reversed() {
            guard case .redact(let rect, let style) = annotation.content, style.style != .solid else { continue }
            let affected = rect.standardized.integral.intersection(working)
            if !affected.isEmpty {
                let padding = Self.effectPadding(style)
                working = working.union(affected.insetBy(dx: -padding, dy: -padding)).integral.intersection(bounds)
            }
        }
        let space = source.colorSpace?.model == .rgb ? source.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let tile = source.cropping(to: working),
              let context = CGContext(data: nil, width: Int(working.width), height: Int(working.height), bitsPerComponent: 8,
                                      bytesPerRow: Int(working.width) * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.rendering }
        context.draw(tile, in: CGRect(origin: .zero, size: working.size))
        context.translateBy(x: -working.minX, y: working.maxY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: working)

        for annotation in document.annotations where annotation.tool != .spotlight && annotation.tool != .counter {
            try Task.checkCancellation()
            if case .redact(let rect, let style) = annotation.content {
                try drawRedaction(rect: rect, style: style, context: context, imageBounds: bounds, workingBounds: working, colorSpace: space)
            } else { Self.drawAnnotation(annotation, in: context) }
        }
        let spotlights = document.annotations.compactMap { annotation -> (CGRect, EditorToolDefaults.Spotlight)? in
            if case .spotlight(let rect, let style) = annotation.content { return (rect, style) }
            return nil
        }
        if !spotlights.isEmpty { drawSpotlights(spotlights, in: context, bounds: working) }
        for annotation in document.annotations where annotation.tool == .counter {
            try Task.checkCancellation()
            Self.drawAnnotation(annotation, in: context)
        }
        guard let rendered = context.makeImage(),
              let result = rendered.cropping(to: requested.offsetBy(dx: -working.minX, dy: -working.minY)) else { throw Failure.rendering }
        return result
    }

    /// Lightweight live vector overlay. Context must already use top-left source-pixel coordinates.
    /// Effect annotations use render(source:state:) on a serial background actor.
    static func drawAnnotation(_ annotation: Annotation, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch annotation.content {
        case .arrow(let start, let end, let bend, let style):
            context.setStrokeColor(style.color.cgColor)
            context.setFillColor(style.color.cgColor)
            context.setLineWidth(style.width)
            let control = bend ?? EditorGeometry.defaultBend(start: start, end: end)
            context.move(to: start)
            if style.style == .curved { context.addQuadCurve(to: end, control: control) }
            else { context.addLine(to: end) }
            context.strokePath()
            arrowhead(at: end, from: style.style == .curved ? control : start, width: style.width, context: context)
            if style.style == .double { arrowhead(at: start, from: end, width: style.width, context: context) }
        case .line(let start, let end, let style):
            context.setStrokeColor(style.color.cgColor)
            context.setLineWidth(style.width)
            context.move(to: start); context.addLine(to: end); context.strokePath()
        case .rectangle(let rect, let style):
            let rect = rect.standardized
            let radius = min(style.cornerRadius, min(rect.width, rect.height) / 2)
            let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            drawShape(path, stroke: style.strokeColor, fill: style.fillColor, width: style.width, context: context)
        case .ellipse(let rect, let style):
            drawShape(CGPath(ellipseIn: rect.standardized, transform: nil), stroke: style.strokeColor,
                      fill: style.fillColor, width: style.width, context: context)
        case .text(let rect, let text, let style):
            drawText(text, rect: rect.standardized, style: style, context: context)
        case .redact: break
        case .counter(let center, let number, let style):
            let rect = CGRect(x: center.x - style.size / 2, y: center.y - style.size / 2, width: style.size, height: style.size)
            context.setFillColor(style.color.cgColor)
            context.fillEllipse(in: rect)
            context.setStrokeColor(RGBAColor.white.cgColor)
            context.setLineWidth(max(1, style.size * 0.045))
            context.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            drawCounterNumber(number, in: rect, context: context)
        case .spotlight: break
        }
    }

    private func drawRedaction(rect: CGRect, style: EditorToolDefaults.Redact, context: CGContext,
                               imageBounds: CGRect, workingBounds: CGRect, colorSpace: CGColorSpace) throws {
        context.saveGState()
        defer { context.restoreGState() }
        let region = rect.standardized.integral.intersection(workingBounds)
        guard !region.isEmpty else { return }
        context.setShouldAntialias(false)
        context.clip(to: region)
        if style.style == .solid {
            var color = style.solidColor; color.alpha = 1
            context.setFillColor(color.cgColor); context.fill(region)
        } else {
            let effect = try filteredRegion(region, style: style, context: context, imageBounds: imageBounds, workingBounds: workingBounds, colorSpace: colorSpace)
            // Core Image and CGImage are bottom-left drawing sources; annotations are top-left.
            context.translateBy(x: region.minX, y: region.maxY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .none
            context.draw(effect, in: CGRect(origin: .zero, size: region.size))
        }
    }

    private static func drawShape(_ path: CGPath, stroke: RGBAColor, fill: RGBAColor?, width: Double, context: CGContext) {
        context.addPath(path)
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(width)
        if let fill { context.setFillColor(fill.cgColor); context.drawPath(using: .fillStroke) }
        else { context.strokePath() }
    }

    private static func arrowhead(at point: CGPoint, from tail: CGPoint, width: Double, context: CGContext) {
        let angle = atan2(point.y - tail.y, point.x - tail.x)
        let length = max(9, width * 3.5), halfWidth = max(4, width * 1.5)
        let base = CGPoint(x: point.x - cos(angle) * length, y: point.y - sin(angle) * length)
        context.move(to: point)
        context.addLine(to: CGPoint(x: base.x - sin(angle) * halfWidth, y: base.y + cos(angle) * halfWidth))
        context.addLine(to: CGPoint(x: base.x + sin(angle) * halfWidth, y: base.y - cos(angle) * halfWidth))
        context.closePath(); context.fillPath()
    }

    /// Each effect samples the current composition once. Crop only the padded tile in Core Image,
    /// retaining global coordinates so resizing a region never shifts its pixel grid.
    private func filteredRegion(_ region: CGRect, style: EditorToolDefaults.Redact, context: CGContext,
                                imageBounds: CGRect, workingBounds: CGRect, colorSpace: CGColorSpace) throws -> CGImage {
        guard let composition = context.makeImage() else { throw Failure.rendering }
        let source = CIImage(cgImage: composition, options: [.colorSpace: colorSpace])
            .transformed(by: CGAffineTransform(translationX: workingBounds.minX, y: imageBounds.height - workingBounds.maxY))
        let ciRegion = CGRect(x: region.minX, y: imageBounds.height - region.maxY, width: region.width, height: region.height)
        let amount = Self.effectAmount(style)
        let padding = Self.effectPadding(style)
        let tile = source.clampedToExtent().cropped(to: ciRegion.insetBy(dx: -padding, dy: -padding))
        let filtered: CIImage
        if style.style == .pixelate {
            filtered = tile.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: amount,
                kCIInputCenterKey: CIVector(x: amount / 2, y: imageBounds.height - amount / 2)
            ])
        } else { filtered = tile.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: amount]) }
        guard let output = imageContext.createCGImage(filtered.cropped(to: ciRegion), from: ciRegion,
                                                      format: .RGBA8, colorSpace: colorSpace) else { throw Failure.rendering }
        return output
    }

    private func drawSpotlights(_ openings: [(CGRect, EditorToolDefaults.Spotlight)], in context: CGContext,
                                bounds: CGRect) {
        context.saveGState()
        defer { context.restoreGState() }
        // Intersect each opening's complement. This leaves the outside of their union without
        // allocating another full-size RGBA image, and overlapping openings stay clear.
        for (rect, style) in openings {
            let path = CGMutablePath()
            path.addRect(bounds)
            switch style.shape {
            case .rectangle: path.addRect(rect.standardized)
            case .ellipse: path.addEllipse(in: rect.standardized)
            case .roundedRectangle:
                let radius = min(12, min(rect.width, rect.height) / 5)
                path.addRoundedRect(in: rect.standardized, cornerWidth: radius, cornerHeight: radius)
            }
            context.addPath(path)
            context.clip(using: .evenOdd)
        }
        context.setFillColor(CGColor(gray: 0, alpha: (openings.last?.1.dimPercent ?? 45) / 100))
        context.fill(bounds)
    }

    private static func effectAmount(_ style: EditorToolDefaults.Redact) -> CGFloat {
        style.style == .pixelate ? (4 + style.strength * 44).rounded() : 2 + style.strength * 28
    }

    /// How far a blur or pixelation reads beyond its region. Preview invalidation spreads edits by
    /// the same distance, so the canvas redraws everything an effect changes.
    static func effectPadding(_ style: EditorToolDefaults.Redact) -> CGFloat {
        let amount = effectAmount(style)
        return style.style == .pixelate ? amount * 2 : ceil(amount * 3)
    }

    static func textFont(_ style: EditorToolDefaults.Text) -> CTFont {
        let weight: NSFont.Weight = switch style.weight { case .regular: .regular; case .semibold: .semibold; case .bold: .bold }
        let font = style.design == .monospaced ? NSFont.monospacedSystemFont(ofSize: style.size, weight: weight)
                                              : NSFont.systemFont(ofSize: style.size, weight: weight)
        return font as CTFont
    }

    private static func drawText(_ text: String, rect: CGRect, style: EditorToolDefaults.Text, context: CGContext) {
        guard !text.isEmpty, rect.width > 0, rect.height > 0 else { return }
        context.saveGState()
        defer { context.restoreGState() }
        let padding = style.treatment == .label ? max(4, style.size * 0.2) : 0
        if style.treatment == .label {
            context.setFillColor(style.color.cgColor)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: padding, cornerHeight: padding, transform: nil))
            context.fillPath()
        }
        let foreground = style.treatment == .label ? RGBAColor.white : style.color
        var attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): textFont(style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground.cgColor
        ]
        if style.treatment == .outlined {
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -4.0
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = RGBAColor.white.cgColor
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let textRect = rect.insetBy(dx: padding, dy: padding)
        guard textRect.width > 0, textRect.height > 0 else { return }
        context.translateBy(x: textRect.minX, y: textRect.maxY); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: CGRect(origin: .zero, size: textRect.size), transform: nil), nil)
        CTFrameDraw(frame, context)
    }

    private static func drawCounterNumber(_ number: Int, in rect: CGRect, context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        var style = EditorToolDefaults.Text()
        style.size = rect.height * 0.54; style.weight = .bold
        let string = String(number)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): textFont(style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): RGBAColor.white.cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
        let box = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        let scale = min(1, rect.width * 0.75 / max(1, box.width))
        context.translateBy(x: rect.midX, y: rect.midY); context.scaleBy(x: scale, y: -scale)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -box.midX, y: -box.midY)
        CTLineDraw(line, context)
    }
}
