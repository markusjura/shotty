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
    let preferences: AppPreferences
    let commands: CommandRegistry
    @State private var pane: SettingsPane? = .general

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(SidebarMaterial())
            .frame(width: 180)
            Divider()
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
        .background(CompactSettingsToolbar().frame(width: 0, height: 0))
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text((pane ?? .general).title).font(.headline)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .frame(width: 660)
        .frame(minHeight: 520)
    }
}

/// The translucent sidebar material of native split views, which this plain HStack lacks.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Settings scenes do not consistently apply the scene toolbar style on macOS.
private struct CompactSettingsToolbar: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarView { ToolbarView() }
    func updateNSView(_ view: ToolbarView, context: Context) {}

    final class ToolbarView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak window] in
                window?.toolbarStyle = .unifiedCompact
            }
        }
    }
}
