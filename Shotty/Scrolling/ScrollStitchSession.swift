import Foundation

struct ScrollLimits: Sendable {
    var maximumAxisPixels = 30_000
    var maximumOutputBytes = 256 * 1_024 * 1_024
    var maximumDuration: TimeInterval = 120
}

/// Apply this edit to caller-owned disk-backed tiles, then publish the new preview.
/// The range addresses full-resolution rows (vertical) or columns (horizontal).
struct ScrollStripEdit: Equatable, Sendable {
    enum Edge: Sendable { case leading, trailing }
    let edge: Edge
    let removePixelCount: Int
    let sourceRange: Range<Int>
}

enum ScrollStep: Equatable, Sendable {
    case unchanged
    case repositioned(ScrollMatch)
    case extended(ScrollMatch, ScrollStripEdit)
    case paused(ScrollRejection)
}

/// Owns one accepted viewport, not the accumulated output. Rejected frames leave all
/// positions untouched so the caller can resume from the last accepted viewport.
struct ScrollStitchSession: Sendable {
    private(set) var previous: ScrollFrame
    private(set) var axis: ScrollAxis?
    private(set) var outputAxisPixels: Int?
    /// Output line holding the accepted viewport's first line. Before an accepted step, adding
    /// the match displacement gives the new frame's line offset within the existing output.
    var viewportOffset: Int { position - minimumPosition }
    private var minimumStationaryBands = ScrollStationaryBands()
    private var position = 0
    private var minimumPosition = 0
    private var maximumPosition = 0
    private let startedAt: TimeInterval
    private let limits: ScrollLimits
    private let aligner = ScrollAligner()

    /// The caller initially stores the entire first frame as the output.
    /// Pass monotonic time, for example ProcessInfo.processInfo.systemUptime.
    init(firstFrame: ScrollFrame, axis: ScrollAxis? = nil, startedAt: TimeInterval, limits: ScrollLimits = .init()) throws {
        guard limits.maximumAxisPixels > 0, limits.maximumOutputBytes > 0,
              limits.maximumDuration > 0, limits.maximumDuration.isFinite, startedAt.isFinite else {
            throw ScrollCaptureError.resourceLimit
        }
        guard firstFrame.pixels.count <= limits.maximumOutputBytes / 4,
              axis.map({ firstFrame.extent(along: $0) <= limits.maximumAxisPixels }) ??
                (max(firstFrame.width, firstFrame.height) <= limits.maximumAxisPixels) else {
            throw ScrollCaptureError.resourceLimit
        }
        previous = firstFrame
        self.axis = axis
        outputAxisPixels = axis.map { firstFrame.extent(along: $0) }
        self.startedAt = startedAt
        self.limits = limits
    }

    mutating func accept(_ frame: ScrollFrame, at time: TimeInterval) -> ScrollStep {
        guard time.isFinite, time >= startedAt, time - startedAt < limits.maximumDuration else {
            return .paused(.timeLimit)
        }
        switch aligner.align(previous: previous, current: frame, axis: axis) {
        case .unchanged: return .unchanged
        case .rejected(let reason):
            if let axis,
               case .matched = aligner.align(previous: previous, current: frame,
                                             axis: axis == .vertical ? .horizontal : .vertical) {
                return .paused(.axisChanged)
            }
            return .paused(reason)
        case .matched(let match):
            // Blank padding cannot establish a precise fixed-chrome boundary. Keep
            // the strongest evidence so far, but replace the entire unchanged edge.
            let replacement = match.replacementBands
            guard replacement.leading >= minimumStationaryBands.leading,
                  replacement.trailing >= minimumStationaryBands.trailing else {
                return .paused(.stationaryBandsChanged)
            }
            let newPosition = position + match.displacement
            let newMinimum = min(minimumPosition, newPosition)
            let newMaximum = max(maximumPosition, newPosition)
            let extent = frame.extent(along: match.axis)
            let outputExtent = extent + newMaximum - newMinimum
            guard outputExtent <= limits.maximumAxisPixels else { return .paused(.lengthLimit) }
            let breadth = frame.breadth(along: match.axis)
            guard outputExtent <= limits.maximumOutputBytes / 4 / breadth else { return .paused(.memoryLimit) }
            let edit: ScrollStripEdit?
            if newPosition > maximumPosition {
                let growth = newPosition - maximumPosition
                edit = ScrollStripEdit(edge: .trailing, removePixelCount: replacement.trailing,
                                       sourceRange: (extent - replacement.trailing - growth)..<extent)
            } else if newPosition < minimumPosition {
                let growth = minimumPosition - newPosition
                edit = ScrollStripEdit(edge: .leading, removePixelCount: replacement.leading,
                                       sourceRange: 0..<(replacement.leading + growth))
            } else {
                edit = nil
            }
            previous = frame
            axis = match.axis
            minimumStationaryBands.leading = max(minimumStationaryBands.leading, match.bands.leading)
            minimumStationaryBands.trailing = max(minimumStationaryBands.trailing, match.bands.trailing)
            position = newPosition
            minimumPosition = newMinimum
            maximumPosition = newMaximum
            outputAxisPixels = outputExtent
            if let edit { return .extended(match, edit) }
            return .repositioned(match)
        }
    }
}
