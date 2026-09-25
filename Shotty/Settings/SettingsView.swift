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

/// Flat native Settings: a sidebar plus one columns-style form per pane. Every control writes
/// straight to the typed stores, which persist immediately and reject invalid values.
struct SettingsView: View {
    let preferences: AppPreferences
    let commands: CommandRegistry
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            let selected = pane ?? .general
            // The columns form does not scroll or top-align by itself; long panes such as
            // Capture scroll, and short ones start at the top instead of floating mid-window.
            ScrollView {
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
                .formStyle(.columns)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .id(selected)
            .navigationTitle(selected.title)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}
