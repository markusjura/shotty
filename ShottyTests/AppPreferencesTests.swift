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
        preferences.editor.tools.width = 9
        preferences.recording.outputs = [.copyClip, .saveClip]
        preferences.recording.codec = .hevc
        preferences.recording.pickMicrophone("usb-mic")
        preferences.editor.gifFrameRate = .fps24

        preferences.capture.outputs = []
        preferences.recording.outputs = []
        preferences.text.outputs = []
        preferences.text.detectsLanguageAutomatically = false
        preferences.scrolling.maximumAxisPixels = 40_000
        preferences.thumbnails.autoCloseDelaySeconds = 0
        preferences.editor.tools.width = 0

        let reloaded = AppPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.capture.outputs, [.copyImage, .saveImage])
        XCTAssertEqual(reloaded.capture.destination, .folder(folder))
        XCTAssertEqual(reloaded.thumbnails.display, .display(uuid: "ABC", name: "Studio Display"))
        XCTAssertFalse(reloaded.general.showsMenuBarIcon, "Both icons may be hidden")
        XCTAssertFalse(reloaded.general.showsDockIcon)
        XCTAssertEqual(reloaded.editor.tools.width, 9)
        XCTAssertEqual(reloaded.text, TextCapturePreferences())
        XCTAssertEqual(reloaded.scrolling.maximumAxisPixels, 30_000)
        XCTAssertEqual(reloaded.thumbnails.autoCloseDelaySeconds, 10)
        XCTAssertEqual(reloaded.recording.outputs, [.copyClip, .saveClip])
        XCTAssertTrue(reloaded.recording.recordsMicrophone, "The Record bar's audio choice survives a relaunch")
        XCTAssertEqual(reloaded.recording.microphoneID, "usb-mic")

        let snapshot = reloaded.snapshot()
        reloaded.capture.format = .png
        XCTAssertEqual(snapshot.exportOptions.format, .jpeg, "A snapshot keeps invocation-time choices")
        XCTAssertEqual(snapshot.exportOptions.scale, .logical)
        XCTAssertEqual(snapshot.saveDirectory, folder)
        reloaded.recording.codec = .h264
        reloaded.editor.gifFrameRate = .fps10
        XCTAssertEqual(snapshot.renderOptions, RenderOptions(codec: .hevc, gifFrameRate: 24))
    }

    func testStoredSectionsMergeOverDefaultsAndBadSectionsFallBackIndividually() throws {
        defaults.set(Data(#"{"outputs":["copyImage"],"includesWindowShadow":false,"showsCursor":true}"#.utf8), forKey: "preferences.v1.capture")
        defaults.set(Data("not json".utf8), forKey: "preferences.v1.thumbnails")
        defaults.set(Data(#"{"maximumAxisPixels":99999}"#.utf8), forKey: "preferences.v1.scrolling")
        defaults.set(Data(#"{"tools":{"width":12,"spotlight":{"dimPercent":60}}}"#.utf8), forKey: "preferences.v1.editor")

        let preferences = AppPreferences(defaults: defaults)
        XCTAssertEqual(preferences.capture.outputs, [.copyImage])
        XCTAssertFalse(preferences.capture.includesWindowShadow, "Unknown stored fields are ignored")
        XCTAssertTrue(preferences.capture.freezesScreen, "Fields missing from older data keep their defaults")
        XCTAssertEqual(preferences.thumbnails, ThumbnailPreferences())
        XCTAssertEqual(preferences.scrolling, ScrollingPreferences(), "Out-of-bounds stored limits are not trusted")
        XCTAssertEqual(preferences.editor.tools.width, 12)
        XCTAssertEqual(preferences.editor.tools.spotlight.shape, .roundedRectangle, "Nested sections merge field by field")
    }

    func testMicrophoneIsTheLastPickedInputWhileConnectedElseTheSystemDefault() {
        let builtIn = Microphone(id: "built-in", name: "MacBook Pro Microphone")
        let usb = Microphone(id: "usb", name: "USB Microphone")
        var recording = RecordingPreferences()
        XCTAssertEqual(recording.microphone(in: [builtIn, usb]), builtIn, "Nothing picked records from the system default")

        recording.pickMicrophone("usb")
        XCTAssertEqual(recording.microphone(in: [builtIn, usb]), usb)
        XCTAssertEqual(recording.microphone(in: [builtIn]), builtIn, "A disconnected input falls back to the system default")
        XCTAssertNil(recording.microphone(in: []))

        recording.pickMicrophone(nil)
        XCTAssertFalse(recording.recordsMicrophone)
        recording.recordsMicrophone = true
        XCTAssertEqual(recording.microphone(in: [builtIn, usb]), usb, "Turning the microphone off keeps the picked input")
    }
}
