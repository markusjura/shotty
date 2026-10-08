import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Shotty

final class GIFWriterTests: XCTestCase {
    /// A 40 × 40 frame of `base` with optional 10 × 10 squares, given by their top left corner.
    private func frame(_ base: TestMovie.Color, squares: [(x: Int, y: Int, color: TestMovie.Color)] = []) throws -> CGImage {
        let side = 40
        var pixels = [UInt8](repeating: 255, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let color = squares.last { x >= $0.x && x < $0.x + 10 && y >= $0.y && y < $0.y + 10 }?.color ?? base
                pixels.replaceSubrange((y * side + x) * 4..<(y * side + x) * 4 + 3,
                                       with: [UInt8(color.red), UInt8(color.green), UInt8(color.blue)])
            }
        }
        return try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// One run as Image I/O encodes it, 0.1 s per frame.
    private func run(_ frames: [CGImage]) throws -> Data {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// Runs encoded separately play as one animation. The second run's blue is missing from the
    /// first run's palette, and its later frame stores only the square that changed.
    func testRunsJoinIntoOneLoopingAnimation() throws {
        let url = try makeTemporaryFolder(self).appendingPathComponent("joined.gif")
        var writer = try GIFWriter(url: url)
        try writer.append(try run([frame(.red), frame(.red, squares: [(15, 15, .green)])]))
        try writer.append(try run([frame(.red, squares: [(15, 15, .blue)]), frame(.red, squares: [(15, 15, .blue), (0, 0, .white)])]))
        try writer.finish()

        XCTAssertEqual(try Data(contentsOf: url).prefix(6), Data("GIF89a".utf8))
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 4)
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(gif, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int, 0)
        let expected: [(center: TestMovie.Color, corner: TestMovie.Color)] = [(.red, .red), (.green, .red), (.blue, .red), (.blue, .white)]
        for (index, colors) in expected.enumerated() {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, index, nil))
            let center = try TestMovie.color(of: image, x: 0.5, y: 0.5), corner = try TestMovie.color(of: image, x: 0.1, y: 0.1)
            XCTAssertTrue(center.matches(colors.center, tolerance: 8), "Frame \(index) center is \(center)")
            XCTAssertTrue(corner.matches(colors.corner, tolerance: 8), "Frame \(index) corner is \(corner)")
            let frame = CGImageSourceCopyPropertiesAtIndex(gif, index, nil) as? [CFString: Any]
            XCTAssertEqual((frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double, 0.1)
        }
    }

    func testMalformedRunsAreRejected() throws {
        var writer = try GIFWriter(url: try makeTemporaryFolder(self).appendingPathComponent("broken.gif"))
        XCTAssertThrowsError(try writer.append(Data("GIF89a".utf8)))
        let valid = try run([frame(.red)])
        XCTAssertThrowsError(try writer.append(valid.dropLast(2)), "A run cut off before its trailer")
    }
}
