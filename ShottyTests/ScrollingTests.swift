import XCTest
@testable import Shotty

final class ScrollingTests: XCTestCase {
    func testAutomationRequiresExplicitStartAndSupportsPauseResume() {
        var state = ScrollInputState()
        state.handle(.toggleAutomaticPause)
        XCTAssertEqual(state.mode, .undecided)
        XCTAssertFalse(state.mayInjectScroll)
        XCTAssertTrue(state.offersAutoScroll)
        state.handle(.startAutomatic)
        XCTAssertTrue(state.mayInjectScroll)
        XCTAssertFalse(state.offersAutoScroll)
        state.handle(.scroll(.shottyInjected))
        XCTAssertEqual(state.mode, .automaticRunning)
        state.handle(.toggleAutomaticPause)
        XCTAssertEqual(state.mode, .automaticPaused)
        XCTAssertFalse(state.mayInjectScroll)
        state.handle(.toggleAutomaticPause)
        XCTAssertTrue(state.mayInjectScroll)
        state.handle(.pauseAutomatic)
        state.handle(.pauseAutomatic)
        XCTAssertEqual(state.mode, .automaticPaused)
    }

    func testPhysicalScrollPermanentlyLocksEveryAutomationState() {
        for initialActions: [ScrollInputAction] in [[], [.startAutomatic], [.startAutomatic, .pauseAutomatic]] {
            var state = ScrollInputState()
            for action in initialActions { state.handle(action) }
            state.handle(.scroll(.physical))
            XCTAssertEqual(state.mode, .manualOnly)
            for action: ScrollInputAction in [.startAutomatic, .toggleAutomaticPause, .pauseAutomatic, .scroll(.shottyInjected)] {
                state.handle(action)
                XCTAssertEqual(state.mode, .manualOnly)
                XCTAssertFalse(state.mayInjectScroll)
                XCTAssertFalse(state.offersAutoScroll)
            }
        }
        XCTAssertTrue(ScrollInputState().offersAutoScroll)
    }

    func testVerticalStitchHasNoMissingOrDuplicatedRows() throws {
        try assertStitch(axis: .vertical, offsets: [100, 116, 139, 164])
    }

    func testHorizontalStitchHasNoMissingOrDuplicatedColumns() throws {
        try assertStitch(axis: .horizontal, offsets: [100, 119, 142, 162])
    }

    func testStationaryBandsOccurOnlyAtOutputEdges() throws {
        try assertStitch(axis: .vertical, offsets: [100, 119, 137, 159], leading: 9, trailing: 7)
        try assertStitch(axis: .horizontal, offsets: [100, 119, 137, 159], leading: 9, trailing: 7)
    }

    func testBlankTextRowsAreNotStationaryBands() throws {
        for axis in ScrollAxis.allCases {
            try assertTextStitch(axis: axis, leading: 0, trailing: 0, sparseInk: false)
        }
    }

    func testSparseEdgeInkIsPreservedAlongsideActualStickyBands() throws {
        for axis in ScrollAxis.allCases {
            try assertTextStitch(axis: axis, leading: 0, trailing: 0, sparseInk: true)
            try assertTextStitch(axis: axis, leading: 9, trailing: 7, sparseInk: true)
        }
    }

    func testPaddedChromeDoesNotReplaceDocumentInkWithWhiteRows() throws {
        for axis in ScrollAxis.allCases {
            try assertTextStitch(axis: axis, leading: 30, trailing: 20, sparseInk: false,
                                 offsets: [2, 42, 71], paddedChrome: true)
            try assertTextStitch(axis: axis, leading: 30, trailing: 20, sparseInk: true,
                                 offsets: [60, 99, 71, 42, 2, 42, 71, 100], paddedChrome: true)
        }
    }

    func testAdjacentExactOffsetsAreAmbiguous() throws {
        for axis in ScrollAxis.allCases {
            func viewport(offset: Int) throws -> ScrollFrame {
                let width = axis == .vertical ? 40 : 96
                let height = axis == .vertical ? 96 : 40
                let pixels = (0..<(width * height)).map { index -> UInt32 in
                    let along = axis == .vertical ? index / width : index % width
                    let cross = axis == .vertical ? index % width : index / width
                    let row = offset + along
                    return (47...95).contains(row) ? 0xFFFFFFFF : color(row: row, cross: cross)
                }
                return try ScrollFrame(width: width, height: height, pixels: pixels)
            }
            let first = try viewport(offset: 0)
            let shifted = try viewport(offset: 47)
            XCTAssertEqual(ScrollAligner().align(previous: first, current: shifted, axis: axis),
                           .rejected(.ambiguousContent))
            var session = try ScrollStitchSession(firstFrame: first, axis: axis, startedAt: 0)
            XCTAssertEqual(session.accept(shifted, at: 1), .paused(.ambiguousContent))
            XCTAssertEqual(session.previous.pixels, first.pixels)
            XCTAssertEqual(session.outputAxisPixels, 96)
        }
    }

    func testAppearingChromePausesWithoutChangingTheAcceptedResult() throws {
        let first = try frame(axis: .vertical, offset: 100)
        let accepted = try frame(axis: .vertical, offset: 120)
        var session = try ScrollStitchSession(firstFrame: first, axis: .vertical, startedAt: 0)
        guard case .extended = session.accept(accepted, at: 1) else { return XCTFail("Expected initial scrolling") }
        let newHeader = try frame(axis: .vertical, offset: 140, leading: 9)
        guard case .paused = session.accept(newHeader, at: 2) else {
            return XCTFail("Appearing chrome must not silently change document geometry")
        }
        XCTAssertEqual(session.previous.pixels, accepted.pixels)
        XCTAssertEqual(session.outputAxisPixels, 116)
    }

    func testReverseMovementReusesAcceptedContentAndCanExtendEitherEdge() throws {
        try assertStitch(axis: .vertical, offsets: [100, 123, 109, 93, 115, 132], leading: 6, trailing: 5)
        try assertStitch(axis: .horizontal, offsets: [100, 80, 95, 117, 97, 77], leading: 6, trailing: 5)
    }

    func testRepeatedRowsRejectAnAmbiguousSeam() throws {
        let first = try frame(axis: .vertical, offset: 0, period: 8)
        let next = try frame(axis: .vertical, offset: 3, period: 8)
        XCTAssertEqual(ScrollAligner().align(previous: first, current: next, axis: .vertical),
                       .rejected(.ambiguousContent))
    }

    func testNoOverlapIsRejectedWithoutChangingAcceptedPosition() throws {
        let first = try frame(axis: .vertical, offset: 100)
        var session = try ScrollStitchSession(firstFrame: first, startedAt: 0)
        XCTAssertEqual(session.accept(try frame(axis: .vertical, offset: 300), at: 1),
                       .paused(.insufficientOverlap))
        guard case .extended(let match, _) = session.accept(try frame(axis: .vertical, offset: 119), at: 2) else {
            return XCTFail("A valid frame must recover from the last accepted position")
        }
        XCTAssertEqual(match.displacement, 19)
        XCTAssertEqual(session.outputAxisPixels, 115)
    }

    func testDuplicateFrameDoesNotGrowOutput() throws {
        let first = try frame(axis: .vertical, offset: 100)
        var session = try ScrollStitchSession(firstFrame: first, axis: .vertical, startedAt: 0)
        XCTAssertEqual(session.accept(first, at: 1), .unchanged)
        XCTAssertEqual(session.outputAxisPixels, 96)
    }

    func testChangedDimensionsAreRejected() throws {
        let first = try frame(axis: .vertical, offset: 100)
        let second = try frame(axis: .vertical, offset: 110, extent: 100)
        XCTAssertEqual(ScrollAligner().align(previous: first, current: second), .rejected(.changedDimensions))
    }

    func testAxisChangePausesAfterAxisHasBeenInferred() throws {
        let first = try frame(axis: .vertical, offset: 100)
        var session = try ScrollStitchSession(firstFrame: first, startedAt: 0)
        guard case .extended = session.accept(try frame(axis: .vertical, offset: 119), at: 1) else {
            return XCTFail("Expected the initial vertical movement to infer an axis")
        }
        let pixels = (0..<(first.width * first.height)).map { index in
            color(row: 119 + index / first.width, cross: index % first.width + 8)
        }
        let sideways = try ScrollFrame(width: first.width, height: first.height, pixels: pixels)
        XCTAssertEqual(session.accept(sideways, at: 2), .paused(.axisChanged))
        XCTAssertEqual(session.axis, .vertical)
        XCTAssertEqual(session.outputAxisPixels, 115)
    }

    func testLimitsPreserveThePartialResult() throws {
        let first = try frame(axis: .vertical, offset: 100)
        let next = try frame(axis: .vertical, offset: 120)
        var lengthSession = try ScrollStitchSession(firstFrame: first, axis: .vertical, startedAt: 0,
                                                    limits: ScrollLimits(maximumAxisPixels: 110))
        XCTAssertEqual(lengthSession.accept(next, at: 1), .paused(.lengthLimit))
        XCTAssertEqual(lengthSession.previous.pixels, first.pixels)
        var memorySession = try ScrollStitchSession(firstFrame: first, axis: .vertical, startedAt: 0,
                                                    limits: ScrollLimits(maximumOutputBytes: 110 * first.width * 4))
        XCTAssertEqual(memorySession.accept(next, at: 1), .paused(.memoryLimit))
        XCTAssertEqual(memorySession.outputAxisPixels, 96)
        var timeSession = try ScrollStitchSession(firstFrame: first, startedAt: 10)
        XCTAssertEqual(timeSession.accept(next, at: 130), .paused(.timeLimit))
        XCTAssertEqual(timeSession.previous.pixels, first.pixels)
    }

    func testInvalidFrameAndOverflowAreRejectedBeforeAllocation() {
        XCTAssertThrowsError(try ScrollFrame(width: Int.max, height: 2, pixels: []))
        XCTAssertThrowsError(try ScrollFrame(width: 1, height: -1, pixels: []))
        XCTAssertThrowsError(try ScrollFrame(width: 2, height: 2, pixels: [0]))
    }

    func testChangingContentIsNotAcceptedAsASeam() throws {
        let first = try frame(axis: .vertical, offset: 100)
        let shifted = try frame(axis: .vertical, offset: 120)
        var pixels = shifted.pixels
        for y in 20..<40 {
            for x in 0..<shifted.width { pixels[y * shifted.width + x] = 0xFFFFFFFF }
        }
        let animated = try ScrollFrame(width: shifted.width, height: shifted.height, pixels: pixels)
        guard case .rejected = ScrollAligner().align(previous: first, current: animated) else {
            return XCTFail("Unstable overlapping content must pause capture")
        }
    }

    private func assertStitch(axis: ScrollAxis, offsets: [Int], leading: Int = 0, trailing: Int = 0,
                              file: StaticString = #filePath, line: UInt = #line) throws {
        let first = try frame(axis: axis, offset: offsets[0], leading: leading, trailing: trailing)
        var session = try ScrollStitchSession(firstFrame: first, startedAt: 0)
        var output = strips(first, axis: axis)
        for (index, offset) in offsets.dropFirst().enumerated() {
            let next = try frame(axis: axis, offset: offset, leading: leading, trailing: trailing)
            switch session.accept(next, at: Double(index + 1)) {
            case .extended(let match, let edit):
                XCTAssertEqual(match.axis, axis, file: file, line: line)
                XCTAssertEqual(match.bands, ScrollStationaryBands(leading: leading, trailing: trailing), file: file, line: line)
                let source = Array(strips(next, axis: axis)[edit.sourceRange])
                switch edit.edge {
                case .leading:
                    output.removeFirst(edit.removePixelCount)
                    output.insert(contentsOf: source, at: 0)
                case .trailing:
                    output.removeLast(edit.removePixelCount)
                    output.append(contentsOf: source)
                }
            case .repositioned: break
            default: XCTFail("Expected reliable seam at offset \(offset)", file: file, line: line)
            }
        }
        let minimum = try XCTUnwrap(offsets.min())
        let maximum = try XCTUnwrap(offsets.max())
        let extent = first.extent(along: axis)
        let breadth = first.breadth(along: axis)
        var expected: [[UInt32]] = []
        for coordinate in 0..<leading {
            expected.append((0..<breadth).map { color(row: -1_000 + coordinate, cross: $0) })
        }
        for coordinate in minimum..<(maximum + extent - leading - trailing) {
            expected.append((0..<breadth).map { color(row: coordinate, cross: $0) })
        }
        for coordinate in 0..<trailing {
            expected.append((0..<breadth).map { color(row: -2_000 + coordinate, cross: $0) })
        }
        XCTAssertEqual(output, expected, "Every output pixel must agree with the continuous synthetic source", file: file, line: line)
        XCTAssertEqual(session.outputAxisPixels, expected.count, file: file, line: line)
    }

    private func strips(_ frame: ScrollFrame, axis: ScrollAxis) -> [[UInt32]] {
        (0..<frame.extent(along: axis)).map { row in
            (0..<frame.breadth(along: axis)).map { frame.pixel(along: row, across: $0, axis: axis) }
        }
    }

    private func assertTextStitch(axis: ScrollAxis, leading: Int, trailing: Int, sparseInk: Bool,
                                  offsets: [Int] = [0, 20, 37, 60, 99, 100, 140, 113, 151], paddedChrome: Bool = false,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let frames = try offsets.map {
            try textFrame(axis: axis, offset: $0, leading: leading, trailing: trailing, sparseInk: sparseInk,
                          paddedChrome: paddedChrome)
        }
        var session = try ScrollStitchSession(firstFrame: frames[0], axis: axis, startedAt: 0)
        var output = strips(frames[0], axis: axis)
        for index in 1..<frames.count {
            let step = session.accept(frames[index], at: Double(index))
            switch step {
            case .extended(let match, let edit):
                XCTAssertEqual(match.displacement, offsets[index] - offsets[index - 1], file: file, line: line)
                if paddedChrome {
                    XCTAssertLessThanOrEqual(match.bands.leading, leading, file: file, line: line)
                    XCTAssertLessThanOrEqual(match.bands.trailing, trailing, file: file, line: line)
                    XCTAssertGreaterThanOrEqual(match.replacementBands.leading, leading, file: file, line: line)
                    XCTAssertGreaterThanOrEqual(match.replacementBands.trailing, trailing, file: file, line: line)
                } else {
                    XCTAssertEqual(match.bands, ScrollStationaryBands(leading: leading, trailing: trailing), file: file, line: line)
                }
                let source = Array(strips(frames[index], axis: axis)[edit.sourceRange])
                switch edit.edge {
                case .leading:
                    output.removeFirst(edit.removePixelCount)
                    output.insert(contentsOf: source, at: 0)
                case .trailing:
                    output.removeLast(edit.removePixelCount)
                    output.append(contentsOf: source)
                }
            case .repositioned: break
            default: return XCTFail("Text offset \(offsets[index]) failed: \(step)", file: file, line: line)
            }
            let seen = offsets[...index]
            let minimum = try XCTUnwrap(seen.min())
            let maximum = try XCTUnwrap(seen.max())
            let extent = 300 + maximum - minimum
            let expected = try textFrame(axis: axis, offset: minimum, extent: extent,
                                         leading: leading, trailing: trailing, sparseInk: sparseInk, paddedChrome: paddedChrome)
            XCTAssertEqual(output, strips(expected, axis: axis), "Text and blank rows must survive every accepted edit exactly", file: file, line: line)
            XCTAssertEqual(session.outputAxisPixels, extent, file: file, line: line)
        }
    }

    /// Twelve ink rows per twenty-pixel line, with narrow glyph strokes and white
    /// paragraph gaps. Sparse marks deliberately fall between the old 64 samples.
    private func textFrame(axis: ScrollAxis, offset: Int, extent: Int = 300,
                           leading: Int, trailing: Int, sparseInk: Bool, paddedChrome: Bool = false) throws -> ScrollFrame {
        let breadth = 400
        let width = axis == .vertical ? breadth : extent
        let height = axis == .vertical ? extent : breadth
        let pixels = (0..<(width * height)).map { index -> UInt32 in
            let along = axis == .vertical ? index / width : index % width
            let cross = axis == .vertical ? index % width : index / width
            if along < leading {
                return paddedChrome && along >= leading - 8 ? 0xFFFFFFFF : color(row: -1_000 + along, cross: cross)
            }
            if along >= extent - trailing {
                return paddedChrome && along < extent - trailing + 6 ? 0xFFFFFFFF : color(row: -2_000 + along - extent + trailing, cross: cross)
            }
            let row = offset + along - leading
            if sparseInk && row % 80 == 79 { return cross == 2 ? 0x202020FF : 0xFFFFFFFF }
            guard row % 20 < 12, (20..<380).contains(cross), cross % 9 < 6 else { return 0xFFFFFFFF }
            let glyph = color(row: row / 20, cross: cross / 9)
            let mask = (glyph >> UInt32((row % 12 + cross % 6) % 24)) & 1
            return mask == 0 ? 0xFFFFFFFF : 0x202020FF
        }
        return try ScrollFrame(width: width, height: height, pixels: pixels)
    }

    private func frame(axis: ScrollAxis, offset: Int, extent: Int = 96, breadth: Int = 40,
                       leading: Int = 0, trailing: Int = 0, period: Int? = nil) throws -> ScrollFrame {
        let width = axis == .vertical ? breadth : extent
        let height = axis == .vertical ? extent : breadth
        let pixels = (0..<(width * height)).map { index -> UInt32 in
            let along = axis == .vertical ? index / width : index % width
            let cross = axis == .vertical ? index % width : index / width
            if along < leading { return color(row: -1_000 + along, cross: cross) }
            if along >= extent - trailing { return color(row: -2_000 + along - extent + trailing, cross: cross) }
            let row = offset + along - leading
            return color(row: period.map { row % $0 } ?? row, cross: cross)
        }
        return try ScrollFrame(width: width, height: height, pixels: pixels)
    }

    private func color(row: Int, cross: Int) -> UInt32 {
        var value = UInt32(truncatingIfNeeded: row) &* 747_796_405 &+ UInt32(cross) &* 2_891_336_453
        value = (value ^ (value >> 16)) &* 2_246_822_519
        value = (value ^ (value >> 13)) &* 3_266_489_917
        return (value & 0xFFFFFF00) | 255
    }
}
