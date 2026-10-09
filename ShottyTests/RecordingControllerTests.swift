import XCTest
@testable import Shotty

@MainActor
final class RecordingControllerTests: XCTestCase {
    /// Discard ends a finishing recording at once, so the next one can start before the first
    /// one's finisher returns. That finisher must leave the next recording alone and report nothing.
    func testDiscardingAFinishingRecordingLeavesTheNextOneAlone() async throws {
        var recorders: [SilentRecorder] = []
        let controller = RecordingController { _ in
            let recorder = SilentRecorder(folder: try makeTemporaryFolder(self))
            recorders.append(recorder)
            return recorder
        }
        var outcomes: [String] = []
        controller.finished = { _, _, _, _ in outcomes.append("finished") }
        controller.failed = { outcomes.append("failed: \($0.localizedDescription)") }
        let settings = AppPreferences(defaults: try XCTUnwrap(UserDefaults(suiteName: "RecordingControllerTests-\(UUID())"))).snapshot()
        let start = { controller.start(.display(CGMainDisplayID()), kind: .screen, settings: settings, ticket: ClipboardWriter().begin()) }
        defer { controller.cancel() }

        start()
        try await waitUntil { controller.phase == .recording }
        controller.stop()
        controller.cancel()
        start()
        // The first finisher fails, since nothing was recorded, and removes its folder before anything else.
        try await waitUntil { recorders.count == 2 && !FileManager.default.fileExists(atPath: recorders[0].folder.path) }
        try await waitUntil { controller.phase == .recording }
        XCTAssertEqual(outcomes, [])
    }

    /// Polls `condition` until it holds, for at most two seconds.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Records nothing, so every recording finishes empty.
@MainActor
private final class SilentRecorder: Recorder {
    let folder: URL
    var stoppedUnexpectedly: (() -> Void)?

    init(folder: URL) { self.folder = folder }

    func start(_ target: RecordingTarget) async throws {}
    func pause() {}
    func resume() throws {}
    func stop() async -> [URL] { [] }
    func cancel() async {}
}
