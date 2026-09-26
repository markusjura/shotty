import AppKit
import SwiftUI

/// Style-menu samples drawn once by the canonical `DocumentRenderer`, so every choice previews
/// what the editor exports. Each family uses one fixed synthetic sample and the default annotation
/// color; nothing is rendered per view update.
@MainActor
enum EditorStyleSamples {
    /// Pixels of each sample; shown at 2× so it stays sharp on Retina menus.
    private static let pixelSize = CGSize(width: 96, height: 40)

    static let redaction: [RedactStyle: NSImage] = render(RedactStyle.allCases, on: contentSample) { style in
        var redact = EditorToolDefaults.Redact()
        redact.style = style
        redact.strength = 0.2
        return .redact(rect: CGRect(x: 6, y: 5, width: 84, height: 30), style: redact)
    }

    static let arrows: [ArrowStyle: NSImage] = render(ArrowStyle.allCases, on: clearSample) { style in
        var arrow = EditorToolDefaults.Arrow()
        arrow.width = 4
        arrow.style = style
        return .arrow(start: CGPoint(x: 14, y: 30), end: CGPoint(x: 82, y: 10), bend: nil, style: arrow)
    }

    static let textTreatments: [TextTreatment: NSImage] = render(TextTreatment.allCases, on: clearSample) { treatment in
        var text = EditorToolDefaults.Text()
        text.size = 22
        text.treatment = treatment
        return .text(rect: CGRect(x: 22, y: 3, width: 52, height: 34), text: "Aa", style: text)
    }

    static let spotlightShapes: [SpotlightShape: NSImage] = render(SpotlightShape.allCases, on: contentSample) { shape in
        var spotlight = EditorToolDefaults.Spotlight()
        spotlight.shape = shape
        return .spotlight(rect: CGRect(x: 24, y: 7, width: 48, height: 26), style: spotlight)
    }

    private static func render<Option: Hashable>(_ options: [Option], on source: CGImage?,
                                                  content: (Option) -> AnnotationContent) -> [Option: NSImage] {
        guard let source else { return [:] }
        let renderer = DocumentRenderer()
        var samples: [Option: NSImage] = [:]
        for option in options {
            let document = AnnotationDocument(annotations: [Annotation(content: content(option))])
            guard let image = try? renderer.render(source: source, state: document) else { continue }
            samples[option] = NSImage(cgImage: image, size: CGSize(width: image.width / 2, height: image.height / 2))
        }
        return samples
    }

    /// Light page with text and colored marks, so blur, pixelation, and dimming are all visible.
    private static let contentSample: CGImage? = drawSample { context in
        context.setFillColor(CGColor(gray: 0.96, alpha: 1))
        context.fill(CGRect(origin: .zero, size: pixelSize))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.45, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 8, y: 6, width: 18, height: 28))
        context.setFillColor(CGColor(srgbRed: 0.95, green: 0.6, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 30, y: 6, width: 10, height: 12))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        ("Aa 42" as NSString).draw(at: CGPoint(x: 44, y: 10), withAttributes: [
            .font: NSFont.systemFont(ofSize: 17, weight: .bold), .foregroundColor: NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static let clearSample: CGImage? = drawSample { _ in }

    private static func drawSample(_ draw: (CGContext) -> Void) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(pixelSize.width), height: Int(pixelSize.height), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(context)
        return context.makeImage()
    }
}
