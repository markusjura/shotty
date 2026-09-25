import CoreGraphics
import ImageIO
import XCTest
@testable import Shotty

final class ScrollTileStoreTests: XCTestCase {
    private var parent: URL!
    private let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

    override func setUpWithError() throws {
        parent = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: parent)
    }

    func testForwardAndReverseEditsProduceExactOutputAlongEitherAxis() async throws {
        for axis in ScrollAxis.allCases {
            let offsets = axis == .vertical ? [100, 123, 109, 93, 80, 115, 132, 150]
                                             : [100, 80, 65, 95, 117, 97, 77, 60, 90, 125]
            let store = try await stitch(axis: axis, offsets: offsets)
            let minimum = offsets.min()!, maximum = offsets.max()!
            let expected = try frame(axis: axis, offset: minimum, extent: 96 + maximum - minimum)
            let size = await store.dimensions
            XCTAssertEqual(size, .init(width: expected.width, height: expected.height))
            let image = try await store.renderImage()
            XCTAssertEqual(image.colorSpace?.name, colorSpace.name)
            XCTAssertEqual(try pixels(image), expected.pixels)
            XCTAssertEqual(try stripBytes(store.directory), expected.pixels.count * 4,
                           "Replaced and trimmed lines must not remain on disk")

            let png = parent.appendingPathComponent("\(axis).png")
            try await store.exportPNG(to: png)
            let remaining = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
            XCTAssertFalse(remaining.contains { $0.hasPrefix("output-") }, "Export must release its assembled disk copy")
            XCTAssertEqual(try pixels(image), expected.pixels, "Previously returned mappings survive export cleanup")
            let source = try XCTUnwrap(CGImageSourceCreateWithURL(png as CFURL, nil))
            let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(try pixels(decoded, in: colorSpace), expected.pixels)
        }
    }

    func testPreviewMatchesOutputAndBoundsItsLongestSide() async throws {
        for (axis, offsets) in [(ScrollAxis.vertical, [100, 123, 90]), (.horizontal, [100, 80, 111])] {
            let store = try await stitch(axis: axis, offsets: offsets)
            let fullSize = try await store.preview(maxDimension: 10_000)
            let image = try await store.renderImage()
            XCTAssertEqual(try pixels(fullSize), try pixels(image))
            let size = await store.dimensions
            let small = try await store.preview(maxDimension: 50)
            XCTAssertEqual(max(small.width, small.height), 50)
            XCTAssertEqual(Double(small.width) / Double(small.height),
                           Double(size.width) / Double(size.height), accuracy: 0.05)
        }
    }

    func testRejectedEditsPreserveTheAcceptedImage() async throws {
        let store = try await stitch(axis: .vertical, offsets: [100, 120], limits: ScrollLimits(maximumAxisPixels: 130))
        let accepted = try pixels(try await store.renderImage())
        let next = try frame(axis: .vertical, offset: 140)
        let edit = ScrollStripEdit(edge: .trailing, removePixelCount: 5, sourceRange: 76..<96)

        await assertThrows(ScrollCaptureError.resourceLimit) { try await store.apply(edit, from: next, axis: .vertical) }
        await assertThrows(ScrollCaptureError.invalidFrame) { try await store.apply(edit, from: next, axis: .horizontal) }
        let files = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: store.directory.path)
        let fitting = ScrollStripEdit(edge: .trailing, removePixelCount: 5, sourceRange: 91..<96)
        do {
            try await store.apply(fitting, from: next, axis: .vertical)
            XCTFail("A read-only session directory must reject the edit")
        } catch {}
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: store.directory.path)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.directory.path).sorted(), files.sorted())

        let size = await store.dimensions
        XCTAssertEqual(size, .init(width: 40, height: 116))
        let unchanged = try await store.renderImage()
        let unchangedPreview = try await store.preview(maxDimension: 1_000)
        XCTAssertEqual(try pixels(unchanged), accepted)
        XCTAssertEqual(try pixels(unchangedPreview), accepted)
        try await store.apply(fitting, from: next, axis: .vertical)
        let recovered = try await store.renderImage()
        XCTAssertEqual(try pixels(recovered), accepted)
    }

    func testDiscardAndReleaseRemoveSessionFiles() async throws {
        let store = try await stitch(axis: .vertical, offsets: [100, 120])
        let image = try await store.renderImage()
        await store.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.directory.path))
        XCTAssertEqual(try pixels(image).count, 40 * 116)
        await assertThrows(ScrollTileStore.Failure.discarded) { _ = try await store.renderImage() }

        var released: ScrollTileStore? = try await ScrollTileStore(firstFrame: try frame(axis: .vertical, offset: 0),
                                                                   colorSpace: colorSpace, in: parent)
        let directory = try XCTUnwrap(released?.directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        released = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    /// Feeds synthetic frames through the real session so the store receives production edits.
    private func stitch(axis: ScrollAxis, offsets: [Int], limits: ScrollLimits = .init()) async throws -> ScrollTileStore {
        let first = try frame(axis: axis, offset: offsets[0])
        var session = try ScrollStitchSession(firstFrame: first, startedAt: 0, limits: limits)
        let store = try await ScrollTileStore(firstFrame: first, colorSpace: colorSpace, in: parent, limits: limits)
        for (index, offset) in offsets.dropFirst().enumerated() {
            let next = try frame(axis: axis, offset: offset)
            switch session.accept(next, at: Double(index + 1)) {
            case .extended(let match, let edit): try await store.apply(edit, from: next, axis: match.axis)
            case .repositioned: break
            case let step: XCTFail("Unexpected step \(step) at offset \(offset)")
            }
        }
        return store
    }

    private func stripBytes(_ directory: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.lastPathComponent.hasPrefix("strip-") }
            .reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    private func assertThrows<E: Error & Equatable>(_ expected: E, _ body: () async throws -> Void,
                                                    file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? E, expected, file: file, line: line)
        }
    }

    /// Redraws into 0xRRGGBBAA words; exact when `space` matches the image's own space.
    private func pixels(_ image: CGImage, in space: CGColorSpace? = nil) throws -> [UInt32] {
        var words = [UInt32](repeating: 0, count: image.width * image.height)
        let drawn = words.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: space ?? image.colorSpace!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw ScrollTileStore.Failure.encoding }
        return words.map { UInt32(bigEndian: $0) }
    }

    /// A viewport onto a continuous synthetic document with sticky leading/trailing chrome.
    private func frame(axis: ScrollAxis, offset: Int, extent: Int = 96, breadth: Int = 40,
                       leading: Int = 6, trailing: Int = 5) throws -> ScrollFrame {
        let width = axis == .vertical ? breadth : extent
        let height = axis == .vertical ? extent : breadth
        let pixels = (0..<(width * height)).map { index -> UInt32 in
            let along = axis == .vertical ? index / width : index % width
            let cross = axis == .vertical ? index % width : index / width
            if along < leading { return color(row: -1_000 + along, cross: cross) }
            if along >= extent - trailing { return color(row: -2_000 + along - extent + trailing, cross: cross) }
            return color(row: offset + along - leading, cross: cross)
        }
        return try ScrollFrame(width: width, height: height, pixels: pixels)
    }

    /// Opaque pseudo-random colors; any missing, duplicated, or reordered line changes the output.
    private func color(row: Int, cross: Int) -> UInt32 {
        var value = UInt32(truncatingIfNeeded: row) &* 747_796_405 &+ UInt32(cross) &* 2_891_336_453
        value = (value ^ (value >> 16)) &* 2_246_822_519
        value = (value ^ (value >> 13)) &* 3_266_489_917
        return (value & 0xFFFFFF00) | 255
    }
}
