import SwiftUI

/// Tool styles are not settings: the editor keeps the last choice for each tool.
struct EditorSettingsPane: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Copy and save") {
                Toggle("Close editor after copying", isOn: $preferences.editor.closesAfterCopy)
                Toggle("Close editor after saving", isOn: $preferences.editor.closesAfterSave)
                Text("Option-click Copy to invert closing, or Save to choose a location.").secondaryNote()
            }
        }
    }
}
