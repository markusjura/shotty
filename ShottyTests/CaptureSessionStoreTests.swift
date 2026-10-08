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
        try await store.markCopied(record.id, revision: snapshot.revision)
        let updated = await store.records()
        XCTAssertTrue(try XCTUnwrap(updated.first).isSaved)
        XCTAssertTrue(try XCTUnwrap(updated.first).isCopied)
        XCTAssertEqual(updated.first?.outputFile?.fingerprint, receipt.fingerprint)
        do {
            try await store.markCopied(record.id, revision: 1)
            XCTFail("A nonexistent revision cannot be marked copied")
        } catch CaptureSessionStore.Failure.missingCapture {}
        try await store.remove(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.destinationURL.path))
        let remaining = await store.records()
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: Clips

    func testScreenshotsAndClipsShareOneSessionInCaptureOrder() async throws {
        let folder = try makeTemporaryFolder(self)
        let movie = folder.appendingPathComponent("recording.mp4")
        try await TestMovie.make(at: movie, seconds: 0.5)
        let store = CaptureSessionStore(directory: folder.appendingPathComponent("Session", isDirectory: true))
        let screenshot = try await store.create(image: image(), kind: .area, scale: 2)
        let clip = try await store.create(movie: movie, kind: .area, format: .mp4)
        let records = await store.records()
        XCTAssertEqual(records.map(\.id), [screenshot.id, clip.id])
        do {
            _ = try await store.snapshot(for: clip.id)
            XCTFail("A clip has no image to export")
        } catch CaptureSessionStore.Failure.missingCapture {}
        try await store.markCopied(clip.id, revision: 0)
        let copied = await store.records()
        XCTAssertEqual(copied.map(\.isCopied), [false, true])
    }

    func testRecordingsJoinTheSessionWithTheirMovieFacts() async throws {
        let folder = try makeTemporaryFolder(self)
        let movie = folder.appendingPathComponent("recording.mp4")
        try await TestMovie.make(at: movie, width: 320, height: 200, seconds: 1.5, audioTracks: 1)
        let store = CaptureSessionStore(directory: folder.appendingPathComponent("Session", isDirectory: true))

        let record = try await store.create(movie: movie, kind: .window, format: .gif)
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.path), "The session takes the recording itself")
        XCTAssertEqual(record.pixelSize, CGSize(width: 320, height: 200))
        XCTAssertEqual(record.duration, 1.5, accuracy: 0.05)
        XCTAssertTrue(record.hasAudio)
        XCTAssertEqual(record.edit.format, .gif)
        XCTAssertEqual(record.edit.size, .px960, "New GIF clips start at the GIF size")

        try await store.remove(record.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.sourceURL.path))
        let records = await store.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testThumbnailsShowTheFirstKeptFrameAsCropped() async throws {
        let folder = try makeTemporaryFolder(self)
        let movie = folder.appendingPathComponent("recording.mp4")
        try await TestMovie.make(at: movie, width: 1600, height: 1200)
        let store = CaptureSessionStore(directory: folder.appendingPathComponent("Session", isDirectory: true))
        let record = try await store.create(movie: movie, kind: .area, format: .mp4)

        let whole = try await store.thumbnail(for: record.id)
        // The image generator may round a pixel down.
        XCTAssertEqual(Double(max(whole.width, whole.height)), 560, accuracy: 1)
        var edit = record.edit
        edit.crop = CGRect(x: 800, y: 600, width: 800, height: 600)
        edit.trimStart = 1.5
        try await store.updateEdit(for: record.id, edit: edit, revision: 1)
        let cropped = try await store.thumbnail(for: record.id)
        XCTAssertEqual(Double(cropped.width), 560, accuracy: 1, "A crop is decoded large enough to fill the thumbnail")
        XCTAssertTrue(try TestMovie.color(of: cropped, x: 0.5, y: 0.5).matches(.black),
                      "The bottom right quadrant after one second")
    }

    func testEditsOnlyMoveForward() async throws {
        let folder = try makeTemporaryFolder(self)
        let movie = folder.appendingPathComponent("recording.mp4")
        try await TestMovie.make(at: movie, seconds: 1)
        let store = CaptureSessionStore(directory: folder.appendingPathComponent("Session", isDirectory: true))
        let record = try await store.create(movie: movie, kind: .screen, format: .mp4)
        var newer = record.edit; newer.speed = .double
        var older = record.edit; older.speed = .quadruple
        try await store.updateEdit(for: record.id, edit: newer, revision: 2)
        try await store.updateEdit(for: record.id, edit: older, revision: 1)
        let snapshot = try await store.clipSnapshot(for: record.id)
        XCTAssertEqual(snapshot.revision, 2)
        XCTAssertEqual(snapshot.edit.speed, .double, "A late write of an older revision never wins")
        XCTAssertEqual(snapshot.outputDuration, 0.5, accuracy: 0.05)
    }
}
