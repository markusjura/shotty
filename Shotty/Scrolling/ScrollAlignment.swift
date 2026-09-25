import Foundation

enum ScrollAxis: String, Codable, Sendable, CaseIterable {
    case vertical, horizontal
}

enum ScrollCaptureError: Error, Equatable {
    case invalidFrame
    case resourceLimit
}

/// Immutable, tightly packed pixels. Each word is 0xRRGGBBAA, independent of host byte order.
struct ScrollFrame: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt32]

    init(width: Int, height: Int, pixels: [UInt32]) throws {
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !overflow, count == pixels.count else {
            throw ScrollCaptureError.invalidFrame
        }
        guard width <= 8_192, height <= 8_192, count <= 32 * 1_024 * 1_024 else {
            throw ScrollCaptureError.resourceLimit
        }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func extent(along axis: ScrollAxis) -> Int { axis == .vertical ? height : width }
    func breadth(along axis: ScrollAxis) -> Int { axis == .vertical ? width : height }

    func pixel(along position: Int, across cross: Int, axis: ScrollAxis) -> UInt32 {
        pixels[axis == .vertical ? position * width + cross : cross * width + position]
    }
}

struct ScrollStationaryBands: Equatable, Sendable {
    var leading = 0
    var trailing = 0
}

struct ScrollMatch: Equatable, Sendable {
    let axis: ScrollAxis
    /// Positive means the viewport advanced toward the end of the document.
    let displacement: Int
    /// Minimum fixed region supported by translation evidence, not a crop boundary.
    let bands: ScrollStationaryBands
    /// Entire in-place-equal edge runs, including padding whose ownership is unknown.
    /// Replacing these whole strips avoids baking fixed white padding into document rows.
    let replacementBands: ScrollStationaryBands
    let confidence: Double
}

enum ScrollRejection: String, Error, Equatable, Sendable {
    case changedDimensions
    case insufficientOverlap
    case ambiguousContent
    case unstableContent
    case axisChanged
    case stationaryBandsChanged
    case lengthLimit
    case memoryLimit
    case timeLimit
}

enum ScrollAlignmentResult: Equatable, Sendable {
    case unchanged
    case matched(ScrollMatch)
    case rejected(ScrollRejection)
}

/// Translation-only registration. Acquisition must supply settled frames of one fixed region.
/// Ambiguous or changing pixels pause the caller; they never become guessed seams.
/// Fixed chrome must already be present and keep its boundaries throughout the session.
struct ScrollAligner: Sendable {
    func align(previous: ScrollFrame, current: ScrollFrame, axis: ScrollAxis? = nil) -> ScrollAlignmentResult {
        guard previous.width == current.width, previous.height == current.height else {
            return .rejected(.changedDimensions)
        }
        if previous.pixels == current.pixels { return .unchanged }
        if let axis { return match(previous, current, axis: axis) }
        let vertical = match(previous, current, axis: .vertical)
        let horizontal = match(previous, current, axis: .horizontal)
        switch (vertical, horizontal) {
        case (.matched, .matched): return .rejected(.ambiguousContent)
        case (.matched, _): return vertical
        case (_, .matched): return horizontal
        case (.rejected(.ambiguousContent), _), (_, .rejected(.ambiguousContent)):
            return .rejected(.ambiguousContent)
        default: return .rejected(.insufficientOverlap)
        }
    }

    private struct Candidate {
        let displacement: Int
        let error: Double
        let exact: Bool
    }

    private func match(_ previous: ScrollFrame, _ current: ScrollFrame, axis: ScrollAxis) -> ScrollAlignmentResult {
        let extent = previous.extent(along: axis)
        let candidateBands = stationaryBands(previous, current, axis: axis)
        let body = extent - candidateBands.leading - candidateBands.trailing
        guard body >= 16 else { return .rejected(.insufficientOverlap) }
        // At least half of the moving body must remain visible between accepted frames.
        let maximumStep = body / 2
        let previousLines = lineFingerprints(previous, axis: axis)
        let currentLines = lineFingerprints(current, axis: axis)
        var candidates: [Candidate] = []
        candidates.reserveCapacity(maximumStep * 2)
        for displacement in -maximumStep...maximumStep where displacement != 0 {
            let start = candidateBands.leading + max(0, -displacement)
            let end = extent - candidateBands.trailing - max(0, displacement)
            let exact = (start..<end).allSatisfy { previousLines[$0 + displacement] == currentLines[$0] }
            let error = difference(previous, current, axis: axis, bands: candidateBands,
                                   displacement: displacement, lineSamples: 24, crossSamples: 16).mean
            candidates.append(Candidate(displacement: displacement, error: error, exact: exact))
        }
        candidates.sort { $0.exact == $1.exact ? $0.error < $1.error : $0.exact }
        guard var best = candidates.first, best.error <= 0.012 else {
            return .rejected(.insufficientOverlap)
        }
        // A unique exact overlap resolves coarse-sampling ambiguity on sparse text. Render noise
        // defeats exactness, so near-tied approximate seams are re-ranked with denser samples.
        // Distinct plausible seams, including repeated rows, are rejected.
        if best.exact {
            if candidates.dropFirst().contains(where: \.exact) { return .rejected(.ambiguousContent) }
        } else {
            guard let resolved = resolveNearTies(candidates, previous, current, axis: axis, bands: candidateBands) else {
                return .rejected(.ambiguousContent)
            }
            best = resolved
        }
        let bands = refineStationaryBands(candidateBands, previous: previous, current: current,
                                          axis: axis, displacement: best.displacement)
        if best.exact {
            let start = bands.leading + max(0, -best.displacement)
            let end = extent - bands.trailing - max(0, best.displacement)
            guard (start..<end).allSatisfy({
                linesEqual(previous, at: $0 + best.displacement, current, at: $0, axis: axis)
            }) else { return .rejected(.unstableContent) }
        }
        let verified = difference(previous, current, axis: axis, bands: bands,
                                  displacement: best.displacement, lineSamples: 192, crossSamples: 64)
        guard verified.mean <= 0.012, verified.outlierFraction <= 0.025 else {
            return .rejected(.unstableContent)
        }
        return .matched(ScrollMatch(axis: axis, displacement: best.displacement, bands: bands, replacementBands: candidateBands,
                                    confidence: max(0, 1 - verified.mean / 0.012)))
    }

    /// Picks among approximate seams: the coarse best, its ±1 neighbors, and rivals whose coarse
    /// errors lie within the ambiguity margin. 24 × 16 samples can miss sparse glyphs, so these are
    /// re-ranked with 192 × 64 samples under the same margin.
    ///
    /// Rivals that remain close are judged by strong outliers across the full breadth. Mean errors
    /// dilute a narrow distinguishing region, such as unique row IDs beside repeated text, and a
    /// wrong period-multiple seam there can stay within the 2.5% outlier tolerances of the final
    /// verification and the output overlap check. Render noise stays far below the outlier level,
    /// so the leader must leave almost none, while each rival must leave at least 8× as many and
    /// at least 100. Genuinely repeated content, or content that changed so no seam explains it,
    /// lacks that separation and stays ambiguous.
    ///
    /// Lists produce a few rivals per row period, so their count grows with the viewport. Rivals
    /// on more than an eighth of all displacements indicate nearly uniform content; the cap and
    /// the early exit on each rival's count bound the work.
    private func resolveNearTies(_ sorted: [Candidate], _ previous: ScrollFrame, _ current: ScrollFrame,
                                 axis: ScrollAxis, bands: ScrollStationaryBands) -> Candidate? {
        func rivals(_ leader: Candidate, among pool: some Sequence<Candidate>) -> [Candidate] {
            pool.filter { abs($0.displacement - leader.displacement) > 1 && $0.error - leader.error < 0.008 }
        }
        let coarseRivals = rivals(sorted[0], among: sorted.dropFirst())
        guard coarseRivals.count <= max(64, sorted.count / 8) else { return nil }
        let neighbors = sorted.filter { abs($0.displacement - sorted[0].displacement) == 1 }
        let reranked = ([sorted[0]] + neighbors + coarseRivals).map { candidate in
            Candidate(displacement: candidate.displacement,
                      error: difference(previous, current, axis: axis, bands: bands, displacement: candidate.displacement,
                                        lineSamples: 192, crossSamples: 64).mean,
                      exact: false)
        }.sorted { $0.error < $1.error }
        let leader = reranked[0]
        let closeRivals = rivals(leader, among: reranked.dropFirst())
        guard !closeRivals.isEmpty else { return leader }
        let leaderOutliers = strongOutliers(previous, current, axis: axis, bands: bands,
                                            displacement: leader.displacement, stoppingAt: .max)
        let required = max(100, 8 * leaderOutliers)
        return closeRivals.allSatisfy({
            strongOutliers(previous, current, axis: axis, bands: bands,
                           displacement: $0.displacement, stoppingAt: required) >= required
        }) ? leader : nil
    }

    /// Pixels differing visibly after translation, on 192 overlapping lines at full breadth.
    /// Counting stops once `limit` is reached.
    private func strongOutliers(_ previous: ScrollFrame, _ current: ScrollFrame, axis: ScrollAxis,
                                bands: ScrollStationaryBands, displacement: Int, stoppingAt limit: Int) -> Int {
        let start = bands.leading + max(0, -displacement)
        let end = previous.extent(along: axis) - bands.trailing - max(0, displacement)
        let breadth = previous.breadth(along: axis)
        var total = 0
        for line in positions(count: end - start, samples: 192) where total < limit {
            total += (0..<breadth).count {
                colorDifference(previous.pixel(along: start + line + displacement, across: $0, axis: axis),
                                current.pixel(along: start + line, across: $0, axis: axis)) > 0.05
            }
        }
        return total
    }

    private func stationaryBands(_ previous: ScrollFrame, _ current: ScrollFrame, axis: ScrollAxis) -> ScrollStationaryBands {
        let extent = previous.extent(along: axis)
        func sameLine(_ line: Int) -> Bool {
            linesEqual(previous, at: line, current, at: line, axis: axis)
        }
        // Larger fixed regions require the user to tighten the capture boundary.
        let cap = extent / 4
        var bands = ScrollStationaryBands()
        while bands.leading < cap && sameLine(bands.leading) { bands.leading += 1 }
        while bands.trailing < cap && sameLine(extent - bands.trailing - 1) { bands.trailing += 1 }
        return bands
    }

    /// Blank document rows can be equal in place as well as after translation.
    /// Only the part that translation cannot explain is evidence of fixed chrome.
    private func refineStationaryBands(_ candidate: ScrollStationaryBands, previous: ScrollFrame,
                                       current: ScrollFrame, axis: ScrollAxis, displacement: Int) -> ScrollStationaryBands {
        let extent = previous.extent(along: axis)
        func explainedByTranslation(_ line: Int) -> Bool {
            let previousLine = line + displacement
            let currentLine = line - displacement
            var compared = false
            if (0..<extent).contains(previousLine) {
                guard linesEqual(previous, at: previousLine, current, at: line, axis: axis) else { return false }
                compared = true
            }
            if (0..<extent).contains(currentLine) {
                guard linesEqual(previous, at: line, current, at: currentLine, axis: axis) else { return false }
                compared = true
            }
            return compared
        }
        var bands = candidate
        while bands.leading > 0 && explainedByTranslation(bands.leading - 1) { bands.leading -= 1 }
        while bands.trailing > 0 && explainedByTranslation(extent - bands.trailing) { bands.trailing -= 1 }
        return bands
    }

    /// Edge classification must see sparse glyphs between the alignment samples.
    private func linesEqual(_ previous: ScrollFrame, at previousLine: Int,
                            _ current: ScrollFrame, at currentLine: Int, axis: ScrollAxis) -> Bool {
        (0..<previous.breadth(along: axis)).allSatisfy {
            previous.pixel(along: previousLine, across: $0, axis: axis) == current.pixel(along: currentLine, across: $0, axis: axis)
        }
    }

    /// Full rows distinguish thin strokes and text lines that coarse samples miss.
    /// Fingerprints only select candidates; exact candidates are verified pixel by pixel.
    private func lineFingerprints(_ frame: ScrollFrame, axis: ScrollAxis) -> [UInt64] {
        (0..<frame.extent(along: axis)).map { line in
            var hash: UInt64 = 14_695_981_039_346_656_037
            for cross in 0..<frame.breadth(along: axis) {
                hash = (hash ^ UInt64(frame.pixel(along: line, across: cross, axis: axis))) &* 1_099_511_628_211
            }
            return hash
        }
    }

    private func difference(_ previous: ScrollFrame, _ current: ScrollFrame, axis: ScrollAxis,
                            bands: ScrollStationaryBands, displacement: Int,
                            lineSamples: Int, crossSamples: Int) -> (mean: Double, outlierFraction: Double) {
        let start = bands.leading + max(0, -displacement)
        let end = previous.extent(along: axis) - bands.trailing - max(0, displacement)
        let lines = positions(count: end - start, samples: lineSamples)
        let crosses = positions(count: previous.breadth(along: axis), samples: crossSamples)
        var total = 0.0
        var outliers = 0
        for line in lines {
            for cross in crosses {
                let a = previous.pixel(along: start + line + displacement, across: cross, axis: axis)
                let b = current.pixel(along: start + line, across: cross, axis: axis)
                let error = colorDifference(a, b)
                total += error
                if error > 0.05 { outliers += 1 }
            }
        }
        let count = Double(lines.count * crosses.count)
        return (total / count, Double(outliers) / count)
    }

    private func positions(count: Int, samples: Int) -> [Int] {
        let sampleCount = min(count, samples)
        guard sampleCount > 1 else { return [0] }
        return (0..<sampleCount).map { $0 * (count - 1) / (sampleCount - 1) }
    }

    private func colorDifference(_ a: UInt32, _ b: UInt32) -> Double {
        let red = abs(Int((a >> 24) & 255) - Int((b >> 24) & 255))
        let green = abs(Int((a >> 16) & 255) - Int((b >> 16) & 255))
        let blue = abs(Int((a >> 8) & 255) - Int((b >> 8) & 255))
        let alpha = abs(Int(a & 255) - Int(b & 255))
        return Double(red + green + blue + alpha) / 1_020
    }
}
