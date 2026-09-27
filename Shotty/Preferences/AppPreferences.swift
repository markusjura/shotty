import Foundation
import Observation

/// Output preferences frozen when a capture is invoked. Later Settings changes never affect it.
struct CaptureOutputSnapshot: Equatable, Sendable {
    let capture: CapturePreferences
    let text: TextCapturePreferences
    let scrolling: ScrollingPreferences

    var saveDirectory: URL { capture.destination.url }

    var exportOptions: ExportOptions {
        ExportOptions(format: capture.format == .png ? .png : .jpeg,
                      scale: capture.outputScale == .native ? .native : .logical,
                      color: capture.colorHandling == .preserveSource ? .preserve : .sRGB,
                      jpegQuality: capture.jpegQuality,
                      jpegBackground: capture.jpegBackground)
    }
}

/// The single typed preference store. Each section persists immediately on assignment; an
/// invalid section value is ignored, keeping the previous value. Stored sections are merged
/// over current defaults when loaded, so added fields keep their defaults and unknown or
/// invalid stored data falls back to the default for that section only.
@MainActor @Observable
final class AppPreferences {
    private enum Key: String {
        case general, capture, text, scrolling, thumbnails, editor
        var storageKey: String { "preferences.v1.\(rawValue)" }
    }

    @ObservationIgnored private let defaults: UserDefaults
    private var storedGeneral: GeneralPreferences
    private var storedCapture: CapturePreferences
    private var storedText: TextCapturePreferences
    private var storedScrolling: ScrollingPreferences
    private var storedThumbnails: ThumbnailPreferences
    private var storedEditor: EditorPreferences

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        storedGeneral = Self.load(.general, from: defaults, default: GeneralPreferences(), isValid: \.isValid)
        storedCapture = Self.load(.capture, from: defaults, default: CapturePreferences(), isValid: \.isValid)
        storedText = Self.load(.text, from: defaults, default: TextCapturePreferences(), isValid: \.isValid)
        storedScrolling = Self.load(.scrolling, from: defaults, default: ScrollingPreferences(), isValid: \.isValid)
        storedThumbnails = Self.load(.thumbnails, from: defaults, default: ThumbnailPreferences(), isValid: \.isValid)
        storedEditor = Self.load(.editor, from: defaults, default: EditorPreferences(), isValid: \.isValid)
    }

    var general: GeneralPreferences {
        get { storedGeneral }
        set { guard newValue.isValid, newValue != storedGeneral else { return }; storedGeneral = newValue; save(newValue, .general) }
    }

    var capture: CapturePreferences {
        get { storedCapture }
        set { guard newValue.isValid, newValue != storedCapture else { return }; storedCapture = newValue; save(newValue, .capture) }
    }

    var text: TextCapturePreferences {
        get { storedText }
        set { guard newValue.isValid, newValue != storedText else { return }; storedText = newValue; save(newValue, .text) }
    }

    var scrolling: ScrollingPreferences {
        get { storedScrolling }
        set { guard newValue.isValid, newValue != storedScrolling else { return }; storedScrolling = newValue; save(newValue, .scrolling) }
    }

    var thumbnails: ThumbnailPreferences {
        get { storedThumbnails }
        set { guard newValue.isValid, newValue != storedThumbnails else { return }; storedThumbnails = newValue; save(newValue, .thumbnails) }
    }

    var editor: EditorPreferences {
        get { storedEditor }
        set { guard newValue.isValid, newValue != storedEditor else { return }; storedEditor = newValue; save(newValue, .editor) }
    }

    /// Freeze output choices at invocation. Pass the result through the whole capture pipeline.
    func snapshot() -> CaptureOutputSnapshot {
        CaptureOutputSnapshot(capture: storedCapture, text: storedText, scrolling: storedScrolling)
    }

    private func save<Value: Encodable>(_ value: Value, _ key: Key) {
        // Encoding plain Codable values cannot fail; a failure would be a programming error.
        guard let data = try? JSONEncoder().encode(value) else { return assertionFailure("Unencodable \(key)") }
        defaults.set(data, forKey: key.storageKey)
    }

    private static func load<Value: Codable>(_ key: Key, from defaults: UserDefaults, default base: Value,
                                             isValid: (Value) -> Bool) -> Value {
        guard let data = defaults.data(forKey: key.storageKey),
              let stored = try? JSONSerialization.jsonObject(with: data),
              let baseData = try? JSONEncoder().encode(base),
              let baseObject = try? JSONSerialization.jsonObject(with: baseData),
              let mergedData = try? JSONSerialization.data(withJSONObject: merge(stored, over: baseObject)),
              let value = try? JSONDecoder().decode(Value.self, from: mergedData),
              isValid(value) else { return base }
        return value
    }

    /// Stored keys win; nested objects merge recursively so new nested fields keep defaults.
    /// Enum cases with associated values encode as single-key objects; a different stored case
    /// replaces the default case instead of merging with it.
    private static func merge(_ stored: Any, over base: Any) -> Any {
        guard let stored = stored as? [String: Any], let base = base as? [String: Any] else { return stored }
        if stored.count == 1, base.count == 1, stored.keys.first != base.keys.first { return stored }
        return base.merging(stored) { baseValue, storedValue in merge(storedValue, over: baseValue) }
    }
}
