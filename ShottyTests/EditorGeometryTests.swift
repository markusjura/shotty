import XCTest
@testable import Shotty

final class EditorGeometryTests: XCTestCase {
    private let limit = CGRect(x: 0, y: 0, width: 1000, height: 800)

    func testNearestVisibleOutlineWinsAndHollowInteriorsDoNotBlock() {
        let hollow = Annotation(content: .rectangle(rect: CGRect(x: 0, y: 0, width: 400, height: 400), style: .init(width: 4)))
        var filledStyle = EditorToolDefaults.Rectangle(); filledStyle.fillColor = .black
        let filled = Annotation(content: .rectangle(rect: CGRect(x: 100, y: 100, width: 50, height: 50), style: filledStyle))
        let line = Annotation(content: .line(start: CGPoint(x: 10, y: 200), end: CGPoint(x: 390, y: 200), style: .init(width: 4)))
        let annotations = [filled, hollow, line]
        // Inside the topmost hollow rectangle, the filled rectangle beneath is still hit.
        XCTAssertEqual(EditorGeometry.hit(CGPoint(x: 120, y: 120), in: annotations, tolerance: 6)?.id, filled.id)
        XCTAssertNil(EditorGeometry.hit(CGPoint(x: 300, y: 100), in: annotations, tolerance: 6))
        // Near both the hollow outline (x = 0, 3 px) and the line's start (7 px away), the nearer outline wins.
        XCTAssertEqual(EditorGeometry.hit(CGPoint(x: 3, y: 200), in: annotations, tolerance: 6)?.id, hollow.id)
        XCTAssertEqual(EditorGeometry.hit(CGPoint(x: 200, y: 204), in: annotations, tolerance: 6)?.id, line.id)
    }

    func testCurvedArrowHitsAlongItsDrawnCurve() {
        var style = EditorToolDefaults.Arrow(width: 4); style.style = .curved
        let start = CGPoint(x: 0, y: 0), end = CGPoint(x: 200, y: 0)
        let arrow = Annotation(content: .arrow(start: start, end: end, bend: nil, style: style))
        let control = EditorGeometry.defaultBend(start: start, end: end)
        let apex = CGPoint(x: 100, y: control.y / 2)   // Quadratic midpoint lies halfway to the control.
        XCTAssertEqual(EditorGeometry.distance(from: apex, to: arrow), 0, accuracy: 0.5)
        XCTAssertGreaterThan(EditorGeometry.distance(from: CGPoint(x: 100, y: 0), to: arrow), 15,
                             "The straight chord is not part of a curved arrow")
    }

    func testCounterHandlesChangeSizeWithinTheStyleRange() {
        let counter = Annotation(content: .counter(center: CGPoint(x: 100, y: 100), number: 3, style: .init(size: 28)))
        guard case .edges(let corner) = EditorGeometry.handles(for: counter)[2].0 else { return XCTFail("Corner handle") }
        let grown = EditorGeometry.resized(counter, handle: .edges(corner), delta: CGVector(dx: 16, dy: 2), limit: limit)
        guard case .counter(let center, let number, let style) = grown.content else { return XCTFail() }
        XCTAssertEqual(center, CGPoint(x: 100, y: 100))
        XCTAssertEqual(number, 3)
        XCTAssertEqual(style.size, 60)
        let huge = EditorGeometry.resized(counter, handle: .edges(corner), delta: CGVector(dx: 500, dy: 0), limit: limit)
        if case .counter(_, _, let style) = huge.content { XCTAssertEqual(style.size, 96) }
    }

    func testEdgeResizeMovesOneSideAndStaysInsideTheImage() {
        let redact = Annotation(content: .redact(rect: CGRect(x: 900, y: 10, width: 50, height: 50), style: .init()))
        let wider = EditorGeometry.resized(redact, handle: .edges(.right), delta: CGVector(dx: 300, dy: 40), limit: limit)
        XCTAssertEqual(wider.bounds, CGRect(x: 900, y: 10, width: 100, height: 50))
        var style = EditorToolDefaults.Arrow(width: 4); style.style = .curved
        let arrow = Annotation(content: .arrow(start: .zero, end: CGPoint(x: 100, y: 0), bend: nil, style: style))
        let bent = EditorGeometry.resized(arrow, handle: .point(2), delta: CGVector(dx: 0, dy: -5000), limit: limit)
        guard case .arrow(_, _, let bend?, _) = bent.content else { return XCTFail("Dragging the bend handle stores a bend") }
        XCTAssertEqual(bend.y, 0, "Bend handles clamp to the image")
    }

    func testMovesClampAndMarqueeRecomputesFromItsBase() {
        let moving = CGRect(x: 950, y: 10, width: 40, height: 40)
        XCTAssertEqual(EditorGeometry.clampedOffset(CGSize(width: 100, height: -50), moving: moving, within: limit),
                       CGSize(width: 10, height: -10))
        let a = Annotation(content: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10), style: .init()))
        let b = Annotation(content: .rectangle(rect: CGRect(x: 50, y: 50, width: 10, height: 10), style: .init()))
        let kept = UUID()
        XCTAssertEqual(EditorGeometry.marqueeSelection(base: [kept], rect: CGRect(x: -1, y: -1, width: 70, height: 70),
                                                       annotations: [a, b]), [kept, a.id, b.id])
        XCTAssertEqual(EditorGeometry.marqueeSelection(base: [kept], rect: CGRect(x: -1, y: -1, width: 20, height: 20),
                                                       annotations: [a, b]), [kept, a.id], "Shrinking deselects")
    }

    /// CleanShot's text box: side handles rewrap at a new width, the corner scales the font.
    func testTextSideHandlesRewrapAndCornerHandleScalesTheFont() {
        var style = EditorToolDefaults.Text(); style.size = 32
        let text = "Hello text"
        let wide = EditorGeometry.textRect(text, style: style, origin: CGPoint(x: 100, y: 100), width: 400)
        let annotation = Annotation(content: .text(rect: wide, text: text, style: style))
        XCTAssertEqual(EditorGeometry.handles(for: annotation).map(\.0), [.edges(.left), .edges(.right), .textSize])

        let narrow = EditorGeometry.resized(annotation, handle: .edges(.right), delta: CGVector(dx: -300, dy: 0), limit: limit)
        guard case .text(let narrowRect, _, let narrowStyle) = narrow.content else { return XCTFail() }
        XCTAssertEqual(narrowRect.width, 100)
        XCTAssertGreaterThan(narrowRect.height, wide.height, "Narrower text wraps onto more lines")
        XCTAssertEqual(narrowStyle.size, 32)

        let grown = EditorGeometry.resized(annotation, handle: .textSize, delta: CGVector(dx: 400, dy: wide.height), limit: limit)
        guard case .text(let grownRect, _, let grownStyle) = grown.content else { return XCTFail() }
        XCTAssertEqual(grownStyle.size, 64, "Dragging the corner one box diagonal doubles the size")
        XCTAssertEqual(grownRect.width, 800, "The wrap width scales with the font")
        XCTAssertEqual(grownRect.origin, wide.origin)
    }

    func testGroupScalingKeepsStylesAndArrangementKeepsRelativeOrder() {
        let rect = Annotation(content: .rectangle(rect: CGRect(x: 0, y: 0, width: 10, height: 10), style: .init()))
        let counter = Annotation(content: .counter(center: CGPoint(x: 20, y: 20), number: 1, style: .init(size: 28)))
        let scaled = EditorGeometry.scaled([rect, counter], from: CGRect(x: 0, y: 0, width: 34, height: 34),
                                           to: CGRect(x: 0, y: 0, width: 68, height: 68))
        XCTAssertEqual(scaled[0].bounds, CGRect(x: 0, y: 0, width: 20, height: 20))
        guard case .counter(let center, _, let style) = scaled[1].content else { return XCTFail() }
        XCTAssertEqual(center, CGPoint(x: 40, y: 40))
        XCTAssertEqual(style.size, 28)

        let items = (0..<5).map { _ in Annotation(content: .counter(center: .zero, number: 1, style: .init())) }
        let ids = items.map(\.id), chosen: Set = [ids[1], ids[3]]
        XCTAssertEqual(EditorGeometry.arranged(items, selected: chosen, .front).map(\.id), [ids[0], ids[2], ids[4], ids[1], ids[3]])
        XCTAssertEqual(EditorGeometry.arranged(items, selected: chosen, .back).map(\.id), [ids[1], ids[3], ids[0], ids[2], ids[4]])
        XCTAssertEqual(EditorGeometry.arranged(items, selected: chosen, .forward).map(\.id), [ids[0], ids[2], ids[1], ids[4], ids[3]])
        XCTAssertEqual(EditorGeometry.arranged(items, selected: chosen, .backward).map(\.id), [ids[1], ids[0], ids[3], ids[2], ids[4]])
    }

    func testDirtyRectsCoverOldAndNewGeometryAndGlobalSpotlightChanges() {
        let original = Annotation(content: .rectangle(rect: CGRect(x: 10, y: 10, width: 20, height: 20), style: .init()))
        let moved = original.translated(by: CGSize(width: 500, height: 0))
        let rects = EditorGeometry.dirtyRects(from: [original], to: [moved], bounds: limit)
        XCTAssertEqual(rects.count, 2)
        XCTAssertTrue(rects.contains { $0.contains(original.bounds) })
        XCTAssertTrue(rects.contains { $0.contains(moved.bounds) })
        XCTAssertEqual(EditorGeometry.dirtyRects(from: [original], to: [original], bounds: limit), [])
        let spotlight = Annotation(content: .spotlight(rect: CGRect(x: 0, y: 0, width: 5, height: 5), style: .init()))
        XCTAssertEqual(EditorGeometry.dirtyRects(from: [], to: [spotlight], bounds: limit), [limit],
                       "The first spotlight dims the whole image")
    }

    func testDirtyRectsPropagateThroughNearbyAndOverlappingEffectSamples() {
        let rectangle = Annotation(content: .rectangle(rect: CGRect(x: 100, y: 100, width: 10, height: 10), style: .init()))
        var restyled = rectangle
        restyled.content = .rectangle(rect: rectangle.bounds, style: .init(strokeColor: .black))
        // The first blur does not overlap the original dirty rectangle, but samples its pixels.
        let first = Annotation(content: .redact(rect: CGRect(x: 145, y: 90, width: 80, height: 40),
                                                style: .init(style: .blur, strength: 1)))
        // This one samples the first blur, propagating changes beyond a single 96px expansion.
        let second = Annotation(content: .redact(rect: CGRect(x: 215, y: 90, width: 100, height: 40),
                                                 style: .init(style: .blur, strength: 1)))
        let dirty = EditorGeometry.dirtyRects(from: [rectangle, first, second], to: [restyled, first, second], bounds: limit)
        XCTAssertTrue(dirty.contains { $0.contains(CGPoint(x: 160, y: 105)) })
        XCTAssertTrue(dirty.contains { $0.contains(CGPoint(x: 280, y: 105)) })
        XCTAssertFalse(dirty.contains { $0.contains(CGPoint(x: 900, y: 700)) })
    }

    func testDirtyInfluenceRespectsEffectCompositionOrder() {
        let rectangle = Annotation(content: .rectangle(rect: CGRect(x: 100, y: 100, width: 10, height: 10), style: .init()))
        var restyled = rectangle
        restyled.content = .rectangle(rect: rectangle.bounds, style: .init(strokeColor: .black))
        let near = Annotation(content: .redact(rect: CGRect(x: 145, y: 90, width: 80, height: 40), style: .init(style: .blur, strength: 1)))
        let far = Annotation(content: .redact(rect: CGRect(x: 215, y: 90, width: 100, height: 40), style: .init(style: .blur, strength: 1)))
        let dirty = EditorGeometry.dirtyRects(from: [rectangle, far, near], to: [restyled, far, near], bounds: limit)
        XCTAssertFalse(dirty.contains { $0.contains(CGPoint(x: 280, y: 105)) }, "An earlier blur cannot sample a later blur's output")
    }

    func testShiftResizePreservesProportionsAndFixedAnchorAtImageBoundary() {
        let rectangle = Annotation(content: .rectangle(rect: CGRect(x: 100, y: 100, width: 200, height: 100), style: .init()))
        let grown = EditorGeometry.resized(rectangle, handle: .edges([.right, .top]), delta: CGVector(dx: 300, dy: 40),
                                           limit: limit, constrained: true)
        XCTAssertEqual(grown.bounds.origin, rectangle.bounds.origin)
        XCTAssertEqual(grown.bounds.width / grown.bounds.height, 2, accuracy: 0.000_001)
        XCTAssertEqual(grown.bounds.width, 500)
        let bounded = EditorGeometry.resized(rectangle, handle: .edges([.right, .top]), delta: CGVector(dx: 2_000, dy: 100),
                                             limit: limit, constrained: true)
        XCTAssertTrue(limit.contains(bounded.bounds))
        XCTAssertEqual(bounded.bounds.width / bounded.bounds.height, 2, accuracy: 0.000_001)
        XCTAssertEqual(bounded.bounds.maxX, limit.maxX)
        let side = EditorGeometry.resized(rectangle, handle: .edges(.right), delta: CGVector(dx: 100, dy: 500),
                                          limit: limit, constrained: true)
        XCTAssertEqual(side.bounds.minX, rectangle.bounds.minX)
        XCTAssertEqual(side.bounds.midY, rectangle.bounds.midY)
        XCTAssertEqual(side.bounds.width / side.bounds.height, 2, accuracy: 0.000_001)
    }

    func testShiftEndpointResizeSnapsAngleWithoutBreakingAtImageEdge() {
        let line = Annotation(content: .line(start: CGPoint(x: 900, y: 700), end: CGPoint(x: 920, y: 720), style: .init()))
        let result = EditorGeometry.resized(line, handle: .point(1), delta: CGVector(dx: 180, dy: 60), limit: limit, constrained: true)
        guard case .line(let start, let end, _) = result.content else { return XCTFail("Line retained") }
        XCTAssertEqual(start, CGPoint(x: 900, y: 700))
        XCTAssertEqual(end.x - start.x, end.y - start.y, accuracy: 0.000_001)
        XCTAssertLessThanOrEqual(end.x, limit.maxX)
        XCTAssertLessThanOrEqual(end.y, limit.maxY)

        let arrow = Annotation(content: .arrow(start: CGPoint(x: 10, y: 20), end: CGPoint(x: 200, y: 100), bend: nil, style: .init()))
        let snapped = EditorGeometry.resized(arrow, handle: .point(0), delta: CGVector(dx: 50, dy: 15), limit: limit, constrained: true)
        guard case .arrow(let a, let b, _, _) = snapped.content else { return XCTFail("Arrow retained") }
        let angle = atan2(a.y - b.y, a.x - b.x) / (.pi / 4)
        XCTAssertEqual(angle, angle.rounded(), accuracy: 0.000_001)
        XCTAssertEqual(b, CGPoint(x: 200, y: 100))
    }
}
