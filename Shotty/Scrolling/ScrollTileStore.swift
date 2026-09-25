import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Disk-backed accumulated output for one scrolling capture.
///
/// Create it with the session's first frame, then pass every `.extended(match, edit)` step to
/// `apply(_:from:axis:)` with `match.axis` and the frame that produced the step. Accepted pixels
/// live in raw RGBA strip files inside a private directory the store owns; only strip metadata
/// stays resident. A failed edit leaves the previously accepted image and files untouched.
/// Call `discard()` on cancel; the directory is also removed when the store is released.
actor ScrollTileStore {
    struct Dimensions: Equatable, Sendable {
        let width: Int
        let height: Int
    }

    enum Failure: Error, Equatable {
        case discarded
        case encoding
    }

    /// Tightly packed 0xRRGGBBAA words, the in-memory form of one strip file.
    private struct Raster {
        let width: Int
        let height: Int
        let words: [UInt32]

        func extent(along axis: ScrollAxis) -> Int { axis == .vertical ? height : width }

        func lines(_ range: Range<Int>, along axis: ScrollAxis) -> Raster {
            if axis == .vertical {
                return Raster(width: width, height: range.count,
                              words: Array(words[(range.lowerBound * width)..<(range.upperBound * width)]))
            }
            var result: [UInt32] = []
            result.reserveCapacity(range.count * height)
            for row in 0..<height {
                result += words[(row * width + range.lowerBound)..<(row * width + range.upperBound)]
            }
            return Raster(width: range.count, height: height, words: result)
        }

        /// Concatenates `self` then `next` along `axis`.
        func joined(with next: Raster, along axis: ScrollAxis) -> Raster {
            if axis == .vertical { return Raster(width: width, height: height + next.height, words: words + next.words) }
            var result: [UInt32] = []
            result.reserveCapacity(words.count + next.words.count)
            for row in 0..<height {
                result += words[(row * width)..<((row + 1) * width)]
                result += next.words[(row * next.width)..<((row + 1) * next.width)]
            }
            return Raster(width: width + next.width, height: height, words: result)
        }
    }

    /// One immutable file of accepted lines, at most one viewport long along the axis.
    private struct Strip {
        let url: URL
        let width: Int
        let height: Int

        func extent(along axis: ScrollAxis) -> Int { axis == .vertical ? height : width }
    }

    nonisolated let directory: URL
    private let viewport: Dimensions
    private let limits: ScrollLimits
    private let colorSpace: CGColorSpace
    private var strips: [Strip]
    /// Unknown until the first edit; the lone first frame reads the same along either axis.
    private var axis: ScrollAxis?
    /// Assembled output for the current strips, rebuilt only after an edit.
    private var raster: URL?
    private var isDiscarded = false

    private static let chunkBytes = 8 * 1_024 * 1_024

    /// Creates a private directory inside `parentDirectory` holding the first frame as output.
    /// The default parent is the launch-swept capture scratch space.
    /// `colorSpace` must be the source frames' space; it is attached to every image unchanged.
    init(firstFrame: ScrollFrame, colorSpace: CGColorSpace,
         in parentDirectory: URL = CaptureScratchSpace.directory, limits: ScrollLimits = .init()) async throws {
        guard max(firstFrame.width, firstFrame.height) <= limits.maximumAxisPixels else {
            throw ScrollCaptureError.resourceLimit
        }
        _ = try Self.byteCount(width: firstFrame.width, height: firstFrame.height, limits: limits)
        // The shared scratch parent is private and swept at launch; create it on first use.
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let directory = parentDirectory.appendingPathComponent("scroll-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            strips = [try Self.write(Raster(width: firstFrame.width, height: firstFrame.height,
                                            words: firstFrame.pixels), in: directory)]
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        viewport = Dimensions(width: firstFrame.width, height: firstFrame.height)
        self.limits = limits
        self.colorSpace = colorSpace
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var dimensions: Dimensions {
        guard let axis else { return viewport }
        let extent = strips.reduce(0) { $0 + $1.extent(along: axis) }
        return axis == .vertical ? Dimensions(width: viewport.width, height: extent)
                                 : Dimensions(width: extent, height: viewport.height)
    }

    /// Removes `edit.removePixelCount` lines from the edge, then adds the source lines there.
    /// Throws before changing accepted content on mismatch, limit, or write failure.
    func apply(_ edit: ScrollStripEdit, from frame: ScrollFrame, axis newAxis: ScrollAxis) throws {
        guard !isDiscarded else { throw Failure.discarded }
        let viewportExtent = newAxis == .vertical ? viewport.height : viewport.width
        let size = dimensions
        let extent = newAxis == .vertical ? size.height : size.width
        guard axis == nil || axis == newAxis, frame.width == viewport.width, frame.height == viewport.height,
              !edit.sourceRange.isEmpty, edit.sourceRange.lowerBound >= 0,
              edit.sourceRange.upperBound <= viewportExtent,
              (0...extent).contains(edit.removePixelCount) else { throw ScrollCaptureError.invalidFrame }
        let newExtent = extent - edit.removePixelCount + edit.sourceRange.count
        guard newExtent <= limits.maximumAxisPixels else { throw ScrollCaptureError.resourceLimit }
        _ = try newAxis == .vertical ? Self.byteCount(width: viewport.width, height: newExtent, limits: limits)
                                     : Self.byteCount(width: newExtent, height: viewport.height, limits: limits)

        // Drop whole strips covered by the removal; the edge strip keeps its remaining lines.
        let leading = edit.edge == .leading
        var kept = strips
        var replaced: [Strip] = []
        var remaining = edit.removePixelCount
        var edge: (strip: Strip, lines: Range<Int>)?
        while let strip = leading ? kept.first : kept.last {
            let length = strip.extent(along: newAxis)
            if remaining >= length && remaining > 0 {
                replaced.append(leading ? kept.removeFirst() : kept.removeLast())
                remaining -= length
                continue
            }
            edge = (strip, leading ? remaining..<length : 0..<(length - remaining))
            break
        }

        // Rewrite at most the edge strip: merge it with the source while the result fits one
        // viewport, otherwise store its surviving lines separately. Trimmed lines never linger.
        let source = Raster(width: frame.width, height: frame.height, words: frame.pixels)
            .lines(edit.sourceRange, along: newAxis)
        var pieces = [source]
        if let edge, edge.lines.count + source.extent(along: newAxis) <= viewportExtent || remaining > 0 {
            let survivor = try read(edge.strip).lines(edge.lines, along: newAxis)
            if edge.lines.count + source.extent(along: newAxis) <= viewportExtent {
                pieces = [leading ? source.joined(with: survivor, along: newAxis) : survivor.joined(with: source, along: newAxis)]
            } else {
                pieces = leading ? [source, survivor] : [survivor, source]
            }
            replaced.append(leading ? kept.removeFirst() : kept.removeLast())
        }
        var written: [Strip] = []
        do {
            for piece in pieces { written.append(try Self.write(piece, in: directory)) }
        } catch {
            for strip in written { try? FileManager.default.removeItem(at: strip.url) }
            throw error
        }

        strips = leading ? written + kept : kept + written
        axis = newAxis
        invalidateRaster()
        for strip in replaced { try? FileManager.default.removeItem(at: strip.url) }
    }

    /// Whether the frame's moving lines agree with the accepted output they overlap. Call it
    /// before committing any matched step, so revisited or retained content that changed since
    /// acceptance pauses capture instead of coexisting with the stale output.
    ///
    /// `offset` is the output line of the frame's first line; it is negative when the frame
    /// extends the leading edge. `bands` are the match's replacement bands: those frame lines are
    /// fixed chrome, and the same counts at the output edges hold chrome or lines the edit replaces.
    /// Only mapped strips that intersect the viewport are read. Tolerance mirrors the aligner's
    /// verification, but per line, so one changed row cannot hide inside a large overlap.
    func overlapMatches(_ frame: ScrollFrame, offset: Int, excluding bands: ScrollStationaryBands,
                        axis frameAxis: ScrollAxis) throws -> Bool {
        guard !isDiscarded else { throw Failure.discarded }
        guard axis == nil || axis == frameAxis, frame.width == viewport.width, frame.height == viewport.height else {
            throw ScrollCaptureError.invalidFrame
        }
        let size = dimensions
        let total = frameAxis == .vertical ? size.height : size.width
        let lower = max(bands.leading, offset + bands.leading)
        let upper = min(total - bands.trailing, offset + frame.extent(along: frameAxis) - bands.trailing)
        guard lower < upper else { return true }
        let compared = lower..<upper
        let breadth = frame.breadth(along: frameAxis)
        var difference = 0
        var start = 0
        for strip in strips {
            let lines = compared.clamped(to: start..<(start + strip.extent(along: frameAxis)))
            defer { start += strip.extent(along: frameAxis) }
            guard !lines.isEmpty else { continue }
            let data = try Data(contentsOf: strip.url, options: .alwaysMapped)
            let agrees = data.withUnsafeBytes { bytes in
                lines.allSatisfy { line in
                    var outliers = 0
                    for cross in 0..<breadth {
                        let index = frameAxis == .vertical ? (line - start) * strip.width + cross
                                                          : cross * strip.width + line - start
                        let stored = UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
                        let error = Self.channelDifference(stored, frame.pixel(along: line - offset, across: cross, axis: frameAxis))
                        difference += error
                        if error > 51 { outliers += 1 }
                    }
                    return outliers * 40 <= breadth
                }
            }
            guard agrees else { return false }
        }
        // Mean channel error at most 0.012 of full scale, as in the aligner.
        return difference * 1_000 <= compared.count * breadth * 12_240
    }

    /// Full-resolution output backed by a mapped raw file, so the pixels stay file-backed.
    /// Images already returned remain valid after later edits or `discard()`.
    func renderImage() throws -> CGImage {
        let size = dimensions
        let data = try Data(contentsOf: try assembledRaster(), options: .alwaysMapped)
        guard let image = Self.image(data, width: size.width, height: size.height, colorSpace: colorSpace) else {
            throw Failure.encoding
        }
        return image
    }

    /// Encodes the full-resolution output. The output layer owns atomic replacement and collisions.
    func exportPNG(to url: URL) throws {
        let image = try renderImage()
        // The encoder owns the mapping until it finishes; no second raw copy needs
        // to stay cached on disk between exports.
        defer { invalidateRaster() }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw Failure.encoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure.encoding }
    }

    /// Draws each mapped strip into a small bitmap without assembling the full raster.
    /// Cost still scales with accepted pixels read, so callers should throttle live updates.
    func preview(maxDimension: Int = 300) throws -> CGImage {
        guard !isDiscarded else { throw Failure.discarded }
        guard maxDimension > 0 else { throw ScrollCaptureError.invalidFrame }
        let size = dimensions
        let scale = min(1, Double(maxDimension) / Double(max(size.width, size.height)))
        let width = max(1, Int((Double(size.width) * scale).rounded()))
        let height = max(1, Int((Double(size.height) * scale).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: colorSpace, bitmapInfo: Self.bitmapInfo.rawValue) else {
            throw Failure.encoding
        }
        context.interpolationQuality = .high
        let scaleX = Double(width) / Double(size.width)
        let scaleY = Double(height) / Double(size.height)
        var position = 0
        for strip in strips {
            let data = try Data(contentsOf: strip.url, options: .alwaysMapped)
            guard let image = Self.image(data, width: strip.width, height: strip.height, colorSpace: colorSpace) else {
                throw Failure.encoding
            }
            // Output coordinates are top-left based; the context is bottom-left based.
            let target = axis == .horizontal
                ? CGRect(x: position, y: 0, width: strip.width, height: strip.height)
                : CGRect(x: 0, y: position, width: strip.width, height: strip.height)
            context.draw(image, in: CGRect(x: target.minX * scaleX, y: (Double(size.height) - target.maxY) * scaleY,
                                           width: target.width * scaleX, height: target.height * scaleY))
            position += strip.extent(along: axis ?? .vertical)
        }
        guard let preview = context.makeImage() else { throw Failure.encoding }
        return preview
    }

    /// Deletes all capture files. Later calls throw `Failure.discarded`.
    func discard() {
        isDiscarded = true
        strips = []
        raster = nil
        try? FileManager.default.removeItem(at: directory)
    }

    private func invalidateRaster() {
        if let raster { try? FileManager.default.removeItem(at: raster) }
        raster = nil
    }

    /// Writes the output with bounded buffers; strip files are mapped, not loaded.
    private func assembledRaster() throws -> URL {
        guard !isDiscarded else { throw Failure.discarded }
        if let raster { return raster }
        let size = dimensions
        let rowBytes = size.width * 4
        let url = directory.appendingPathComponent("output-\(UUID().uuidString).rgba")
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            if axis != .horizontal {
                for strip in strips {
                    let data = try Data(contentsOf: strip.url, options: .alwaysMapped)
                    for start in stride(from: 0, to: data.count, by: Self.chunkBytes) {
                        try handle.write(contentsOf: data[start..<min(start + Self.chunkBytes, data.count)])
                    }
                }
            } else {
                let sources = try strips.map { try Data(contentsOf: $0.url, options: .alwaysMapped) }
                let bandRows = max(1, Self.chunkBytes / rowBytes)
                var band = Data(count: bandRows * rowBytes)
                for bandStart in stride(from: 0, to: size.height, by: bandRows) {
                    let rows = bandStart..<min(bandStart + bandRows, size.height)
                    band.withUnsafeMutableBytes { output in
                        var column = 0
                        for (strip, source) in zip(strips, sources) {
                            source.withUnsafeBytes { input in
                                for row in rows {
                                    (output.baseAddress! + (row - bandStart) * rowBytes + column * 4)
                                        .copyMemory(from: input.baseAddress! + row * strip.width * 4, byteCount: strip.width * 4)
                                }
                            }
                            column += strip.width
                        }
                    }
                    try handle.write(contentsOf: band.prefix(rows.count * rowBytes))
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        raster = url
        return url
    }

    private func read(_ strip: Strip) throws -> Raster {
        let data = try Data(contentsOf: strip.url, options: .alwaysMapped)
        let words = data.withUnsafeBytes { bytes in
            (0..<(strip.width * strip.height)).map { UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: $0 * 4, as: UInt32.self)) }
        }
        return Raster(width: strip.width, height: strip.height, words: words)
    }

    private static func byteCount(width: Int, height: Int, limits: ScrollLimits) throws -> Int {
        do {
            return try RasterBudget(maximumBytes: limits.maximumOutputBytes).byteCount(width: width, height: height)
        } catch {
            throw ScrollCaptureError.resourceLimit
        }
    }

    /// Stores words as R, G, B, A bytes in a new file, removing partial writes.
    private static func write(_ raster: Raster, in directory: URL) throws -> Strip {
        let url = directory.appendingPathComponent("strip-\(UUID().uuidString).rgba")
        var bytes = Data(count: raster.words.count * 4)
        bytes.withUnsafeMutableBytes { output in
            let words = output.bindMemory(to: UInt32.self)
            for index in raster.words.indices { words[index] = raster.words[index].bigEndian }
        }
        do {
            try bytes.write(to: url, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return Strip(url: url, width: raster.width, height: raster.height)
    }

    /// Sum of absolute RGBA channel differences, 0...1_020.
    private static func channelDifference(_ a: UInt32, _ b: UInt32) -> Int {
        stride(from: 0, to: 32, by: 8).reduce(0) { $0 + abs(Int((a >> UInt32($1)) & 255) - Int((b >> UInt32($1)) & 255)) }
    }

    private static let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                                           | CGBitmapInfo.byteOrder32Big.rawValue)

    private static func image(_ data: Data, width: Int, height: Int, colorSpace: CGColorSpace) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
