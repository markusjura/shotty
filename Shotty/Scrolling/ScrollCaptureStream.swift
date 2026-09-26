import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Streams one screen region into a `ScrollStitcher`. Every changed frame is stitched on the
/// capture queue straight from the stream's buffer, so no frame is copied or delayed first.
final class ScrollCaptureStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.markus.Shotty.scrolling", qos: .userInitiated)
    private let limits: ScrollStitcher.Limits
    private let onUpdate: @Sendable (ScrollStitcher.Update) -> Void
    private var stream: SCStream?
    // Accessed only on `queue`.
    private var stitcher: ScrollStitcher?
    private var colorSpace: CGColorSpace?
    private let lock = NSLock()
    private var knownAxis: ScrollAxis?

    /// The axis the first movement established, nil before it. Readable from any thread.
    var axis: ScrollAxis? { lock.withLock { knownAxis } }

    /// `onUpdate` runs on the capture queue for every changed frame after the first.
    init(limits: ScrollStitcher.Limits, onUpdate: @escaping @Sendable (ScrollStitcher.Update) -> Void) {
        self.limits = limits
        self.onUpdate = onUpdate
    }

    /// `region` is in points from the display's top-left corner. Shotty's own windows are excluded.
    func start(displayID: CGDirectDisplayID, region: CGRect) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureFailure.targetUnavailable
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == ownPID },
                                     exceptingWindows: [])
        let clipped = region.intersection(CGRect(origin: .zero, size: display.frame.size)).integral
        guard !clipped.isEmpty else { throw CaptureFailure.targetUnavailable }
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = clipped
        configuration.width = Int(clipped.width * scale)
        configuration.height = Int(clipped.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 4
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.displayP3
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        self.stream = stream
        try await stream.startCapture()
    }

    /// Stops capturing and returns the stitched image, or nil if no frame arrived.
    func finish() async -> CGImage? {
        try? await stream?.stopCapture()
        stream = nil
        return queue.sync {
            defer { stitcher = nil }
            guard let colorSpace else { return nil }
            return stitcher?.render(colorSpace: colorSpace, bitmapInfo: Self.bitmapInfo)
        }
    }

    func cancel() async {
        try? await stream?.stopCapture()
        stream = nil
        queue.sync { stitcher = nil }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
              let buffer = sampleBuffer.imageBuffer,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let viewport = ScrollViewport(base: base, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        if stitcher == nil {
            colorSpace = Self.colorSpace(of: buffer)
            stitcher = ScrollStitcher(first: viewport, limits: limits)
        } else if let update = stitcher?.add(viewport) {
            if update == .moved { lock.withLock { knownAxis = stitcher?.axis } }
            onUpdate(update)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {}

    /// Stream buffers are BGRA in memory, as the stitched output keeps them.
    private static let bitmapInfo = CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                           | CGImageAlphaInfo.premultipliedFirst.rawValue)

    private static func colorSpace(of buffer: CVPixelBuffer) -> CGColorSpace {
        if let value = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil), CFGetTypeID(value) == CGColorSpace.typeID {
            return value as! CGColorSpace
        }
        if let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate),
           let space = CVImageBufferCreateColorSpaceFromAttachments(attachments)?.takeRetainedValue() {
            return space
        }
        return CGColorSpace(name: CGColorSpace.displayP3)!
    }
}
