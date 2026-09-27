import CoreGraphics
import Foundation

enum ScrollAxis: Sendable {
    case vertical, horizontal
}

/// Borrowed 32-bit pixels of one captured viewport. Valid only during the call that receives it.
struct ScrollViewport {
    let base: UnsafeRawPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int

    private static let offset: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01B3

    /// One hash per row (vertical) or column (horizontal). Equal lines hash equally; the
    /// stitcher only compares hashes, so a line is read once per frame.
    func lineHashes(along axis: ScrollAxis) -> [UInt64] {
        axis == .vertical ? rowHashes() : columnHashes()
    }

    /// Four independent lanes over 8-byte words keep the multiply chain from serializing.
    private func rowHashes() -> [UInt64] {
        let words = width / 2
        return (0..<height).map { row in
            let line = base + row * bytesPerRow
            var lanes = (Self.offset, Self.offset ^ 1, Self.offset ^ 2, Self.offset ^ 3)
            var index = 0
            while index + 4 <= words {
                lanes.0 = (lanes.0 ^ line.loadUnaligned(fromByteOffset: index * 8, as: UInt64.self)) &* Self.prime
                lanes.1 = (lanes.1 ^ line.loadUnaligned(fromByteOffset: index * 8 + 8, as: UInt64.self)) &* Self.prime
                lanes.2 = (lanes.2 ^ line.loadUnaligned(fromByteOffset: index * 8 + 16, as: UInt64.self)) &* Self.prime
                lanes.3 = (lanes.3 ^ line.loadUnaligned(fromByteOffset: index * 8 + 24, as: UInt64.self)) &* Self.prime
                index += 4
            }
            var hash = lanes.0 ^ (lanes.1 &* 31) ^ (lanes.2 &* 961) ^ (lanes.3 &* 29_791)
            for byte in stride(from: index * 8, to: width * 4, by: 4) {
                hash = (hash ^ UInt64(line.loadUnaligned(fromByteOffset: byte, as: UInt32.self))) &* Self.prime
            }
            return hash
        }
    }

    private func columnHashes() -> [UInt64] {
        var hashes = [UInt64](repeating: Self.offset, count: width)
        hashes.withUnsafeMutableBufferPointer { hashes in
            for row in 0..<height {
                let line = base + row * bytesPerRow
                for column in 0..<width {
                    hashes[column] = (hashes[column] ^ UInt64(line.loadUnaligned(fromByteOffset: column * 4, as: UInt32.self))) &* Self.prime
                }
            }
        }
        return hashes
    }

    /// Lines `range` along `axis` as a tightly packed row-major block.
    func copyLines(_ range: Range<Int>, along axis: ScrollAxis) -> [UInt32] {
        let (columns, rows) = axis == .vertical ? (0..<width, range) : (range, 0..<height)
        return [UInt32](unsafeUninitializedCapacity: columns.count * rows.count) { buffer, count in
            for (index, row) in rows.enumerated() {
                memcpy(buffer.baseAddress! + index * columns.count, base + row * bytesPerRow + columns.lowerBound * 4, columns.count * 4)
            }
            count = columns.count * rows.count
        }
    }
}

/// Builds one long image from overlapping viewports of a scrolling region.
///
/// Each frame is aligned with the last accepted one by voting: every line whose hash is unique in
/// both frames votes for the displacement that maps it onto the earlier frame. Blank and repeated
/// lines abstain, so large jumps, sparse text, and small animated areas still align. The first
/// movement fixes the axis. Lines that stay in place at either edge are sticky chrome; they appear
/// once, at the matching end of the output. Frames that cannot be aligned are skipped, and the
/// next one is compared with the same accepted frame. Only newly revealed lines are copied.
struct ScrollStitcher {
    struct Limits: Sendable {
        var maximumExtent = 30_000
        var maximumBytes = 256 * 1_024 * 1_024
    }

    enum Update: Equatable, Sendable {
        /// Identical pixels, or content that changed in place without moving.
        case unchanged
        case moved
        /// No reliable displacement; the frame was ignored.
        case unmatched
        /// Growing further would exceed the limits; the output keeps what it has.
        case full
    }

    private struct Bands: Equatable {
        var leading = 0
        var trailing = 0
    }

    /// Accepted lines placed at `start` along the axis; a row-major block of pixels.
    private struct Strip {
        let start: Int
        let pixels: [UInt32]
    }

    let width: Int
    let height: Int
    private(set) var axis: ScrollAxis?
    private(set) var isFull = false
    private let limits: Limits
    private var rows: [UInt64]
    /// Column hashes of the accepted frame, needed until a vertical axis is known.
    private var columns: [UInt64]?
    private var bands = Bands()
    /// Document line shown at the top (or left) of the accepted frame.
    private var position = 0
    private var minimum = 0
    private var maximum = 0
    private var strips: [Strip]

    init(first frame: ScrollViewport, limits: Limits = .init()) {
        width = frame.width
        height = frame.height
        self.limits = limits
        rows = frame.lineHashes(along: .vertical)
        columns = frame.lineHashes(along: .horizontal)
        strips = [Strip(start: 0, pixels: frame.copyLines(0..<frame.height, along: .vertical))]
    }

    /// Output length along the axis; the viewport height before any movement.
    var extent: Int { length(along: axis ?? .vertical) + maximum - minimum }

    mutating func add(_ frame: ScrollViewport) -> Update {
        guard frame.width == width, frame.height == height else { return .unmatched }
        guard !isFull else { return .full }
        let currentRows = frame.lineHashes(along: .vertical)
        guard currentRows != rows else { return .unchanged }
        let currentColumns = axis == .vertical ? nil : frame.lineHashes(along: .horizontal)
        var candidates: [(ScrollAxis, [UInt64], [UInt64])] = []
        if axis != .horizontal { candidates.append((.vertical, rows, currentRows)) }
        if axis != .vertical, let columns, let currentColumns { candidates.append((.horizontal, columns, currentColumns)) }
        let matches = candidates.compactMap { axis, previous, current in
            Self.match(previous, current, bands: self.axis == axis ? bands : Bands()).map { (axis, $0) }
        }
        // Before the axis is known, the axis that moved wins over one that merely stayed in place.
        guard let (matchedAxis, match) = matches.first(where: { $0.1.displacement != 0 }) ?? matches.first else {
            return .unmatched
        }
        guard match.displacement != 0 else {
            rows = currentRows
            if axis != .vertical { columns = currentColumns }
            return .unchanged
        }
        let extent = length(along: matchedAxis)
        let newPosition = position + match.displacement
        let newMinimum = min(minimum, newPosition)
        let newMaximum = max(maximum, newPosition)
        let outputExtent = extent + newMaximum - newMinimum
        guard outputExtent <= limits.maximumExtent,
              outputExtent * breadth(along: matchedAxis) * 4 <= limits.maximumBytes else {
            isFull = true
            return .full
        }
        if newPosition > maximum {
            let lower = max(match.bands.leading, extent - match.bands.trailing - (newPosition - maximum))
            strips.append(Strip(start: newPosition + lower, pixels: frame.copyLines(lower..<extent, along: matchedAxis)))
        } else if newPosition < minimum {
            let upper = min(extent - match.bands.trailing, match.bands.leading + minimum - newPosition)
            strips.append(Strip(start: newPosition, pixels: frame.copyLines(0..<upper, along: matchedAxis)))
        }
        axis = matchedAxis
        bands = match.bands
        position = newPosition
        minimum = newMinimum
        maximum = newMaximum
        rows = currentRows
        columns = matchedAxis == .horizontal ? currentColumns : nil
        return .moved
    }

    /// The stitched image. Strips are copied in acceptance order, so newer lines replace the
    /// sticky chrome that earlier frames placed at the edge they extend.
    func render(colorSpace: CGColorSpace, bitmapInfo: CGBitmapInfo) -> CGImage? {
        let axis = axis ?? .vertical
        let breadth = breadth(along: axis)
        let (outputWidth, outputHeight) = axis == .vertical ? (width, extent) : (extent, height)
        let byteCount = outputWidth * outputHeight * 4
        guard byteCount > 0, let output = malloc(byteCount) else { return nil }
        for strip in strips {
            let lines = strip.pixels.count / breadth
            let offset = strip.start - minimum
            strip.pixels.withUnsafeBytes { source in
                if axis == .vertical {
                    memcpy(output + offset * outputWidth * 4, source.baseAddress!, strip.pixels.count * 4)
                } else {
                    for row in 0..<height {
                        memcpy(output + (row * outputWidth + offset) * 4, source.baseAddress! + row * lines * 4, lines * 4)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: output, size: byteCount, releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }) else {
            free(output)
            return nil
        }
        return CGImage(width: outputWidth, height: outputHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: outputWidth * 4, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func length(along axis: ScrollAxis) -> Int { axis == .vertical ? height : width }
    private func breadth(along axis: ScrollAxis) -> Int { axis == .vertical ? width : height }

    private struct Match {
        /// Positive when the view advanced toward the end of the document; zero when it stayed.
        let displacement: Int
        let bands: Bands
    }

    /// Nil when the frames share no reliable alignment.
    private static func match(_ previous: [UInt64], _ current: [UInt64], bands known: Bands) -> Match? {
        let extent = previous.count
        var previousIndex = [UInt64: Int](minimumCapacity: extent)
        for (line, hash) in previous.enumerated() { previousIndex[hash] = previousIndex[hash] == nil ? line : -1 }
        var currentCount = [UInt64: Int](minimumCapacity: extent)
        for hash in current { currentCount[hash, default: 0] += 1 }
        var votes: [Int: Int] = [:]
        for (line, hash) in current.enumerated() where currentCount[hash] == 1 {
            if let earlier = previousIndex[hash], earlier >= 0 { votes[earlier - line, default: 0] += 1 }
        }
        let ranked = votes.filter { $0.key != 0 }.sorted { $0.value > $1.value }
        if let best = ranked.first {
            let rival = ranked.dropFirst().first { abs($0.key - best.key) > 1 }?.value ?? 0
            if best.value >= 3 && best.value >= 2 * rival {
                let bands = stationaryBands(previous, current, displacement: best.key, known: known)
                let overlap = (bands.leading + max(0, -best.key))..<(extent - bands.trailing - max(0, best.key))
                let agreeing = overlap.count { previous[$0 + best.key] == current[$0] }
                if !overlap.isEmpty && agreeing * 2 >= overlap.count { return Match(displacement: best.key, bands: bands) }
            }
        }
        let unmoved = zip(previous, current).count { $0 == $1 }
        return unmoved * 2 >= extent ? Match(displacement: 0, bands: known) : nil
    }

    /// Lines equal in place at either edge that the displacement does not explain. Bands only grow,
    /// so a moment of blank content at an edge cannot reintroduce chrome into the middle.
    private static func stationaryBands(_ previous: [UInt64], _ current: [UInt64], displacement: Int, known: Bands) -> Bands {
        let extent = previous.count
        let cap = extent / 3
        func explained(_ line: Int) -> Bool {
            (0..<extent).contains(line + displacement) && previous[line + displacement] == current[line]
        }
        var leading = 0
        while leading < cap && previous[leading] == current[leading] { leading += 1 }
        while leading > 0 && explained(leading - 1) { leading -= 1 }
        var trailing = 0
        while trailing < cap && previous[extent - 1 - trailing] == current[extent - 1 - trailing] { trailing += 1 }
        while trailing > 0 && explained(extent - trailing) { trailing -= 1 }
        return Bands(leading: max(known.leading, leading), trailing: max(known.trailing, trailing))
    }
}
