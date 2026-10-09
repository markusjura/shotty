import XCTest
@testable import Shotty

final class ClipAssemblerTests: XCTestCase {
    func testPausedSegmentsJoinIntoOneMovie() async throws {
        let folder = try makeTemporaryFolder(self)
        let segments = (0..<2).map { folder.appendingPathComponent("segment-\($0).mp4") }
        try await TestMovie.make(at: segments[0], seconds: 1, audioTracks: 1)
        try await TestMovie.make(at: segments[1], seconds: 1.5, audioTracks: 1)
        let clip = folder.appendingPathComponent("clip.mp4")
        try await ClipAssembler.assemble(segments, into: clip)
        let movie = try await TestMovie.describe(clip)
        XCTAssertEqual(movie.duration, 2.5, accuracy: 0.1)
        XCTAssertEqual(movie.videoTracks, 1)
        XCTAssertEqual(movie.audioTracks, 1)
        XCTAssertTrue(segments.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Joined segments are removed")
    }

    /// Browsers and chat apps play only the first audio track, so separate system audio and
    /// microphone tracks are mixed into one.
    func testSystemAudioAndMicrophoneMixIntoOneTrack() async throws {
        let folder = try makeTemporaryFolder(self)
        let segment = folder.appendingPathComponent("segment-0.mp4")
        try await TestMovie.make(at: segment, seconds: 1, audioTracks: 2)
        let recorded = try await TestMovie.describe(segment)
        XCTAssertEqual(recorded.audioTracks, 2)
        let clip = folder.appendingPathComponent("clip.mp4")
        try await ClipAssembler.assemble([segment], into: clip)
        let movie = try await TestMovie.describe(clip)
        XCTAssertEqual(movie.audioTracks, 1)
        XCTAssertEqual(movie.duration, 1, accuracy: 0.1)
    }

    func testASingleSegmentBecomesTheClipUnchanged() async throws {
        let folder = try makeTemporaryFolder(self)
        let segment = folder.appendingPathComponent("segment-0.mp4")
        try await TestMovie.make(at: segment, seconds: 1)
        let bytes = try Data(contentsOf: segment)
        let clip = folder.appendingPathComponent("clip.mp4")
        try await ClipAssembler.assemble([segment], into: clip)
        XCTAssertEqual(try Data(contentsOf: clip), bytes)
        do {
            try await ClipAssembler.assemble([], into: folder.appendingPathComponent("empty.mp4"))
            XCTFail("A recording without segments has nothing to keep")
        } catch RecordingFailure.nothingRecorded {}
    }
}
