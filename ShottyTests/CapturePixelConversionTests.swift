import CoreGraphics
import CoreVideo
import XCTest
@testable import Shotty

final class CapturePixelConversionTests: XCTestCase {
    func testBGRABytesProfileAndAlphaSurviveWithoutRenderingOrBorrowedStorage() throws {
        for straight in [false, true] {
            let buffer = try pixelBuffer()
            let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey,
                                  straight ? kCVImageBufferAlphaChannelMode_StraightAlpha : kCVImageBufferAlphaChannelMode_PremultipliedAlpha,
                                  .shouldPropagate)
            let expected = try fill(buffer)
            let image = try CapturePixelConversion.image(from: buffer)
            XCTAssertEqual(image.width, 11)
            XCTAssertEqual(image.height, 7)
            XCTAssertEqual(image.bytesPerRow, 44)
            XCTAssertEqual(image.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little)
            XCTAssertEqual(image.alphaInfo, straight ? .first : .premultipliedFirst)
            XCTAssertEqual(image.colorSpace, space)
            XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data, expected)
            XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
            memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
            CVPixelBufferUnlockBaseAddress(buffer, [])
            XCTAssertEqual(try XCTUnwrap(image.dataProvider?.data) as Data, expected, "The image must own its pixels after the stream reuses its buffer")
        }
    }

    func testColorimetryAttachmentsSupplyTheProfileWhenNoCGColorSpaceIsAttached() throws {
        let buffer = try pixelBuffer()
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let attachments = try XCTUnwrap(CVBufferCopyAttachments(buffer, .shouldPropagate))
        let expectedSpace = try XCTUnwrap(CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue())
        _ = try fill(buffer)
        let image = try CapturePixelConversion.image(from: buffer)
        XCTAssertEqual(image.colorSpace, expectedSpace)
    }

    func testMissingProfileAndOversizeRasterAreRejected() throws {
        let buffer = try pixelBuffer()
        XCTAssertThrowsError(try CapturePixelConversion.image(from: buffer)) { error in
            guard case CapturePixelConversion.Failure.missingColorProfile = error else { return XCTFail("Expected missing profile") }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)), .shouldPropagate)
        XCTAssertThrowsError(try CapturePixelConversion.image(from: buffer, budget: RasterBudget(maximumBytes: 100)))
    }

    private func pixelBuffer() throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferBytesPerRowAlignmentKey: 64] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 11, 7, kCVPixelFormatType_32BGRA, attributes, &buffer), kCVReturnSuccess)
        return try XCTUnwrap(buffer)
    }

    private func fill(_ buffer: CVPixelBuffer) throws -> Data {
        XCTAssertEqual(CVPixelBufferLockBaseAddress(buffer, []), kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let pointer = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        memset(pointer, 0xCC, CVPixelBufferGetDataSize(buffer))
        var expected = Data()
        for row in 0..<7 {
            for column in 0..<11 {
                let pixel: [UInt8] = [UInt8(row * 5), UInt8(column * 7), UInt8(row + column), 128]
                _ = pixel.withUnsafeBytes { memcpy(pointer + row * stride + column * 4, $0.baseAddress!, 4) }
                expected.append(contentsOf: pixel)
            }
        }
        return expected
    }
}
