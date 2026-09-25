import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Compile the production accumulator and its dependencies with Swift 6 optimization:
/// xcrun swiftc -O -whole-module-optimization -swift-version 6 -parse-as-library -target arm64-apple-macos26.0 Shotty/Geometry/DisplayGeometry.swift Shotty/Capture/StillCaptureService.swift Shotty/Capture/CaptureScratchSpace.swift Shotty/Scrolling/ScrollAlignment.swift Shotty/Scrolling/ScrollStitchSession.swift Shotty/Scrolling/ScrollFrameConversion.swift Shotty/Scrolling/ScrollTileStore.swift Shotty/Scrolling/ScrollAccumulator.swift Scripts/ScrollPipelineBenchmark.swift -o /tmp/shotty-scroll-benchmark
/// Run with: /usr/bin/time -l /tmp/shotty-scroll-benchmark run 2000 1500 /tmp/shotty-scroll-benchmark-unique
/// Then: /usr/bin/time -l /tmp/shotty-scroll-benchmark verify 2000 1500 /tmp/shotty-scroll-benchmark-unique
/// The directory must not exist before `run`. `verify` removes it after checking every PNG pixel.
/// Separate processes keep PNG decoding/verification memory out of the pipeline measurement.
@main
struct ScrollPipelineBenchmark {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 4, ["run", "verify"].contains(arguments[0]),
              let width = Int(arguments[1]), let height = Int(arguments[2]),
              width >= 32, height >= 32 else { throw Failure.check("Usage: run|verify width height private-output-directory") }
        _ = try RasterBudget(maximumDimension: 8_192, maximumBytes: 128 * 1_024 * 1_024).byteCount(width: width, height: height)
        let directory = URL(fileURLWithPath: arguments[3], isDirectory: true)
        let output = directory.appendingPathComponent("synthetic.png")
        let outputHeight = min(ScrollLimits().maximumAxisPixels, ScrollLimits().maximumOutputBytes / 4 / width)
        guard outputHeight > height else { throw Failure.check("Viewport leaves no room for a scrolling step") }
        if arguments[0] == "verify" {
            try verify(output, width: width, height: outputHeight)
            try FileManager.default.removeItem(at: output)
            // rmdir only removes an empty directory, never unrelated contents.
            _ = directory.path.withCString { rmdir($0) }
            return
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let accumulator = ScrollAccumulator(axis: .vertical)
        do {
            try await run(accumulator, width: width, height: height, outputHeight: outputHeight, output: output)
            await accumulator.discard()
        } catch {
            await accumulator.discard()
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private static func run(_ accumulator: ScrollAccumulator, width: Int, height: Int,
                            outputHeight: Int, output: URL) async throws {
        let start = now
        let step = max(1, height / 5)
        var offset = 0
        var count = 0
        var previews = 0
        var acceptTimes: [Double] = []
        var generationSeconds = 0.0
        while true {
            let generationStart = now
            let image = try autoreleasepool { try frame(width: width, height: height, offset: offset) }
            generationSeconds += now - generationStart
            let acceptStart = now
            let progress = try await accumulator.accept(image)
            acceptTimes.append(now - acceptStart)
            count += 1
            try require(!progress.paused, "Unexpected pause at offset \(offset): \(progress.message)")
            try require(progress.dimensions == CGSize(width: width, height: height + offset), "Wrong accumulated dimensions at offset \(offset)")
            try require(progress.acceptedFrames == count, "Frame was not accepted at offset \(offset)")
            try require(progress.didMove == (offset != 0), "Wrong movement status at offset \(offset)")
            if let preview = progress.preview {
                previews += 1
                try require(max(preview.width, preview.height) <= 300, "Live preview exceeded its bound")
            }
            if height + offset == outputHeight { break }
            offset = min(offset + step, outputHeight - height)
        }
        let accumulationSeconds = now - start
        let capStart = now
        let beyondLimit = try frame(width: width, height: height, offset: offset + 1)
        let rejected = try await accumulator.accept(beyondLimit)
        let expectedLimit: ScrollRejection = outputHeight == ScrollLimits().maximumAxisPixels ? .lengthLimit : .memoryLimit
        try require(rejected.paused && rejected.message.contains(expectedLimit.rawValue), "The next row must pause at \(expectedLimit): \(rejected.message)")
        try require(rejected.dimensions == CGSize(width: width, height: outputHeight) && rejected.acceptedFrames == count,
                    "A rejected frame changed the partial output")
        let capSeconds = now - capStart
        let previewStart = now
        let finalPreview = try await accumulator.finishPreview()
        try require(max(finalPreview.width, finalPreview.height) == 800, "Final preview must have an 800px longest side")
        let finalPreviewSeconds = now - previewStart
        let exportStart = now
        try await accumulator.exportPNG(to: output)
        let exportSeconds = now - exportStart
        let sorted = acceptTimes.sorted()
        let result = Measurement(viewportWidth: width, viewportHeight: height, logicalScale: 2,
                                 outputHeight: outputHeight, outputBytes: width * outputHeight * 4,
                                 acceptedFrames: count, livePreviews: previews, stepPixels: step,
                                 capReason: expectedLimit.rawValue, accumulationSeconds: accumulationSeconds,
                                 generationSeconds: generationSeconds, acceptP50Seconds: percentile(sorted, 0.50),
                                 acceptP95Seconds: percentile(sorted, 0.95), acceptMaxSeconds: sorted.last!,
                                 capCheckSeconds: capSeconds, finalPreviewSeconds: finalPreviewSeconds,
                                 exportSeconds: exportSeconds, totalSeconds: now - start,
                                 pngBytes: try output.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }

    /// Stable unique content at every source coordinate; no full document is held in memory.
    private static func frame(width: Int, height: Int, offset: Int) throws -> CGImage {
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let words = storage.bindMemory(to: UInt32.self)
            for y in 0..<height {
                for x in 0..<width { words[y * width + x] = color(row: offset + y, cross: x).bigEndian }
            }
        }
        guard let provider = CGDataProvider(data: bytes as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { throw Failure.check("Cannot create fixture image") }
        return image
    }

    /// A bounded verification strip avoids a second full RGBA output allocation.
    /// ImageIO's decoded source itself may still retain the entire image in this separate process.
    private static func verify(_ output: URL, width: Int, height: Int) throws {
        let start = now
        guard let source = CGImageSourceCreateWithURL(output as CFURL, nil), CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == "public.png",
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw Failure.check("Output is not a readable single-image PNG") }
        try require(decoded.width == width && decoded.height == height, "PNG dimensions do not match the accepted result")
        for firstRow in stride(from: 0, to: height, by: 128) {
            try autoreleasepool {
                let rows = min(128, height - firstRow)
                guard let strip = decoded.cropping(to: CGRect(x: 0, y: firstRow, width: width, height: rows)) else {
                    throw Failure.check("Cannot crop output verification strip")
                }
                var words = [UInt32](repeating: 0, count: width * rows)
                try words.withUnsafeMutableBytes { storage in
                    guard let context = CGContext(data: storage.baseAddress, width: width, height: rows,
                                                  bitsPerComponent: 8, bytesPerRow: width * 4,
                                                  space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
                        throw Failure.check("Cannot create verification context")
                    }
                    context.draw(strip, in: CGRect(x: 0, y: 0, width: width, height: rows))
                }
                for y in 0..<rows {
                    for x in 0..<width {
                        try require(UInt32(bigEndian: words[y * width + x]) == color(row: firstRow + y, cross: x),
                                    "PNG pixel mismatch at \(x),\(firstRow + y)")
                    }
                }
            }
        }
        print("Verified every pixel in \(width)×\(height) PNG; seconds=\(now - start).")
    }

    private static func color(row: Int, cross: Int) -> UInt32 {
        var value = UInt32(truncatingIfNeeded: row) &* 747_796_405 &+ UInt32(cross) &* 2_891_336_453
        value = (value ^ (value >> 16)) &* 2_246_822_519
        value = (value ^ (value >> 13)) &* 3_266_489_917
        return (value & 0xFFFFFF00) | 255
    }

    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double { sorted[Int(ceil(Double(sorted.count) * fraction)) - 1] }
    private static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure.check(message()) }
    }

    private struct Measurement: Encodable {
        let viewportWidth, viewportHeight, logicalScale, outputHeight, outputBytes, acceptedFrames, livePreviews, stepPixels: Int
        let capReason: String
        let accumulationSeconds, generationSeconds, acceptP50Seconds, acceptP95Seconds, acceptMaxSeconds: Double
        let capCheckSeconds, finalPreviewSeconds, exportSeconds, totalSeconds: Double
        let pngBytes: Int
    }
    private enum Failure: Error { case check(String) }
}
