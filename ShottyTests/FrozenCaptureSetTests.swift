import CoreGraphics
import Foundation
import XCTest
@testable import Shotty

final class FrozenCaptureSetTests: XCTestCase {
    func testProfilingLimitCanForceSequentialAcquisitionWithoutChangingReservations() throws {
        let estimates = [1_024, 1_024, 1_024]
        let sequential = try FrozenCaptureBatch(estimates: estimates[...], retainedProfileBytes: 0, storedDiskBytes: 0,
                                                limits: FrozenCaptureLimits(maximumConcurrentCaptures: 1))
        let parallel = try FrozenCaptureBatch(estimates: estimates[...], retainedProfileBytes: 0, storedDiskBytes: 0, limits: .init())
        XCTAssertEqual(sequential.reservations.count, 1)
        XCTAssertEqual(parallel.reservations.count, 3)
        XCTAssertEqual(sequential.reservations[0].residentBytes, parallel.reservations[0].residentBytes)
        XCTAssertThrowsError(try FrozenCaptureBatch(estimates: estimates[...], retainedProfileBytes: 0, storedDiskBytes: 0,
                                                    limits: FrozenCaptureLimits(maximumConcurrentCaptures: 0)))
    }

    func testBatchBoundsConcurrencyAndChargesBothInFlightBuffersAndRetainedProfiles() throws {
        let mib = 1_024 * 1_024
        let estimates = [32 * mib, 32 * mib, 32 * mib, 32 * mib]
        let batch = try FrozenCaptureBatch(estimates: estimates[...], retainedProfileBytes: mib,
                                           storedDiskBytes: 100 * mib, limits: .init())
        XCTAssertEqual(batch.reservations.map(\.index), [0, 1, 2])
        XCTAssertEqual(batch.residentBytes, 198 * mib)
        XCTAssertLessThanOrEqual(batch.residentBytes + mib, FrozenCaptureLimits().maximumResidentBytes)
        for reservation in batch.reservations {
            XCTAssertGreaterThanOrEqual(reservation.residentBytes, reservation.rasterBytes * 2 + mib)
        }
        let large = try FrozenCaptureBatch(estimates: [80 * mib, 80 * mib][...], retainedProfileBytes: 0,
                                           storedDiskBytes: 0, limits: .init())
        XCTAssertEqual(large.reservations.count, 1, "Large images must fall back to sequential acquisition")
    }

    func testBatchUsesOnlyUncommittedDiskAndMemoryWithoutIntegerOverflow() throws {
        let mib = 1_024 * 1_024
        let limits = FrozenCaptureLimits(maximumResidentBytes: 16 * mib, maximumDiskBytes: 10 * mib)
        let estimates = [3 * mib, 3 * mib, 3 * mib]
        let batch = try FrozenCaptureBatch(estimates: estimates[1...], retainedProfileBytes: mib,
                                           storedDiskBytes: 4 * mib, limits: limits)
        XCTAssertEqual(batch.reservations.map(\.index), [1, 2])
        XCTAssertEqual(batch.reservations.reduce(0) { $0 + $1.rasterBytes }, 6 * mib)
        XCTAssertEqual(batch.residentBytes + mib, limits.maximumResidentBytes)
        XCTAssertThrowsError(try FrozenCaptureBatch(estimates: [Int.max][...], retainedProfileBytes: 0, storedDiskBytes: 0, limits: .init()))
        XCTAssertThrowsError(try FrozenCaptureBatch(estimates: [3 * mib][...], retainedProfileBytes: 0, storedDiskBytes: 8 * mib, limits: limits)) { error in
            guard case FrozenCaptureFailure.diskLimit = error else { return XCTFail("Expected the disk reservation limit") }
        }
    }

    func testBatchReturnsMetadataInRequestOrderDespiteConcurrentCompletion() async throws {
        let batch = try FrozenCaptureBatch(estimates: [1_024, 1_024, 1_024][...], retainedProfileBytes: 0, storedDiskBytes: 0, limits: .init())
        let result = try await batch.run { reservation in
            try await Task.sleep(for: .milliseconds((3 - reservation.index) * 5))
            return reservation.index
        }
        XCTAssertEqual(result, [0, 1, 2])
    }

    func testCancelledBatchWaitsForAllCaptureOperationsBeforeReturning() async throws {
        actor Finished {
            var count = 0
            func record() { count += 1 }
        }
        let finished = Finished()
        let started = expectation(description: "all reserved captures started")
        started.expectedFulfillmentCount = 3
        let batch = try FrozenCaptureBatch(estimates: [1_024, 1_024, 1_024][...], retainedProfileBytes: 0, storedDiskBytes: 0, limits: .init())
        let operation = Task {
            try await batch.run { reservation in
                started.fulfill()
                do {
                    try await Task.sleep(for: .seconds(30))
                    return reservation.index
                } catch {
                    await finished.record()
                    throw error
                }
            }
        }
        await fulfillment(of: [started], timeout: 2)
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Cancellation must abort the complete batch")
        } catch is CancellationError {}
        let count = await finished.count
        XCTAssertEqual(count, 3, "The transaction must not delete its directory while a sibling can still write")
    }

    func testRawRoundTripPreservesPixelsPaddingAndColorSpace() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in [CGColorSpace.sRGB, CGColorSpace.displayP3, CGColorSpace.linearSRGB] {
            let source = try fixture(colorSpace: XCTUnwrap(CGColorSpace(name: name)))
            let descriptor = try FrozenRasterFile.store(source, directory: directory,
                                                         remainingDiskBytes: 1_000_000, limits: .init())
            let restored = try FrozenRasterFile.load(descriptor, directory: directory)
            XCTAssertEqual(restored.width, source.width)
            XCTAssertEqual(restored.height, source.height)
            XCTAssertEqual(restored.bitsPerComponent, source.bitsPerComponent)
            XCTAssertEqual(restored.bitsPerPixel, source.bitsPerPixel)
            XCTAssertEqual(restored.bytesPerRow, source.bytesPerRow)
            XCTAssertEqual(restored.bitmapInfo, source.bitmapInfo)
            XCTAssertEqual(restored.renderingIntent, source.renderingIntent)
            XCTAssertEqual(restored.shouldInterpolate, source.shouldInterpolate)
            XCTAssertEqual(try XCTUnwrap(restored.dataProvider?.data) as Data, try XCTUnwrap(source.dataProvider?.data) as Data)
            XCTAssertEqual(restored.colorSpace?.copyICCData() as Data?, source.colorSpace?.copyICCData() as Data?)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 3)
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testLoadedImageRetainsExactPixelsAfterPrivateFileCleanup() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture()
        let descriptor = try FrozenRasterFile.store(source, directory: directory, remainingDiskBytes: 1_000_000, limits: .init())
        let frozen = try FrozenRasterFile.load(descriptor, directory: directory)
        try FileManager.default.removeItem(at: directory)
        XCTAssertEqual(try XCTUnwrap(frozen.dataProvider?.data) as Data, try XCTUnwrap(source.dataProvider?.data) as Data)
    }

    func testTrailingProviderAllocationIsExcludedFromTheStoredRaster() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(trailingBytes: 6_656)
        let rasterBytes = source.bytesPerRow * source.height
        let sourceBytes = try XCTUnwrap(source.dataProvider?.data) as Data
        XCTAssertEqual(sourceBytes.count, rasterBytes + 6_656)
        let descriptor = try FrozenRasterFile.store(source, directory: directory,
                                                     remainingDiskBytes: rasterBytes, limits: .init())
        XCTAssertEqual(descriptor.byteCount, rasterBytes)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        XCTAssertEqual(try Data(contentsOf: file).count, rasterBytes)
        let restored = try FrozenRasterFile.load(descriptor, directory: directory)
        XCTAssertEqual(try XCTUnwrap(restored.dataProvider?.data) as Data, sourceBytes.prefix(rasterBytes))
        XCTAssertEqual(restored.bytesPerRow, source.bytesPerRow)
        XCTAssertEqual(restored.bitmapInfo, source.bitmapInfo)
        XCTAssertEqual(restored.colorSpace?.copyICCData() as Data?, source.colorSpace?.copyICCData() as Data?)
    }

    func testTrailingProviderBytesStillCountAgainstResidentLimit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture(trailingBytes: 6_656)
        let rasterBytes = source.bytesPerRow * source.height
        let limits = FrozenCaptureLimits(maximumResidentBytes: 1_024 * 1_024 + rasterBytes * 2)
        XCTAssertThrowsError(try FrozenRasterFile.store(source, directory: directory,
                                                        remainingDiskBytes: 1_000_000, limits: limits)) { error in
            guard case FrozenCaptureFailure.resourceLimit = error else { return XCTFail("Expected the resident limit") }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testDiskAndResidentLimitsRejectBeforeCreatingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture()
        XCTAssertThrowsError(try FrozenRasterFile.store(source, directory: directory, remainingDiskBytes: 1, limits: .init()))
        XCTAssertThrowsError(try FrozenRasterFile.store(source, directory: directory, remainingDiskBytes: 1_000_000,
                                                        limits: FrozenCaptureLimits(maximumResidentBytes: 1_024 * 1_024)))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        XCTAssertThrowsError(try FrozenCaptureLimits().validateRaster(width: 1, height: 2, bytesPerRow: Int.max))
    }

    func testSDRBudgetAdmitsShadowedFullscreenWindowOn5KDisplay() throws {
        let limits = FrozenCaptureLimits()
        let fullscreen = CGSize(width: 2_560, height: 1_440)
        XCTAssertNoThrow(try limits.validateSDRCapture(pointSize: fullscreen, scale: 2, shadow: true))
        // A window spanning both 5K displays is still refused before capture.
        XCTAssertThrowsError(try limits.validateSDRCapture(pointSize: CGSize(width: 5_120, height: 2_880),
                                                           scale: 2, shadow: true))
    }

    func testTruncatedRasterCannotBecomeAnImage() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let descriptor = try FrozenRasterFile.store(fixture(), directory: directory, remainingDiskBytes: 1_000_000, limits: .init())
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        try Data([0]).write(to: url)
        XCTAssertThrowsError(try FrozenRasterFile.load(descriptor, directory: directory))
    }

    func testCancellationRemovesThePartiallyStoredRaster() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try FrozenRasterFile.store(source, directory: directory, remainingDiskBytes: 1_000_000, limits: .init())
                return false
            } catch is CancellationError {
                return true
            }
        }
        let cancelled = try await task.value
        XCTAssertTrue(cancelled)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Shotty-frozen-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func fixture(colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!, trailingBytes: Int = 0) throws -> CGImage {
        let width = 11
        let height = 7
        let bytesPerRow = 64
        let pixels = Data((0..<(bytesPerRow * height + trailingBytes)).map { index in
            index % 4 == 3 ? UInt8(255) : UInt8((index * 37) % 256)
        })
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: bytesPerRow, space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .relativeColorimetric))
    }
}
