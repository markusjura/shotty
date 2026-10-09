import SwiftUI

/// Recording settings. Microphone and system audio are set in the Record bar, before each recording.
struct RecordingSettingsPane: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Form {
            outputSection
            SaveLocationSection(destination: $preferences.recording.destination)
            videoSection
        }
    }

    private var outputSection: some View {
        Section("After recording") {
            ForEach(RecordingOutput.allCases, id: \.self) { output in
                Toggle(output.title, isOn: membership(output))
                    .disabled(preferences.recording.outputs == [output])
            }
            if preferences.recording.outputs.count == 1 {
                Text("At least one option must be enabled.").settingsNote()
            }
        }
    }

    private var videoSection: some View {
        Section("Video") {
            Picker("Format", selection: $preferences.recording.format) {
                Text("MP4").tag(ClipFormat.mp4)
                Text("GIF").tag(ClipFormat.gif)
            }
            .pickerStyle(.segmented)
            Picker("Codec", selection: $preferences.recording.codec) {
                Text("H.264").tag(VideoCodecPreference.h264)
                Text("HEVC").tag(VideoCodecPreference.hevc)
            }
            .pickerStyle(.segmented)
            .settingsRowNote(preferences.recording.codec == .hevc
                             ? "HEVC files are about half the size, but some browsers and chat apps can't play them." : nil)
            Picker("Frame rate", selection: $preferences.recording.frameRate) {
                Text("30 fps").tag(FrameRatePreference.fps30)
                Text("60 fps").tag(FrameRatePreference.fps60)
            }
            .pickerStyle(.segmented)
            Picker("Resolution", selection: $preferences.recording.scale) {
                Text("Native pixels").tag(OutputScalePreference.native)
                Text("1× (points)").tag(OutputScalePreference.logical)
            }
            .buttonStyle(.borderless)
            Picker("Record Screen", selection: $preferences.recording.screenTarget) {
                Text("Current display").tag(ScreenTarget.pointerDisplay)
                Text("Main display").tag(ScreenTarget.mainDisplay)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Helpers

    private func membership(_ output: RecordingOutput) -> Binding<Bool> {
        Binding {
            preferences.recording.outputs.contains(output)
        } set: { isOn in
            if isOn { preferences.recording.outputs.insert(output) } else { preferences.recording.outputs.remove(output) }
        }
    }
}

private extension RecordingOutput {
    var title: String {
        switch self {
        case .showThumbnail: "Show thumbnail"
        case .copyClip: "Copy clip"
        case .saveClip: "Save clip"
        case .openEditor: "Open editor"
        }
    }
}
