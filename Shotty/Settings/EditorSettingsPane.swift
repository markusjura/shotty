import SwiftUI

/// Tool styles and clip edits are not settings: the image editor keeps the last tool, color, stroke
/// width, and tool options, and trim, crop, speed, and size belong to each clip.
struct EditorSettingsPane: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Copy and save") {
                Toggle("Close editor after copying", isOn: $preferences.editor.closesAfterCopy)
                Toggle("Close editor after saving", isOn: $preferences.editor.closesAfterSave)
                Text("Option-click Copy to invert closing, or Save to choose a location.").settingsNote()
            }
            Section("Video") {
                Toggle("Play when the editor opens", isOn: $preferences.editor.playsOnOpen)
                Toggle("Loop playback", isOn: $preferences.editor.loopsPlayback)
                Picker("GIF frame rate", selection: $preferences.editor.gifFrameRate) {
                    Text("10 fps").tag(GIFFrameRate.fps10)
                    Text("15 fps").tag(GIFFrameRate.fps15)
                    Text("24 fps").tag(GIFFrameRate.fps24)
                }
                .pickerStyle(.segmented)
            }
        }
    }
}
