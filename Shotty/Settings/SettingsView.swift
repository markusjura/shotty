import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, capture, thumbnails, editor, shortcuts, permissions

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .capture: "Capture"
        case .thumbnails: "Thumbnails"
        case .editor: "Editor"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .capture: "camera.viewfinder"
        case .thumbnails: "rectangle.stack"
        case .editor: "pencil.and.outline"
        case .shortcuts: "command"
        case .permissions: "lock.shield"
        }
    }
}

/// Flat native Settings: a sidebar plus one grouped form per pane. Every control writes
/// straight to the typed stores, which persist immediately and reject invalid values.
struct SettingsView: View {
    static let windowID = "settings"
    let preferences: AppPreferences
    let commands: CommandRegistry
    @State private var pane: SettingsPane? = .general

    var body: some View {
        // A native split view gives Finder's full-height translucent sidebar under the traffic lights
        // and a toolbar that blends into the pane instead of a separate titlebar band.
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol)
            }
            .navigationSplitViewColumnWidth(180)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            let selected = pane ?? .general
            Group {
                switch selected {
                case .general: GeneralSettingsPane(preferences: preferences)
                case .capture: CaptureSettingsPane(preferences: preferences)
                case .thumbnails: ThumbnailSettingsPane(preferences: preferences)
                case .editor: EditorSettingsPane(preferences: preferences)
                case .shortcuts: ShortcutSettingsPane(commands: commands)
                case .permissions: PermissionSettingsPane(preferences: preferences)
                }
            }
            .formStyle(.grouped)
            .id(selected)
        }
        .navigationTitle((pane ?? .general).title)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                // Finder's toolbar title: 15 pt semibold.
                Text((pane ?? .general).title).font(.system(size: 15, weight: .semibold))
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .frame(minWidth: 660, minHeight: 520)
    }
}

/// Opens Settings, or brings it forward, from the app menu and the menu bar item.
struct SettingsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            NSApp.activate()
            openWindow(id: SettingsView.windowID)
        }
        .keyboardShortcut(",")
    }
}
