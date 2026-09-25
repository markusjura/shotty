import SwiftUI

/// Persistent new-object defaults. The editor's own toolbar edits the same values.
struct EditorSettingsPane: View {
    @Bindable var preferences: AppPreferences

    var body: some View {
        Form {
            Section("Copy and save") {
                Toggle("Close editor after copying", isOn: $preferences.editor.closesAfterCopy)
                Toggle("Close editor after saving", isOn: $preferences.editor.closesAfterSave)
                Text("Hold Option while clicking Copy or Save to do the opposite once.").font(.callout).foregroundStyle(.secondary)
            }
            toolSection(.arrow) {
                color("Color", \.arrow.color)
                width(\.arrow.width)
                Picker("Style", selection: $preferences.editor.tools.arrow.style) {
                    Text("Standard").tag(ArrowStyle.standard)
                    Text("Double-ended").tag(ArrowStyle.double)
                    Text("Curved").tag(ArrowStyle.curved)
                }
            }
            toolSection(.rectangle) {
                color("Outline", \.rectangle.strokeColor)
                width(\.rectangle.width)
                fill(\.rectangle.fillColor)
                Stepper(value: $preferences.editor.tools.rectangle.cornerRadius, in: 0...64, step: 2) {
                    LabeledContent("Corner radius", value: "\(Int(preferences.editor.tools.rectangle.cornerRadius)) px")
                }
            }
            toolSection(.ellipse) {
                color("Outline", \.ellipse.strokeColor)
                width(\.ellipse.width)
                fill(\.ellipse.fillColor)
            }
            toolSection(.line) {
                color("Color", \.line.color)
                width(\.line.width)
            }
            toolSection(.text) {
                color("Color", \.text.color)
                Stepper(value: $preferences.editor.tools.text.size, in: EditorToolDefaults.Text.sizeRange, step: 2) {
                    LabeledContent("Size", value: "\(Int(preferences.editor.tools.text.size)) px")
                }
                Picker("Weight", selection: $preferences.editor.tools.text.weight) {
                    Text("Regular").tag(TextWeight.regular)
                    Text("Semibold").tag(TextWeight.semibold)
                    Text("Bold").tag(TextWeight.bold)
                }
                Picker("Font", selection: $preferences.editor.tools.text.design) {
                    Text("System").tag(TextDesign.system)
                    Text("Monospaced").tag(TextDesign.monospaced)
                }
                Picker("Style", selection: $preferences.editor.tools.text.treatment) {
                    Text("Plain").tag(TextTreatment.plain)
                    Text("Outlined").tag(TextTreatment.outlined)
                    Text("Label").tag(TextTreatment.label)
                }
            }
            toolSection(.redact) {
                Picker("Style", selection: $preferences.editor.tools.redact.style) {
                    Text("Pixelate").tag(RedactStyle.pixelate)
                    Text("Blur").tag(RedactStyle.blur)
                    Text("Solid").tag(RedactStyle.solid)
                }
                if preferences.editor.tools.redact.style == .solid {
                    color("Color", \.redact.solidColor)
                } else {
                    Slider(value: $preferences.editor.tools.redact.strength, in: 0...1) { Text("Strength") }
                        .frame(maxWidth: 260)
                }
                Text("Pixelate and Blur obscure content visually. Solid replaces it completely.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            toolSection(.spotlight) {
                Picker("Shape", selection: $preferences.editor.tools.spotlight.shape) {
                    Text("Rectangle").tag(SpotlightShape.rectangle)
                    Text("Rounded rectangle").tag(SpotlightShape.roundedRectangle)
                    Text("Ellipse").tag(SpotlightShape.ellipse)
                }
                Slider(value: $preferences.editor.tools.spotlight.dimPercent, in: EditorToolDefaults.Spotlight.dimRange, step: 5) {
                    Text("Dim outside")
                }
                .frame(maxWidth: 260)
            }
            toolSection(.counter) {
                color("Color", \.counter.color)
                Stepper(value: $preferences.editor.tools.counter.size, in: EditorToolDefaults.Counter.sizeRange, step: 2) {
                    LabeledContent("Size", value: "\(Int(preferences.editor.tools.counter.size)) px")
                }
            }
        }
    }

    private func toolSection(_ tool: EditorTool, @ViewBuilder content: () -> some View) -> some View {
        Section(tool.settingsTitle) {
            content()
            Button("Reset \(tool.settingsTitle)") { preferences.resetToolDefaults(tool) }
                .disabled(preferences.editor.tools.isDefault(tool))
        }
    }

    private func color(_ title: String, _ keyPath: WritableKeyPath<EditorToolDefaults, RGBAColor>) -> some View {
        ColorPicker(title, selection: RGBAColor.binding({ preferences.editor.tools[keyPath: keyPath] },
                                                        { preferences.editor.tools[keyPath: keyPath] = $0 }),
                    supportsOpacity: false)
    }

    private func width(_ keyPath: WritableKeyPath<EditorToolDefaults, Double>) -> some View {
        Stepper(value: Binding { preferences.editor.tools[keyPath: keyPath] } set: { preferences.editor.tools[keyPath: keyPath] = $0 },
                in: EditorToolDefaults.widthRange) {
            LabeledContent("Line width", value: "\(Int(preferences.editor.tools[keyPath: keyPath])) px")
        }
    }

    @ViewBuilder
    private func fill(_ keyPath: WritableKeyPath<EditorToolDefaults, RGBAColor?>) -> some View {
        Toggle("Fill", isOn: Binding { preferences.editor.tools[keyPath: keyPath] != nil } set: { isOn in
            preferences.editor.tools[keyPath: keyPath] = isOn ? RGBAColor.annotationRed.withAlpha(0.25) : nil
        })
        if let fill = preferences.editor.tools[keyPath: keyPath] {
            ColorPicker("Fill color", selection: RGBAColor.binding({ fill }, { preferences.editor.tools[keyPath: keyPath] = $0 }),
                        supportsOpacity: true)
        }
    }
}

private extension EditorTool {
    var settingsTitle: String { CommandID.tool(self).title }
}

private extension RGBAColor {
    func withAlpha(_ alpha: Double) -> RGBAColor { RGBAColor(red: red, green: green, blue: blue, alpha: alpha) }
}
