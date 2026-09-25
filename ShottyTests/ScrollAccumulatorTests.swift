import CoreGraphics
import ImageIO
import XCTest
@testable import Shotty

final class ScrollAccumulatorTests: XCTestCase {
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    func testUnchangedReverseMovementAccumulatesExactOutput() async throws {
        for (axis, offsets) in [(ScrollAxis.vertical, [100, 123, 109, 93, 115, 132]),
                                (.horizontal, [100, 80, 95, 117, 97, 77])] {
            let accumulator = ScrollAccumulator()
            for offset in offsets {
                let progress = try await accumulator.accept(image(try frame(axis: axis, offset: offset)))
                XCTAssertFalse(progress.paused, "\(axis) offset \(offset): \(progress.message)")
            }
            try await assertOutput(of: accumulator, axis: axis, from: offsets.min()!, to: offsets.max()!)
            await accumulator.discard()
        }
    }

    /// The aligner only sees the previous viewport. Rows it cannot see must still match the
    /// accepted output, whether revisited in reverse or retained ahead after a reverse.
    func testChangedAcceptedRowsPauseWithoutAlteringTheResult() async throws {
        for axis in ScrollAxis.allCases {
            let accumulator = ScrollAccumulator()
            for offset in [100, 130, 160] {
                _ = try await accumulator.accept(image(try frame(axis: axis, offset: offset)))
            }
            // Row 135 left the viewport at 160; row 230 was accepted at 160 but is not visible at 130.
            for (offset, changedRow) in [(130, 135), (170, 230)] {
                let changed = try await accumulator.accept(image(try frame(axis: axis, offset: offset, changedRow: changedRow)))
                XCTAssertTrue(changed.paused, "\(axis) offset \(offset) must not accept a changed row")
                XCTAssertEqual(changed.dimensions, try size(axis: axis, extent: 96 + 60))
                let recovered = try await accumulator.accept(image(try frame(axis: axis, offset: offset)))
                XCTAssertFalse(recovered.paused, recovered.message)
            }
            try await assertOutput(of: accumulator, axis: axis, from: 100, to: 170)
            await accumulator.discard()
        }
    }

    func testConfiguredLengthCapPausesWithItsReasonAndKeepsTheResult() async throws {
        let accumulator = ScrollAccumulator(axis: .vertical, limits: ScrollLimits(maximumAxisPixels: 120))
        for offset in [100, 120] {
            let progress = try await accumulator.accept(image(try frame(axis: .vertical, offset: offset)))
            XCTAssertNil(progress.rejection)
        }
        let capped = try await accumulator.accept(image(try frame(axis: .vertical, offset: 130)))
        XCTAssertTrue(capped.paused)
        XCTAssertEqual(capped.rejection, .lengthLimit)
        XCTAssertEqual(capped.dimensions, try size(axis: .vertical, extent: 116))
        let rendered = try await accumulator.renderImage()
        XCTAssertEqual(rendered.height, 116)
        await accumulator.discard()
    }

    private func assertOutput(of accumulator: ScrollAccumulator, axis: ScrollAxis, from minimum: Int, to maximum: Int,
                              file: StaticString = #filePath, line: UInt = #line) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-accumulator-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try await accumulator.exportPNG(to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let expected = try frame(axis: axis, offset: minimum, extent: 96 + maximum - minimum)
        XCTAssertEqual(try ScrollFrame(image: decoded).pixels, expected.pixels,
                       "Output must equal the continuous source", file: file, line: line)
    }

    private func size(axis: ScrollAxis, extent: Int) throws -> CGSize {
        axis == .vertical ? CGSize(width: 40, height: extent) : CGSize(width: extent, height: 40)
    }

    private func image(_ frame: ScrollFrame) throws -> CGImage {
        let bytes = frame.pixels.map(\.bigEndian).withUnsafeBytes { Data($0) }
        let provider = try XCTUnwrap(CGDataProvider(data: bytes as CFData))
        return try XCTUnwrap(CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: frame.width * 4, space: colorSpace,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                                                        | CGBitmapInfo.byteOrder32Big.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// A viewport onto a continuous document with sticky chrome; `changedRow` re-renders one document row.
    private func frame(axis: ScrollAxis, offset: Int, extent: Int = 96, changedRow: Int? = nil,
                       leading: Int = 6, trailing: Int = 5) throws -> ScrollFrame {
        let width = axis == .vertical ? 40 : extent
        let height = axis == .vertical ? extent : 40
        let pixels = (0..<(width * height)).map { index -> UInt32 in
            let along = axis == .vertical ? index / width : index % width
            let cross = axis == .vertical ? index % width : index / width
            if along < leading { return color(row: -1_000 + along, cross: cross) }
            if along >= extent - trailing { return color(row: -2_000 + along - extent + trailing, cross: cross) }
            let row = offset + along - leading
            return color(row: row == changedRow ? row + 50_000 : row, cross: cross)
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
