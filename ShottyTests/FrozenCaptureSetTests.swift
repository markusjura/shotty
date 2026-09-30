import CoreGraphics
import Foundation
import ScreenCaptureKit
import XCTest
@testable import Shotty

final class FrozenCaptureSetTests: XCTestCase {
    func testUnavailableWindowDoesNotAbortOrReorderDisplayCaptures() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raster = try FrozenRasterFile.store(fixture(), directory: directory, remainingDiskBytes: 1_000_000, limits: .init())
        let requests = [true, true, false].map {
            FrozenCaptureBatch.Request(estimatedBytes: raster.byteCount, isWindow: $0, diagnosticLabel: "fixture")
        }
        let results = try await FrozenCaptureBatch.capture(requests, maximumDiskBytes: raster.byteCount * 3, concurrency: 3) { index in
            if index == 1 { throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue) }
            if index == 0 { try await Task.sleep(for: .milliseconds(20)) }
            return raster
        }
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results[0]?.id, raster.id)
        XCTAssertNil(results[1])
        XCTAssertEqual(results[2]?.id, raster.id)
    }

    func testUnavailableWindowReturnsItsDiskReservation() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let raster = try FrozenRasterFile.store(fixture(), directory: directory, remainingDiskBytes: 1_000_000, limits: .init())
        let requests = [true, false].map {
            FrozenCaptureBatch.Request(estimatedBytes: raster.byteCount, isWindow: $0, diagnosticLabel: "fixture")
        }
        let results = try await FrozenCaptureBatch.capture(requests, maximumDiskBytes: raster.byteCount, concurrency: 3) { index in
            if index == 0 { throw NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue) }
            return raster
        }
        XCTAssertNil(results[0])
        XCTAssertEqual(results[1]?.id, raster.id)
    }

    func testDisplayPermissionAndResourceFailuresStillAbortFreezing() async {
        let cases: [(isWindow: Bool, error: NSError)] = [
            (false, NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.internalError.rawValue)),
            (true, NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue)),
            (true, NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.missingEntitlements.rawValue)),
            (true, FrozenCaptureFailure.diskLimit as NSError),
            (true, FrozenCaptureFailure.resourceLimit as NSError),
            (true, NSError(domain: "UnrelatedError", code: SCStreamError.Code.internalError.rawValue))
        ]
        for (isWindow, error) in cases {
            let request = FrozenCaptureBatch.Request(estimatedBytes: 1, isWindow: isWindow, diagnosticLabel: "fixture")
            do {
                _ = try await FrozenCaptureBatch.capture([request], maximumDiskBytes: 1, concurrency: 1) { _ in throw error }
                XCTFail("Expected \(error) to abort freezing")
            } catch let actual as NSError {
                XCTAssertEqual(actual.domain, error.domain)
                XCTAssertEqual(actual.code, error.code)
            }
        }
    }

    func testWindowCaptureCancellationStillAbortsFreezing() async {
        let request = FrozenCaptureBatch.Request(estimatedBytes: 1, isWindow: true, diagnosticLabel: "fixture")
        do {
            _ = try await FrozenCaptureBatch.capture([request], maximumDiskBytes: 1, concurrency: 1) { _ in
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
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

    func testDiskAndRasterLimitsRejectBeforeCreatingFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try fixture()
        XCTAssertThrowsError(try FrozenRasterFile.store(source, directory: directory, remainingDiskBytes: 1, limits: .init()))
        XCTAssertThrowsError(try FrozenRasterFile.store(source, directory: directory, remainingDiskBytes: 1_000_000,
                                                        limits: FrozenCaptureLimits(maximumRasterBytes: 100)))
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
