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
    /// Settings reopens on the pane the user last viewed. First launch sets it to Permissions.
    static let paneKey = "settingsPane"
    let preferences: AppPreferences
    let commands: CommandRegistry
    let updater: AppUpdater
    @AppStorage(SettingsView.paneKey) private var pane = SettingsPane.general
    @State private var history = SettingsHistory()

    var body: some View {
        // A native split view gives Finder's full-height sidebar under the traffic lights and a
        // toolbar that blends into the pane instead of a separate titlebar band. The sidebar is
        // translucent unless General turns translucent windows off.
        NavigationSplitView {
            // Ignore deselection so a pane is always shown. Rows draw the selection fill themselves.
            List(SettingsPane.allCases, selection: Binding<SettingsPane?> { pane } set: { if let new = $0 { open(new) } }) { item in
                SettingsSidebarRow(pane: item, isSelected: item == pane, showsUpdateDot: item == .general && updater.needsAttention)
                    .listRowInsets(EdgeInsets())
            }
            .navigationSplitViewColumnWidth(180)
            // Starts the first row 60 pt below the window top, where System Settings and Raycast
            // start their search field and Finder its first section header.
            .safeAreaPadding(.top, 8)
            .scrollContentBackground(.hidden)
            .background { sidebarFill.ignoresSafeArea() }
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralSettingsPane(preferences: preferences, updater: updater)
                case .capture: CaptureSettingsPane(preferences: preferences)
                case .thumbnails: ThumbnailSettingsPane(preferences: preferences)
                case .editor: EditorSettingsPane(preferences: preferences)
                case .shortcuts: ShortcutSettingsPane(commands: commands)
                case .permissions: PermissionSettingsPane(preferences: preferences)
                }
            }
            .formStyle(SettingsFormStyle())
            .id(pane)
            // The canvas also fills the toolbar above the pane.
            .background(SettingsColor.canvas.ignoresSafeArea())
            .settingsToolbarBand()
            .toolbar {
                // System Settings' back and forward pair. Like System Settings, it has no keyboard shortcuts.
                ToolbarItem(placement: .navigation) {
                    ControlGroup {
                        Button("Back", systemImage: "chevron.left") { pane = history.back(from: pane) ?? pane }
                            .disabled(!history.canGoBack)
                        Button("Forward", systemImage: "chevron.right") { pane = history.forward(from: pane) ?? pane }
                            .disabled(!history.canGoForward)
                    }
                    .controlGroupStyle(.navigation)
                }
            }
        }
        // The standard window title, left-aligned after the back and forward pair as in System Settings.
        .navigationTitle(pane.title)
        // AppKit's own toolbar background would use system colors; the band above draws the
        // toolbar states with the settings colors instead.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 660, minHeight: 520)
    }

    /// The sidebar's fill: a translucent material or the opaque gray.
    @ViewBuilder private var sidebarFill: some View {
        if preferences.general.usesTranslucentWindows { SidebarMaterial() } else { SettingsColor.opaqueSidebar }
    }

    private func open(_ next: SettingsPane) {
        history.visit(next, from: pane)
        pane = next
    }
}

/// Pane history behind the toolbar's back and forward buttons, like a browser's: visiting a new
/// pane records the current one and clears the forward history.
struct SettingsHistory {
    private var backStack: [SettingsPane] = []
    private var forwardStack: [SettingsPane] = []

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    mutating func visit(_ next: SettingsPane, from current: SettingsPane) {
        guard next != current else { return }
        backStack.append(current)
        forwardStack.removeAll()
    }

    /// The pane to show instead of `current`, or nil when there is no earlier pane.
    mutating func back(from current: SettingsPane) -> SettingsPane? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(current)
        return previous
    }

    /// The pane to show instead of `current`, or nil when there is no later pane.
    mutating func forward(from current: SettingsPane) -> SettingsPane? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(current)
        return next
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
