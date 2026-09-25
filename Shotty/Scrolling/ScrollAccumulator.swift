import CoreGraphics
import Foundation

/// The caller supplies frames serially. Disk acceptance precedes publishing session progress.
actor ScrollAccumulator {
    struct Progress: Sendable {
        let dimensions: CGSize
        let preview: CGImage?
        let message: String
        let paused: Bool
        let acceptedFrames: Int
        let didMove: Bool
        /// Why a paused result stopped; limits are terminal, alignment pauses can recover.
        let rejection: ScrollRejection?
        /// The capture axis: requested up front, or inferred from the first accepted movement.
        let axis: ScrollAxis?
    }

    private var session: ScrollStitchSession?
    private var tiles: ScrollTileStore?
    private var acceptedFrames = 0
    private var lastPreviewTime: TimeInterval = 0
    private var previewIsDirty = true
    private var generation = 0
    private let requestedAxis: ScrollAxis?
    private let limits: ScrollLimits

    init(axis: ScrollAxis? = nil, limits: ScrollLimits = .init()) {
        requestedAxis = axis
        self.limits = limits
    }

    func accept(_ image: CGImage) async throws -> Progress {
        try Task.checkCancellation()
        let request = generation
        let now = ProcessInfo.processInfo.systemUptime
        let frame = try ScrollFrame(image: image)
        if session == nil {
            guard let colorSpace = image.colorSpace else { throw CaptureFailure.noImage }
            let initial = try ScrollStitchSession(firstFrame: frame, axis: requestedAxis, startedAt: now, limits: limits)
            let initialTiles = try await ScrollTileStore(firstFrame: frame, colorSpace: colorSpace, limits: limits)
            guard request == generation, !Task.isCancelled else {
                await initialTiles.discard()
                throw CancellationError()
            }
            tiles = initialTiles
            session = initial
            acceptedFrames = 1
            previewIsDirty = true
            lastPreviewTime = now
            return try await progress(message: "First frame accepted. Scroll the target in overlapping steps.", paused: false, refreshPreview: true)
        }
        guard var candidate = session, let tiles else { throw CaptureFailure.noImage }
        let offset = candidate.viewportOffset
        let step = candidate.accept(frame, at: now)
        // Moving pixels must agree with accepted output, not only with the previous viewport.
        switch step {
        case .repositioned(let match), .extended(let match, _):
            let agrees = try await tiles.overlapMatches(frame, offset: offset + match.displacement,
                                                        excluding: match.replacementBands, axis: match.axis)
            guard request == generation else { throw CancellationError() }
            if !agrees { return try await paused(.unstableContent) }
        case .unchanged, .paused: break
        }
        switch step {
        case .unchanged:
            return try await progress(message: "Waiting for scrolling.", paused: false, refreshPreview: false)
        case .repositioned:
            session = candidate
            return try await progress(message: "Reverse movement recovered within accepted content.", paused: false, refreshPreview: false, didMove: true)
        case .extended(let match, let edit):
            try await tiles.apply(edit, from: frame, axis: match.axis)
            guard request == generation else { throw CancellationError() }
            session = candidate
            acceptedFrames += 1
            previewIsDirty = true
            let refresh = now - lastPreviewTime >= 0.15
            if refresh { lastPreviewTime = now }
            return try await progress(message: "Accepted \(acceptedFrames) frames along \(match.axis.rawValue).", paused: false, refreshPreview: refresh, didMove: true)
        case .paused(let reason):
            return try await paused(reason)
        }
    }

    func finishPreview() async throws -> CGImage {
        guard let tiles else { throw CaptureFailure.noImage }
        return try await tiles.preview(maxDimension: 800)
    }

    /// Full-resolution output backed by a mapped file; it stays valid after `discard()`.
    func renderImage() async throws -> CGImage {
        guard let tiles else { throw CaptureFailure.noImage }
        return try await tiles.renderImage()
    }

    func exportPNG(to url: URL) async throws {
        guard let tiles else { throw CaptureFailure.noImage }
        try await tiles.exportPNG(to: url)
    }

    func discard() async {
        generation += 1
        let previousTiles = tiles
        tiles = nil
        session = nil
        acceptedFrames = 0
        previewIsDirty = true
        lastPreviewTime = 0
        await previousTiles?.discard()
    }

    private func paused(_ reason: ScrollRejection) async throws -> Progress {
        try await progress(message: "Paused: \(reason.rawValue). The accepted partial result is retained.", paused: true,
                           refreshPreview: true, rejection: reason)
    }

    private func progress(message: String, paused: Bool, refreshPreview: Bool, didMove: Bool = false,
                          rejection: ScrollRejection? = nil) async throws -> Progress {
        guard let tiles else { throw CaptureFailure.noImage }
        let dimensions = await tiles.dimensions
        return Progress(dimensions: CGSize(width: dimensions.width, height: dimensions.height),
                        preview: try await refreshedPreview(if: refreshPreview),
                        message: message, paused: paused, acceptedFrames: acceptedFrames, didMove: didMove, rejection: rejection,
                        axis: session?.axis)
    }

    private func refreshedPreview(if requested: Bool) async throws -> CGImage? {
        guard requested, previewIsDirty, let tiles else { return nil }
        let image = try await tiles.preview()
        previewIsDirty = false
        return image
    }
}
