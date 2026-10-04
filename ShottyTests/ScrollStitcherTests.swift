import CoreGraphics
import XCTest
@testable import Shotty

final class ScrollStitcherTests: XCTestCase {
    func testFastUnevenAndReverseScrollingProducesTheExactDocument() throws {
        let offsets = [0, 37, 220, 221, 440, 400, 660, 610, 900]
        let output = try stitch(offsets.map { document(offset: $0) })
        assertSame(output, document(offset: 0, extent: 900 + 300))
    }

    func testStickyHeaderAndFooterAppearOnceAtTheEnds() throws {
        let offsets = [0, 120, 260, 180, 380]
        let output = try stitch(offsets.map { document(offset: $0, header: 24, footer: 40) })
        assertSame(output, document(offset: 0, extent: 380 + 300, header: 24, footer: 40))
    }

    func testHorizontalScrollingIsInferredFromTheFirstMovement() throws {
        let offsets = [0, 90, 250, 400]
        let output = try stitch(offsets.map { transposed(document(offset: $0)) }, horizontal: true)
        assertSame(output, transposed(document(offset: 0, extent: 400 + 300)))
    }

    func testUnrelatedAndInPlaceChangesNeverEnterTheOutput() throws {
        var changed = document(offset: 100)
        for row in 150..<160 { changed.rows[row] = Array(repeating: 0xFF00FF00, count: changed.width) }
        let unrelated = Page(width: 80, rows: (0..<300).map { row in (0..<80).map { UInt32(truncatingIfNeeded: row &* 7_919 &+ $0 &* 104_729) | 0xFF } })
        let output = try stitch([document(offset: 0), unrelated, document(offset: 100), changed, document(offset: 200)])
        assertSame(output, document(offset: 0, extent: 200 + 300))
    }

    /// While a trackpad scroll is in motion, each frame is composited at a subpixel offset, so no
    /// line is bit-identical between frames. Noise in green's low bit stands in for that.
    func testFramesCapturedMidScrollAlignDespitePixelNoise() throws {
        let offsets = [0, 37, 220, 400, 360, 610, 790, 900]
        let frames = offsets.enumerated().map { frame, offset in noisy(document(offset: offset), seed: frame + 1) }
        assertSame(withoutNoise(try stitch(frames)), withoutNoise(document(offset: 0, extent: 900 + 300)))
        let output = try stitch(frames.map(transposed), horizontal: true)
        assertSame(withoutNoise(output), withoutNoise(transposed(document(offset: 0, extent: 900 + 300))))
    }

    func testGrowthStopsAtTheLimitAndKeepsTheAcceptedImage() throws {
        var stitcher = try withViewport(document(offset: 0)) { ScrollStitcher(first: $0, limits: .init(maximumExtent: 500)) }
        XCTAssertEqual(try withViewport(document(offset: 150)) { stitcher.add($0) }, .moved)
        XCTAssertEqual(try withViewport(document(offset: 260)) { stitcher.add($0) }, .full)
        XCTAssertEqual(try withViewport(document(offset: 20)) { stitcher.add($0) }, .full)
        XCTAssertEqual(stitcher.extent, 450)
    }

    /// Compares row by row so a failure names the first wrong row instead of printing both images.
    private func assertSame(_ actual: Page, _ expected: Page, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.width, expected.width, "width", file: file, line: line)
        XCTAssertEqual(actual.rows.count, expected.rows.count, "rows", file: file, line: line)
        if let row = zip(actual.rows, expected.rows).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            XCTFail("First differing row: \(row)", file: file, line: line)
        }
    }

    // MARK: - Fixtures

    /// Rows of 32-bit pixels, top to bottom.
    private struct Page: Equatable {
        let width: Int
        var rows: [[UInt32]]
    }

    /// A 300-row viewport of an endless document starting at `offset`. Every fifth row is blank, and
    /// text rows repeat a short pattern so only some columns distinguish them.
    private func document(offset: Int, extent: Int = 300, header: Int = 0, footer: Int = 0) -> Page {
        let width = 80
        let body = (offset..<(offset + extent - header - footer)).map { row -> [UInt32] in
            guard row % 5 != 0 else { return Array(repeating: 0xFFFF_FFFF, count: width) }
            return (0..<width).map { column in column < 6 ? Self.mixed(row, column) | 0xFF : UInt32(column % 7) << 8 | 0xFF }
        }
        let chrome = { (seed: UInt32, count: Int) in (0..<count).map { row in (0..<width).map { UInt32($0 + row) &* seed | 0xFF } } }
        return Page(width: width, rows: chrome(0x1234_5601, header) + body + chrome(0x6543_2101, footer))
    }

    private static let noiseBit: UInt32 = 0x100

    /// Flips green's low bit in about a quarter of the pixels, in a pattern unique to `seed`.
    private func noisy(_ page: Page, seed: Int) -> Page {
        var page = page
        for row in page.rows.indices {
            for column in 0..<page.width where Self.mixed(row, column, seed) & 3 == 0 {
                page.rows[row][column] ^= Self.noiseBit
            }
        }
        return page
    }

    private func withoutNoise(_ page: Page) -> Page {
        Page(width: page.width, rows: page.rows.map { $0.map { $0 & ~Self.noiseBit } })
    }

    /// Deterministic, well-distributed bits for each combination of `values`.
    private static func mixed(_ values: Int...) -> UInt32 {
        let mixed = values.reduce(UInt64(0x9E37_79B9_7F4A_7C15)) { state, value in
            let state = (state ^ UInt64(bitPattern: Int64(value))) &* 0xBF58_476D_1CE4_E5B9
            return state ^ (state >> 31)
        }
        return UInt32(truncatingIfNeeded: mixed >> 16)
    }

    private func transposed(_ page: Page) -> Page {
        Page(width: page.rows.count, rows: (0..<page.width).map { column in page.rows.map { $0[column] } })
    }

    private func withViewport<Result>(_ page: Page, _ body: (ScrollViewport) throws -> Result) throws -> Result {
        let pixels = page.rows.flatMap { $0 }
        return try pixels.withUnsafeBytes { bytes in
            try body(ScrollViewport(base: bytes.baseAddress!, width: page.width, height: page.rows.count, bytesPerRow: page.width * 4))
        }
    }

    private func stitch(_ pages: [Page], horizontal: Bool = false) throws -> Page {
        var stitcher = try withViewport(pages[0]) { ScrollStitcher(first: $0) }
        for page in pages.dropFirst() { _ = try withViewport(page) { stitcher.add($0) } }
        XCTAssertEqual(stitcher.axis ?? .vertical, horizontal ? .horizontal : .vertical)
        let image = try XCTUnwrap(stitcher.render(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)))
        let data = try XCTUnwrap(image.dataProvider?.data) as Data
        let words = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
        return Page(width: image.width, rows: (0..<image.height).map { Array(words[($0 * image.width)..<(($0 + 1) * image.width)]) })
    }
}
