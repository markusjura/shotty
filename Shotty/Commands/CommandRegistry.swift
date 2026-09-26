import AppKit
import Carbon.HIToolbox
import Observation

/// Where a command's shortcut is active. Only `.global` commands register system-wide.
enum CommandScope: String, Sendable {
    case global, editorTool, editor
}

enum CommandGroup: String, CaseIterable, Sendable {
    case capture, thumbnails, editor

    var title: String {
        switch self {
        case .capture: "Capture"
        case .thumbnails: "Thumbnails"
        case .editor: "Editor"
        }
    }

    /// Thumbnail commands are menu items only; the other groups have shortcuts in Settings.
    var hasShortcuts: Bool { self != .thumbnails }

    var commands: [CommandID] { CommandID.allCases.filter { $0.group == self } }
}

/// Stable IDs; custom bindings persist by raw value. Standard Undo, Redo, Select All, Cut,
/// Copy, Paste, and Delete stay system Edit-menu actions and are not remappable here.
enum CommandID: String, CaseIterable, Codable, Sendable {
    case captureArea, captureWindow, captureFullscreen, captureScrolling, captureText
    case showThumbnails, hideThumbnails, openLatest, saveAll, dismissAll
    case toolSelect, toolArrow, toolRectangle, toolEllipse, toolLine, toolText, toolRedact, toolSpotlight, toolCounter, toolCrop
    case copyImage, save, saveAs, done, duplicate, zoomIn, zoomOut, zoomToFit, actualSize

    var title: String {
        switch self {
        case .captureArea: "Capture Area"
        case .captureWindow: "Capture Window"
        case .captureFullscreen: "Capture Fullscreen"
        case .captureScrolling: "Capture Scrolling"
        case .captureText: "Capture Text"
        case .showThumbnails: "Show Thumbnails"
        case .hideThumbnails: "Hide Thumbnails"
        case .openLatest: "Open Latest Capture"
        case .saveAll: "Save All"
        case .dismissAll: "Dismiss All"
        case .toolSelect: "Select"
        case .toolArrow: "Arrow"
        case .toolRectangle: "Rectangle"
        case .toolEllipse: "Ellipse"
        case .toolLine: "Line"
        case .toolText: "Text"
        case .toolRedact: "Redact"
        case .toolSpotlight: "Spotlight"
        case .toolCounter: "Counter"
        case .toolCrop: "Crop"
        case .copyImage: "Copy Image"
        case .save: "Save"
        case .saveAs: "Save As…"
        case .done: "Done"
        case .duplicate: "Duplicate"
        case .zoomIn: "Zoom In"
        case .zoomOut: "Zoom Out"
        case .zoomToFit: "Fit Canvas"
        case .actualSize: "Actual Size"
        }
    }

    var group: CommandGroup {
        switch self {
        case .captureArea, .captureWindow, .captureFullscreen, .captureScrolling, .captureText: .capture
        case .showThumbnails, .hideThumbnails, .openLatest, .saveAll, .dismissAll: .thumbnails
        case .toolSelect, .toolArrow, .toolRectangle, .toolEllipse, .toolLine, .toolText, .toolRedact,
             .toolSpotlight, .toolCounter, .toolCrop,
             .copyImage, .save, .saveAs, .done, .duplicate, .zoomIn, .zoomOut, .zoomToFit, .actualSize: .editor
        }
    }

    var scope: CommandScope {
        switch group {
        case .capture, .thumbnails: .global
        case .editor: tool == nil ? .editor : .editorTool
        }
    }

    var captureKind: CaptureKind? {
        switch self {
        case .captureArea: .area
        case .captureWindow: .window
        case .captureFullscreen: .fullscreen
        case .captureScrolling: .scrolling
        case .captureText: .text
        default: nil
        }
    }

    var tool: EditorTool? {
        switch self {
        case .toolSelect: .select
        case .toolArrow: .arrow
        case .toolRectangle: .rectangle
        case .toolEllipse: .ellipse
        case .toolLine: .line
        case .toolText: .text
        case .toolRedact: .redact
        case .toolSpotlight: .spotlight
        case .toolCounter: .counter
        case .toolCrop: .crop
        default: nil
        }
    }

    static func tool(_ tool: EditorTool) -> CommandID {
        allCases.first { $0.tool == tool }!
    }

    /// Fresh-install bindings. Capture commands start unassigned, so Shotty never claims keys that
    /// macOS or another screenshot app owns; thumbnail commands have no shortcuts at all.
    var defaultShortcut: Shortcut? {
        switch self {
        case .captureArea, .captureWindow, .captureFullscreen, .captureScrolling, .captureText: return nil
        case .showThumbnails, .hideThumbnails, .openLatest, .saveAll, .dismissAll: return nil
        case .toolSelect: return Shortcut(kVK_ANSI_V)
        case .toolArrow: return Shortcut(kVK_ANSI_A)
        case .toolRectangle: return Shortcut(kVK_ANSI_R)
        case .toolEllipse: return Shortcut(kVK_ANSI_E)
        case .toolLine: return Shortcut(kVK_ANSI_L)
        case .toolText: return Shortcut(kVK_ANSI_T)
        case .toolRedact: return Shortcut(kVK_ANSI_P)
        case .toolSpotlight: return Shortcut(kVK_ANSI_H)
        case .toolCounter: return Shortcut(kVK_ANSI_C)
        case .toolCrop: return Shortcut(kVK_ANSI_K)
        case .copyImage: return Shortcut(kVK_ANSI_C, [.shift, .command])
        case .save: return Shortcut(kVK_ANSI_S, .command)
        case .saveAs: return Shortcut(kVK_ANSI_S, [.shift, .command])
        case .done: return Shortcut(kVK_Return, .command)
        case .duplicate: return Shortcut(kVK_ANSI_D, .command)
        case .zoomIn: return Shortcut(kVK_ANSI_Equal, .command)
        case .zoomOut: return Shortcut(kVK_ANSI_Minus, .command)
        case .zoomToFit: return Shortcut(kVK_ANSI_1, .command)
        case .actualSize: return Shortcut(kVK_ANSI_0, .command)
        }
    }
}

enum ShortcutProblem: Error, Equatable, Sendable {
    case unsupported
    case conflict(CommandID)
    /// Global and editor commands need ⌘ or ⌃; macOS also restricts Option-only global hotkeys.
    case needsCommandOrControl
    /// Used by macOS or standard application commands.
    case reserved
    /// Return, Space, Tab, arrows, Escape, and Delete operate the editor itself.
    case reservedForEditing

    var message: String {
        switch self {
        case .unsupported: "Choose a regular key or function key. Fn combinations and media keys are not supported."
        case .conflict(let other): "Already used by \(other.title)."
        case .needsCommandOrControl: "Add ⌘ or ⌃. Shortcuts with only ⌥ or ⇧ are not allowed here."
        case .reserved: "macOS or standard app commands use this shortcut."
        case .reservedForEditing: "The editor uses this key for selection, text, or navigation."
        }
    }
}

/// The single source for command names, scopes, and bindings. Menus, Settings, tooltips,
/// the global hotkey adapter, and editor key routing all read from here.
@MainActor @Observable
final class CommandRegistry {
    static let storageKey = "commands.v1.shortcuts"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let systemShortcuts: () -> Set<Shortcut>
    private(set) var bindings: [CommandID: Shortcut]
    private(set) var unavailable: Set<CommandID> = []
    /// Global commands whose last registration failed, typically because another app owns the key.
    private(set) var registrationFailures: Set<CommandID> = []
    /// While set, global hotkeys are suspended so the recorder receives every combination.
    var recordingCommand: CommandID?
    /// The app supplies current capture/session availability; local editors can supply their context at routing time.
    var availability: ((CommandID) -> Bool)?
    private(set) var keyboardLayoutVersion = 0
    private var contextVersion = 0

    /// `systemShortcuts` returns the macOS screenshot shortcuts that are currently turned on.
    init(defaults: UserDefaults = .standard, systemShortcuts: @escaping () -> Set<Shortcut> = { MacScreenshotShortcuts.current }) {
        self.defaults = defaults
        self.systemShortcuts = systemShortcuts
        bindings = Self.load(from: defaults)
    }

    func shortcut(for id: CommandID) -> Shortcut? {
        _ = keyboardLayoutVersion
        return bindings[id]
    }

    var globalBindings: [CommandID: Shortcut] {
        _ = keyboardLayoutVersion
        return bindings.filter { $0.key.scope == .global && Self.ruleProblem($0.value, scope: .global) == nil }
    }

    /// Nil when `shortcut` may be assigned to `id`.
    func problem(assigning shortcut: Shortcut, to id: CommandID) -> ShortcutProblem? {
        if let rule = Self.ruleProblem(shortcut, scope: id.scope) { return rule }
        if let other = bindings.first(where: { $0.key != id && $0.value == shortcut })?.key { return .conflict(other) }
        return nil
    }

    /// Applies the binding, or leaves everything unchanged and returns why not. Nil clears.
    @discardableResult
    func assign(_ shortcut: Shortcut?, to id: CommandID) -> ShortcutProblem? {
        guard let shortcut else {
            guard bindings[id] != nil else { return nil }
            bindings[id] = nil
            save()
            return nil
        }
        if let problem = problem(assigning: shortcut, to: id) { return problem }
        guard bindings[id] != shortcut else { return nil }
        bindings[id] = shortcut
        save()
        return nil
    }

    /// Clears the group first so bindings swapped within it restore cleanly.
    @discardableResult
    func restoreDefaults(in group: CommandGroup) -> [CommandID: ShortcutProblem] {
        for id in group.commands { bindings[id] = nil }
        var problems: [CommandID: ShortcutProblem] = [:]
        for id in group.commands {
            guard let shortcut = id.defaultShortcut else { continue }
            if let problem = problem(assigning: shortcut, to: id) { problems[id] = problem } else { bindings[id] = shortcut }
        }
        save()
        return problems
    }

    /// Non-blocking guidance when a global shortcut is also one of macOS's screenshot shortcuts
    /// and that shortcut is still turned on in Keyboard Settings.
    func advisory(for id: CommandID) -> String? {
        guard id.scope == .global, let shortcut = bindings[id], systemShortcuts().contains(shortcut) else { return nil }
        return "macOS uses this for its own screenshots. Turn it off in Keyboard Settings to use it here."
    }

    func setAvailable(_ available: Bool, for id: CommandID) {
        if available { unavailable.remove(id) } else { unavailable.insert(id) }
    }

    func isAvailable(_ id: CommandID) -> Bool {
        _ = contextVersion
        return recordingCommand == nil && !unavailable.contains(id) && (availability?(id) ?? true)
    }

    /// AppKit window focus is not observable by SwiftUI menu validation.
    func contextDidChange() { contextVersion &+= 1 }

    /// For local key routing, such as the focused editor.
    func command(matching shortcut: Shortcut, in scopes: Set<CommandScope>, isTextEditing: Bool = false) -> CommandID? {
        bindings.first {
            scopes.contains($0.key.scope) && $0.value == shortcut && isAvailable($0.key)
                && (!isTextEditing || $0.key.scope != .editorTool)
                && Self.ruleProblem(shortcut, scope: $0.key.scope) == nil
        }?.key
    }

    func keyboardLayoutDidChange() { keyboardLayoutVersion &+= 1 }

    func reportRegistration(failures: Set<CommandID>) {
        if registrationFailures != failures { registrationFailures = failures }
    }

    // MARK: - Rules and persistence

    private static let editingKeys: Set<Int> = [
        kVK_Return, kVK_ANSI_KeypadEnter, kVK_Space, kVK_Tab, kVK_Escape, kVK_Delete, kVK_ForwardDelete,
        kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
        kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
    ]

    /// Positional key codes of standard app commands and macOS system shortcuts.
    private static let reserved: Set<Shortcut> = [
        Shortcut(kVK_ANSI_Q, .command), Shortcut(kVK_ANSI_W, .command), Shortcut(kVK_ANSI_H, .command),
        Shortcut(kVK_ANSI_H, [.option, .command]), Shortcut(kVK_ANSI_M, .command), Shortcut(kVK_ANSI_Comma, .command),
        Shortcut(kVK_ANSI_Z, .command), Shortcut(kVK_ANSI_Z, [.shift, .command]), Shortcut(kVK_ANSI_X, .command),
        Shortcut(kVK_ANSI_C, .command), Shortcut(kVK_ANSI_V, .command), Shortcut(kVK_ANSI_A, .command),
        Shortcut(kVK_Tab, .command), Shortcut(kVK_Tab, [.shift, .command]), Shortcut(kVK_ANSI_Grave, .command),
        Shortcut(kVK_Space, .command), Shortcut(kVK_Space, .control), Shortcut(kVK_Space, [.option, .command]),
        Shortcut(kVK_Escape, [.option, .command]), Shortcut(kVK_ANSI_Q, [.control, .command]),
        Shortcut(kVK_ANSI_F, [.control, .command]),
    ]

    private static func ruleProblem(_ shortcut: Shortcut, scope: CommandScope) -> ShortcutProblem? {
        guard shortcut.isSupported else { return .unsupported }
        if reserved.contains(shortcut) { return .reserved }
        // Standard application actions follow characters on the active layout, while our bindings
        // use physical key codes. For example, German ⌘Z lives at the ANSI Y position.
        if let character = KeyNames.character(for: shortcut.keyCode),
           isReservedCharacter(String(character).lowercased(), modifiers: shortcut.modifiers) { return .reserved }
        if scope != .global, editingKeys.contains(Int(shortcut.keyCode)) {
            let commandReturn = [kVK_Return, kVK_ANSI_KeypadEnter].contains(Int(shortcut.keyCode)) && shortcut.modifiers == .command
            if !commandReturn { return .reservedForEditing }
        }
        switch scope {
        case .global, .editor:
            return shortcut.hasCommandOrControl ? nil : .needsCommandOrControl
        case .editorTool:
            return !shortcut.hasCommandOrControl && editingKeys.contains(Int(shortcut.keyCode)) ? .reservedForEditing : nil
        }
    }

    static func isReservedCharacter(_ character: String, modifiers: Shortcut.Modifiers) -> Bool {
        if modifiers == .command { return ["q", "w", "h", "m", ",", "z", "x", "c", "v", "a", "`"].contains(character) }
        if modifiers == [.shift, .command] { return character == "z" }
        if modifiers == [.option, .command] { return character == "h" }
        if modifiers == [.control, .command] { return character == "q" || character == "f" }
        return false
    }

    /// Stores only differences from defaults, so improved defaults reach users who never customized.
    private func save() {
        var overrides: [String: Shortcut?] = [:]
        for id in CommandID.allCases where bindings[id] != id.defaultShortcut {
            overrides[id.rawValue] = .some(bindings[id])
        }
        guard let data = try? JSONEncoder().encode(overrides) else { return assertionFailure("Unencodable shortcuts") }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Overrides win over defaults on duplicates; invalid entries fall back to the default when it
    /// still fits, otherwise to unassigned.
    private static func load(from defaults: UserDefaults) -> [CommandID: Shortcut] {
        let stored = defaults.data(forKey: storageKey)
            .flatMap { try? JSONDecoder().decode([String: Shortcut?].self, from: $0) } ?? [:]
        let overrides = Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            CommandID(rawValue: key).flatMap { $0.group.hasShortcuts ? ($0, value) : nil }
        })
        var result: [CommandID: Shortcut] = [:]
        let customized = CommandID.allCases.filter { overrides.keys.contains($0) }
        for id in customized + CommandID.allCases.filter({ !overrides.keys.contains($0) }) {
            // An explicitly cleared command stays unassigned.
            let candidates: [Shortcut] = if let override = overrides[id] {
                override.map { [$0] + [id.defaultShortcut].compactMap { $0 } } ?? []
            } else {
                [id.defaultShortcut].compactMap { $0 }
            }
            if let shortcut = candidates.first(where: { ruleProblem($0, scope: id.scope) == nil && !result.values.contains($0) }) {
                result[id] = shortcut
            }
        }
        return result
    }
}

/// macOS's screenshot shortcuts (⇧⌘3, ⌃⇧⌘3, ⇧⌘4, ⌃⇧⌘4, and ⇧⌘5 by default) as set in Keyboard Settings.
enum MacScreenshotShortcuts {
    /// Symbolic hot key IDs with their factory bindings. An ID missing from the preferences has
    /// never been changed, so it is on with its factory binding.
    private static let factory: [String: Shortcut] = [
        "28": Shortcut(kVK_ANSI_3, [.shift, .command]), "29": Shortcut(kVK_ANSI_3, [.control, .shift, .command]),
        "30": Shortcut(kVK_ANSI_4, [.shift, .command]), "31": Shortcut(kVK_ANSI_4, [.control, .shift, .command]),
        "184": Shortcut(kVK_ANSI_5, [.shift, .command]),
    ]

    static var current: Set<Shortcut> {
        enabled(in: UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys"))
    }

    /// `hotKeys` is the `AppleSymbolicHotKeys` dictionary. Each entry stores `enabled` and
    /// `value.parameters` as [character, key code, NSEvent modifier flags].
    static func enabled(in hotKeys: [String: Any]?) -> Set<Shortcut> {
        Set(factory.compactMap { id, fallback in
            guard let entry = hotKeys?[id] as? [String: Any] else { return fallback }
            guard entry["enabled"] as? Bool ?? true else { return nil }
            guard let parameters = (entry["value"] as? [String: Any])?["parameters"] as? [Int], parameters.count == 3,
                  let keyCode = UInt16(exactly: parameters[1]) else { return fallback }
            return Shortcut(keyCode: keyCode, flags: NSEvent.ModifierFlags(rawValue: UInt(parameters[2])))
        })
    }
}
