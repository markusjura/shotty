import SwiftUI
import Vision

/// Screenshot settings, including Capture Text and scrolling capture.
struct CaptureSettingsPane: View {
    @Bindable var preferences: AppPreferences
    @State private var recognitionLanguages: [String] = []

    var body: some View {
        Form {
            outputSection
            SaveLocationSection(destination: $preferences.capture.destination)
            imageSection
            selectionSection
            textSection
            scrollingSection
        }
        .task { recognitionLanguages = Self.supportedRecognitionLanguages() }
    }

    // MARK: Screenshots

    private var outputSection: some View {
        Section("After capture") {
            ForEach(ScreenshotOutput.allCases, id: \.self) { output in
                Toggle(output.title, isOn: membership(\.capture.outputs, output))
                    .disabled(preferences.capture.outputs == [output])
            }
        }
    }

    private var imageSection: some View {
        Section("Image") {
            Picker("Format", selection: $preferences.capture.format) {
                Text("PNG").tag(ImageFormatPreference.png)
                Text("JPEG").tag(ImageFormatPreference.jpeg)
            }
            .pickerStyle(.segmented)
            if preferences.capture.format == .jpeg {
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $preferences.capture.jpegQuality, in: CapturePreferences.jpegQualityRange, step: 0.05)
                            .frame(maxWidth: 220)
                        Text(preferences.capture.jpegQuality, format: .percent.precision(.fractionLength(0)))
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .contain)
                }
                ColorPicker("Transparent areas", selection: RGBAColor.binding({ preferences.capture.jpegBackground },
                                                                              { preferences.capture.jpegBackground = $0 }),
                            supportsOpacity: false)
            }
            Picker("Color", selection: $preferences.capture.colorHandling) {
                Text("Display profile").tag(ColorHandlingPreference.preserveSource)
                Text("sRGB").tag(ColorHandlingPreference.convertToSRGB)
            }
            .buttonStyle(.borderless)
            Picker("Resolution", selection: $preferences.capture.outputScale) {
                Text("Native pixels").tag(OutputScalePreference.native)
                Text("1× (points)").tag(OutputScalePreference.logical)
            }
            .buttonStyle(.borderless)
            Picker("Capture Screen", selection: $preferences.capture.fullscreenTarget) {
                Text("Current display").tag(FullscreenTarget.pointerDisplay)
                Text("Main display").tag(FullscreenTarget.mainDisplay)
                Text("Each display").tag(FullscreenTarget.allDisplays)
            }
            .buttonStyle(.borderless)
        }
    }

    private var selectionSection: some View {
        Section("Selection") {
            Toggle("Freeze screen", isOn: $preferences.capture.freezesScreen)
                .settingsRowNote("Lets you capture hover effects and animations.")
            Toggle("Include window shadow", isOn: $preferences.capture.includesWindowShadow)
                .help("Hold Option while capturing a window to invert this once.")
            SelectionReadoutPicker(selection: $preferences.capture.readout)
            LabeledContent("Self-Timer interval") {
                SecondsField("Self-Timer interval", value: $preferences.capture.selfTimerSeconds, in: CapturePreferences.selfTimerRange)
            }
        }
    }

    // MARK: Text

    private var textSection: some View {
        Section("Capture Text") {
            ForEach(TextOutput.allCases, id: \.self) { output in
                Toggle(output.title, isOn: membership(\.text.outputs, output))
                    .disabled(preferences.text.outputs == [output])
            }
            Toggle("Keep line breaks", isOn: $preferences.text.preservesLineBreaks)
            Toggle("Detect languages automatically", isOn: $preferences.text.detectsLanguageAutomatically)
                .disabled(preferences.text.detectsLanguageAutomatically && preferences.text.languages.isEmpty)
            languageList
        }
    }

    /// Numbered rows show the recognition order; each row moves up or is removed in place.
    @ViewBuilder private var languageList: some View {
        LabeledContent("Languages") {
            Menu("Add Language") {
                ForEach(recognitionLanguages.filter { !preferences.text.languages.contains($0) }, id: \.self) { identifier in
                    Button(Self.languageName(identifier)) { preferences.text.languages.append(identifier) }
                }
            }
            .fixedSize()
            .buttonStyle(.borderless)
            .disabled(recognitionLanguages.isEmpty)
        }
        ForEach(Array(preferences.text.languages.enumerated()), id: \.element) { index, identifier in
            LabeledContent("\(index + 1). \(Self.languageName(identifier))") {
                HStack {
                    Button("Move Up", systemImage: "arrow.up") { preferences.text.languages.swapAt(index, index - 1) }
                        .disabled(index == 0)
                    Button("Remove", systemImage: "minus.circle") { preferences.text.languages.remove(at: index) }
                        .disabled(preferences.text.languages.count == 1 && !preferences.text.detectsLanguageAutomatically)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
        }
        if preferences.text.detectsLanguageAutomatically {
            Text(preferences.text.languages.isEmpty ? "Add a language to turn off automatic detection."
                                                    : "Used when automatic detection is turned off.")
                .settingsNote()
        }
    }

    // MARK: Scrolling

    private var scrollingSection: some View {
        Section("Scrolling Capture") {
            Picker("Auto Scroll pace", selection: $preferences.scrolling.pace) {
                Text("Slow").tag(ScrollPace.slow)
                Text("Normal").tag(ScrollPace.normal)
                Text("Fast").tag(ScrollPace.fast)
            }
            .pickerStyle(.segmented)
            Stepper(value: $preferences.scrolling.maximumAxisPixels, in: ScrollingPreferences.axisPixelRange, step: 1_000) {
                LabeledContent("Maximum length") { Text("\(preferences.scrolling.maximumAxisPixels.formatted()) pixels").settingsValue() }
            }
        }
    }

    // MARK: Helpers

    private func membership<Element: Hashable>(_ keyPath: ReferenceWritableKeyPath<AppPreferences, Set<Element>>,
                                               _ element: Element) -> Binding<Bool> {
        Binding {
            preferences[keyPath: keyPath].contains(element)
        } set: { isOn in
            if isOn { preferences[keyPath: keyPath].insert(element) } else { preferences[keyPath: keyPath].remove(element) }
        }
    }

    private static func supportedRecognitionLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        return (try? request.supportedRecognitionLanguages()) ?? []
    }

    private static func languageName(_ identifier: String) -> String {
        Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// Seconds with up to two decimals, typed in. Out of range values snap to the nearest limit.
private struct SecondsField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>) {
        self.title = title
        _value = value
        self.range = range
    }

    var body: some View {
        HStack(spacing: 3) {
            TextField(title, value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: SecondsFormat())
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 48)
            Text("seconds").settingsValue()
        }
    }
}

/// Seconds as text. It reads a comma or a period as the decimal separator, whatever the locale, so
/// both 2,5 and 2.5 work, and writes the value the way the user's locale does.
struct SecondsFormat: ParseableFormatStyle, ParseStrategy {
    var parseStrategy: SecondsFormat { self }

    func format(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) }

    func parse(_ value: String) throws -> Double {
        let text = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(text), seconds.isFinite else { throw CocoaError(.formatting) }
        // What the field shows afterwards is what is stored.
        return (seconds * 100).rounded() / 100
    }
}

private extension ScreenshotOutput {
    var title: String {
        switch self {
        case .showThumbnail: "Show thumbnail"
        case .copyImage: "Copy image"
        case .saveImage: "Save image"
        case .openEditor: "Open editor"
        }
    }
}

private extension TextOutput {
    var title: String {
        switch self {
        case .copyText: "Copy text"
        case .openReview: "Open Review automatically"
        case .saveText: "Save text file"
        }
    }
}
