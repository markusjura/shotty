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

/// System Settings destinations used by the Settings panes.
enum SystemSettingsLink {
    static let screenRecording = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let microphone = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
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

/// The pointer readout setting, shared by the Screenshots and Recording panes.
struct SelectionReadoutPicker: View {
    @Binding var selection: SelectionReadout

    var body: some View {
        Picker("Coordinates", selection: $selection) {
            Text("Position and size").tag(SelectionReadout.positionAndSize)
            Text("Position only").tag(SelectionReadout.position)
            Text("Size only").tag(SelectionReadout.size)
            Text("Off").tag(SelectionReadout.off)
        }
        .buttonStyle(.borderless)
    }
}
