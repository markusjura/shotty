import AppKit
import SwiftUI

/// Where screenshots or recordings save. The previous folder stays selected unless the new one
/// proves writable.
struct SaveLocationSection: View {
    @Binding var destination: SaveDestination
    @State private var message: String?

    var body: some View {
        Section("Save location") {
            LabeledContent("Folder") {
                HStack(spacing: 8) {
                    Text(FileManager.default.displayName(atPath: destination.url.path))
                        .settingsValue()
                        .help(destination.url.path)
                    Button("Choose…", action: chooseFolder)
                }
            }
            .settingsRowWarning(message ?? SaveDestinationCheck.status(of: destination.url).message)
            if destination != .downloads {
                Button("Use Downloads") { apply(.downloads) }
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = destination.url
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let downloads = SaveDestination.downloads.url.standardizedFileURL
        apply(url.standardizedFileURL == downloads ? .downloads : .folder(url))
    }

    private func apply(_ new: SaveDestination) {
        message = SaveDestinationCheck.verifyWritable(new.url).message
        if message == nil { destination = new }
    }
}
