import XCTest
@testable import Shotty

@MainActor
final class AppPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "AppPreferencesTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testChangesPersistImmediatelyAndInvalidWritesKeepThePreviousValue() {
        let preferences = AppPreferences(defaults: defaults)
        let folder = URL(fileURLWithPath: "/tmp/Shotty Captures", isDirectory: true)
        preferences.capture.outputs = [.copyImage, .saveImage]
        preferences.capture.destination = .folder(folder)
        preferences.capture.format = .jpeg
        preferences.capture.outputScale = .logical
        preferences.thumbnails.display = .display(uuid: "ABC", name: "Studio Display")
        preferences.general.showsMenuBarIcon = false
        preferences.editor.tools.arrow.width = 9

        preferences.capture.outputs = []
        preferences.text.outputs = []
        preferences.text.detectsLanguageAutomatically = false
        preferences.scrolling.maximumAxisPixels = 40_000
        preferences.thumbnails.autoCloseDelaySeconds = 0
        preferences.editor.tools.arrow.width = 0

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.capture.outputs, [.copyImage, .saveImage])
        XCTAssertEqual(reloaded.capture.destination, .folder(folder))
        XCTAssertEqual(reloaded.thumbnails.display, .display(uuid: "ABC", name: "Studio Display"))
        XCTAssertFalse(reloaded.general.showsMenuBarIcon, "Both icons may be hidden")
        XCTAssertFalse(reloaded.general.showsDockIcon)
        XCTAssertEqual(reloaded.editor.tools.arrow.width, 9)
        XCTAssertEqual(reloaded.text, TextCapturePreferences())
        XCTAssertEqual(reloaded.scrolling.maximumAxisPixels, 30_000)
        XCTAssertEqual(reloaded.thumbnails.autoCloseDelaySeconds, 10)

        let snapshot = reloaded.snapshot(for: .area)
        reloaded.capture.format = .png
        XCTAssertEqual(snapshot.exportOptions.format, .jpeg, "A snapshot keeps invocation-time choices")
        XCTAssertEqual(snapshot.exportOptions.scale, .logical)
        XCTAssertEqual(snapshot.saveDirectory, folder)
    }

    func testStoredSectionsMergeOverDefaultsAndBadSectionsFallBackIndividually() throws {
        defaults.set(Data(#"{"outputs":["copyImage"],"showsCursor":true}"#.utf8), forKey: "preferences.v1.capture")
        defaults.set(Data("not json".utf8), forKey: "preferences.v1.thumbnails")
        defaults.set(Data(#"{"maximumAxisPixels":99999}"#.utf8), forKey: "preferences.v1.scrolling")
        defaults.set(Data(#"{"tools":{"arrow":{"width":12}}}"#.utf8), forKey: "preferences.v1.editor")

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.capture.outputs, [.copyImage])
        XCTAssertTrue(preferences.capture.showsCursor)
        XCTAssertTrue(preferences.capture.freezesScreen, "Fields missing from older data keep their defaults")
        XCTAssertEqual(preferences.thumbnails, ThumbnailPreferences())
        XCTAssertEqual(preferences.scrolling, ScrollingPreferences(), "Out-of-bounds stored limits are not trusted")
        XCTAssertEqual(preferences.editor.tools.arrow.width, 12)
        XCTAssertEqual(preferences.editor.tools.arrow.style, .standard, "Nested sections merge field by field")
    }

    func testResettingOneToolLeavesOtherToolDefaults() {
        let preferences = AppPreferences(defaults: defaults)
        preferences.editor.tools.arrow.color = .black
        preferences.editor.tools.counter.size = 40
        preferences.resetToolDefaults(.arrow)
        XCTAssertTrue(preferences.editor.tools.isDefault(.arrow))
        XCTAssertEqual(preferences.editor.tools.counter.size, 40)
    }
}
