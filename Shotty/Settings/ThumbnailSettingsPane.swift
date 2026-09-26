import AppKit
import SwiftUI

struct ThumbnailSettingsPane: View {
    @Bindable var preferences: AppPreferences
    @State private var screens: [(uuid: String, name: String)] = []

    var body: some View {
        Form {
            Section("Placement") {
                Picker("Position", selection: $preferences.thumbnails.placement) {
                    Text("Top left").tag(ThumbnailPlacement.topLeft)
                    Text("Left center").tag(ThumbnailPlacement.leftCenter)
                    Text("Bottom left").tag(ThumbnailPlacement.bottomLeft)
                    Text("Top right").tag(ThumbnailPlacement.topRight)
                    Text("Right center").tag(ThumbnailPlacement.rightCenter)
                    Text("Bottom right").tag(ThumbnailPlacement.bottomRight)
                }
                Picker("Size", selection: $preferences.thumbnails.size) {
                    Text("Small").tag(ThumbnailSize.small)
                    Text("Medium").tag(ThumbnailSize.medium)
                    Text("Large").tag(ThumbnailSize.large)
                }
                .pickerStyle(.segmented)
                Picker("Display", selection: $preferences.thumbnails.display) {
                    Text("Follow the pointer").tag(ThumbnailDisplayPolicy.followPointer)
                    Text("Main display").tag(ThumbnailDisplayPolicy.mainDisplay)
                    Divider()
                    ForEach(displayChoices, id: \.self) { choice in
                        if case .display(let uuid, let name) = choice {
                            Text(screens.contains { $0.uuid == uuid } ? name : "\(name) (disconnected)").tag(choice)
                        }
                    }
                }
                Toggle("Hide while capturing", isOn: $preferences.thumbnails.hidesDuringCapture)
                if case .display(let uuid, _) = preferences.thumbnails.display, !screens.contains(where: { $0.uuid == uuid }) {
                    Text("Uses the main display until this one reconnects.").secondaryNote()
                } else if preferences.thumbnails.display == .followPointer {
                    Text("The whole stack moves to the display under the pointer.").secondaryNote()
                }
            }
            Section("Closing") {
                Picker("Close automatically", selection: $preferences.thumbnails.autoClose) {
                    Text("Never").tag(ThumbnailAutoClose.never)
                    Text("Dismiss").tag(ThumbnailAutoClose.dismiss)
                    Text("Save, then dismiss").tag(ThumbnailAutoClose.saveThenDismiss)
                }
                if preferences.thumbnails.autoClose != .never {
                    Stepper(value: $preferences.thumbnails.autoCloseDelaySeconds, in: ThumbnailPreferences.autoCloseDelayRange) {
                        LabeledContent("After", value: "\(preferences.thumbnails.autoCloseDelaySeconds) seconds")
                    }
                    Text(preferences.thumbnails.autoClose == .dismiss
                         ? "Discards unsaved captures. Hovering, editing, or a failed save pauses it."
                         : "Saves first. A failed save keeps the thumbnail.")
                        .secondaryNote()
                }
                Toggle("Dismiss after saving", isOn: $preferences.thumbnails.dismissesAfterSave)
                Toggle("Dismiss after dragging out", isOn: $preferences.thumbnails.dismissesAfterDrag)
            }
        }
        .onAppear(perform: refreshScreens)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            refreshScreens()
        }
    }

    /// Connected displays plus a remembered one that is currently disconnected.
    private var displayChoices: [ThumbnailDisplayPolicy] {
        let stored = preferences.thumbnails.display
        var choices = screens.map { screen -> ThumbnailDisplayPolicy in
            // Keep the stored value's tag when only the display name changed.
            if case .display(let uuid, _) = stored, uuid == screen.uuid { return stored }
            return .display(uuid: screen.uuid, name: screen.name)
        }
        if case .display(let uuid, _) = stored, !screens.contains(where: { $0.uuid == uuid }) { choices.append(stored) }
        return choices
    }

    private func refreshScreens() {
        screens = NSScreen.screens.compactMap { screen in screen.displayUUID.map { ($0, screen.localizedName) } }
    }
}
