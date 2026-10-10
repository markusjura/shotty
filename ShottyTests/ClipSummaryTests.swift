import XCTest
@testable import Shotty

@MainActor
final class ClipSummaryTests: XCTestCase {
    /// A clip card's size is the file a copy hands over: the recording itself while the clip is
    /// unedited, and unknown after an edit until its render exists.
    func testCardsShowTheRecordingSizeUntilAnEditNeedsARender() throws {
        let recording = try makeTemporaryFolder(self).appendingPathComponent("recording.mp4")
        try Data(count: 4_321).write(to: recording)
        let suite = "ClipSummaryTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppCoordinator(preferences: AppPreferences(defaults: defaults))
        var snapshot = ClipSnapshot(captureID: UUID(), revision: 0, sourceURL: recording, createdAt: Date(),
                                    pixelSize: CGSize(width: 160, height: 120), duration: 1.5, hasAudio: false, edit: VideoEdit())

        XCTAssertEqual(coordinator.summary(of: snapshot), .init(format: .mp4, duration: 1.5, byteCount: 4_321))
        snapshot.edit.trimStart = 0.5
        XCTAssertEqual(coordinator.summary(of: snapshot), .init(format: .mp4, duration: 1, byteCount: nil))
        snapshot.edit = VideoEdit(format: .gif)
        XCTAssertEqual(coordinator.summary(of: snapshot), .init(format: .gif, duration: 1.5, byteCount: nil))
    }
}
