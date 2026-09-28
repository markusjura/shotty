import CoreGraphics
import XCTest
@testable import Shotty

@MainActor
final class CaptureSessionStoreTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-session-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func image(width: Int = 1_200, height: Int = 600) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                             bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.6, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testSourceIsKeptPrivatelyWithABoundedThumbnail() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureSessionStore(directory: directory)
        let created = try await store.create(image: image(), kind: .window, scale: 2)
        XCTAssertEqual(created.pixelWidth, 1_200)
        XCTAssertEqual(created.sourceScale, 2)
        let thumbnail = try await store.thumbnail(for: created.id)
        XCTAssertEqual(thumbnail.width, 560)
        XCTAssertEqual(thumbnail.height, 280)
        let fromMemory = try await store.thumbnail(of: image())
        XCTAssertEqual(fromMemory.width, 560)
        XCTAssertEqual(fromMemory.height, 280)
        let permissions = try FileManager.default.attributesOfItem(atPath: created.sourceURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        let backup = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(backup.isExcludedFromBackup, true)
        let source = try await store.image(for: created.id)
        XCTAssertEqual(source.width, 1_200)
        XCTAssertEqual(source.colorSpace?.name, CGColorSpace.displayP3)
    }

    /// A launch after a crash or kill starts empty, removing whatever the previous run left.
    func testResetForgetsCapturesAndClearsLeftoverFiles() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let crashed = CaptureSessionStore(directory: directory)
        let record = try await crashed.create(image: image(), kind: .area, scale: 1)
        try Data("{}".utf8).write(to: directory.appendingPathComponent("session.json"))
        let relaunched = CaptureSessionStore(directory: directory)
        try await relaunched.reset()
        let records = await relaunched.records()
        XCTAssertTrue(records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.sourceURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        _ = try await relaunched.create(image: image(), kind: .window, scale: 1)
    }

    func testCopyAndSaveStateRequireMatchingRevisionAndRemovalDeletesTheSource() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureSessionStore(directory: directory.appendingPathComponent("session"))
        let record = try await store.create(image: image(), kind: .area, scale: 2)
        let snapshot = try await store.snapshot(for: record.id)
        let receipt = try await ExportService().export(snapshot, to: directory)
        try await store.markSaved(receipt)
        try await store.markCopied(snapshot)
        let updated = await store.records()
        XCTAssertTrue(try XCTUnwrap(updated.first).isSaved)
        XCTAssertTrue(try XCTUnwrap(updated.first).isCopied)
        XCTAssertEqual(updated.first?.outputFile?.fingerprint, receipt.fingerprint)
        let invalid = CaptureSnapshot(captureID: record.id, revision: 1, sourceURL: snapshot.sourceURL,
                                      sourceScale: 2, createdAt: record.createdAt)
        do {
            try await store.markCopied(invalid)
            XCTFail("A nonexistent revision cannot be marked copied")
        } catch CaptureSessionStore.Failure.missingCapture {}
        try await store.remove(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.destinationURL.path))
        let remaining = await store.records()
        XCTAssertTrue(remaining.isEmpty)
    }
}
