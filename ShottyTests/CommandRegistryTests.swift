import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Shotty

@MainActor
final class CommandRegistryTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "CommandRegistryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testDefaultBindingsAreConflictFreeAndSatisfyTheirScopeRules() {
        let registry = CommandRegistry(defaults: defaults)
        for id in CommandID.allCases {
            XCTAssertEqual(registry.shortcut(for: id), id.defaultShortcut, id.rawValue)
            if let shortcut = id.defaultShortcut { XCTAssertNil(registry.problem(assigning: shortcut, to: id), id.rawValue) }
        }
        XCTAssertTrue(CommandGroup.thumbnails.commands.allSatisfy { $0.defaultShortcut == nil && $0.scope == .global })
    }

    func testRejectedAssignmentsExplainWhyAndChangeNothing() {
        let registry = CommandRegistry(defaults: defaults)
        let before = registry.bindings
        XCTAssertEqual(registry.assign(Shortcut(kVK_ANSI_S, .command), to: .copyImage), .conflict(.save))
        XCTAssertEqual(registry.assign(Shortcut(kVK_ANSI_4, [.option, .shift]), to: .captureArea), .needsCommandOrControl)
        XCTAssertEqual(registry.assign(Shortcut(kVK_ANSI_X), to: .duplicate), .needsCommandOrControl)
        XCTAssertEqual(registry.assign(Shortcut(kVK_ANSI_Q, .command), to: .openLatest), .reserved)
        XCTAssertEqual(registry.assign(Shortcut(kVK_Space), to: .toolCrop), .reservedForEditing)
        XCTAssertEqual(registry.bindings, before)
        XCTAssertNil(registry.assign(Shortcut(kVK_ANSI_X), to: .toolCrop), "Tool keys may be single letters")
    }

    func testCustomBindingsPersistIncludingClearedAndMovedKeys() {
        let registry = CommandRegistry(defaults: defaults)
        let fullscreen = CommandID.captureFullscreen.defaultShortcut!
        XCTAssertNil(registry.assign(nil, to: .captureFullscreen))
        XCTAssertNil(registry.assign(fullscreen, to: .captureArea))
        XCTAssertNil(registry.assign(nil, to: .toolText))
        XCTAssertNil(registry.assign(Shortcut(kVK_ANSI_O, [.control, .command]), to: .duplicate))

        let reloaded = CommandRegistry(defaults: defaults)
        XCTAssertNil(reloaded.shortcut(for: .captureFullscreen), "A cleared default stays cleared")
        XCTAssertEqual(reloaded.shortcut(for: .captureArea), fullscreen, "A moved key wins over its old default owner")
        XCTAssertNil(reloaded.shortcut(for: .toolText))
        XCTAssertEqual(reloaded.shortcut(for: .duplicate), Shortcut(kVK_ANSI_O, [.control, .command]))
        XCTAssertEqual(reloaded.shortcut(for: .captureWindow), CommandID.captureWindow.defaultShortcut)
    }

    func testCorruptStoredDuplicatesKeepOneOwnerAndFallBackToDefaults() throws {
        let duplicate = Shortcut(kVK_ANSI_S, .command)
        let stored: [String: Shortcut?] = ["copyImage": duplicate, "saveAs": duplicate, "zoomIn": Shortcut(kVK_ANSI_Q, .command)]
        defaults.set(try JSONEncoder().encode(stored), forKey: CommandRegistry.storageKey)

        let registry = CommandRegistry(defaults: defaults)
        let owners = CommandID.allCases.filter { registry.shortcut(for: $0) == duplicate }
        XCTAssertEqual(owners.count, 1)
        XCTAssertEqual(registry.shortcut(for: .zoomIn), CommandID.zoomIn.defaultShortcut, "Rule-breaking stored keys fall back")
    }

    func testGroupRestoreHandlesSwappedKeysAndSingleRestoreReportsConflicts() {
        let registry = CommandRegistry(defaults: defaults)
        let arrow = CommandID.toolArrow.defaultShortcut!, rectangle = CommandID.toolRectangle.defaultShortcut!
        registry.assign(nil, to: .toolArrow)
        registry.assign(arrow, to: .toolRectangle)
        registry.assign(rectangle, to: .toolArrow)
        XCTAssertEqual(registry.restoreDefaults(in: .editor), [:])
        XCTAssertEqual(registry.shortcut(for: .toolArrow), arrow)
        XCTAssertEqual(registry.shortcut(for: .toolRectangle), rectangle)

        registry.assign(nil, to: .save)
        registry.assign(Shortcut(kVK_ANSI_S, .command), to: .saveAs)
        XCTAssertEqual(registry.restoreDefault(.save), .conflict(.saveAs))
        XCTAssertNil(registry.shortcut(for: .save))
    }

    func testAdvisoryFlagsMacOSScreenshotKeys() {
        let registry = CommandRegistry(defaults: defaults)
        XCTAssertNil(registry.assign(Shortcut(kVK_ANSI_3, [.shift, .command]), to: .captureFullscreen))
        XCTAssertNotNil(registry.advisory(for: .captureFullscreen), "macOS's own screenshot keys are an external owner")
        XCTAssertNil(registry.advisory(for: .captureWindow))
    }

    func testStoredThumbnailBindingsAreIgnored() throws {
        let stored = [CommandID.showThumbnails.rawValue: Shortcut(kVK_ANSI_9, [.control, .command])]
        defaults.set(try JSONEncoder().encode(stored), forKey: CommandRegistry.storageKey)
        XCTAssertNil(CommandRegistry(defaults: defaults).shortcut(for: .showThumbnails), "Thumbnail commands have no shortcut settings")
    }

    func testLocalRoutingOnlyMatchesRequestedScopes() {
        let registry = CommandRegistry(defaults: defaults)
        let local: Set<CommandScope> = [.editorTool, .editor]
        XCTAssertEqual(registry.command(matching: Shortcut(kVK_ANSI_T), in: local), .toolText)
        XCTAssertEqual(registry.command(matching: Shortcut(kVK_ANSI_C, [.shift, .command]), in: local), .copyImage)
        XCTAssertNil(registry.command(matching: CommandID.captureText.defaultShortcut!, in: local))
        XCTAssertEqual(registry.command(matching: CommandID.captureText.defaultShortcut!, in: [.global]), .captureText)
    }

    func testRecordedEventsIgnoreModifierOnlyKeys() throws {
        func event(_ keyCode: Int, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                             context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
                             keyCode: UInt16(keyCode))
        }
        let area = try XCTUnwrap(event(kVK_ANSI_4, [.shift, .command, .capsLock]))
        XCTAssertEqual(Shortcut(event: area), Shortcut(kVK_ANSI_4, [.shift, .command]))
        XCTAssertNil(Shortcut(event: try XCTUnwrap(event(kVK_Command, .command))))
        XCTAssertNil(Shortcut(event: try XCTUnwrap(event(kVK_ANSI_A, [.command, .function]))), "Do not silently drop Fn from an unsupported combination")
        XCTAssertNil(Shortcut(event: try XCTUnwrap(event(kVK_VolumeUp, .command))))
        XCTAssertEqual(Shortcut(event: try XCTUnwrap(event(kVK_F5, [.command, .function]))), Shortcut(kVK_F5, .command))
        XCTAssertEqual(Shortcut(event: try XCTUnwrap(event(kVK_LeftArrow, [.command, .function]))), Shortcut(kVK_LeftArrow, .command))
    }

    func testRoutingHonorsAvailabilityRecordingAndTextInputContext() {
        let registry = CommandRegistry(defaults: defaults)
        let shortcut = CommandID.toolArrow.defaultShortcut!
        registry.setAvailable(false, for: .toolArrow)
        XCTAssertNil(registry.command(matching: shortcut, in: [.editorTool]))
        registry.setAvailable(true, for: .toolArrow)
        XCTAssertEqual(registry.command(matching: shortcut, in: [.editorTool]), .toolArrow)
        XCTAssertNil(registry.command(matching: shortcut, in: [.editorTool], isTextEditing: true))
        registry.recordingCommand = .captureArea
        XCTAssertNil(registry.command(matching: shortcut, in: [.editorTool]))
        XCTAssertFalse(registry.isAvailable(.captureFullscreen))
        registry.recordingCommand = nil
        var hasCaptures = false
        registry.availability = { $0.group != .thumbnails || hasCaptures }
        XCTAssertFalse(registry.isAvailable(.saveAll))
        hasCaptures = true
        XCTAssertTrue(registry.isAvailable(.saveAll))
    }

    func testUnsupportedStoredKeysFallBackAndNavigationCannotShadowCanvasOperations() throws {
        let invalid = Shortcut(keyCode: 65_535, modifiers: .command)
        let invalidFlags = Shortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: .init(rawValue: 128))
        let registry = CommandRegistry(defaults: defaults)
        XCTAssertEqual(registry.assign(invalid, to: .save), .unsupported)
        XCTAssertEqual(registry.assign(invalidFlags, to: .toolArrow), .unsupported)
        XCTAssertEqual(registry.assign(Shortcut(kVK_Delete, .command), to: .toolArrow), .reservedForEditing)
        XCTAssertEqual(registry.assign(Shortcut(kVK_LeftArrow, .command), to: .copyImage), .reservedForEditing)
        XCTAssertNil(registry.problem(assigning: CommandID.done.defaultShortcut!, to: .done))
        let stored: [String: Shortcut?] = ["save": invalid, "toolArrow": invalidFlags]
        defaults.set(try JSONEncoder().encode(stored), forKey: CommandRegistry.storageKey)
        let restored = CommandRegistry(defaults: defaults)
        XCTAssertEqual(restored.shortcut(for: .save), CommandID.save.defaultShortcut)
        XCTAssertEqual(restored.shortcut(for: .toolArrow), CommandID.toolArrow.defaultShortcut)
    }

    func testStandardEditingCharactersAreReservedOnTheActiveLayout() throws {
        let registry = CommandRegistry(defaults: defaults)
        // On a German layout, the physical ANSI Y key resolves to Z. On QWERTY, ANSI Z does.
        let undoKey = (0...126).compactMap { code -> Int? in
            KeyNames.character(for: UInt16(code)).map { String($0).lowercased() == "z" ? code : nil } ?? nil
        }.first
        let key = try XCTUnwrap(undoKey)
        XCTAssertEqual(registry.problem(assigning: Shortcut(key, .command), to: .openLatest), .reserved)
        XCTAssertEqual(registry.problem(assigning: Shortcut(key, [.shift, .command]), to: .openLatest), .reserved)
    }
}
