@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit
import os

/// What one recording captures. Frames and regions are global AppKit points.
enum RecordingTarget: Equatable, Sendable {
    case region(CGRect, display: CGDirectDisplayID)
    case window(CGWindowID, frame: CGRect)
    case display(CGDirectDisplayID)
}

enum RecordingFailure: LocalizedError {
    case permissionRequired, targetUnavailable, nothingRecorded, microphoneDenied

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "Allow Screen Recording for Shotty in System Settings, then reopen Shotty."
        case .targetUnavailable: "The selected window or display is no longer available. Select it again."
        case .nothingRecorded: "Nothing was recorded. Record a little longer before stopping."
        case .microphoneDenied: "Allow Microphone access for Shotty in System Settings, or turn off microphone recording."
        }
    }
}

/// One recording's capture, as `RecordingController` drives it. `ScreenRecorder` records the
/// screen; tests stand in for it.
@MainActor
protocol Recorder: AnyObject {
    /// Holds this recording's files. Whoever assembles them removes the folder.
    var folder: URL { get }
    /// Runs when the capture stops on its own, for example because the recorded window closed.
    var stoppedUnexpectedly: (() -> Void)? { get set }
    func start(_ target: RecordingTarget) async throws
    func pause()
    func resume() throws
    func stop() async -> [URL]
    func cancel() async
}

/// Records one target with ScreenCaptureKit straight into movie files in `folder`. Pausing
/// finishes the current file and resuming starts the next one; `stop` returns the finished files
/// in order. Shotty's own windows, such as the recording controls and thumbnails, never appear in
/// the recording.
@MainActor
final class ScreenRecorder: NSObject, Recorder {
    let folder: URL
    var stoppedUnexpectedly: (() -> Void)?
    private let preferences: RecordingPreferences
    private var stream: SCStream?
    private var output: SCRecordingOutput?
    private var segments: [Segment] = []
    private var segmentWaiters: [CheckedContinuation<Void, Never>] = []
    private var isCancelled = false
    private let logger = Logger(subsystem: "local.markus.Shotty", category: "Recording")

    /// One recording output and the file it writes. Holding the output keeps its identity unique
    /// while the delegate reports on it.
    private struct Segment {
        enum State { case writing, finished, failed }
        let url: URL
        let output: SCRecordingOutput
        var state = State.writing
    }

    init(preferences: RecordingPreferences) throws {
        self.preferences = preferences
        folder = try CaptureScratchSpace.makeFolder()
    }

    /// Throws `CancellationError` when `cancel` runs before the stream is up.
    func start(_ target: RecordingTarget) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw RecordingFailure.permissionRequired }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let configuration = SCStreamConfiguration()
        let filter: SCContentFilter
        let pointSize: CGSize
        switch target {
        case .region(_, let displayID), .display(let displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }),
                  let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { throw RecordingFailure.targetUnavailable }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            if case .region(let region, _) = target {
                let geometry = DisplayGeometry(appKitFrame: screen.frame, captureFrame: CGDisplayBounds(displayID))
                let topLeft = geometry.capturePoint(fromAppKit: CGPoint(x: region.minX, y: region.maxY))
                let local = CGRect(x: topLeft.x - geometry.captureFrame.minX, y: topLeft.y - geometry.captureFrame.minY,
                                   width: region.width, height: region.height)
                    .intersection(CGRect(origin: .zero, size: display.frame.size))
                guard local.width >= 2, local.height >= 2 else { throw RecordingFailure.targetUnavailable }
                configuration.sourceRect = local
                pointSize = local.size
            } else {
                pointSize = display.frame.size
            }
        case .window(let id, _):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw RecordingFailure.targetUnavailable }
            filter = SCContentFilter(desktopIndependentWindow: window)
            configuration.ignoreShadowsSingleWindow = true
            pointSize = window.frame.size
        }
        let scale = preferences.scale == .native ? CGFloat(filter.pointPixelScale) : 1
        configuration.width = Self.evenPixels(pointSize.width * scale)
        configuration.height = Self.evenPixels(pointSize.height * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(preferences.frameRate.rawValue))
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = preferences.recordsSystemAudio
        configuration.excludesCurrentProcessAudio = true
        if preferences.recordsMicrophone {
            guard await Self.microphoneAllowed() else { throw RecordingFailure.microphoneDenied }
            configuration.captureMicrophone = true
            configuration.microphoneCaptureDeviceID = preferences.microphone(in: Microphone.available())?.id
        }
        guard !isCancelled else { throw CancellationError() }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream
        try attachOutput()
        do { try await stream.startCapture() } catch {
            self.stream = nil
            output = nil
            throw error
        }
        // A cancel while the stream was starting found nothing running to stop.
        guard !isCancelled else {
            try? await stream.stopCapture()
            throw CancellationError()
        }
        logger.info("Recording started at \(configuration.width)x\(configuration.height)")
    }

    /// Finishes the current file at once. Nothing is recorded until `resume`.
    func pause() {
        guard let stream, let output else { return }
        detach(output, from: stream)
    }

    func resume() throws {
        guard stream != nil, output == nil else { return }
        try attachOutput()
    }

    /// Stops capturing and returns the files that finished writing, in recording order. A segment
    /// that failed, such as one paused before its first frame, is left out.
    func stop() async -> [URL] {
        guard let stream else { return [] }
        if let output { detach(output, from: stream) }
        self.stream = nil
        await segmentsWritten()
        try? await stream.stopCapture()
        return segments.filter { $0.state == .finished }.map(\.url)
    }

    /// Stops without keeping anything and removes `folder`.
    func cancel() async {
        isCancelled = true
        let stream = self.stream
        self.stream = nil
        output = nil
        try? await stream?.stopCapture()
        try? FileManager.default.removeItem(at: folder)
    }

    private func attachOutput() throws {
        guard let stream else { return }
        let url = folder.appendingPathComponent("segment-\(segments.count).mp4")
        let configuration = SCRecordingOutputConfiguration()
        configuration.outputURL = url
        configuration.outputFileType = .mp4
        configuration.videoCodecType = preferences.codec == .hevc ? .hevc : .h264
        let output = SCRecordingOutput(configuration: configuration, delegate: self)
        try stream.addRecordingOutput(output)
        self.output = output
        segments.append(Segment(url: url, output: output))
    }

    /// Removing an output makes it finish its file; the delegate reports when that is done.
    private func detach(_ output: SCRecordingOutput, from stream: SCStream) {
        self.output = nil
        do { try stream.removeRecordingOutput(output) } catch {
            segmentEnded(ObjectIdentifier(output), error: error)
        }
    }

    /// Waits until no segment is still writing, at most ten seconds. Finishing a file only adds
    /// its index, so a segment that takes longer has failed.
    private func segmentsWritten() async {
        guard segments.contains(where: { $0.state == .writing }) else { return }
        let timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.logger.error("Segments didn't finish writing in time")
            self?.resumeSegmentWaiters()
        }
        await withCheckedContinuation { segmentWaiters.append($0) }
        timeout.cancel()
    }

    private func resumeSegmentWaiters() {
        let waiters = segmentWaiters
        segmentWaiters = []
        waiters.forEach { $0.resume() }
    }

    fileprivate func segmentEnded(_ output: ObjectIdentifier, error: Error?) {
        guard let index = segments.firstIndex(where: { ObjectIdentifier($0.output) == output }), segments[index].state == .writing else { return }
        segments[index].state = error == nil ? .finished : .failed
        if let error { logger.error("Segment \(index) failed: \(error.localizedDescription, privacy: .public)") }
        if !segments.contains(where: { $0.state == .writing }) { resumeSegmentWaiters() }
    }

    fileprivate func streamStopped(_ error: Error) {
        guard stream != nil else { return }
        logger.error("Stream stopped: \(error.localizedDescription, privacy: .public)")
        stoppedUnexpectedly?()
    }

    /// H.264 and HEVC encode 2×2 chroma blocks, so frame dimensions are even.
    nonisolated static func evenPixels(_ value: CGFloat) -> Int { max(2, Int((value / 2).rounded()) * 2) }

    private static func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }
}

extension ScreenRecorder: SCStreamDelegate, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor in self.streamStopped(error) }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        let output = ObjectIdentifier(recordingOutput)
        Task { @MainActor in self.segmentEnded(output, error: nil) }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let output = ObjectIdentifier(recordingOutput)
        Task { @MainActor in self.segmentEnded(output, error: error) }
    }
}
