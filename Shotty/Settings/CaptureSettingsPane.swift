import AppKit
import SwiftUI
import Vision

struct CaptureSettingsPane: View {
    @Bindable var preferences: AppPreferences
    @State private var destinationMessage: String?
    @State private var recognitionLanguages: [String] = []

    var body: some View {
        Form {
            outputSection
            destinationSection
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
                Text("Keep at least one action so every capture has somewhere to go.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var destinationSection: some View {
        Section("Save location") {
            LabeledContent("Folder") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(FileManager.default.displayName(atPath: preferences.capture.destination.url.path))
                        .help(preferences.capture.destination.url.path)
                    HStack {
                        Button("Choose…", action: chooseFolder)
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([preferences.capture.destination.url]) }
                        if preferences.capture.destination != .downloads {
                            Button("Use Downloads") { apply(SaveDestination.downloads) }
                        }
                    }
                    if let message = destinationMessage ?? SaveDestinationCheck.status(of: preferences.capture.destination.url).message {
                        Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .contain)
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("File name", text: $preferences.capture.filenameTemplate, prompt: Text(ExportService.defaultFilenameTemplate))
                Text("Example: \(ExportService.filenameStem(template: preferences.capture.filenameTemplate, date: .now, kind: .area)).\(preferences.capture.format == .png ? "png" : "jpg")")
                    .font(.callout).foregroundStyle(.secondary)
                Text("{date}, {time}, and {type} are replaced. Existing files get -2, -3, and so on.")
                    .font(.callout).foregroundStyle(.secondary)
                if preferences.capture.filenameTemplate != ExportService.defaultFilenameTemplate {
                    Button("Restore Default Name") { preferences.capture.filenameTemplate = ExportService.defaultFilenameTemplate }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var imageSection: some View {
        Section("Image") {
            Picker("Format", selection: $preferences.capture.format) {
                Text("PNG").tag(ImageFormatPreference.png)
                Text("JPEG").tag(ImageFormatPreference.jpeg)
            }
            .pickerStyle(.segmented)
            .fixedSize()
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
                Text("Keep display color profile").tag(ColorHandlingPreference.preserveSource)
                Text("Convert to sRGB").tag(ColorHandlingPreference.convertToSRGB)
            }
            Picker("Resolution", selection: $preferences.capture.outputScale) {
                Text("Native pixels").tag(OutputScalePreference.native)
                Text("1× (points)").tag(OutputScalePreference.logical)
            }
            Picker("Fullscreen captures", selection: $preferences.capture.fullscreenTarget) {
                Text("Display under the pointer").tag(FullscreenTarget.pointerDisplay)
                Text("Main display").tag(FullscreenTarget.mainDisplay)
                Text("Every display, one image each").tag(FullscreenTarget.allDisplays)
            }
        }
    }

    private var selectionSection: some View {
        Section("Selection") {
            Toggle("Freeze screen while selecting", isOn: $preferences.capture.freezesScreen)
            Toggle("Adjust area before capturing", isOn: $preferences.capture.adjustsBeforeCapture)
            Toggle("Show crosshair", isOn: $preferences.capture.showsCrosshair)
            Toggle("Show magnifier", isOn: $preferences.capture.showsMagnifier)
            Toggle("Include window shadow", isOn: $preferences.capture.includesWindowShadow)
                .help("Hold Option while capturing a window to invert this once.")
            Toggle("Include pointer", isOn: $preferences.capture.showsCursor)
        }
    }

    // MARK: Text

    private var textSection: some View {
        Section("Capture Text") {
            ForEach(TextOutput.allCases, id: \.self) { output in
                Toggle(output.title, isOn: membership(\.text.outputs, output))
                    .disabled(preferences.text.outputs == [output])
            }
            if preferences.text.outputs.contains(.saveText) {
                Text("Text files are saved as UTF-8 in the save location above.").font(.callout).foregroundStyle(.secondary)
            }
            Toggle("Keep line breaks", isOn: $preferences.text.preservesLineBreaks)
            Toggle("Detect languages automatically", isOn: $preferences.text.detectsLanguageAutomatically)
                .disabled(preferences.text.detectsLanguageAutomatically && preferences.text.languages.isEmpty)
            languageList
        }
    }

    private var languageList: some View {
        LabeledContent("Languages, in order") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(preferences.text.languages.enumerated()), id: \.element) { index, identifier in
                    HStack {
                        Text(Self.languageName(identifier))
                        Spacer()
                        Button("Move Up", systemImage: "arrow.up") { preferences.text.languages.swapAt(index, index - 1) }
                            .labelStyle(.iconOnly).disabled(index == 0)
                        Button("Remove", systemImage: "minus.circle") { preferences.text.languages.remove(at: index) }
                            .labelStyle(.iconOnly)
                            .disabled(preferences.text.languages.count == 1 && !preferences.text.detectsLanguageAutomatically)
                    }
                    .buttonStyle(.borderless)
                }
                Menu("Add Language") {
                    ForEach(recognitionLanguages.filter { !preferences.text.languages.contains($0) }, id: \.self) { identifier in
                        Button(Self.languageName(identifier)) { preferences.text.languages.append(identifier) }
                    }
                }
                .fixedSize()
                .disabled(recognitionLanguages.isEmpty)
                if preferences.text.detectsLanguageAutomatically {
                    Text(preferences.text.languages.isEmpty ? "Add a language to turn off automatic detection."
                                                            : "Used when automatic detection is turned off.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    // MARK: Scrolling

    private var scrollingSection: some View {
        Section("Scrolling Capture") {
            Picker("Auto Scroll pace", selection: $preferences.scrolling.pace) {
                Text("Slow").tag(ScrollPace.slow)
                Text("Adaptive").tag(ScrollPace.adaptive)
                Text("Fast").tag(ScrollPace.fast)
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Picker("Direction", selection: $preferences.scrolling.axis) {
                Text("Detect from first movement").tag(ScrollAxisPreference.automatic)
                Text("Vertical").tag(ScrollAxisPreference.vertical)
                Text("Horizontal").tag(ScrollAxisPreference.horizontal)
            }
            Stepper(value: $preferences.scrolling.maximumAxisPixels, in: ScrollingPreferences.axisPixelRange, step: 1_000) {
                Text("Maximum length: \(preferences.scrolling.maximumAxisPixels.formatted()) pixels")
            }
            Stepper(value: $preferences.scrolling.maximumDurationSeconds, in: ScrollingPreferences.durationRange, step: 10) {
                Text("Maximum duration: \(preferences.scrolling.maximumDurationSeconds) seconds")
            }
            Text("Auto Scroll starts only from its button. Scrolling by hand first keeps that capture manual.")
                .font(.callout).foregroundStyle(.secondary)
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

    /// The previous folder stays selected unless the new one proves writable.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = preferences.capture.destination.url
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let downloads = SaveDestination.downloads.url.standardizedFileURL
        apply(url.standardizedFileURL == downloads ? .downloads : .folder(url))
    }

    private func apply(_ destination: SaveDestination) {
        if let message = SaveDestinationCheck.verifyWritable(destination.url).message {
            destinationMessage = message
        } else {
            destinationMessage = nil
            preferences.capture.destination = destination
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
