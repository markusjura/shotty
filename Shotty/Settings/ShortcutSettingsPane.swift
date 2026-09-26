import SwiftUI

struct ShortcutSettingsPane: View {
    let commands: CommandRegistry
    @State private var problems: [CommandID: ShortcutProblem] = [:]

    var body: some View {
        Form {
            ForEach(CommandGroup.allCases.filter(\.hasShortcuts), id: \.self) { group in
                Section(group.title) {
                    ForEach(group.commands, id: \.self, content: row)
                    Button("Restore \(group.title) Defaults") { report(commands.restoreDefaults(in: group), for: group.commands) }
                }
            }
        }
    }

    private func row(_ id: CommandID) -> some View {
        LabeledContent(id.title) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    ShortcutRecorder(commands: commands, command: id) { problems[id] = $0 }
                        .fixedSize()
                    if commands.shortcut(for: id) != id.defaultShortcut {
                        Button("Restore Default", systemImage: "arrow.uturn.backward") { problems[id] = commands.restoreDefault(id) }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help(id.defaultShortcut.map { "Restore \($0.displayString)" } ?? "Restore to no shortcut")
                    }
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
    }

    private func report(_ result: [CommandID: ShortcutProblem], for ids: [CommandID]) {
        for id in ids { problems[id] = result[id] }
    }
}
