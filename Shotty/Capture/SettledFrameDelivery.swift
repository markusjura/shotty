import CoreGraphics
import CoreMedia
import Dispatch
import Foundation
import Synchronization

struct CapturedScrollFrame: Sendable {
    let image: CGImage
    /// ScreenCaptureKit presentation timestamps use the CoreMedia host clock. This
    /// is that clock's monotonic seconds, not wall time or callback-arrival time.
    let capturedAt: TimeInterval
    let isSettled: Bool

    static var monotonicNow: TimeInterval { CMClockGetTime(CMClockGetHostTimeClock()).seconds }
}

/// Coalesces changed pixels into paced moving frames and one final settled frame.
/// One timer and one pending image bound producer work even when the consumer lags.
/// The callback runs within the delivery gate; it must not call back into this object.
final class SettledFrameDelivery: Sendable {
    private struct Frame: Sendable {
        let image: CGImage
        let bytes: Data
        let capturedAt: TimeInterval

        func hasSameContent(as other: Frame) -> Bool {
            if image === other.image { return true }
            let (a, b) = (image, other.image)
            guard a.width == b.width, a.height == b.height, a.bitsPerComponent == b.bitsPerComponent,
                  a.bitsPerPixel == b.bitsPerPixel, a.bitmapInfo == b.bitmapInfo, a.colorSpace == b.colorSpace,
                  let rowBytes = validRowBytes, rowBytes == other.validRowBytes else { return false }
            return bytes.withUnsafeBytes { lhs in
                other.bytes.withUnsafeBytes { rhs in
                    (0..<a.height).allSatisfy {
                        memcmp(lhs.baseAddress! + $0 * a.bytesPerRow, rhs.baseAddress! + $0 * b.bytesPerRow, rowBytes) == 0
                    }
                }
            }
        }

        var validRowBytes: Int? {
            let (bits, overflow) = image.width.multipliedReportingOverflow(by: image.bitsPerPixel)
            let (roundedBits, roundingOverflow) = bits.addingReportingOverflow(7)
            guard !overflow, !roundingOverflow, image.width > 0, image.height > 0 else { return nil }
            let rowBytes = roundedBits / 8
            guard rowBytes > 0, image.bytesPerRow >= rowBytes else { return nil }
            let (lastRow, rowOverflow) = (image.height - 1).multipliedReportingOverflow(by: image.bytesPerRow)
            let (end, endOverflow) = lastRow.addingReportingOverflow(rowBytes)
            return !rowOverflow && !endOverflow && end <= bytes.count ? rowBytes : nil
        }
    }

    private struct State {
        var latest: Frame?
        var nextMovingDeadline = DispatchTime.now()
        var settledDeadline = DispatchTime.distantFuture
        var pendingMoving = false
        var pendingSettled = false
        var finished = false
        var newestObservedTimestamp: TimeInterval = 0
        var timer: DispatchSourceTimer?
    }

    private let delay: DispatchTimeInterval
    private let movingInterval: DispatchTimeInterval
    private let deliver: @Sendable (CapturedScrollFrame) -> Void
    private let state = Mutex(State())

    init(queue: DispatchQueue, delay: DispatchTimeInterval = .milliseconds(150),
         movingInterval: DispatchTimeInterval = .milliseconds(100),
         deliver: @escaping @Sendable (CapturedScrollFrame) -> Void) {
        self.delay = delay
        self.movingInterval = movingInterval
        self.deliver = deliver
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.setEventHandler { [weak self] in self?.fire() }
        timer.schedule(deadline: .distantFuture)
        state.withLock { $0.timer = timer }
        timer.resume()
    }

    deinit { state.withLock { $0.timer?.cancel() } }

    var isFinished: Bool { state.withLock { $0.finished } }

    /// Identical repeats do not reset either deadline or replace the original capture
    /// timestamp. Out-of-order callbacks are ignored rather than publishing old pixels.
    func submit(_ image: CGImage, capturedAt: TimeInterval = CapturedScrollFrame.monotonicNow) {
        guard !isFinished, capturedAt.isFinite, capturedAt >= 0, let bytes = image.dataProvider?.data else { return }
        let frame = Frame(image: image, bytes: bytes as Data, capturedAt: capturedAt)
        guard frame.validRowBytes != nil else { return }
        state.withLock { state in
            guard !state.finished, capturedAt >= state.newestObservedTimestamp else { return }
            state.newestObservedTimestamp = capturedAt
            guard !(state.latest?.hasSameContent(as: frame) ?? false) else { return }
            state.latest = frame
            state.pendingMoving = true
            state.pendingSettled = true
            state.settledDeadline = .now() + delay
            reschedule(&state)
        }
    }

    /// Synchronizes with the yield gate. Once this returns, queued callbacks cannot
    /// publish a frame; an already executing delivery finishes before the stop returns.
    func finish() {
        state.withLock { state in
            state.finished = true
            state.latest = nil
            state.timer?.cancel()
            state.timer = nil
        }
    }

    private func fire() {
        state.withLock { state in
            guard !state.finished, let frame = state.latest else { return }
            let now = DispatchTime.now()
            if state.pendingSettled && now >= state.settledDeadline {
                state.pendingSettled = false
                state.pendingMoving = false
                deliver(CapturedScrollFrame(image: frame.image, capturedAt: frame.capturedAt, isSettled: true))
            } else if state.pendingMoving && now >= state.nextMovingDeadline {
                state.pendingMoving = false
                state.nextMovingDeadline = now + movingInterval
                deliver(CapturedScrollFrame(image: frame.image, capturedAt: frame.capturedAt, isSettled: false))
            }
            reschedule(&state)
        }
    }

    private func reschedule(_ state: inout State) {
        let moving = state.pendingMoving ? state.nextMovingDeadline : .distantFuture
        let settled = state.pendingSettled ? state.settledDeadline : .distantFuture
        state.timer?.schedule(deadline: min(moving, settled), leeway: .milliseconds(1))
    }
}
