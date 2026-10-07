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

    /// The title and recorder share one line, with a problem or else an advisory below them.
    private func row(_ id: CommandID) -> some View {
        let problem = problems[id]?.message ?? (commands.registrationFailures.contains(id)
            ? "Another app or macOS already uses this shortcut. Choose a different one." : nil)
        return HStack {
            Text(id.title)
            Spacer()
            ShortcutRecorder(commands: commands, command: id) { problems[id] = $0 }
                .fixedSize()
        }
        .settingsRowWarning(problem)
        .settingsRowNote(problem == nil ? commands.advisory(for: id) : nil)
    }

    private func report(_ result: [CommandID: ShortcutProblem], for ids: [CommandID]) {
        for id in ids { problems[id] = result[id] }
    }
}
