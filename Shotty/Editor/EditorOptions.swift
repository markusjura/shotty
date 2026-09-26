import AppKit
import SwiftUI

/// CleanShot-style option buttons for the current tool or selection. Each shows its value with a
/// chevron and opens a compact picker. A choice applies to the selected objects and becomes the
/// default for new ones, so the editor always opens with the last configuration.
struct EditorOptions: View {
    @Bindable var model: EditorWindowModel

    var body: some View {
        HStack(spacing: EditorBar.buttonSpacing) {
            switch model.styleTool {
            case .arrow:
                color(\.arrow.color)
                thickness(\.arrow.width)
                choice("Arrow style", \.arrow.style, samples: EditorStyleSamples.arrows)
            case .rectangle:
                color(\.rectangle.strokeColor)
                thickness(\.rectangle.width)
                fill(\.rectangle.fillColor, corners: true)
            case .ellipse:
                color(\.ellipse.strokeColor)
                thickness(\.ellipse.width)
                fill(\.ellipse.fillColor, corners: false)
            case .line:
                color(\.line.color)
                thickness(\.line.width)
            case .text:
                color(\.text.color)
                size("Text size", \.text.size, presets: [14, 18, 24, 32, 48, 64], symbol: "textformat.size")
                TextStyleOption(model: model)
            case .redact:
                choice("Redaction style", \.redact.style, samples: EditorStyleSamples.redaction)
                if model.defaults.redact.style == .solid { color(\.redact.solidColor) }
            case .spotlight:
                choice("Spotlight shape", \.spotlight.shape, samples: EditorStyleSamples.spotlightShapes)
                size("Dimming", \.spotlight.dimPercent, presets: [25, 45, 65, 80], unit: "%", symbol: "circle.lefthalf.filled")
            case .counter:
                color(\.counter.color)
                size("Counter size", \.counter.size, presets: [20, 28, 36, 48, 64], symbol: "textformat.size")
                CounterOption(model: model)
            case .select, .crop:
                EmptyView()
            }
        }
    }

    private func color(_ key: WritableKeyPath<EditorToolDefaults, RGBAColor>) -> some View {
        let mixed = model.hasMixedValues(key)
        let current = model.defaults[keyPath: key]
        return OptionButton(mixed ? "Color (mixed)" : "Color") {
            ColorDot(color: mixed ? nil : current)
        } content: { close in
            ColorPalette(selection: mixed ? nil : current, custom: model.colorBinding(key), model: model) {
                model.setColor($0, key); close()
            }
        }
    }

    private func thickness(_ key: WritableKeyPath<EditorToolDefaults, Double>) -> some View {
        let current = model.defaults[keyPath: key]
        let selection = model.hasMixedValues(key) ? nil : current
        return OptionButton("Thickness") {
            ThicknessGlyph(width: current)
        } content: { close in
            ChoiceList(values: EditorToolDefaults.widthPresets, selection: selection, choose: {
                model.binding(key).wrappedValue = $0; close()
            }) { width in
                Capsule().frame(width: 44, height: max(1, width / 2))
                Text("\(Int(width)) px").monospacedDigit()
            }
        }
    }

    private func size(_ title: String, _ key: WritableKeyPath<EditorToolDefaults, Double>, presets: [Double],
                      unit: String = " px", symbol: String) -> some View {
        let selection = model.hasMixedValues(key) ? nil : model.defaults[keyPath: key]
        return OptionButton(title) {
            Image(systemName: symbol)
        } content: { close in
            ChoiceList(values: presets, selection: selection, choose: { model.binding(key).wrappedValue = $0; close() }) {
                Text("\(Int($0))\(unit)").monospacedDigit()
            }
        }
    }

    private func choice<Value: StyleChoice>(_ title: String, _ key: WritableKeyPath<EditorToolDefaults, Value>,
                                            samples: [Value: NSImage]) -> some View {
        let current = model.defaults[keyPath: key]
        return OptionButton(title) {
            Image(systemName: current.symbol)
        } content: { close in
            ChoiceList(values: Value.allCases, selection: model.hasMixedValues(key) ? nil : current,
                       choose: { model.binding(key).wrappedValue = $0; close() }) { value in
                if let sample = samples[value] { Image(nsImage: sample).accessibilityHidden(true) }
                Text(value.title)
            }
        }
    }

    /// Outline or filled, plus rounded corners for rectangles. The fill follows the outline color.
    private func fill(_ key: WritableKeyPath<EditorToolDefaults, RGBAColor?>, corners: Bool) -> some View {
        let tool = model.styleTool
        let filled = model.defaults[keyPath: key] != nil
        let rounded = model.defaults.rectangle.cornerRadius > 0
        let shape = tool == .ellipse ? "circle" : rounded ? "app" : "square"
        return OptionButton("Shape style") {
            Image(systemName: filled ? "\(shape).fill" : shape)
        } content: { close in
            VStack(alignment: .leading, spacing: 0) {
                ChoiceList(values: [false, true], selection: model.hasMixedValues(key) ? nil : filled,
                           choose: { model.setFilled($0, for: tool); close() }) { isFilled in
                    Image(systemName: isFilled ? "\(shape).fill" : shape).frame(width: 18)
                    Text(isFilled ? "Filled" : "Outline")
                }
                if corners {
                    Divider().padding(.horizontal, 8)
                    Toggle("Rounded corners", isOn: Binding(get: { rounded }, set: {
                        model.binding(\.rectangle.cornerRadius).wrappedValue = $0 ? EditorToolDefaults.roundedCornerRadius : 0
                    }))
                    .toggleStyle(.checkbox).padding(.horizontal, 13).padding(.vertical, 8)
                }
            }
        }
    }
}

private struct TextStyleOption: View {
    @Bindable var model: EditorWindowModel

    var body: some View {
        OptionButton("Text style") {
            Image(systemName: "textformat")
        } content: { _ in
            VStack(alignment: .leading, spacing: 8) {
                ChoiceList(values: TextTreatment.allCases, selection: model.defaults.text.treatment,
                           choose: { model.binding(\.text.treatment).wrappedValue = $0 }) { treatment in
                    if let sample = EditorStyleSamples.textTreatments[treatment] { Image(nsImage: sample).accessibilityHidden(true) }
                    Text(treatment.title)
                }
                Divider()
                Group {
                    Picker("Font", selection: model.binding(\.text.design)) {
                        Text("System").tag(TextDesign.system)
                        Text("Monospaced").tag(TextDesign.monospaced)
                    }
                    Picker("Weight", selection: model.binding(\.text.weight)) {
                        Text("Regular").tag(TextWeight.regular)
                        Text("Semibold").tag(TextWeight.semibold)
                        Text("Bold").tag(TextWeight.bold)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 10)
            }
            .padding(.bottom, 10)
            .frame(width: 280)
        }
    }
}

private struct CounterOption: View {
    @Bindable var model: EditorWindowModel

    var body: some View {
        OptionButton("Numbering") {
            Image(systemName: "number")
        } content: { _ in
            VStack(alignment: .leading, spacing: 10) {
                // Canvas state is AppKit-owned; its callback invalidates this view.
                let _ = model.selectionVersion
                Stepper(value: Binding(get: { model.canvas.nextCounter },
                                       set: { model.canvas.nextCounter = max(1, $0); model.selectionVersion += 1 }), in: 1...999) {
                    Text("Next number: \(model.canvas.nextCounter)").monospacedDigit()
                }
                Button("Renumber in Order") { model.canvas.renumber() }
            }
            .padding(12)
        }
    }
}

/// A toolbar button that shows the current value with a chevron and opens `content` in a popover.
/// `content` receives an action that closes the popover.
private struct OptionButton<Icon: View, Content: View>: View {
    let title: String
    let icon: Icon
    let content: (_ close: @escaping () -> Void) -> Content
    @State private var isPresented = false

    init(_ title: String, @ViewBuilder icon: () -> Icon, @ViewBuilder content: @escaping (_ close: @escaping () -> Void) -> Content) {
        self.title = title
        self.icon = icon()
        self.content = content
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            HStack(spacing: 3) {
                icon.frame(width: 18, height: 18)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: EditorBar.buttonHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(OptionButtonStyle(isOpen: isPresented))
        .help(title)
        .accessibilityLabel(title)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) { content { isPresented = false } }
    }
}

/// A tinted capsule like CleanShot's toolbar options, darker while pressed or open.
private struct OptionButtonStyle: ButtonStyle {
    let isOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, isOpen: isOpen)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let isOpen: Bool
        var body: some View {
            configuration.label
                .background(EditorBar.buttonFill, in: Capsule())
                .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed || isOpen ? 0.15 : 0)))
        }
    }
}

/// A menu-like list: the hovered row is highlighted and the current value has a checkmark.
private struct ChoiceList<Value: Hashable, Label: View>: View {
    let values: [Value]
    let selection: Value?
    let choose: (Value) -> Void
    @ViewBuilder let label: (Value) -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(values, id: \.self) { value in
                ChoiceRow(isSelected: value == selection, action: { choose(value) }) { label(value) }
            }
        }
        .padding(5)
    }
}

private struct ChoiceRow<Label: View>: View {
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).opacity(isSelected ? 1 : 0)
                label()
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .foregroundStyle(isHovered ? Color.white : .primary)
            .background(isHovered ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Preset swatches, plus a well for any other color.
private struct ColorPalette: View {
    let selection: RGBAColor?
    @Binding var custom: Color
    let model: EditorWindowModel
    let choose: (RGBAColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(24), spacing: 6), count: 5), spacing: 6) {
                ForEach(RGBAColor.palette, id: \.name) { swatch in
                    Button { choose(swatch.color) } label: {
                        ColorDot(color: swatch.color, diameter: 20)
                            .padding(2)
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).opacity(swatch.color == selection ? 1 : 0))
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                    .accessibilityLabel(swatch.name)
                    .accessibilityAddTraits(swatch.color == selection ? .isSelected : [])
                }
            }
            Divider()
            HStack {
                Text("Custom")
                Spacer()
                EditorColorWell(color: $custom, model: model, label: "Custom color").frame(width: 28, height: 20)
            }
        }
        .padding(12)
        .frame(width: 164)
    }
}

/// A color swatch; nil draws a multicolor swatch for mixed selections.
private struct ColorDot: View {
    let color: RGBAColor?
    var diameter: CGFloat = 16

    var body: some View {
        Group {
            if let color {
                Circle().fill(Color(cgColor: color.cgColor))
            } else {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
            }
        }
        .overlay(Circle().strokeBorder(.primary.opacity(0.2)))
        .frame(width: diameter, height: diameter)
    }
}

/// A diagonal stroke whose weight follows the current thickness.
private struct ThicknessGlyph: View {
    let width: Double

    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 3, y: size.height - 3))
            path.addLine(to: CGPoint(x: size.width - 3, y: 3))
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: min(5, max(1, width / 3)), lineCap: .round))
        }
    }
}

/// Style enums offered as a choice list with rendered samples.
private protocol StyleChoice: Hashable, CaseIterable where AllCases == [Self] {
    var title: String { get }
    /// Shown on the toolbar button for the current value.
    var symbol: String { get }
}

extension ArrowStyle: StyleChoice {
    var title: String {
        switch self { case .standard: "Standard"; case .double: "Double-ended"; case .curved: "Curved" }
    }
    var symbol: String {
        switch self { case .standard: "arrow.up.right"; case .double: "arrow.up.left.and.arrow.down.right"; case .curved: "arrow.turn.up.right" }
    }
}

extension RedactStyle: StyleChoice {
    var title: String {
        switch self { case .pixelate: "Pixelate"; case .blur: "Blur"; case .solid: "Solid" }
    }
    var symbol: String {
        switch self { case .pixelate: "checkerboard.rectangle"; case .blur: "drop.halffull"; case .solid: "rectangle.fill" }
    }
}

extension SpotlightShape: StyleChoice {
    var title: String {
        switch self { case .rectangle: "Rectangle"; case .roundedRectangle: "Rounded rectangle"; case .ellipse: "Ellipse" }
    }
    var symbol: String {
        switch self { case .rectangle: "rectangle.dashed"; case .roundedRectangle: "app.dashed"; case .ellipse: "circle.dashed" }
    }
}

private extension TextTreatment {
    var title: String {
        switch self { case .plain: "Plain"; case .outlined: "Outlined"; case .label: "Filled label" }
    }
}

private extension RGBAColor {
    /// CleanShot-like presets; the first is the default annotation color.
    static let palette: [(name: String, color: RGBAColor)] = [
        ("Red", .annotationRed), ("Orange", RGBAColor(red: 1, green: 0.584, blue: 0)),
        ("Yellow", RGBAColor(red: 1, green: 0.8, blue: 0)), ("Green", RGBAColor(red: 0.204, green: 0.78, blue: 0.349)),
        ("Teal", RGBAColor(red: 0.188, green: 0.69, blue: 0.78)), ("Blue", RGBAColor(red: 0, green: 0.478, blue: 1)),
        ("Purple", RGBAColor(red: 0.686, green: 0.322, blue: 0.871)), ("Pink", RGBAColor(red: 1, green: 0.176, blue: 0.333)),
        ("White", .white), ("Black", .black),
    ]
}
