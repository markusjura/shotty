import AppKit
import SwiftUI

extension AppearancePreference {
    /// Nil follows the system appearance.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

extension GeneralPreferences {
    var activationPolicy: NSApplication.ActivationPolicy { showsDockIcon ? .regular : .accessory }
}

extension NSScreen {
    /// Stable across reconnection and rearrangement; matches `ThumbnailDisplayPolicy.display(uuid:)`.
    var displayUUID: String? {
        guard let displayID, let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

/// System Settings destinations used by the Settings panes.
enum SystemSettingsLink {
    static let screenRecording = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let keyboardShortcuts = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
    static let privacy = URL(string: "x-apple.systempreferences:com.apple.preference.security")!

    /// Falls back to Privacy & Security if a deep link stops resolving.
    static func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) { NSWorkspace.shared.open(privacy) }
    }
}

extension RGBAColor {
    /// Bridges a persisted color into a SwiftUI `ColorPicker`.
    @MainActor
    static func binding(_ get: @escaping @MainActor () -> RGBAColor,
                        _ set: @escaping @MainActor (RGBAColor) -> Void) -> Binding<CGColor> {
        Binding { get().cgColor } set: { if let color = RGBAColor($0) { set(color) } }
    }
}
