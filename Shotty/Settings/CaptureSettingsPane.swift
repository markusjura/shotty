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
            if preferences.capture.outputs.count == 1 {
                Text("At least one option must be enabled.")
                    .settingsNote()
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
                .settingsRowNote("Holds the screen still while you select, so you can capture hover effects, animations, and moving content.")
            Toggle("Include window shadow", isOn: $preferences.capture.includesWindowShadow)
                .help("Hold Option while capturing a window to invert this once.")
            SelectionReadoutPicker(selection: $preferences.capture.readout)
        }
    }

    // MARK: Text

    private var textSection: some View {
        Section("Capture Text") {
            ForEach(TextOutput.allCases, id: \.self) { output in
                Toggle(output.title, isOn: membership(\.text.outputs, output))
                    .disabled(preferences.text.outputs == [output])
                    .settingsRowNote(output == .saveText && preferences.text.outputs.contains(.saveText)
                                     ? "Saved as UTF-8 in the save location above." : nil)
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
