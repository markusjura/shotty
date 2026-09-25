import CoreGraphics
import Foundation

extension ScrollFrame {
    /// Keep the source profile for export; alignment compares pixels in that same space.
    init(image: CGImage) throws {
        _ = try RasterBudget(maximumDimension: 8_192, maximumBytes: 128 * 1_024 * 1_024)
            .byteCount(width: image.width, height: image.height)
        guard let colorSpace = image.colorSpace else { throw CaptureFailure.noImage }
        var pixels = [UInt32](repeating: 0, count: image.width * image.height)
        let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(data: storage.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw CaptureFailure.noImage }
        // CGContext wrote RGBA bytes; the core's words have a host-independent definition.
        for index in pixels.indices { pixels[index] = UInt32(bigEndian: pixels[index]) }
        try self.init(width: image.width, height: image.height, pixels: pixels)
    }
}
