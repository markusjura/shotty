import AppKit
import SwiftUI

/// CleanShot-style option buttons for the current tool or selection. Each shows its value with a
/// chevron and opens a native menu below it. A choice applies to the selected objects and becomes
/// the default for new ones. Color and stroke width are shared by all tools.
struct EditorOptions: View {
    @Bindable var model: EditorWindowModel

    var body: some View {
        HStack(spacing: EditorBar.buttonSpacing) {
            switch model.styleTool {
            case .rectangle, .ellipse, .line:
                color(\.color)
                thickness()
            case .filledRectangle:
                color(\.color)
            case .arrow:
                color(\.color)
                thickness()
                choice("Arrow style", \.arrowStyle, samples: EditorStyleSamples.arrows, tinted: true)
            case .text:
                color(\.color)
                size("Text size", \.textSize, presets: EditorToolDefaults.textSizePresets, value: model.textSize) { size in
                    OptionMenu.textSample(pointSize: 5 + size / 4)
                } label: { Text("\(Int($0)) px").font(.system(size: 13, weight: .medium)).monospacedDigit() }
                textStyle()
            case .redact:
                choice("Redaction style", \.redact.style, samples: EditorStyleSamples.redaction, tinted: false)
                if model.defaults.redact.style == .solid { color(\.redact.solidColor) }
            case .spotlight:
                choice("Spotlight shape", \.spotlight.shape, samples: EditorStyleSamples.spotlightShapes, tinted: false)
                size("Dimming", \.spotlight.dimPercent, presets: [25, 45, 65, 80], unit: "%") { _ in nil } label: { _ in
                    Image(systemName: "circle.lefthalf.filled")
                }
            case .counter:
                color(\.color)
                // Labeled by digit size, the text size of the same stop, as in text mode.
                size("Counter size", \.textSize, presets: EditorToolDefaults.textSizePresets, value: model.textSize) { size in
                    let stop = EditorToolDefaults.textSizePresets.firstIndex(of: size) ?? 0
                    return OptionMenu.dotSample(diameter: EditorToolDefaults.counterSizePresets[stop] / 4)
                } label: { Text("\(Int($0)) px").font(.system(size: 13, weight: .medium)).monospacedDigit() }
                numbering()
            case .select, .crop:
                EmptyView()
            }
        }
    }

    /// CleanShot's palette as a column of swatches, with the color panel for anything else.
    private func color(_ key: WritableKeyPath<EditorToolDefaults, RGBAColor>) -> some View {
        let mixed = model.hasMixedValues(key)
        let current = model.defaults[keyPath: key]
        return OptionButton(mixed ? "Color (mixed)" : "Color") {
            ColorDot(color: mixed ? nil : current)
        } menu: {
            let menu = OptionMenu.make(showsState: false)
            let isPreset = RGBAColor.annotationPalette.contains { $0.color == current }
            for swatch in RGBAColor.annotationPalette {
                let selected = !mixed && swatch.color == current
                menu.addItem(OptionMenu.item(swatch.name, image: OptionMenu.swatch(swatch.color, selected: selected), hidesTitle: true) {
                    model.binding(key).wrappedValue = swatch.color
                })
            }
            menu.addItem(.separator())
            menu.addItem(OptionMenu.item("Custom Color…", image: OptionMenu.swatch(nil, selected: !mixed && !isPreset), hidesTitle: true) {
                EditorColorPanel.shared.show(current, begin: { model.styleGesture(true) },
                                             change: { model.binding(key).wrappedValue = $0 }, end: { model.styleGesture(false) })
            })
            return menu
        }
    }

    /// The six stroke widths, drawn as strokes of increasing weight.
    private func thickness() -> some View {
        let current = model.defaults.width
        let selection = model.hasMixedValues(\.width) ? nil : current
        return OptionButton("Thickness") {
            ThicknessGlyph(width: current)
        } menu: {
            let menu = OptionMenu.make(showsState: false)
            for (index, width) in EditorToolDefaults.widthPresets.enumerated() {
                menu.addItem(OptionMenu.item("\(Int(width)) px", image: OptionMenu.stroke(index: index, selected: width == selection),
                                             hidesTitle: true) {
                    model.binding(\.width).wrappedValue = width
                })
            }
            return menu
        }
    }

    /// Numeric presets. Rows with a sample dim unselected values; rows without one use a checkmark.
    private func size<Label: View>(_ title: String, _ key: WritableKeyPath<EditorToolDefaults, Double>, presets: [Double],
                                   value: Double? = nil, unit: String = " px", sample: @escaping (Double) -> NSImage?,
                                   @ViewBuilder label: (Double) -> Label) -> some View {
        let current = value ?? model.defaults[keyPath: key]
        let selection = model.hasMixedValues(key) ? nil : current
        return OptionButton(title) {
            label(current)
        } menu: {
            let menu = OptionMenu.make(showsState: sample(presets[0]) == nil)
            for value in presets {
                let image = sample(value).map { OptionMenu.dimmed($0, selected: value == selection) }
                menu.addItem(OptionMenu.item("\(Int(value))\(unit)", image: image, isOn: image == nil && value == selection) {
                    model.binding(key).wrappedValue = value
                })
            }
            return menu
        }
    }

    /// Style enums with rendered samples. `tinted` samples take the menu's text color, as CleanShot's arrows do.
    private func choice<Value: StyleChoice>(_ title: String, _ key: WritableKeyPath<EditorToolDefaults, Value>,
                                            samples: [Value: NSImage], tinted: Bool) -> some View {
        let current = model.defaults[keyPath: key]
        let selection = model.hasMixedValues(key) ? nil : current
        return OptionButton(title) {
            Image(systemName: current.symbol)
        } menu: {
            let menu = OptionMenu.make(showsState: false)
            for value in Value.allCases {
                let image = samples[value].map { OptionMenu.dimmed($0, selected: value == selection, template: tinted) }
                menu.addItem(OptionMenu.item(value.title, image: image) { model.binding(key).wrappedValue = value })
            }
            return menu
        }
    }

    private func textStyle() -> some View {
        let text = model.defaults.text
        return OptionButton("Text style") {
            Image(systemName: "textformat")
        } menu: {
            let menu = OptionMenu.make(showsState: true)
            for treatment in TextTreatment.allCases {
                let image = EditorStyleSamples.textTreatments[treatment].map {
                    OptionMenu.dimmed($0, selected: treatment == text.treatment, template: false)
                }
                menu.addItem(OptionMenu.item(treatment.title, image: image) { model.binding(\.textTreatment).wrappedValue = treatment })
            }
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Font"))
            for (design, title) in [(TextDesign.system, "System"), (.monospaced, "Monospaced")] {
                menu.addItem(OptionMenu.item(title, isOn: design == text.design) { model.binding(\.textDesign).wrappedValue = design })
            }
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Weight"))
            for (weight, title) in [(TextWeight.regular, "Regular"), (.semibold, "Semibold"), (.bold, "Bold")] {
                menu.addItem(OptionMenu.item(title, isOn: weight == text.weight) { model.binding(\.textWeight).wrappedValue = weight })
            }
            return menu
        }
    }

    private func numbering() -> some View {
        OptionButton("Numbering") {
            Image(systemName: "number")
        } menu: {
            let menu = OptionMenu.make(showsState: false)
            let row = NSMenuItem()
            row.view = NextCounterView(model: model)
            menu.addItem(row)
            menu.addItem(.separator())
            menu.addItem(OptionMenu.item("Renumber in Order") { model.canvas.renumber() })
            return menu
        }
    }
}

/// "Next number" as a native number field with a stepper, sized to its content and aligned
/// with the menu's item titles.
private final class NextCounterView: NSView {
    private let model: EditorWindowModel
    private let field = ClickToEditField()
    private let stepper = NSStepper()

    init(model: EditorWindowModel) {
        self.model = model
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: "Next number")
        label.font = .menuFont(ofSize: 0)
        let formatter = NumberFormatter()
        formatter.minimum = 1; formatter.maximum = 999; formatter.allowsFloats = false
        field.formatter = formatter
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.bezelStyle = .roundedBezel; field.alignment = .center
        field.integerValue = model.canvas.nextCounter
        field.target = self; field.action = #selector(typed)
        field.setAccessibilityLabel("Next number")
        stepper.minValue = 1; stepper.maxValue = 999; stepper.increment = 1
        stepper.integerValue = model.canvas.nextCounter
        stepper.target = self; stepper.action = #selector(stepped)
        stepper.setAccessibilityLabel("Next number")
        let controls = NSStackView(views: [field, stepper]); controls.spacing = 2
        let stack = NSStackView(views: [label, controls]); stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            field.widthAnchor.constraint(equalToConstant: 44),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32)
        ])
        setFrameSize(fittingSize)
    }
    required init?(coder: NSCoder) { nil }

    @objc private func stepped() { set(stepper.integerValue) }
    @objc private func typed() { set(field.integerValue) }

    private func set(_ number: Int) {
        let number = min(999, max(1, number))
        model.canvas.nextCounter = number
        field.integerValue = number; stepper.integerValue = number
        model.selectionVersion += 1  // Canvas state is AppKit-owned; this invalidates the options.
    }
}

/// A menu opens with its first text field focused. This one waits for a click, so the menu
/// opens without a focus ring and keyboard navigation still reaches the items.
private final class ClickToEditField: NSTextField {
    private var clicked = false
    override var acceptsFirstResponder: Bool { clicked }
    override func mouseDown(with event: NSEvent) {
        clicked = true; window?.makeFirstResponder(self); super.mouseDown(with: event)
    }
}

/// A 26 pt capsule that shows the current value with a chevron and opens `menu` below itself.
private struct OptionButton<Icon: View>: View {
    let title: String
    let icon: Icon
    let menu: () -> NSMenu
    @State private var anchor = MenuAnchor.Reference()
    @State private var isOpen = false

    init(_ title: String, @ViewBuilder icon: () -> Icon, menu: @escaping () -> NSMenu) {
        self.title = title
        self.icon = icon()
        self.menu = menu
    }

    var body: some View {
        Button {
            guard let view = anchor.view else { return }
            isOpen = true
            // Let the open state draw before the menu starts tracking.
            DispatchQueue.main.async {
                // Left-aligned below the button, clear of its shadow, like a pull-down menu.
                menu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 5), in: view)
                isOpen = false
            }
        } label: {
            HStack(spacing: 3) {
                icon.frame(minHeight: 18).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 9)
            .frame(height: EditorBar.buttonHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(OptionButtonStyle(isOpen: isOpen))
        .background(MenuAnchor(reference: anchor))
        .help(title)
        .accessibilityLabel(title)
    }
}

/// Exposes the button's view so the menu can open relative to it.
private struct MenuAnchor: NSViewRepresentable {
    @MainActor final class Reference { weak var view: NSView? }
    private final class FlippedView: NSView { override var isFlipped: Bool { true } }

    let reference: Reference
    func makeNSView(context: Context) -> NSView {
        let view = FlippedView()
        reference.view = view
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { reference.view = view }
}

/// A tinted capsule like CleanShot's toolbar options, darker while pressed or open.
private struct OptionButtonStyle: ButtonStyle {
    let isOpen: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(EditorBar.buttonFill, in: Capsule())
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed || isOpen ? 0.15 : 0)))
    }
}

/// Builds the option menus. Rows with images show the selected value at full strength and the rest
/// dimmed, as CleanShot does; plain rows use checkmarks.
@MainActor
private enum OptionMenu {
    static func make(showsState: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.showsStateColumn = showsState
        return menu
    }

    /// `hidesTitle` keeps the title for accessibility while the row shows only its image.
    static func item(_ title: String, image: NSImage? = nil, isOn: Bool = false, hidesTitle: Bool = false,
                     action: @escaping () -> Void) -> NSMenuItem {
        let item = ActionItem(title: hidesTitle ? "" : title, action: action)
        item.image = image
        // macOS 27 hides menu item images unless an item opts in.
        if #available(macOS 27, *), image != nil { item.preferredImageVisibility = .visible }
        item.state = isOn ? .on : .off
        if hidesTitle {
            item.setAccessibilityLabel(title)
            item.toolTip = title
        }
        return item
    }

    /// Unselected samples draw at reduced opacity. Template samples take the menu's text color.
    static func dimmed(_ image: NSImage, selected: Bool, template: Bool = true) -> NSImage {
        let result = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: selected ? 1 : 0.4)
            return true
        }
        result.isTemplate = template
        return result
    }

    /// A 24 pt swatch in a 30 pt cell; nil draws the color wheel. The selected one gets a ring.
    static func swatch(_ color: RGBAColor?, selected: Bool) -> NSImage {
        NSImage(size: NSSize(width: 30, height: 30), flipped: false) { rect in
            let dot = rect.insetBy(dx: 3, dy: 3)
            if let color {
                NSColor(cgColor: color.cgColor)?.setFill()
                NSBezierPath(ovalIn: dot).fill()
                NSColor.labelColor.withAlphaComponent(0.2).setStroke()
                NSBezierPath(ovalIn: dot.insetBy(dx: 0.25, dy: 0.25)).stroke()
            } else {
                let steps = 48
                for step in 0..<steps {
                    let wedge = NSBezierPath()
                    wedge.move(to: NSPoint(x: dot.midX, y: dot.midY))
                    wedge.appendArc(withCenter: NSPoint(x: dot.midX, y: dot.midY), radius: dot.width / 2,
                                    startAngle: CGFloat(step) * 360 / CGFloat(steps), endAngle: CGFloat(step + 1) * 360 / CGFloat(steps) + 0.5)
                    NSColor(hue: CGFloat(step) / CGFloat(steps), saturation: 0.75, brightness: 1, alpha: 1).setFill()
                    wedge.fill()
                }
                let center = NSGradient(colors: [.white, NSColor.white.withAlphaComponent(0)])
                center?.draw(in: NSBezierPath(ovalIn: dot), relativeCenterPosition: .zero)
            }
            if selected {
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                NSColor.labelColor.withAlphaComponent(0.45).setStroke()
                ring.stroke()
            }
            return true
        }
    }

    /// A diagonal stroke for the `index`th width preset. Menu strokes grow more gently than the presets.
    /// Glyph weights for the six width presets, from thinnest to thickest.
    static let strokeWeights: [CGFloat] = [1.5, 2, 3, 4, 5, 6.5]

    static func stroke(index: Int, selected: Bool) -> NSImage {
        let weights = strokeWeights
        let image = NSImage(size: NSSize(width: 32, height: 28), flipped: false) { rect in
            let path = NSBezierPath()
            path.move(to: NSPoint(x: rect.midX - 7, y: rect.midY - 7))
            path.line(to: NSPoint(x: rect.midX + 7, y: rect.midY + 7))
            path.lineWidth = weights[min(index, weights.count - 1)]
            path.lineCapStyle = .round
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        return dimmed(image, selected: selected)
    }

    /// "Aa" at a size that follows the text size preset, like CleanShot's font size menu.
    static func textSample(pointSize: CGFloat) -> NSImage {
        let text = NSAttributedString(string: "Aa", attributes: [.font: NSFont.systemFont(ofSize: pointSize, weight: .medium)])
        let size = text.size()
        return NSImage(size: NSSize(width: 34, height: max(18, ceil(size.height))), flipped: false) { rect in
            text.draw(at: NSPoint(x: 0, y: (rect.height - size.height) / 2))
            return true
        }
    }

    /// A filled circle that grows with the counter size.
    static func dotSample(diameter: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 26, height: max(18, diameter)), flipped: false) { rect in
            NSBezierPath(ovalIn: NSRect(x: (rect.width - diameter) / 2, y: (rect.height - diameter) / 2, width: diameter, height: diameter)).fill()
            return true
        }
    }

    private final class ActionItem: NSMenuItem {
        private let handler: () -> Void

        init(title: String, action: @escaping () -> Void) {
            handler = action
            super.init(title: title, action: #selector(run), keyEquivalent: "")
            target = self
        }
        required init(coder: NSCoder) { fatalError("Not used from nibs") }

        @objc private func run() { handler() }
    }
}

/// A color swatch; nil draws a multicolor swatch for mixed selections.
private struct ColorDot: View {
    let color: RGBAColor?

    var body: some View {
        Group {
            if let color {
                Circle().fill(Color(cgColor: color.cgColor))
            } else {
                Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .blue, .purple, .red], center: .center))
            }
        }
        .overlay(Circle().strokeBorder(.primary.opacity(0.2)))
        .frame(width: 16, height: 16)
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
            let weight = min(5, OptionMenu.strokeWeights[EditorToolDefaults.widthLevel(of: width)])
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: weight, lineCap: .round))
        }
        .frame(width: 18, height: 18)
    }
}

/// Style enums offered as a menu with rendered samples.
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
