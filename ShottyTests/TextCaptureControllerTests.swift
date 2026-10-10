import AppKit
import XCTest
@testable import Shotty

@MainActor
final class TextCaptureControllerTests: XCTestCase {
    /// As in CleanShot X, recognized text goes to the clipboard and nothing opens. Text the clipboard
    /// refuses, because something else was copied meanwhile, opens in Review instead of getting lost.
    func testCopiedTextOpensNothingAndRefusedTextOpensReview() async throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let suite = "TextCaptureControllerTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = AppCoordinator(preferences: AppPreferences(defaults: defaults), clipboard: ClipboardWriter(pasteboard: board))
        let recognized = RecognizedTextResult(lines: [RecognizedLine(text: "Shotty reads this", confidence: 1, wrapsToNextLine: false)])
        let controller = TextCaptureController(coordinator: coordinator) { _, _ in recognized }
        let settings = coordinator.preferences.snapshot()
        XCTAssertEqual(settings.text.outputs, [.copyText])
        let image = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?.makeImage())

        controller.start(image, region: .zero, settings: settings, ticket: coordinator.clipboard.begin())
        try await waitUntil { !controller.isActive }
        XCTAssertEqual(board.string(forType: .string), "Shotty reads this")
        XCTAssertFalse(controller.isShowingResults)

        let ticket = coordinator.clipboard.begin()
        board.clearContents()
        board.setString("copied meanwhile", forType: .string)
        controller.start(image, region: .zero, settings: settings, ticket: ticket)
        try await waitUntil { !controller.isActive }
        XCTAssertEqual(board.string(forType: .string), "copied meanwhile")
        XCTAssertTrue(controller.isShowingResults)
        await controller.stop()
        try await waitUntil { !controller.isShowingResults }
    }

    /// Polls `condition` until it holds, since the controller finishes on a task of its own.
    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
