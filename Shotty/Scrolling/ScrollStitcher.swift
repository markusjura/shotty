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

    /// Copies lines `range` along `axis` into `destination`, whose rows start `stride` pixels apart.
    func copyLines(_ range: Range<Int>, along axis: ScrollAxis, into destination: UnsafeMutablePointer<UInt32>, stride: Int) {
        let (columns, rows) = axis == .vertical ? (0..<width, range) : (range, 0..<height)
        for (index, row) in rows.enumerated() {
            memcpy(destination + index * stride, base + row * bytesPerRow + columns.lowerBound * 4, columns.count * 4)
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
/// next one is compared with the same accepted frame. Accepted frames go to a `Canvas`, which
/// keeps each line's cleanest copy.
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
    /// The first frame, row-major, until the first movement fixes the axis and `canvas` takes it.
    private var first: [UInt32]
    private var canvas: Canvas?

    init(first frame: ScrollViewport, limits: Limits = .init()) {
        width = frame.width
        height = frame.height
        self.limits = limits
        rows = frame.lines(along: .vertical)
        columns = frame.lines(along: .horizontal)
        first = [UInt32](unsafeUninitializedCapacity: frame.width * frame.height) { buffer, count in
            frame.copyLines(0..<frame.height, along: .vertical, into: buffer.baseAddress!, stride: frame.width)
            count = frame.width * frame.height
        }
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
        if canvas == nil {
            // Written with this frame's bands, so the first frame's chrome is not taken for content.
            let first = first
            self.first = []
            canvas = Canvas(axis: matchedAxis, breadth: breadth(along: matchedAxis))
            first.withUnsafeBytes { bytes in
                canvas!.write(ScrollViewport(base: bytes.baseAddress!, width: width, height: height, bytesPerRow: width * 4),
                              at: 0, bands: match.bands)
            }
        }
        // Lines past the edge the frame extends, with its chrome there, replace what earlier frames
        // left at that edge even when they rank lower, as the bands found then may have been smaller.
        let extending = if newPosition > maximum {
            max(match.bands.leading, extent - match.bands.trailing - (newPosition - maximum))..<extent
        } else if newPosition < minimum {
            0..<min(extent - match.bands.trailing, match.bands.leading + minimum - newPosition)
        } else {
            0..<0
        }
        canvas!.write(frame, at: newPosition, bands: match.bands, extending: extending)
        axis = matchedAxis
        bands = match.bands
        position = newPosition
        minimum = newMinimum
        maximum = newMaximum
        rows = currentRows
        columns = matchedAxis == .horizontal ? currentColumns : nil
        return .moved
    }

    /// The stitched image.
    func render(colorSpace: CGColorSpace, bitmapInfo: CGBitmapInfo) -> CGImage? {
        let axis = axis ?? .vertical
        let (outputWidth, outputHeight) = axis == .vertical ? (width, extent) : (extent, height)
        let byteCount = outputWidth * outputHeight * 4
        guard byteCount > 0, let output = calloc(byteCount, 1) else { return nil }
        if let canvas {
            canvas.render(minimum..<(minimum + extent), into: output.assumingMemoryBound(to: UInt32.self))
        } else {
            memcpy(output, first, byteCount)
        }
        guard let provider = CGDataProvider(dataInfo: nil, data: output, size: byteCount, releaseData: { _, data, _ in free(UnsafeMutableRawPointer(mutating: data)) }) else {
            free(output)
            return nil
        }
        return CGImage(width: outputWidth, height: outputHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: outputWidth * 4, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// Accepted lines by document position along the axis. Each line keeps the copy from the frame
    /// that showed it farthest inside the scrolling content. Translucent overlays at the edges, like
    /// a toolbar's scroll edge effect or a fade above a chat composer, tint whatever scrolls under
    /// them, so lines copied as they enter would carry the tint into the middle of the image as
    /// stripes. Lines live in blocks, so the image grows at either end without moving what it has.
    private struct Canvas {
        private static let blockLines = 256

        private struct Block {
            /// Row-major pixels of the block's lines.
            var pixels: [UInt32]
            /// How far inside its frame each line's copy was, from `Canvas.write`; nil until copied.
            var quality: [Int?]

            /// Copies those of the frame's `lines` whose `rank` beats the held copy's, and those in
            /// `extending`, the first to the block's line `index`, in runs of consecutive lines.
            mutating func write(_ frame: ScrollViewport, lines: Range<Int>, at index: Int, axis: ScrollAxis,
                                rank: (Int) -> Int, extending: Range<Int>) {
                let (stride, step) = axis == .vertical ? (frame.width, frame.width) : (Canvas.blockLines, 1)
                let offset = index - lines.lowerBound
                var run: Range<Int>?
                func flush() {
                    guard let copied = run else { return }
                    pixels.withUnsafeMutableBufferPointer {
                        frame.copyLines(copied, along: axis, into: $0.baseAddress! + (copied.lowerBound + offset) * step, stride: stride)
                    }
                    run = nil
                }
                for line in lines {
                    let rank = rank(line)
                    if extending.contains(line) || quality[line + offset].map({ rank > $0 }) ?? true {
                        quality[line + offset] = rank
                        run = (run?.lowerBound ?? line)..<(line + 1)
                    } else {
                        flush()
                    }
                }
                flush()
            }
        }

        let axis: ScrollAxis
        let breadth: Int
        private var blocks: [Int: Block] = [:]

        init(axis: ScrollAxis, breadth: Int) {
            self.axis = axis
            self.breadth = breadth
        }

        /// Copies the lines of `frame`, its first line at document line `position`, that improve on
        /// the copies held, and its lines `extending` regardless. A content line ranks by its distance
        /// to the nearer edge of the content, counted up to a quarter of the content, so a copy that
        /// far inside is final and a steady scroll rewrites about that many lines per frame. Chrome
        /// ranks below any content, so it only fills lines that no frame has shown as content.
        mutating func write(_ frame: ScrollViewport, at position: Int, bands: Bands, extending: Range<Int> = 0..<0) {
            let extent = axis == .vertical ? frame.height : frame.width
            let content = bands.leading..<(extent - bands.trailing)
            let cap = max(1, content.count / 4)
            let quality = { (line: Int) in
                content.contains(line) ? min(line - content.lowerBound, content.upperBound - 1 - line, cap) : -1
            }
            var line = 0
            while line < extent {
                let (block, index) = Self.locate(position + line)
                let lines = line..<min(extent, line + Self.blockLines - index)
                blocks[block, default: Block(pixels: Array(repeating: 0, count: Self.blockLines * breadth),
                                             quality: Array(repeating: nil, count: Self.blockLines))]
                    .write(frame, lines: lines, at: index, axis: axis, rank: quality, extending: extending)
                line = lines.upperBound
            }
        }

        /// Copies document lines `lines` into `output`, a tightly packed image of exactly them.
        func render(_ lines: Range<Int>, into output: UnsafeMutablePointer<UInt32>) {
            var line = lines.lowerBound
            while line < lines.upperBound {
                let (block, index) = Self.locate(line)
                let count = min(lines.upperBound - line, Self.blockLines - index)
                let offset = line - lines.lowerBound
                blocks[block]?.pixels.withUnsafeBufferPointer { pixels in
                    if axis == .vertical {
                        memcpy(output + offset * breadth, pixels.baseAddress! + index * breadth, count * breadth * 4)
                    } else {
                        for row in 0..<breadth {
                            memcpy(output + row * lines.count + offset, pixels.baseAddress! + row * Self.blockLines + index, count * 4)
                        }
                    }
                }
                line += count
            }
        }

        /// The block holding a document line, which may be negative, and the line's index in it.
        private static func locate(_ line: Int) -> (block: Int, index: Int) {
            let block = line >= 0 ? line / blockLines : (line + 1) / blockLines - 1
            return (block, line - block * blockLines)
        }
    }

    private func length(along axis: ScrollAxis) -> Int { axis == .vertical ? height : width }
    private func breadth(along axis: ScrollAxis) -> Int { axis == .vertical ? width : height }

    private struct Match {
        /// Positive when the view advanced toward the end of the document; zero when it stayed.
        let displacement: Int
        let bands: Bands
    }

    /// Displacements this close count as the same alignment. Scrolling by a fraction of a line, or
    /// content drawn two or three scanlines tall, leaves neighboring displacements nearly as good.
    private static let slack = 1

    /// Displacement votes, and which lines of the current frame may confirm the winner: those whose
    /// matches in the earlier frame all lie within `slack` of one line, like a scanline drawn twice
    /// by Retina scaling. Blank and other repeated lines match all over, so they agree with any
    /// displacement and would confirm chance votes between unrelated frames.
    private struct Ballot {
        var votes: [Int: Int] = [:]
        var confirmers: [Bool]

        /// Whether a line whose matches span `lines` of the earlier frame, nil for none, may confirm.
        static func confirms(_ lines: ClosedRange<Int>?) -> Bool { lines.map { $0.count <= 2 * slack + 1 } ?? true }
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
    private static func exactVotes(_ previous: [UInt64], _ current: [UInt64]) -> Ballot {
        var occurrences = [UInt64: ClosedRange<Int>](minimumCapacity: previous.count)
        for (line, hash) in previous.enumerated() { occurrences[hash] = (occurrences[hash]?.lowerBound ?? line)...line }
        var currentCount = [UInt64: Int](minimumCapacity: current.count)
        for hash in current { currentCount[hash, default: 0] += 1 }
        var ballot = Ballot(confirmers: current.map { Ballot.confirms(occurrences[$0]) })
        for (line, hash) in current.enumerated() where currentCount[hash] == 1 {
            if let earlier = occurrences[hash], earlier.count == 1 { ballot.votes[earlier.lowerBound - line, default: 0] += 1 }
        }
        return ballot
    }

    /// Every line with content votes for each displacement onto an earlier line it matches within
    /// noise. Matching lines have totals within `spans` tolerances of each other, so each line is
    /// only compared with the earlier lines in that window of totals.
    private static func similarVotes(_ previous: ScrollLines, _ current: ScrollLines) -> Ballot {
        let window = Int32(ScrollLines.spans) * current.tolerance
        let earlier = (0..<previous.count).map { (total: previous.total(of: $0), line: $0) }.sorted { $0.total < $1.total }
        var ballot = Ballot(confirmers: Array(repeating: true, count: current.count))
        for line in 0..<current.count {
            let total = current.total(of: line)
            let hasContent = current.hasContent(line)
            // The first earlier line whose total is within the window.
            var (low, high) = (0, earlier.count)
            while low < high {
                let middle = (low + high) / 2
                if earlier[middle].total < total - window { low = middle + 1 } else { high = middle }
            }
            var matched: ClosedRange<Int>?
            for candidate in earlier[low...] {
                // A line without content only needs to know whether it confirms.
                guard candidate.total <= total + window, hasContent || Ballot.confirms(matched) else { break }
                guard current.line(line, matches: candidate.line, of: previous) else { continue }
                matched = matched.map { min($0.lowerBound, candidate.line)...max($0.upperBound, candidate.line) } ?? candidate.line...candidate.line
                if hasContent { ballot.votes[candidate.line - line, default: 0] += 1 }
            }
            ballot.confirmers[line] = Ballot.confirms(matched)
        }
        return ballot
    }

    /// The displacement that clearly wins the ballot, if at least half of the confirming lines in the
    /// overlap agree with it and staying in place does not explain the confirming lines as well.
    /// Smooth content, such as a gradient, matches its neighbors, so a frame that only changed in
    /// place would otherwise move by a line. `same(earlier, line)` compares a line of the previous
    /// frame with one of the current frame.
    private static func moved(by ballot: Ballot, _ previous: ScrollLines, _ current: ScrollLines, bands known: Bands,
                              same: (Int, Int) -> Bool) -> Match? {
        let ranked = ballot.votes.filter { $0.key != 0 }.sorted { $0.value > $1.value }
        guard let best = ranked.first else { return nil }
        let rival = ranked.dropFirst().first { abs($0.key - best.key) > slack }?.value ?? 0
        guard best.value >= 3 && best.value >= 2 * rival else { return nil }
        let extent = previous.count
        let bands = stationaryBands(previous.hashes, current.hashes, displacement: best.key, known: known, same: same)
        let overlap = ((bands.leading + max(0, -best.key))..<(extent - bands.trailing - max(0, best.key))).filter { ballot.confirmers[$0] }
        let agreeing = overlap.count { same($0 + best.key, $0) }
        guard !overlap.isEmpty && agreeing * 2 >= overlap.count else { return nil }
        let unmoved = (bands.leading..<(extent - bands.trailing)).filter { ballot.confirmers[$0] }
        let staying = unmoved.count { same($0, $0) }
        // Compared as shares, since the overlap is smaller than the whole frame.
        guard staying * overlap.count < agreeing * unmoved.count else { return nil }
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
