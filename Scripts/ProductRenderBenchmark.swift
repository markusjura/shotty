import CoreGraphics
import Darwin
import Foundation
import ImageIO

/// Production storage/render/export benchmark; compilation and cases are recorded in .plans/product-render-profile.md.
/// Usage: ProductRenderBenchmark width height png|jpeg native|logical repetitions serial|concurrent
/// Fixtures and exports live in a unique temporary directory that is removed on success or failure.
@main
struct ProductRenderBenchmark {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 6, let width = Int(args[0]), let height = Int(args[1]),
              width >= 1_024, height >= 1_024, width <= 30_000, height <= 30_000,
              width * height <= ExportService.maximumPixels,
              let format = ExportOptions.Format(rawValue: args[2]), ["native", "logical"].contains(args[3]),
              let repetitions = Int(args[4]), (1...3).contains(repetitions),
              ["serial", "concurrent"].contains(args[5]) else { throw Failure.invalidArguments }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-product-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureSessionStore(directory: directory.appendingPathComponent("Session"))
        let exporter = ExportService()
        let options = ExportOptions(format: format, scale: args[3] == "logical" ? .logical : .native)
        let concurrent = args[5] == "concurrent"
        let initialRSS = try residentBytes()
        let initialFootprint = try footprintBytes()
        var runs: [Measurement] = []
        do {
            for iteration in 1...repetitions {
                let start = now
                let record = try await create(store: store, width: width, height: height)
                let createSeconds = now - start
                let afterCreateRSS = try residentBytes()
                let afterCreateFootprint = try footprintBytes()
                let sourceBytes = try fileSize(record.sourceURL)
                let edited = try await store.updateDocument(for: record.id, state: annotations(width: width, height: height), revision: 1)
                let renderStart = now
                let receipt: ExportReceipt
                var thumbnailDimensions: [Int] = []
                if concurrent {
                    async let exported = exporter.export(edited.snapshot, to: directory, options: options, filenameTemplate: "fixture")
                    async let thumbnail = thumbnailSize(store: store, id: record.id)
                    (receipt, thumbnailDimensions) = try await (exported, thumbnail)
                } else {
                    receipt = try await exporter.export(edited.snapshot, to: directory, options: options, filenameTemplate: "fixture")
                }
                let exportSeconds = now - renderStart
                let expectedWidth = options.scale == .logical ? Int((Double(width) / 2).rounded()) : width
                let expectedHeight = options.scale == .logical ? Int((Double(height) / 2).rounded()) : height
                try verifyMetadata(receipt.destinationURL, width: expectedWidth, height: expectedHeight, format: format)
                let outputBytes = try fileSize(receipt.destinationURL)
                let beforeDiscardRSS = try residentBytes()
                try await store.discard()
                try FileManager.default.removeItem(at: receipt.destinationURL)
                // Actor work is complete before sampling; no synthetic memory-pressure or allocator purge.
                let afterDiscardRSS = try residentBytes()
                let afterDiscardFootprint = try footprintBytes()
                runs.append(Measurement(iteration: iteration, createSeconds: createSeconds, exportSeconds: exportSeconds,
                                        totalSeconds: now - start, sourceBytes: sourceBytes, outputBytes: outputBytes,
                                        beforeDiscardRSS: beforeDiscardRSS, afterDiscardRSS: afterDiscardRSS,
                                        afterCreateRSS: afterCreateRSS, afterCreateFootprint: afterCreateFootprint,
                                        afterDiscardFootprint: afterDiscardFootprint,
                                        thumbnailDimensions: thumbnailDimensions))
            }
        } catch {
            try? await store.discard()
            throw error
        }
        let result = Result(width: width, height: height, sourceRGBABytes: width * height * 4,
                            format: args[2], scale: args[3], concurrentThumbnail: concurrent,
                            initialRSS: initialRSS, initialFootprint: initialFootprint, runs: runs)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(result), as: UTF8.self))
    }

    /// The fixture image's lifetime ends before the export starts.
    private static func create(store: CaptureSessionStore, width: Int, height: Int) async throws -> CaptureRecord {
        let source = try autoreleasepool { try fixture(width: width, height: height) }
        return try await store.create(image: source, kind: .scrolling, scale: 2)
    }

    private static func thumbnailSize(store: CaptureSessionStore, id: UUID) async throws -> [Int] {
        let image = try await store.thumbnail(for: id)
        guard max(image.width, image.height) <= 560 else { throw Failure.invalidOutput }
        return [image.width, image.height]
    }

    /// Deterministic blocks, gradients, and thin stripes model varied screen content without a second fixture buffer.
    private static func fixture(width: Int, height: Int) throws -> CGImage {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw Failure.invalidOutput }
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                let tile = UInt32(x / 64) &* 747_796_405 &+ UInt32(y / 48) &* 2_891_336_453
                bytes[index] = UInt8(truncatingIfNeeded: tile >> 8) &+ UInt8(x % 32)
                bytes[index + 1] = UInt8(truncatingIfNeeded: tile >> 16) &+ UInt8(y % 32)
                bytes[index + 2] = (y % 24 < 3 && x % 160 < 100) ? 32 : UInt8(truncatingIfNeeded: tile >> 24)
                bytes[index + 3] = 255
            }
        }
        guard let image = context.makeImage() else { throw Failure.invalidOutput }
        return image
    }

    private static func annotations(width: Int, height: Int) -> AnnotationDocument {
        let x = Double(width) * 0.2, y = Double(height) * 0.2
        return AnnotationDocument(annotations: [
            Annotation(content: .redact(rect: CGRect(x: x, y: y, width: 650, height: 450), style: .init(style: .blur, strength: 0.6))),
            Annotation(content: .redact(rect: CGRect(x: x + 100, y: y + 300, width: 700, height: 350), style: .init(style: .pixelate, strength: 0.5))),
            Annotation(content: .spotlight(rect: CGRect(x: x, y: y, width: 900, height: 750), style: .init(shape: .roundedRectangle, dimPercent: 45))),
            Annotation(content: .redact(rect: CGRect(x: x, y: Double(height) * 0.7, width: 700, height: 400), style: .init(style: .blur, strength: 0.7)))
        ])
    }

    private static func verifyMetadata(_ url: URL, width: Int, height: Int, format: ExportOptions.Format) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              CGImageSourceGetType(source) as String? == (format == .png ? "public.png" : "public.jpeg"),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height else { throw Failure.invalidOutput }
    }

    private static func residentBytes() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw Failure.invalidOutput }
        return info.resident_size
    }

    private static func footprintBytes() throws -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw Failure.invalidOutput }
        return info.phys_footprint
    }

    private static func fileSize(_ url: URL) throws -> Int { try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
    private static var now: Double { ProcessInfo.processInfo.systemUptime }
    private struct Result: Encodable {
        let width, height, sourceRGBABytes: Int
        let format, scale: String
        let concurrentThumbnail: Bool
        let initialRSS, initialFootprint: UInt64
        let runs: [Measurement]
    }
    private struct Measurement: Encodable {
        let iteration: Int
        let createSeconds, exportSeconds, totalSeconds: Double
        let sourceBytes, outputBytes: Int
        let beforeDiscardRSS, afterDiscardRSS: UInt64
        let afterCreateRSS, afterCreateFootprint, afterDiscardFootprint: UInt64
        let thumbnailDimensions: [Int]
    }
    private enum Failure: Error { case invalidArguments, invalidOutput }
}
