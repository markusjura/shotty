import CoreGraphics
import Foundation

enum ScrollAxis: Sendable {
    case vertical, horizontal
}

/// Fingerprints of every row (vertical) or column (horizontal) of one frame.
struct ScrollLines {
    static let spans = 8

    /// Exact identity: equal lines hash equally.
    let hashes: [UInt64]
    /// Brightness of each line summed over `spans` equal parts of it, `spans` values per line.
    /// Frames captured mid-scroll are composited at subpixel offsets, so the same line can differ by
    /// a few levels between frames and its hash changes, while each sum stays within `tolerance`.
    let profiles: [Int32]
    /// One level per pixel of a span.
    let tolerance: Int32

    var count: Int { hashes.count }

    func total(of line: Int) -> Int32 { profiles[(line * Self.spans)..<((line + 1) * Self.spans)].reduce(0, +) }

    /// Whether the line varies across its spans by more than noise, so it has content to align by.
    func hasContent(_ line: Int) -> Bool {
        let profile = profiles[(line * Self.spans)..<((line + 1) * Self.spans)]
        return profile.max()! - profile.min()! > tolerance
    }

    /// Whether `line` matches line `earlier` of `previous` within noise.
    func line(_ line: Int, matches earlier: Int, of previous: ScrollLines) -> Bool {
        for span in 0..<Self.spans where abs(profiles[line * Self.spans + span] - previous.profiles[earlier * Self.spans + span]) > tolerance {
            return false
        }
        return true
    }
}

/// Borrowed 32-bit pixels of one captured viewport. Valid only during the call that receives it.
struct ScrollViewport {
    let base: UnsafeRawPointer
    let width: Int
    let height: Int
    let bytesPerRow: Int

    private static let offset: UInt64 = 0xCBF2_9CE4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01B3

    func lines(along axis: ScrollAxis) -> ScrollLines {
        // Rows are summed two pixels at a time, so their spans hold whole 8-byte words.
        let span = axis == .vertical ? width / (2 * ScrollLines.spans) * 2 : height / ScrollLines.spans
        return ScrollLines(hashes: axis == .vertical ? rowHashes() : columnHashes(),
                           profiles: axis == .vertical ? rowProfiles(span: span) : columnProfiles(span: span),
                           tolerance: Int32(span))
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

    private static let laneMask: UInt64 = 0x00FF_00FF_00FF_00FF

    /// Each 8-byte word holds two BGRA pixels. One mask and add sums their channels pairwise into
    /// four 16-bit lanes, which take 128 words before they could overflow. Captures are opaque, so
    /// alpha adds the same to every span. Pixels past the last whole span are left out.
    private func rowProfiles(span: Int) -> [Int32] {
        let words = span / 2
        var profiles = [Int32](repeating: 0, count: height * ScrollLines.spans)
        for row in 0..<height {
            let line = base + row * bytesPerRow
            for part in 0..<ScrollLines.spans {
                var sum: UInt64 = 0
                var word = part * words
                let end = word + words
                while word < end {
                    var lanes: UInt64 = 0
                    let stop = min(end, word + 128)
                    while word < stop {
                        let pixels = line.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self)
                        lanes &+= (pixels & Self.laneMask) &+ (pixels >> 8 & Self.laneMask)
                        word += 1
                    }
                    sum += (lanes & 0xFFFF) + (lanes >> 16 & 0xFFFF) + (lanes >> 32 & 0xFFFF) + (lanes >> 48)
                }
                profiles[row * ScrollLines.spans + part] = Int32(sum)
            }
        }
        return profiles
    }

    /// Sums down two columns at once, like `rowProfiles`, flushing the lanes every 128 rows. The
    /// last column of an odd width is left out.
    private func columnProfiles(span: Int) -> [Int32] {
        var profiles = [Int32](repeating: 0, count: width * ScrollLines.spans)
        var lanes = [UInt64](repeating: 0, count: width / 2)
        profiles.withUnsafeMutableBufferPointer { profiles in
            lanes.withUnsafeMutableBufferPointer { lanes in
                func flush(into part: Int) {
                    for (word, lane) in lanes.enumerated() {
                        profiles[2 * word * ScrollLines.spans + part] += Int32(lane & 0xFFFF) + Int32(lane >> 16 & 0xFFFF)
                        profiles[(2 * word + 1) * ScrollLines.spans + part] += Int32(lane >> 32 & 0xFFFF) + Int32(lane >> 48)
                    }
                    lanes.update(repeating: 0)
                }
                for part in 0..<ScrollLines.spans {
                    for (index, row) in ((part * span)..<((part + 1) * span)).enumerated() {
                        let line = base + row * bytesPerRow
                        for word in lanes.indices {
                            let pixels = line.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self)
                            lanes[word] &+= (pixels & Self.laneMask) &+ (pixels >> 8 & Self.laneMask)
                        }
                        if index % 128 == 127 { flush(into: part) }
                    }
                    flush(into: part)
                }
            }
        }
        return profiles
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
/// lines abstain, so large jumps, sparse text, and small animated areas still align. Frames
/// captured while a trackpad scroll is in motion differ by a few levels from any other frame, so
/// when hashes find nothing, lines vote wherever their profiles match within noise. The first
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
    private var rows: ScrollLines
    /// Columns of the accepted frame, needed until a vertical axis is known.
    private var columns: ScrollLines?
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
        rows = frame.lines(along: .vertical)
        columns = frame.lines(along: .horizontal)
        strips = [Strip(start: 0, pixels: frame.copyLines(0..<frame.height, along: .vertical))]
    }

    /// Output length along the axis; the viewport height before any movement.
    var extent: Int { length(along: axis ?? .vertical) + maximum - minimum }

    mutating func add(_ frame: ScrollViewport) -> Update {
        guard frame.width == width, frame.height == height else { return .unmatched }
        guard !isFull else { return .full }
        let currentRows = frame.lines(along: .vertical)
        guard currentRows.hashes != rows.hashes else { return .unchanged }
        let vertical = axis == .horizontal ? nil : Self.match(rows, currentRows, bands: axis == .vertical ? bands : Bands())
        // Before the axis is known, the axis that moved wins over one that merely stayed in place.
        // Columns cost far more to read than rows, so they are only read when rows did not move.
        var currentColumns: ScrollLines?
        var horizontal: Match?
        if axis != .vertical, vertical.map({ $0.displacement == 0 }) ?? true, let columns {
            let current = frame.lines(along: .horizontal)
            currentColumns = current
            horizontal = Self.match(columns, current, bands: axis == .horizontal ? bands : Bands())
        }
        let moving = [(ScrollAxis.vertical, vertical), (.horizontal, horizontal)].compactMap { axis, match in match.map { (axis, $0) } }
        guard let (matchedAxis, match) = moving.first(where: { $0.1.displacement != 0 }) ?? moving.first else {
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

    /// Nil when the frames share no reliable alignment. Exact hashes are tried first, as they are
    /// cheaper and stricter; profiles only run when hashes find nothing.
    private static func match(_ previous: ScrollLines, _ current: ScrollLines, bands known: Bands) -> Match? {
        let (before, after) = (previous.hashes, current.hashes)
        let equal = { (earlier: Int, line: Int) in before[earlier] == after[line] }
        if let match = moved(by: exactVotes(before, after), previous, current, bands: known, same: equal) { return match }
        let similar = { (earlier: Int, line: Int) in current.line(line, matches: earlier, of: previous) }
        if let match = moved(by: similarVotes(previous, current), previous, current, bands: known, same: similar) { return match }
        let unmoved = zip(before, after).count { $0 == $1 }
        return unmoved * 2 >= before.count ? Match(displacement: 0, bands: known) : nil
    }

    /// Every line whose hash is unique in both frames votes for the displacement onto the earlier one.
    private static func exactVotes(_ previous: [UInt64], _ current: [UInt64]) -> [Int: Int] {
        var previousIndex = [UInt64: Int](minimumCapacity: previous.count)
        for (line, hash) in previous.enumerated() { previousIndex[hash] = previousIndex[hash] == nil ? line : -1 }
        var currentCount = [UInt64: Int](minimumCapacity: current.count)
        for hash in current { currentCount[hash, default: 0] += 1 }
        var votes: [Int: Int] = [:]
        for (line, hash) in current.enumerated() where currentCount[hash] == 1 {
            if let earlier = previousIndex[hash], earlier >= 0 { votes[earlier - line, default: 0] += 1 }
        }
        return votes
    }

    /// Every line with content votes for each displacement onto an earlier line it matches within
    /// noise. Matching lines have totals within `spans` tolerances of each other, so each line is
    /// only compared with the earlier lines in that window of totals.
    private static func similarVotes(_ previous: ScrollLines, _ current: ScrollLines) -> [Int: Int] {
        let window = Int32(ScrollLines.spans) * current.tolerance
        let earlier = (0..<previous.count).map { (total: previous.total(of: $0), line: $0) }.sorted { $0.total < $1.total }
        var votes: [Int: Int] = [:]
        for line in 0..<current.count where current.hasContent(line) {
            let total = current.total(of: line)
            // The first earlier line whose total is within the window.
            var (low, high) = (0, earlier.count)
            while low < high {
                let middle = (low + high) / 2
                if earlier[middle].total < total - window { low = middle + 1 } else { high = middle }
            }
            for candidate in earlier[low...].prefix(while: { $0.total <= total + window })
            where current.line(line, matches: candidate.line, of: previous) {
                votes[candidate.line - line, default: 0] += 1
            }
        }
        return votes
    }

    /// The displacement that clearly wins `votes`, if at least half the overlapping lines with content
    /// confirm it. Blank lines match any other blank line, so frames that share no content but are
    /// mostly blank would otherwise confirm a few chance votes. `same(earlier, line)` compares a line
    /// of the previous frame with one of the current frame.
    private static func moved(by votes: [Int: Int], _ previous: ScrollLines, _ current: ScrollLines, bands known: Bands,
                              same: (Int, Int) -> Bool) -> Match? {
        let ranked = votes.filter { $0.key != 0 }.sorted { $0.value > $1.value }
        guard let best = ranked.first else { return nil }
        let rival = ranked.dropFirst().first { abs($0.key - best.key) > 1 }?.value ?? 0
        guard best.value >= 3 && best.value >= 2 * rival else { return nil }
        let extent = previous.count
        let bands = stationaryBands(previous.hashes, current.hashes, displacement: best.key, known: known, same: same)
        let overlap = (bands.leading + max(0, -best.key))..<(extent - bands.trailing - max(0, best.key))
        let confirming = overlap.filter(current.hasContent)
        let agreeing = confirming.count { same($0 + best.key, $0) }
        guard !confirming.isEmpty && agreeing * 2 >= confirming.count else { return nil }
        return Match(displacement: best.key, bands: bands)
    }

    /// Lines equal in place at either edge that the displacement does not explain. Bands only grow,
    /// so a moment of blank content at an edge cannot reintroduce chrome into the middle. Chrome
    /// never moves, so it stays exactly equal in place even when scrolled lines only match by `same`.
    private static func stationaryBands(_ previous: [UInt64], _ current: [UInt64], displacement: Int, known: Bands,
                                        same: (Int, Int) -> Bool) -> Bands {
        let extent = previous.count
        let cap = extent / 3
        func explained(_ line: Int) -> Bool {
            (0..<extent).contains(line + displacement) && same(line + displacement, line)
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
