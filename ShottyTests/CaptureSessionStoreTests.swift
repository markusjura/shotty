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

    func testSourceAndBoundedThumbnailSurviveInterruptionAndRestore() async throws {
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

        // Relaunching without Quit, as after a crash, finds the session interrupted until Restore.
        let relaunched = CaptureSessionStore(directory: directory)
        let recovery = try await relaunched.load()
        XCTAssertEqual(recovery.state, .interrupted)
        XCTAssertEqual(recovery.records, [created])
        try await relaunched.resume()
        let source = try await relaunched.image(for: created.id)
        XCTAssertEqual(source.width, 1_200)
        XCTAssertEqual(source.colorSpace?.name, CGColorSpace.displayP3)
    }

    func testSessionOpenedThroughSymlinkKeepsOwnedSourceWhenCleaningOrphans() async throws {
        let parent = try directory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let actual = parent.appendingPathComponent("actual", isDirectory: true)
        try FileManager.default.createDirectory(at: actual, withIntermediateDirectories: false)
        let alias = parent.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: actual)
        let store = CaptureSessionStore(directory: alias)
        let record = try await store.create(image: image(), kind: .area, scale: 1)
        let orphan = actual.appendingPathComponent("\(UUID()).png")
        try Data("orphan".utf8).write(to: orphan)
        let restored = CaptureSessionStore(directory: actual)
        let recovery = try await restored.load()
        XCTAssertEqual(recovery.records, [record])
        try await restored.resume()
        let source = try await restored.image(for: record.id)
        XCTAssertEqual(source.width, 1_200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.sourceURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testInterruptedSessionRequiresRestoreAndDiscardCleansSources() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = CaptureSessionStore(directory: directory)
        let record = try await first.create(image: image(), kind: .area, scale: 1)
        let relaunched = CaptureSessionStore(directory: directory)
        do {
            _ = try await relaunched.create(image: image(), kind: .window, scale: 1)
            XCTFail("Must not overwrite an interrupted session")
        } catch CaptureSessionStore.Failure.recoveryRequired {}
        let recovery = try await relaunched.load()
        XCTAssertEqual(recovery.state, .interrupted)
        XCTAssertEqual(recovery.records.map(\.id), [record.id])
        try await relaunched.discard()
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.sourceURL.path))
        let empty = try await CaptureSessionStore(directory: directory).load()
        XCTAssertEqual(empty.state, .empty)
        XCTAssertTrue(empty.records.isEmpty)
    }

    func testManifestFailureLeavesExistingCaptureAndNoOrphanSource() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CaptureSessionStore(directory: directory)
        let record = try await store.create(image: image(), kind: .fullscreen, scale: 2)
        let manifest = directory.appendingPathComponent("session.json")
        let preserved = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        do {
            _ = try await store.create(image: image(), kind: .area, scale: 1)
            XCTFail("Replacing a directory with the manifest must fail")
        } catch {}
        let records = await store.records()
        XCTAssertEqual(records, [record])
        let sources = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(sources.map { $0.resolvingSymlinksInPath() }, [record.sourceURL.resolvingSymlinksInPath()])
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.hasPrefix(".shotty-") },
                       "Failed manifest publication must remove the directly encoded source and all staging files")
        try FileManager.default.removeItem(at: manifest)
        try preserved.write(to: manifest)
        let recovered = try await CaptureSessionStore(directory: directory).load()
        XCTAssertEqual(recovered.records, [record])
    }

    func testCopyAndSaveStateRequireMatchingRevisionAndRemovalIsDurable() async throws {
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
        let reloaded = try await CaptureSessionStore(directory: directory.appendingPathComponent("session")).load()
        XCTAssertTrue(reloaded.records.isEmpty)
    }
}
