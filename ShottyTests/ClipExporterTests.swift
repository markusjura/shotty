import AppKit
import XCTest
@testable import Shotty

/// Rendering is tested through the exporter, which copy, save, and drag all go through.
final class ClipExporterTests: XCTestCase {
    private func snapshot(_ source: URL, duration: Double = 2, audio: Bool = false, edit: VideoEdit = VideoEdit(),
                          revision: Int = 0) -> ClipSnapshot {
        ClipSnapshot(captureID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, revision: revision, sourceURL: source,
                     createdAt: Date(timeIntervalSince1970: 1_790_000_000), pixelSize: CGSize(width: 160, height: 120),
                     duration: duration, hasAudio: audio, edit: edit)
    }

    func testEditsRenderTrimmedSpedUpCroppedAndScaled() async throws {
        let folder = try makeTemporaryFolder(self)
        let source = folder.appendingPathComponent("source.mp4")
        try await TestMovie.make(at: source, seconds: 3, audioTracks: 1)
        var edit = VideoEdit()
        edit.trimStart = 1
        edit.trimEnd = 3
        edit.speed = .double
        // The top right quadrant, green, in top-left frame coordinates.
        edit.crop = CGRect(x: 80, y: 0, width: 80, height: 60)
        edit.removesAudio = true
        let output = try await ClipExporter().rendered(snapshot(source, duration: 3, audio: true, edit: edit), options: RenderOptions())

        let movie = try await TestMovie.describe(output)
        XCTAssertEqual(movie.duration, 1, accuracy: 0.1)
        XCTAssertEqual(movie.size, CGSize(width: 80, height: 60))
        XCTAssertEqual(movie.audioTracks, 0)
        let color = try TestMovie.color(of: try await TestMovie.frame(of: output, at: 0.1), x: 0.5, y: 0.5)
        XCTAssertTrue(color.matches(.green), "The crop shows the top right quadrant, not \(color)")
    }

    func testTrimStartDecidesTheFirstFrame() async throws {
        let folder = try makeTemporaryFolder(self)
        let source = folder.appendingPathComponent("source.mp4")
        try await TestMovie.make(at: source)
        var edit = VideoEdit()
        edit.trimStart = 1.2
        let output = try await ClipExporter().rendered(snapshot(source, edit: edit), options: RenderOptions())
        let frame = try await TestMovie.frame(of: output, at: 0)
        // The bottom right quadrant turns from white to black at one second.
        XCTAssertTrue(try TestMovie.color(of: frame, x: 0.75, y: 0.75).matches(.black))
        let movie = try await TestMovie.describe(output)
        XCTAssertEqual(movie.duration, 0.8, accuracy: 0.1)
    }

    func testGIFLoopsAtTheChosenFrameRateSizeAndPace() async throws {
        let folder = try makeTemporaryFolder(self)
        let source = folder.appendingPathComponent("source.mp4")
        try await TestMovie.make(at: source, seconds: 1)
        var edit = VideoEdit(format: .gif)
        edit.size = .original
        let output = try await ClipExporter().rendered(snapshot(source, duration: 1, edit: edit), options: RenderOptions(gifFrameRate: 15))
        XCTAssertEqual(output.pathExtension, "gif")
        let gif = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(gif), 15)
        let delays = (0..<CGImageSourceGetCount(gif)).map { index in
            let frame = CGImageSourceCopyPropertiesAtIndex(gif, index, nil) as? [CFString: Any]
            return (frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
        }
        XCTAssertEqual(delays.reduce(0, +), 1, accuracy: 0.001, "Whole-centisecond delays still add up to the clip's length")
        let properties = try XCTUnwrap(CGImageSourceCopyProperties(gif, nil) as? [CFString: Any])
        let loop = (properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
        XCTAssertEqual(loop, 0, "GIFs loop forever")
        let first = try XCTUnwrap(CGImageSourceCreateImageAtIndex(gif, 0, nil))
        XCTAssertEqual(first.width, 160)
        XCTAssertTrue(try TestMovie.color(of: first, x: 0.25, y: 0.25).matches(.red))
    }

    func testUneditedClipsCopyTheRecordingAndRendersAreShared() async throws {
        let folder = try makeTemporaryFolder(self)
        let source = folder.appendingPathComponent("source.mp4")
        try await TestMovie.make(at: source)
        let exporter = ClipExporter()
        let first = try await exporter.rendered(snapshot(source), options: RenderOptions())
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: source))
        XCTAssertEqual(first.lastPathComponent, "\(ClipExporter.filenameStem(date: Date(timeIntervalSince1970: 1_790_000_000))).mp4")
        let again = try await exporter.rendered(snapshot(source), options: RenderOptions())
        XCTAssertEqual(again, first, "The same revision renders once")
        let next = try await exporter.rendered(snapshot(source, revision: 1), options: RenderOptions())
        XCTAssertNotEqual(next, first, "Every revision gets a file of its own, since receivers may still read older ones")
    }

    /// A drop can dismiss the clip, deleting its recording, before the receiver asks for the promised
    /// file, so the promise must not read the recording itself.
    @MainActor
    func testPromisedDragRendersAfterTheRecordingIsGone() async throws {
        let folder = try makeTemporaryFolder(self)
        let source = folder.appendingPathComponent("source.mp4")
        try await TestMovie.make(at: source)
        var edit = VideoEdit()
        edit.trimStart = 1
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ClipExporterTests-\(UUID())"))
        let coordinator = AppCoordinator(preferences: AppPreferences(defaults: defaults))
        let provider = try XCTUnwrap(coordinator.dragItem(snapshot(source, edit: edit)) as? NSFilePromiseProvider)
        try FileManager.default.removeItem(at: source)

        let dropped = folder.appendingPathComponent("dropped.mp4")
        let error = await withCheckedContinuation { continuation in
            provider.delegate?.filePromiseProvider(provider, writePromiseTo: dropped) { continuation.resume(returning: $0) }
        }
        XCTAssertNil(error)
        let movie = try await TestMovie.describe(dropped)
        XCTAssertEqual(movie.duration, 1, accuracy: 0.1)
    }

    func testFilenamesSortByRecordingTime() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let stem = ClipExporter.filenameStem(date: date, timeZone: TimeZone(identifier: "Europe/Berlin")!)
        XCTAssertEqual(stem, "clip-2026-09-21-16.13.20")
        XCTAssertEqual(ClipExporter.filename(stem: stem, collision: 3, format: .gif), "clip-2026-09-21-16.13.20-3.gif")
    }

    func testSavingNeverOverwritesUnlessTheFileIsUnchanged() async throws {
        let folder = try makeTemporaryFolder(self)
        let source = folder.appendingPathComponent("source.mp4")
        try await TestMovie.make(at: source)
        let saves = folder.appendingPathComponent("Saves", isDirectory: true)
        try FileManager.default.createDirectory(at: saves, withIntermediateDirectories: false)
        let exporter = ClipExporter()
        let clip = snapshot(source)
        let first = try await exporter.export(clip, to: saves, options: RenderOptions())
        let second = try await exporter.export(clip, to: saves, options: RenderOptions())
        let stem = ClipExporter.filenameStem(date: clip.createdAt)
        XCTAssertEqual(first.destinationURL.lastPathComponent, "\(stem).mp4")
        XCTAssertEqual(second.destinationURL.lastPathComponent, "\(stem)-2.mp4")

        do {
            _ = try await exporter.save(clip, to: first.destinationURL, options: RenderOptions())
            XCTFail("Saving over an existing file needs its fingerprint")
        } catch ClipExporter.Failure.destinationExists {}
        // Another app replaces the saved file; the next save must not silently overwrite it.
        try Data("edited elsewhere".utf8).write(to: first.destinationURL)
        do {
            _ = try await exporter.save(clip, to: first.destinationURL, options: RenderOptions(), replacing: first.fingerprint)
            XCTFail("A file changed outside Shotty is not replaced")
        } catch ClipExporter.Failure.externallyModified {}
        XCTAssertEqual(try Data(contentsOf: first.destinationURL), Data("edited elsewhere".utf8))
        let fresh = try await exporter.fingerprint(at: first.destinationURL)
        let replaced = try await exporter.save(clip, to: first.destinationURL, options: RenderOptions(), replacing: fresh)
        XCTAssertEqual(try Data(contentsOf: replaced.destinationURL), try Data(contentsOf: source))
    }
}
