import CoreGraphics
import Synchronization
import XCTest
@testable import Shotty

final class SettledFrameDeliveryTests: XCTestCase {
    private let queue = DispatchQueue(label: "SettledFrameDeliveryTests")
    private let delivered = Delivered()

    private struct Delivery: Sendable {
        let value: UInt8
        let capturedAt: TimeInterval
        let settled: Bool
        let deliveredAt: TimeInterval
    }

    private final class Delivered: Sendable {
        private let values = Mutex<[Delivery]>([])
        func append(_ value: Delivery) { values.withLock { $0.append(value) } }
        var all: [Delivery] { values.withLock { $0 } }
    }

    func testContinuousChangesDeliverPacedMovingFramesThenFinalSettledFrame() {
        let delivery = makeDelivery()
        defer { delivery.finish() }
        for step in 0..<20 {
            queue.asyncAfter(deadline: .now() + .milliseconds(step * 20)) {
                delivery.submit(Self.image(UInt8(step)), capturedAt: 100 + Double(step))
            }
        }
        wait(milliseconds: 260)
        XCTAssertTrue(delivered.all.contains { !$0.settled }, "Manual capture needs frames while scrolling continues")
        XCTAssertFalse(delivered.all.contains { $0.settled })
        wait(milliseconds: 450)
        let records = delivered.all
        let moving = records.filter { !$0.settled }
        XCTAssertGreaterThanOrEqual(moving.count, 2)
        XCTAssertLessThanOrEqual(moving.count, 5)
        for pair in zip(moving, moving.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.1.deliveredAt - pair.0.deliveredAt, 0.09)
            XCTAssertGreaterThan(pair.1.capturedAt, pair.0.capturedAt)
        }
        XCTAssertEqual(records.filter(\.settled).map(\.value), [19])
        XCTAssertEqual(records.last?.capturedAt, 119)
        XCTAssertEqual(records.last?.settled, true)
    }

    func testIdenticalRepeatsDoNotPostponeSettlementOrPublishAgain() {
        let delivery = makeDelivery()
        defer { delivery.finish() }
        for step in 0..<25 {
            queue.asyncAfter(deadline: .now() + .milliseconds(step * 20)) {
                delivery.submit(Self.image(7, padding: step % 3 * 4), capturedAt: 100 + Double(step))
            }
        }
        wait(milliseconds: 300)
        XCTAssertEqual(delivered.all.map(\.value), [7, 7])
        XCTAssertEqual(delivered.all.map(\.settled), [false, true])
        XCTAssertEqual(delivered.all.map(\.capturedAt), [100, 100])
        wait(milliseconds: 400)
        XCTAssertEqual(delivered.all.count, 2)
    }

    func testFinishSuppressesQueuedTimerAndSubmissions() {
        let delivery = makeDelivery()
        queue.suspend()
        delivery.submit(Self.image(3), capturedAt: 10)
        DispatchQueue.global().sync { delivery.finish() }
        delivery.submit(Self.image(4), capturedAt: 11)
        queue.resume()
        wait(milliseconds: 250)
        XCTAssertTrue(delivered.all.isEmpty)
        XCTAssertTrue(delivery.isFinished)
    }

    func testNewestFrameWinsAndOlderTimestampsCannotReplaceIdenticalRepeat() {
        let delivery = makeDelivery()
        defer { delivery.finish() }
        queue.suspend()
        delivery.submit(Self.image(1), capturedAt: 100)
        delivery.submit(Self.image(2), capturedAt: 101)
        delivery.submit(Self.image(2), capturedAt: 103)
        delivery.submit(Self.image(9), capturedAt: 102)
        queue.resume()
        wait(milliseconds: 300)
        XCTAssertEqual(delivered.all.map(\.value), [2, 2])
        XCTAssertEqual(delivered.all.map(\.capturedAt), [101, 101])
    }

    private func makeDelivery() -> SettledFrameDelivery {
        SettledFrameDelivery(queue: queue) { [delivered] record in
            let value = CFDataGetBytePtr(record.image.dataProvider!.data!)![0]
            delivered.append(Delivery(value: value, capturedAt: record.capturedAt, settled: record.isSettled,
                                      deliveredAt: CapturedScrollFrame.monotonicNow))
        }
    }

    private func wait(milliseconds: Int) {
        let done = expectation(description: "elapsed")
        queue.asyncAfter(deadline: .now() + .milliseconds(milliseconds)) { done.fulfill() }
        wait(for: [done], timeout: Double(milliseconds) / 1_000 + 2)
    }

    private static func image(_ value: UInt8, padding: Int = 0) -> CGImage {
        let stride = 16 + padding
        var bytes = [UInt8](repeating: UInt8(0xA0 + padding), count: 4 * stride + padding)
        for row in 0..<4 {
            bytes.replaceSubrange((row * stride)..<(row * stride + 16), with: repeatElement(value, count: 16))
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
