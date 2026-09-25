import SwiftUI

struct EditorOptions: View {
    @Bindable var model: EditorWindowModel
    @State private var expanded = false
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                primaryOptions
                optionsButton
            }
            optionsButton
        }
    }

    private var optionsButton: some View {
        Button("Options") { expanded.toggle() }
            .disabled([.select, .crop].contains(model.styleTool))
            .popover(isPresented: $expanded) {
                Form {
                    if model.selectedAnnotations.count > 1 {
                        Text(model.hasMixedStyles ? "Mixed styles · \(model.selectedAnnotations.count) selected objects" : "Editing \(model.selectedAnnotations.count) selected objects").foregroundStyle(.secondary)
                    }
                    switch model.styleTool {
                    case .arrow:
                        LabeledContent("Color") { EditorColorWell(color: model.colorBinding(\.arrow.color), model: model).frame(width: 28, height: 24) }
                        StyleSlider(title: "Thickness", value: model.binding(\.arrow.width), range: 1...32, model: model)
                        Picker("Arrow", selection: model.binding(\.arrow.style)) {
                            ForEach(ArrowStyle.allCases, id: \.self) { style in
                                StyleSampleLabel(title: style.title, sample: EditorStyleSamples.arrows[style]).tag(style)
                            }
                        }.pickerStyle(.menu)
                    case .rectangle:
                        LabeledContent("Color") { EditorColorWell(color: model.colorBinding(\.rectangle.strokeColor), model: model).frame(width: 28, height: 24) }
                        StyleSlider(title: "Thickness", value: model.binding(\.rectangle.width), range: 1...32, model: model)
                        Toggle("Fill", isOn: Binding(get: { model.defaults.rectangle.fillColor != nil }, set: { enabled in
                            var values = model.defaults; values.rectangle.fillColor = enabled ? values.rectangle.strokeColor : nil; model.setDefaults(values)
                        }))
                        StyleSlider(title: "Corner radius", value: model.binding(\.rectangle.cornerRadius), range: 0...64, model: model)
                    case .ellipse:
                        LabeledContent("Color") { EditorColorWell(color: model.colorBinding(\.ellipse.strokeColor), model: model).frame(width: 28, height: 24) }
                        StyleSlider(title: "Thickness", value: model.binding(\.ellipse.width), range: 1...32, model: model)
                        Toggle("Fill", isOn: Binding(get: { model.defaults.ellipse.fillColor != nil }, set: { enabled in
                            var values = model.defaults; values.ellipse.fillColor = enabled ? values.ellipse.strokeColor : nil; model.setDefaults(values)
                        }))
                    case .line:
                        LabeledContent("Color") { EditorColorWell(color: model.colorBinding(\.line.color), model: model).frame(width: 28, height: 24) }
                        StyleSlider(title: "Thickness", value: model.binding(\.line.width), range: 1...32, model: model)
                    case .text:
                        LabeledContent("Color") { EditorColorWell(color: model.colorBinding(\.text.color), model: model).frame(width: 28, height: 24) }
                        StyleSlider(title: "Size", value: model.binding(\.text.size), range: 8...200, model: model)
                        Picker("Font", selection: model.binding(\.text.design)) {
                            Text("System").tag(TextDesign.system); Text("Monospaced").tag(TextDesign.monospaced)
                        }
                        Picker("Weight", selection: model.binding(\.text.weight)) {
                            Text("Regular").tag(TextWeight.regular); Text("Semibold").tag(TextWeight.semibold); Text("Bold").tag(TextWeight.bold)
                        }
                        Picker("Style", selection: model.binding(\.text.treatment)) {
                            ForEach(TextTreatment.allCases, id: \.self) { treatment in
                                StyleSampleLabel(title: treatment.title, sample: EditorStyleSamples.textTreatments[treatment]).tag(treatment)
                            }
                        }.pickerStyle(.menu)
                    case .redact:
                        redactStylePicker
                        if model.defaults.redact.style == .solid {
                            LabeledContent("Color") { EditorColorWell(color: model.colorBinding(\.redact.solidColor), model: model).frame(width: 28, height: 24) }
                            HStack {
                                Button("Dark") { var values = model.defaults; values.redact.solidColor = .black; model.setDefaults(values) }
                                Button("Light") { var values = model.defaults; values.redact.solidColor = .white; model.setDefaults(values) }
                            }
                        } else {
                            StyleSlider(title: "Strength", value: model.binding(\.redact.strength), range: 0...1, model: model)
                        }
                        Text("Solid replaces pixels. Pixelate and Blur obscure their appearance. Previously copied or saved images remain unchanged.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .spotlight:
                        Picker("Shape", selection: model.binding(\.spotlight.shape)) {
                            ForEach(SpotlightShape.allCases, id: \.self) { shape in
                                StyleSampleLabel(title: shape.title, sample: EditorStyleSamples.spotlightShapes[shape]).tag(shape)
                            }
                        }.pickerStyle(.menu)
                        StyleSlider(title: "Dim amount", value: model.binding(\.spotlight.dimPercent), range: 5...90, model: model)
                    case .counter:
                        LabeledContent("Color") { EditorColorWell(color: model.colorBinding(\.counter.color), model: model).frame(width: 28, height: 24) }
                        StyleSlider(title: "Size", value: model.binding(\.counter.size), range: 12...96, model: model)
                        TextField("Next / starting number", value: Binding(get: { model.canvas.nextCounter }, set: { model.canvas.nextCounter = max(1, $0); model.selectionVersion += 1 }), format: .number)
                        Button("Renumber") { model.canvas.renumber() }
                    case .select, .crop: EmptyView()
                    }
                    Button("Reset tool defaults") {
                        model.coordinator.preferences.resetToolDefaults(model.styleTool)
                    }
                }.formStyle(.columns).padding(16).frame(width: 320)
            }
    }

    @ViewBuilder private var primaryOptions: some View {
        switch model.styleTool {
        case .arrow: inlineColor(\.arrow.color); inlineSize("Thickness", \.arrow.width, 1...32)
        case .rectangle: inlineColor(\.rectangle.strokeColor); inlineSize("Thickness", \.rectangle.width, 1...32)
        case .ellipse: inlineColor(\.ellipse.strokeColor); inlineSize("Thickness", \.ellipse.width, 1...32)
        case .line: inlineColor(\.line.color); inlineSize("Thickness", \.line.width, 1...32)
        case .text: inlineColor(\.text.color); inlineSize("Size", \.text.size, 8...200)
        case .counter: inlineColor(\.counter.color); inlineSize("Size", \.counter.size, 12...96)
        case .redact: redactStylePicker.labelsHidden().frame(width: 110)
        case .spotlight: inlineSize("Dim", \.spotlight.dimPercent, 5...90)
        case .select, .crop: EmptyView()
        }
    }

    /// Each treatment previews on the same sample, so the choice is visible before drawing.
    private var redactStylePicker: some View {
        Picker("Style", selection: model.binding(\.redact.style)) {
            ForEach(RedactStyle.allCases, id: \.self) { style in
                StyleSampleLabel(title: style.title, sample: EditorStyleSamples.redaction[style]).tag(style)
            }
        }.pickerStyle(.menu)
    }

    private func inlineColor(_ key: WritableKeyPath<EditorToolDefaults, RGBAColor>) -> some View {
        EditorColorWell(color: model.colorBinding(key), model: model, label: model.hasMixedValues(key) ? "Mixed colors" : "Color")
            .frame(width: 28, height: 24)
    }

    private func inlineSize(_ title: String, _ key: WritableKeyPath<EditorToolDefaults, Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 4) {
            Text(model.hasMixedValues(key) ? "Mixed" : title).font(.caption).foregroundStyle(.secondary)
            Slider(value: model.binding(key), in: range, onEditingChanged: model.styleGesture)
                .accessibilityLabel(title).frame(width: 64)
        }.fixedSize()
    }
}

private struct StyleSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let model: EditorWindowModel
    var body: some View {
        Slider(value: $value, in: range, onEditingChanged: model.styleGesture) { Text(title) }
    }
}

private extension ArrowStyle {
    var title: String {
        switch self { case .standard: "Standard"; case .double: "Double-ended"; case .curved: "Curved" }
    }
}

private extension TextTreatment {
    var title: String {
        switch self { case .plain: "Plain"; case .outlined: "Outlined"; case .label: "Filled label" }
    }
}

private extension RedactStyle {
    var title: String {
        switch self { case .pixelate: "Pixelate"; case .blur: "Blur"; case .solid: "Solid" }
    }
}

private extension SpotlightShape {
    var title: String {
        switch self { case .rectangle: "Rectangle"; case .roundedRectangle: "Rounded rectangle"; case .ellipse: "Ellipse" }
    }
}
