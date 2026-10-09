import XCTest
@testable import Shotty

final class VideoEditTests: XCTestCase {
    func testTrimStaysInsideTheRecordingAndKeepsAMinimumLength() {
        var edit = VideoEdit()
        XCTAssertEqual(edit.trimRange(duration: 10), 0...10)
        edit.trimStart = 4
        edit.trimEnd = 2
        let shortest = edit.trimRange(duration: 10)
        XCTAssertEqual(shortest.lowerBound, 1.9, accuracy: 1e-9, "A start past the end leaves the shortest clip")
        XCTAssertEqual(shortest.upperBound, 2)
        edit.trimStart = -3
        edit.trimEnd = 30
        XCTAssertEqual(edit.trimRange(duration: 10), 0...10)
        edit.trimStart = 2
        edit.trimEnd = 8
        edit.speed = .quadruple
        XCTAssertEqual(edit.outputDuration(sourceDuration: 10), 1.5)
    }

    func testCropIsClippedToTheFrameOnWholePixels() {
        let source = CGSize(width: 1000, height: 600)
        var edit = VideoEdit()
        XCTAssertEqual(edit.cropRect(in: source), CGRect(origin: .zero, size: source))
        edit.crop = CGRect(x: 900.4, y: -50, width: 300, height: 200.2)
        XCTAssertEqual(edit.cropRect(in: source), CGRect(x: 900, y: 0, width: 100, height: 151))
        edit.crop = CGRect(x: 2000, y: 0, width: 10, height: 10)
        XCTAssertEqual(edit.cropRect(in: source), CGRect(origin: .zero, size: source), "A crop outside the frame keeps the frame")
    }

    func testRenderSizeFitsTheLongestSideAndStaysEven() {
        let source = CGSize(width: 2880, height: 1801)
        var edit = VideoEdit()
        XCTAssertEqual(edit.renderSize(source: source), CGSize(width: 2880, height: 1802), "Encoders need even dimensions")
        edit.size = .px1280
        XCTAssertEqual(edit.renderSize(source: source), CGSize(width: 1280, height: 800))
        edit.crop = CGRect(x: 0, y: 0, width: 501, height: 1001)
        XCTAssertEqual(edit.renderSize(source: source), CGSize(width: 502, height: 1002), "Smaller crops are never scaled up")
    }

    func testOnlyAnUneditedMP4PassesThrough() {
        let source = CGSize(width: 640, height: 400)
        XCTAssertTrue(VideoEdit().isPassthrough(sourceSize: source, sourceDuration: 3))
        var trimmed = VideoEdit(); trimmed.trimEnd = 2
        var muted = VideoEdit(); muted.removesAudio = true
        var smaller = VideoEdit(); smaller.size = .px640
        var resized = VideoEdit(); resized.size = .px960
        XCTAssertFalse(trimmed.isPassthrough(sourceSize: source, sourceDuration: 3))
        XCTAssertFalse(muted.isPassthrough(sourceSize: source, sourceDuration: 3))
        XCTAssertFalse(VideoEdit(format: .gif).isPassthrough(sourceSize: source, sourceDuration: 3))
        XCTAssertTrue(smaller.isPassthrough(sourceSize: source, sourceDuration: 3), "A size the clip already fits changes nothing")
        XCTAssertTrue(resized.isPassthrough(sourceSize: source, sourceDuration: 3))
        XCTAssertFalse(VideoEdit().isPassthrough(sourceSize: CGSize(width: 641, height: 400), sourceDuration: 3),
                       "Odd recordings are encoded at even dimensions")
    }

    func testSwitchingToGIFStartsAtAShareableSize() {
        var edit = VideoEdit()
        edit.setFormat(.gif)
        XCTAssertEqual(edit.size, .px960)
        edit.size = .original
        edit.setFormat(.mp4)
        edit.setFormat(.gif)
        XCTAssertEqual(edit.size, .px960, "Each switch to GIF from the original size picks the GIF size")
        edit.size = .px640
        edit.setFormat(.mp4)
        edit.setFormat(.gif)
        XCTAssertEqual(edit.size, .px640, "A chosen size is kept")
    }
}
