import AppKit
import XCTest
@testable import Shotty

@MainActor
final class CaptureFilePromiseTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-promise-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("drop"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func promise() async throws -> CaptureFilePromise {
        let store = CaptureSessionStore(directory: directory.appendingPathComponent("session"))
        let context = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0, green: 0.4, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let record = try await store.create(image: XCTUnwrap(context.makeImage()), kind: .area, scale: 2)
        return CaptureFilePromise(snapshot: record.snapshot, options: .init(), exporter: ExportService())
    }

    private func requestWrite(_ promise: CaptureFilePromise, provider: NSFilePromiseProvider) async -> (URL, Error?) {
        let url = directory.appendingPathComponent("drop").appendingPathComponent(promise.filename)
        let error = await withCheckedContinuation { continuation in
            promise.filePromiseProvider(provider, writePromiseTo: url) { continuation.resume(returning: $0) }
        }
        return (url, error)
    }

    func testCancelledBeforeWriteRejectsLateRequestsWithoutWriting() async throws {
        let promise = try await promise()
        let provider = promise.makeProvider()
        var completions = 0
        promise.completed = { _ in completions += 1 }

        XCTAssertTrue(promise.cancelUnused())
        let (url, error) = await requestWrite(promise, provider: provider)

        XCTAssertNotNil(error, "A promise released for cleanup must refuse to write")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(promise.state, .cancelled)
    }

    func testStartedWriteCannotBeCancelledAndReportsItsReceipt() async throws {
        let promise = try await promise()
        let provider = promise.makeProvider()
        var receipt: ExportReceipt?
        promise.completed = { receipt = try? $0.get() }
        let url = directory.appendingPathComponent("drop").appendingPathComponent(promise.filename)

        let finished = expectation(description: "write finished")
        promise.filePromiseProvider(provider, writePromiseTo: url) { error in
            XCTAssertNil(error)
            finished.fulfill()
        }
        XCTAssertFalse(promise.cancelUnused(), "The request marks the write as started synchronously")
        await fulfillment(of: [finished], timeout: 10)

        XCTAssertEqual(promise.state, .finished)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(receipt?.destinationURL.standardizedFileURL, url.standardizedFileURL)
        XCTAssertFalse(promise.cancelUnused())
    }
}
