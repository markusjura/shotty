import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A physical key plus modifiers. Key codes are layout-independent; display strings use the
/// current ASCII-capable layout, as macOS menus do.
struct Shortcut: Codable, Hashable, Sendable {
    struct Modifiers: OptionSet, Codable, Hashable, Sendable {
        let rawValue: UInt8
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    let keyCode: UInt16
    let modifiers: Modifiers

    init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Convenience for Carbon `kVK_*` constants.
    init(_ key: Int, _ modifiers: Modifiers = []) {
        self.init(keyCode: UInt16(key), modifiers: modifiers)
    }

    /// Nil for modifier-only presses and anything other than a key-down event.
    init?(event: NSEvent) {
        guard event.type == .keyDown, Self.supports(keyCode: event.keyCode),
              !event.modifierFlags.contains(.function) || Self.functionKeyCodes.contains(Int(event.keyCode))
                || Self.navigationKeyCodes.contains(Int(event.keyCode)) else { return nil }
        let flags = event.modifierFlags
        var modifiers: Modifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(keyCode: event.keyCode, modifiers: modifiers)
    }

    var hasCommandOrControl: Bool { !modifiers.isDisjoint(with: [.command, .control]) }

    var isSupported: Bool { Self.supports(keyCode: keyCode) && modifiers.rawValue & ~UInt8(15) == 0 }

    private static func supports(keyCode: UInt16) -> Bool {
        keyCode <= 126 && !modifierKeyCodes.contains(Int(keyCode))
            && ![kVK_VolumeUp, kVK_VolumeDown, kVK_Mute].contains(Int(keyCode))
    }

    static let functionKeyCodes: [Int] = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let navigationKeyCodes: Set<Int> = [
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_ForwardDelete,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
    ]

    var carbonModifiers: UInt32 {
        var result = 0
        if modifiers.contains(.control) { result |= controlKey }
        if modifiers.contains(.option) { result |= optionKey }
        if modifiers.contains(.shift) { result |= shiftKey }
        if modifiers.contains(.command) { result |= cmdKey }
        return UInt32(result)
    }

    @MainActor var displayString: String { Self.symbols(modifiers) + KeyNames.name(for: keyCode) }

    /// For SwiftUI menu items; nil when the key has no menu key equivalent.
    @MainActor var keyboardShortcut: KeyboardShortcut? {
        guard let key = KeyNames.keyEquivalent(for: keyCode) else { return nil }
        var eventModifiers: SwiftUI.EventModifiers = []
        if modifiers.contains(.control) { eventModifiers.insert(.control) }
        if modifiers.contains(.option) { eventModifiers.insert(.option) }
        if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
        if modifiers.contains(.command) { eventModifiers.insert(.command) }
        return KeyboardShortcut(key, modifiers: eventModifiers)
    }

    static func symbols(_ modifiers: Modifiers) -> String {
        (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
    }

    static let modifierKeyCodes: Set<Int> = [
        kVK_Command, kVK_RightCommand, kVK_Shift, kVK_RightShift, kVK_Option, kVK_RightOption,
        kVK_Control, kVK_RightControl, kVK_CapsLock, kVK_Function,
    ]
}

/// Key names for display and menu key equivalents.
@MainActor
enum KeyNames {
    private static let special: [Int: (name: String, key: KeyEquivalent)] = [
        kVK_Return: ("↩", .return), kVK_Tab: ("⇥", .tab), kVK_Space: ("Space", .space),
        kVK_Delete: ("⌫", .delete), kVK_ForwardDelete: ("⌦", .deleteForward), kVK_Escape: ("⎋", .escape),
        kVK_LeftArrow: ("←", .leftArrow), kVK_RightArrow: ("→", .rightArrow),
        kVK_UpArrow: ("↑", .upArrow), kVK_DownArrow: ("↓", .downArrow),
        kVK_Home: ("↖", .home), kVK_End: ("↘", .end), kVK_PageUp: ("⇞", .pageUp), kVK_PageDown: ("⇟", .pageDown),
        kVK_ANSI_KeypadEnter: ("⌤", .return),
    ]

    private static let functionKeys = Shortcut.functionKeyCodes

    static func name(for keyCode: UInt16) -> String {
        let code = Int(keyCode)
        if let special = special[code] { return special.name }
        if let index = functionKeys.firstIndex(of: code) { return "F\(index + 1)" }
        return character(for: keyCode).map { String($0).uppercased() } ?? "Key \(keyCode)"
    }

    static func keyEquivalent(for keyCode: UInt16) -> KeyEquivalent? {
        let code = Int(keyCode)
        if let special = special[code] { return special.key }
        if let index = functionKeys.firstIndex(of: code),
           let scalar = Unicode.Scalar(NSF1FunctionKey + index) {
            return KeyEquivalent(Character(scalar))
        }
        return character(for: keyCode).map { KeyEquivalent(Character($0.lowercased())) }
    }

    /// The unmodified character on the current ASCII-capable layout, like menu key equivalents.
    static func character(for keyCode: UInt16) -> Character? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layout = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layout.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &deadKeyState, characters.count,
                                  &length, &characters)
        }
        guard status == noErr, length > 0,
              let text = String(utf16CodeUnits: characters, count: length).first,
              !text.isWhitespace else { return nil }
        return text
    }
}
