import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// A single bounded producer. Both ScreenCaptureKit and the consumer drop superseded frames.
actor LiveCaptureSource {
    private var stream: SCStream?
    private var output: FrameOutput?
    private var generation: UUID?

    /// The region is in logical points from this display's top-left, not global coordinates.
    func start(displayID: CGDirectDisplayID, displayLocalRegion: CGRect, excluding processID: pid_t) async throws -> AsyncThrowingStream<CGImage, Error> {
        let request = UUID()
        generation = request
        await stopActiveStream()
        try checkGeneration(request)
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permissionRequired }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try checkGeneration(request)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureFailure.targetUnavailable
        }
        let filter = SCContentFilter(display: display,
                                     excludingApplications: content.applications.filter { $0.processID == processID },
                                     exceptingWindows: [])
        let bounds = CGRect(origin: .zero, size: display.frame.size)
        let clipped = displayLocalRegion.standardized.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty else { throw CaptureFailure.targetUnavailable }
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = clipped
        configuration.width = Int(ceil(clipped.width * scale))
        configuration.height = Int(ceil(clipped.height * scale))
        _ = try RasterBudget().byteCount(width: configuration.width, height: configuration.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        let (frames, continuation) = AsyncThrowingStream<CGImage, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let output = FrameOutput(continuation: continuation)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        self.stream = stream
        self.output = output
        continuation.onTermination = { [weak self] _ in Task { await self?.stop(generation: request) } }
        do {
            try await stream.startCapture()
            try checkGeneration(request)
        } catch {
            // A newer start may already own the actor. Never tear down its stream.
            await stop(generation: request)
            try? await stream.stopCapture()
            throw error
        }
        return frames
    }

    func stop() async {
        generation = nil
        await stopActiveStream()
    }

    private func stop(generation request: UUID) async {
        guard generation == request else { return }
        await stop()
    }

    private func checkGeneration(_ request: UUID) throws {
        try Task.checkCancellation()
        guard generation == request else { throw CancellationError() }
    }

    private func stopActiveStream() async {
        let active = stream
        stream = nil
        let activeOutput = output
        output = nil
        activeOutput?.finish()
        try? await active?.stopCapture()
    }
}

/// All properties are immutable. CIContext is thread-safe; the continuation synchronizes yields.
private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "local.markus.Shotty.frames", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let continuation: AsyncThrowingStream<CGImage, Error>.Continuation

    init(continuation: AsyncThrowingStream<CGImage, Error>.Continuation) { self.continuation = continuation }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        // Explicitly retain the buffer's profile instead of using CIContext's default output space.
        guard let colorSpace = image.colorSpace,
              let raster = context.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: colorSpace) else {
            continuation.finish(throwing: CaptureFailure.noImage)
            return
        }
        continuation.yield(raster)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { continuation.finish(throwing: error) }
    func finish() { continuation.finish() }
}
