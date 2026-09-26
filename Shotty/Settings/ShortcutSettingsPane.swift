import SwiftUI

struct ShortcutSettingsPane: View {
    let commands: CommandRegistry
    @State private var problems: [CommandID: ShortcutProblem] = [:]

    var body: some View {
        Form {
            ForEach(CommandGroup.allCases.filter(\.hasShortcuts), id: \.self) { group in
                Section(group.title) {
                    ForEach(group.commands, id: \.self, content: row)
                    // Capture commands have no defaults, so only groups with defaults can restore them.
                    if group.commands.contains(where: { $0.defaultShortcut != nil }) {
                        Button("Restore \(group.title) Defaults") { report(commands.restoreDefaults(in: group), for: group.commands) }
                    }
                }
            }
        }
    }

    /// The title and recorder share one line; a note goes below them, so it never moves the recorder.
    private func row(_ id: CommandID) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(id.title)
                Spacer()
                ShortcutRecorder(commands: commands, command: id) { problems[id] = $0 }
                    .fixedSize()
            }
            if let problem = problems[id] {
                Label(problem.message, systemImage: "exclamationmark.triangle").secondaryNote()
            } else if commands.registrationFailures.contains(id) {
                Label("Another app or macOS already uses this shortcut. Choose a different one.", systemImage: "exclamationmark.triangle")
                    .secondaryNote()
            } else if let advisory = commands.advisory(for: id) {
                Text(advisory).secondaryNote()
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func report(_ result: [CommandID: ShortcutProblem], for ids: [CommandID]) {
        for id in ids { problems[id] = result[id] }
    }
}
