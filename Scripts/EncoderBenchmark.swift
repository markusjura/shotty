import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Compile with DisplayGeometry.swift, then run under /usr/bin/time -l.
/// This measures ImageIO on incompressible synthetic pixels, never screen content.
@main
struct EncoderBenchmark {
    static func main() throws {
        let arguments = CommandLine.arguments.dropFirst()
        guard arguments.count == 2, let width = Int(arguments.first!), let height = Int(arguments.last!) else {
            throw BenchmarkError.usage
        }
        let byteCount = try RasterBudget().byteCount(width: width, height: height)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-encoder-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("synthetic.png")
        var pixels = Data(count: byteCount)
        pixels.withUnsafeMutableBytes { bytes in
            let words = bytes.bindMemory(to: UInt32.self)
            var seed: UInt32 = 0x12345678
            for index in words.indices {
                seed ^= seed << 13
                seed ^= seed >> 17
                seed ^= seed << 5
                words[index] = seed | 0xFF000000
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let encoder = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw BenchmarkError.encoding
        }
        let start = ContinuousClock.now
        CGImageDestinationAddImage(encoder, image, nil)
        guard CGImageDestinationFinalize(encoder) else { throw BenchmarkError.encoding }
        let elapsed = start.duration(to: .now)
        let size = try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        print("\(width)x\(height) RGBA bytes=\(byteCount) PNG bytes=\(size) encode=\(elapsed)")
    }

    enum BenchmarkError: Error { case usage, encoding }
}
