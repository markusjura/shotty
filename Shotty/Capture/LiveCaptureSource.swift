import CoreGraphics
import CoreVideo
import CoreMedia
import Foundation
import ScreenCaptureKit

/// A single bounded producer. Both ScreenCaptureKit and the consumer drop superseded frames.
actor LiveCaptureSource {
    private var stream: SCStream?
    private var output: FrameOutput?
    private var generation: UUID?

    /// The region is in logical points from this display's top-left, not global coordinates.
    func start(displayID: CGDirectDisplayID, displayLocalRegion: CGRect, excluding processID: pid_t) async throws -> AsyncThrowingStream<CapturedScrollFrame, Error> {
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
        return try await begin(filter: filter, region: clipped, request: request)
    }

    /// Foundation fixture acquisition. The production region path still captures display pixels.
    func start(windowID: CGWindowID) async throws -> AsyncThrowingStream<CapturedScrollFrame, Error> {
        let request = UUID()
        generation = request
        await stopActiveStream()
        try checkGeneration(request)
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permissionRequired }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try checkGeneration(request)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureFailure.targetUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try await begin(filter: filter, region: CGRect(origin: .zero, size: filter.contentRect.size), request: request, cropsRegion: false)
    }

    private func begin(filter: SCContentFilter, region: CGRect, request: UUID, cropsRegion: Bool = true) async throws -> AsyncThrowingStream<CapturedScrollFrame, Error> {
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        if cropsRegion { configuration.sourceRect = region }
        configuration.width = Int(ceil(region.width * scale))
        configuration.height = Int(ceil(region.height * scale))
        _ = try CapturePixelConversion.rasterBudget.byteCount(width: configuration.width, height: configuration.height)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // An unset space uses display-encoded bytes, but the stream's attachments
        // can describe sRGB. Request an explicit wide-gamut SDR conversion instead.
        configuration.colorSpaceName = CGColorSpace.displayP3
        configuration.ignoreShadowsSingleWindow = true
        let (frames, continuation) = AsyncThrowingStream<CapturedScrollFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
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

/// Conversion runs on one serial queue; the delivery gate synchronizes stop and yields.
private final class FrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue: DispatchQueue
    private let continuation: AsyncThrowingStream<CapturedScrollFrame, Error>.Continuation
    private let settled: SettledFrameDelivery

    init(continuation: AsyncThrowingStream<CapturedScrollFrame, Error>.Continuation) {
        let queue = DispatchQueue(label: "local.markus.Shotty.frames", qos: .userInitiated)
        self.queue = queue
        self.continuation = continuation
        settled = SettledFrameDelivery(queue: queue) { continuation.yield($0) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard !settled.isFinished, type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer else { return }
        let capturedAt = sampleBuffer.presentationTimeStamp.seconds
        guard capturedAt.isFinite, capturedAt >= 0 else { return }
        do {
            let raster = try CapturePixelConversion.image(from: buffer)
            settled.submit(raster, capturedAt: capturedAt)
        } catch {
            settled.finish()
            continuation.finish(throwing: error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        settled.finish()
        continuation.finish(throwing: error)
    }
    func finish() {
        settled.finish()
        continuation.finish()
    }
}

/// Copies only BGRA pixel bytes, with no rendering, transfer-function conversion or
/// borrowed CVPixelBuffer storage. The returned image remains valid after unlock/reuse.
enum CapturePixelConversion {
    static let rasterBudget = RasterBudget(maximumBytes: 64 * 1_024 * 1_024)

    static func image(from buffer: CVPixelBuffer, budget: RasterBudget = rasterBudget) throws -> CGImage {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(buffer) else { throw Failure.unsupportedPixelFormat }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let count = try budget.byteCount(width: width, height: height)
        let rowBytes = width * 4
        let sourceStride = CVPixelBufferGetBytesPerRow(buffer)
        guard sourceStride >= rowBytes else { throw Failure.unsupportedPixelFormat }
        let space = try colorSpace(of: buffer)
        let alphaMode = CVBufferCopyAttachment(buffer, kCVImageBufferAlphaChannelModeKey, nil)
        let straight = alphaMode.map { CFEqual($0, kCVImageBufferAlphaChannelMode_StraightAlpha) } ?? false
        let alpha: CGImageAlphaInfo = straight ? .first : .premultipliedFirst
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw CaptureFailure.noImage }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let source = CVPixelBufferGetBaseAddress(buffer) else { throw CaptureFailure.noImage }
        var pixels = Data(count: count)
        pixels.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                memcpy(destination.baseAddress! + row * rowBytes, source + row * sourceStride, rowBytes)
            }
        }
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: rowBytes, space: space,
                  bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | alpha.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw CaptureFailure.noImage
        }
        return image
    }

    private static func colorSpace(of buffer: CVPixelBuffer) throws -> CGColorSpace {
        if let value = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil) {
            guard CFGetTypeID(value) == CGColorSpace.typeID else { throw Failure.missingColorProfile }
            return value as! CGColorSpace
        }
        guard let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
              let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() else {
            throw Failure.missingColorProfile
        }
        return space
    }

    enum Failure: LocalizedError {
        case unsupportedPixelFormat, missingColorProfile
        var errorDescription: String? {
            switch self {
            case .unsupportedPixelFormat: "The stream did not supply supported BGRA pixels."
            case .missingColorProfile: "The stream did not supply a usable color profile. Capture paused to preserve color."
            }
        }
    }
}
