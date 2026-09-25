import CoreGraphics
import XCTest
@testable import Shotty

final class DocumentRendererTests: XCTestCase {
    private let size = 96

    private func source(solid: Bool = false) throws -> CGImage {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        if !solid {
            for y in 0..<size {
                for x in 0..<size {
                    let offset = (y * size + x) * 4
                    bytes[offset] = UInt8((x * 17 + y * 31) % 255)
                    bytes[offset + 1] = UInt8((x * 3 + y * 47) % 255)
                    bytes[offset + 2] = UInt8((x * 23 + y * 11) % 255)
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    func testSolidRedactionHasExactOpaqueCoverageAndCropRemovesOutsidePixels() throws {
        let renderer = DocumentRenderer()
        let original = try source()
        let state = AnnotationDocument(annotations: [Annotation(content: .redact(rect: CGRect(x: 3.2, y: 5.2, width: 18.2, height: 12.2),
                                                                                style: .init(style: .solid, solidColor: RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.2))))])
        let output = try renderer.render(source: original, state: state)
        let pixels = try rgba(output), previous = try rgba(original)
        for y in 0..<size {
            for x in 0..<size {
                let expected = (3..<22).contains(x) && (5..<18).contains(y) ? [UInt8(0), 0, 0, 255] : pixel(previous, x, y)
                XCTAssertEqual(pixel(pixels, x, y), expected, "Pixel \(x),\(y)")
            }
        }
        var cropped = state; cropped.crop = CGRect(x: 3, y: 5, width: 19, height: 13)
        let crop = try renderer.render(source: original, state: cropped)
        XCTAssertEqual(crop.width, 19)
        XCTAssertEqual(crop.height, 13)
        XCTAssertTrue(try rgba(crop).enumerated().allSatisfy { $0.offset % 4 == 3 ? $0.element == 255 : $0.element == 0 })
    }

    func testPixelateGridIsStableWhenRegionMovesAndResizes() throws {
        let renderer = DocumentRenderer(), original = try source()
        let style = EditorToolDefaults.Redact(style: .pixelate, strength: 0.4)
        let first = AnnotationDocument(annotations: [Annotation(content: .redact(rect: CGRect(x: 8, y: 10, width: 50, height: 42), style: style))])
        let second = AnnotationDocument(annotations: [Annotation(content: .redact(rect: CGRect(x: 12, y: 6, width: 60, height: 70), style: style))])
        let a = try rgba(renderer.render(source: original, state: first))
        let b = try rgba(renderer.render(source: original, state: second))
        let unedited = try rgba(original)
        for y in 10..<52 { for x in 12..<58 { XCTAssertEqual(pixel(a, x, y), pixel(b, x, y)) } }
        XCTAssertNotEqual(pixel(a, 30, 30), pixel(unedited, 30, 30))
        XCTAssertEqual(pixel(a, 2, 2), pixel(unedited, 2, 2))
    }

    func testBlurPadsImageEdgesAndRecomputesFromImmutableComposition() throws {
        let renderer = DocumentRenderer(), original = try source(solid: true)
        let style = EditorToolDefaults.Redact(style: .blur, strength: 0.8)
        let state = AnnotationDocument(annotations: [Annotation(content: .redact(rect: CGRect(x: 0, y: 0, width: 40, height: 40), style: style))])
        let first = try rgba(renderer.render(source: original, state: state))
        let second = try rgba(renderer.render(source: original, state: state))
        XCTAssertEqual(first, second)
        for y in 0..<40 { for x in 0..<40 { XCTAssertEqual(pixel(first, x, y), [255, 255, 255, 255]) } }
    }

    func testSpotlightsFormUnionAndCountersRemainAboveDimAndOtherAnnotations() throws {
        let renderer = DocumentRenderer(), original = try source(solid: true)
        let spotlight = EditorToolDefaults.Spotlight(shape: .rectangle, dimPercent: 50)
        var state = AnnotationDocument(annotations: [
            Annotation(content: .counter(center: CGPoint(x: 80, y: 80), number: 1, style: .init(color: .annotationRed, size: 24))),
            Annotation(content: .redact(rect: CGRect(x: 70, y: 70, width: 24, height: 24), style: .init(style: .solid))),
            Annotation(content: .spotlight(rect: CGRect(x: 10, y: 10, width: 35, height: 35), style: spotlight)),
            Annotation(content: .spotlight(rect: CGRect(x: 30, y: 30, width: 35, height: 35), style: spotlight))
        ])
        let result = try rgba(renderer.render(source: original, state: state))
        XCTAssertEqual(pixel(result, 20, 20), [255, 255, 255, 255])
        XCTAssertEqual(pixel(result, 35, 35), [255, 255, 255, 255])
        XCTAssertEqual(pixel(result, 55, 55), [255, 255, 255, 255])
        XCTAssertEqual(Int(pixel(result, 3, 3)[0]), 128, accuracy: 1)
        // Inside the counter's red body, away from its white number and outline.
        XCTAssertGreaterThan(pixel(result, 73, 80)[0], 240)
        state.annotations.removeAll { $0.tool == .counter }
        let without = try rgba(renderer.render(source: original, state: state))
        XCTAssertEqual(pixel(without, 73, 80), [0, 0, 0, 255])
    }

    func testAllVectorStylesRenderAndGeometryTransformPreservesStyle() throws {
        let renderer = DocumentRenderer(), original = try source(solid: true)
        var annotations: [Annotation] = []
        for (index, arrowStyle) in ArrowStyle.allCases.enumerated() {
            annotations.append(Annotation(content: .arrow(start: CGPoint(x: 5, y: 10 + index * 15), end: CGPoint(x: 60, y: 10 + index * 15),
                                                           bend: CGPoint(x: 25, y: 4), style: .init(style: arrowStyle))))
        }
        annotations += [
            Annotation(content: .rectangle(rect: CGRect(x: 5, y: 55, width: 20, height: 20), style: .init(fillColor: .black, cornerRadius: 3))),
            Annotation(content: .ellipse(rect: CGRect(x: 30, y: 55, width: 20, height: 20), style: .init())),
            Annotation(content: .line(start: CGPoint(x: 55, y: 55), end: CGPoint(x: 75, y: 75), style: .init()))
        ]
        for (index, treatment) in TextTreatment.allCases.enumerated() {
            annotations.append(Annotation(content: .text(rect: CGRect(x: 66, y: index * 25, width: 30, height: 24), text: "A",
                                                          style: .init(size: 12, treatment: treatment))))
        }
        let rendered = try renderer.render(source: original, state: AnnotationDocument(annotations: annotations))
        XCTAssertNotEqual(try rgba(rendered), try rgba(original))
        let translated = annotations[0].translated(by: CGSize(width: 4, height: 6))
        XCTAssertEqual(translated.id, annotations[0].id)
        XCTAssertEqual(translated.bounds.origin.x, annotations[0].bounds.origin.x + 4)
        XCTAssertEqual(translated.bounds.origin.y, annotations[0].bounds.origin.y + 6)
        let roundTrip = try JSONDecoder().decode(AnnotationDocument.self, from: JSONEncoder().encode(AnnotationDocument(annotations: annotations)))
        XCTAssertEqual(roundTrip.annotations, annotations)
    }

    func testBoundedRegionMatchesFullRenderThroughOverlappingEffectsAndSpotlight() throws {
        let renderer = DocumentRenderer(), original = try source()
        var state = AnnotationDocument(annotations: [
            Annotation(content: .rectangle(rect: CGRect(x: 18, y: 16, width: 25, height: 25), style: .init(fillColor: .annotationRed))),
            Annotation(content: .redact(rect: CGRect(x: 8, y: 8, width: 45, height: 40), style: .init(style: .blur, strength: 0))),
            Annotation(content: .redact(rect: CGRect(x: 14, y: 12, width: 35, height: 40), style: .init(style: .pixelate, strength: 0))),
            Annotation(content: .redact(rect: CGRect(x: 20, y: 18, width: 40, height: 40), style: .init(style: .blur, strength: 0))),
            Annotation(content: .spotlight(rect: CGRect(x: 25, y: 21, width: 15, height: 15), style: .init(shape: .ellipse)))
        ])
        let full = try renderer.render(source: original, state: state)
        let region = CGRect(x: 22, y: 19, width: 15, height: 17)
        let expected = try XCTUnwrap(full.cropping(to: region))
        // Region previews deliberately ignore the document crop.
        state.crop = CGRect(x: 0, y: 0, width: 8, height: 8)
        let tile = try renderer.render(source: original, state: state, region: region)
        XCTAssertEqual(tile.width, 15)
        XCTAssertEqual(tile.height, 17)
        XCTAssertEqual(try rgba(tile), try rgba(expected))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { data in
            guard let context = CGContext(data: data.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                                          bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(success)
        return bytes
    }

    private func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int) -> [UInt8] {
        let offset = (y * size + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }
}
