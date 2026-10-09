import Carbon.HIToolbox
import XCTest
@testable import Shotty

@MainActor
final class ThumbnailShortcutTests: XCTestCase {
    func testCardActionsFollowRemappedClearedAndSuspendedBindings() throws {
        let suite = "ThumbnailShortcutTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = CommandRegistry(defaults: defaults)
        let thumbnails = ThumbnailCoordinator(preferences: AppPreferences(defaults: defaults))
        thumbnails.commands = registry
        let copy = Shortcut(kVK_ANSI_C, [.shift, .command]), remapped = Shortcut(kVK_ANSI_K, [.control, .command])

        XCTAssertEqual(thumbnails.cardAction(for: copy), .copy)
        XCTAssertEqual(thumbnails.cardAction(for: Shortcut(kVK_ANSI_S, [.shift, .command])), .saveAs)
        XCTAssertNil(registry.assign(remapped, to: .copy))
        XCTAssertNil(thumbnails.cardAction(for: copy), "The old key no longer copies")
        XCTAssertEqual(thumbnails.cardAction(for: remapped), .copy)
        XCTAssertEqual(thumbnails.shortcut(for: .copy), remapped, "Context menus show the current binding")

        registry.assign(nil, to: .save)
        XCTAssertNil(thumbnails.cardAction(for: Shortcut(kVK_ANSI_S, .command)))
        XCTAssertNil(thumbnails.shortcut(for: .save))

        registry.recordingCommand = .saveAs
        XCTAssertNil(thumbnails.cardAction(for: remapped), "Recording suspends card shortcuts")
    }
}
