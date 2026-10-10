import CoreGraphics
import Foundation

// Typed, persisted preference sections. Each section is one Codable value stored by
// AppPreferences; `isValid` rejects writes that would leave the app unusable.

enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

struct GeneralPreferences: Codable, Equatable, Sendable {
    var appearance = AppearancePreference.system
    /// Off gives the Settings sidebar and the editor bars opaque fills instead of letting what's
    /// behind the window show through.
    var usesTranslucentWindows = true
    var showsMenuBarIcon = true
    var showsDockIcon = false
    var playsSounds = false

    /// Both icons may be hidden; reopening Shotty from Finder or Spotlight shows Settings.
    var isValid: Bool { true }
}

/// An sRGB color with components in 0...1, independent of the app appearance.
struct RGBAColor: Codable, Equatable, Sendable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha = 1.0

    static let white = RGBAColor(red: 1, green: 1, blue: 1)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)
    static let annotationRed = RGBAColor(red: 0.976, green: 0.204, blue: 0.259)
    static let annotationBlue = RGBAColor(red: 0, green: 0.48, blue: 1)

    /// The annotation colors, in menu order.
    static let annotationPalette: [(name: String, color: RGBAColor)] = [
        ("Black", .black), ("Red", .annotationRed), ("Orange", RGBAColor(red: 1, green: 0.549, blue: 0)),
        ("Yellow", RGBAColor(red: 1, green: 0.882, blue: 0)), ("Green", RGBAColor(red: 0.25, green: 0.84, blue: 0.32)),
        ("Teal", RGBAColor(red: 0.18, green: 0.81, blue: 0.76)), ("Blue", .annotationBlue),
        ("Purple", RGBAColor(red: 0.54, green: 0.32, blue: 1)), ("Pink", RGBAColor(red: 1, green: 0.18, blue: 0.42)),
        ("White", .white),
    ]

    var isValid: Bool { [red, green, blue, alpha].allSatisfy { (0...1).contains($0) } }

    var cgColor: CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: [red, green, blue, alpha])!
    }

    /// Converts any color to sRGB; nil when the color cannot be represented.
    init?(_ color: CGColor) {
        guard let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 4 else { return nil }
        self.init(red: min(max(components[0], 0), 1), green: min(max(components[1], 0), 1),
                  blue: min(max(components[2], 0), 1), alpha: min(max(components[3], 0), 1))
    }

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

// MARK: - Capture

enum ScreenshotOutput: String, Codable, CaseIterable, Sendable {
    case showThumbnail, copyImage, saveImage, openEditor
}

enum SaveDestination: Codable, Equatable, Sendable {
    case downloads
    case folder(URL)

    var url: URL {
        switch self {
        case .downloads: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .folder(let url): url
        }
    }
}

enum ImageFormatPreference: String, Codable, CaseIterable, Sendable { case png, jpeg }
enum ColorHandlingPreference: String, Codable, CaseIterable, Sendable { case preserveSource, convertToSRGB }
enum OutputScalePreference: String, Codable, CaseIterable, Sendable { case native, logical }
enum FullscreenTarget: String, Codable, CaseIterable, Sendable { case pointerDisplay, mainDisplay, allDisplays }

/// What the readout beside the pointer shows while drawing a region: the pointer's position before
/// the region exists, its size while dragging, both, or neither. Errors always show.
enum SelectionReadout: String, Codable, CaseIterable, Sendable {
    case positionAndSize, position, size, off

    var showsPosition: Bool { self == .positionAndSize || self == .position }
    var showsSize: Bool { self == .positionAndSize || self == .size }
}

struct CapturePreferences: Codable, Equatable, Sendable {
    static let jpegQualityRange = 0.5...1.0

    var outputs: Set<ScreenshotOutput> = [.showThumbnail]
    var destination = SaveDestination.downloads
    var format = ImageFormatPreference.png
    var jpegQuality = 0.9
    /// JPEG has no alpha; transparent pixels are composited onto this color.
    var jpegBackground = RGBAColor.white
    var colorHandling = ColorHandlingPreference.preserveSource
    var outputScale = OutputScalePreference.native
    var fullscreenTarget = FullscreenTarget.pointerDisplay
    var freezesScreen = true
    var includesWindowShadow = true
    var readout = SelectionReadout.positionAndSize

    var isValid: Bool {
        !outputs.isEmpty && Self.jpegQualityRange.contains(jpegQuality) && jpegBackground.isValid
    }
}

enum TextOutput: String, Codable, CaseIterable, Sendable {
    case copyText, openReview, saveText
}

struct TextCapturePreferences: Codable, Equatable, Sendable {
    var outputs: Set<TextOutput> = [.copyText]
    var preservesLineBreaks = true
    var detectsLanguageAutomatically = true
    /// Ordered Vision recognition language identifiers, used when automatic detection is off.
    var languages: [String] = []

    var isValid: Bool { !outputs.isEmpty && (detectsLanguageAutomatically || !languages.isEmpty) }
}

enum ScrollPace: String, Codable, CaseIterable, Sendable {
    case slow, normal, fast

    /// Auto Scroll speed in viewports per second along the scrolling axis.
    var viewportsPerSecond: Double {
        switch self {
        case .slow: 0.6
        case .normal: 1.2
        case .fast: 2
        }
    }
}

struct ScrollingPreferences: Codable, Equatable, Sendable {
    static let axisPixelRange = 5_000...30_000

    var pace = ScrollPace.normal
    var maximumAxisPixels = 30_000

    var isValid: Bool { Self.axisPixelRange.contains(maximumAxisPixels) }

    var limits: ScrollStitcher.Limits { ScrollStitcher.Limits(maximumExtent: maximumAxisPixels) }
}

// MARK: - Recording

enum RecordingOutput: String, Codable, CaseIterable, Sendable {
    case showThumbnail, copyClip, saveClip, openEditor
}

/// The file a clip becomes when it is copied, saved, or dragged.
enum ClipFormat: String, Codable, CaseIterable, Sendable {
    case mp4, gif

    var fileExtension: String { rawValue }
    var title: String { self == .mp4 ? "MP4" : "GIF" }
}

enum VideoCodecPreference: String, Codable, CaseIterable, Sendable { case h264, hevc }
enum ScreenTarget: String, Codable, CaseIterable, Sendable { case pointerDisplay, mainDisplay }

enum FrameRatePreference: Int, Codable, CaseIterable, Sendable {
    case fps30 = 30, fps60 = 60
}

struct RecordingPreferences: Codable, Equatable, Sendable {
    var outputs: Set<RecordingOutput> = [.showThumbnail]
    var destination = SaveDestination.downloads
    /// The format new clips copy and save as. The video editor can change it per clip.
    var format = ClipFormat.mp4
    var codec = VideoCodecPreference.h264
    var frameRate = FrameRatePreference.fps30
    var scale = OutputScalePreference.native
    var screenTarget = ScreenTarget.pointerDisplay
    var readout = SelectionReadout.positionAndSize
    /// Set from the Record bar. The choice of the last recording carries over to the next one.
    var recordsSystemAudio = false
    var recordsMicrophone = false
    /// The input picked last, nil until one is picked, which means the system default. It is kept
    /// while disconnected, so the input is used again once it returns.
    var microphoneID: String?

    var isValid: Bool { !outputs.isEmpty }
}

// MARK: - Thumbnails

enum ThumbnailPlacement: String, Codable, CaseIterable, Sendable {
    case topLeft, leftCenter, bottomLeft, topRight, rightCenter, bottomRight
}

enum ThumbnailSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    var width: CGFloat {
        switch self {
        case .small: 180
        case .medium: 220
        case .large: 280
        }
    }
}

enum ThumbnailDisplayPolicy: Codable, Hashable, Sendable {
    /// Moves the whole stack to the display under the pointer.
    case followPointer
    case mainDisplay
    /// A specific display by its stable CoreGraphics UUID. The name is shown while it is disconnected;
    /// the stack falls back to the main display until it reconnects.
    case display(uuid: String, name: String)
}

enum ThumbnailAutoClose: String, Codable, CaseIterable, Sendable {
    case never, dismiss, saveThenDismiss
}

struct ThumbnailPreferences: Codable, Equatable, Sendable {
    static let autoCloseDelayRange = 3...60

    var placement = ThumbnailPlacement.bottomLeft
    var size = ThumbnailSize.medium
    var display = ThumbnailDisplayPolicy.followPointer
    var autoClose = ThumbnailAutoClose.never
    var autoCloseDelaySeconds = 10
    var dismissesAfterSave = true
    var dismissesAfterDrag = true
    /// Dismisses a thumbnail once its copied image or clip is pasted into another app.
    var dismissesAfterPaste = false
    /// Hides the stack from the start of a capture until its pixels are taken, so thumbnails
    /// never appear in screenshots. Off by default: the stack stays visible. Recordings always
    /// leave Shotty's windows out.
    var hidesDuringCapture = false

    var isValid: Bool { Self.autoCloseDelayRange.contains(autoCloseDelaySeconds) }
}

// MARK: - Editor

/// Declared in toolbar order.
enum EditorTool: String, Codable, CaseIterable, Sendable {
    case select, rectangle, filledRectangle, ellipse, line, arrow, text, redact, spotlight, counter, crop

    /// Tools that create objects.
    var isDrawing: Bool { self != .select && self != .crop }
}

enum ArrowStyle: String, Codable, CaseIterable, Sendable { case standard, double, curved }
enum TextWeight: String, Codable, CaseIterable, Sendable { case regular, semibold, bold }
enum TextDesign: String, Codable, CaseIterable, Sendable { case system, monospaced }
enum TextTreatment: String, Codable, CaseIterable, Sendable { case plain, outlined, label }
enum RedactStyle: String, Codable, CaseIterable, Sendable { case pixelate, blur, solid }
enum SpotlightShape: String, Codable, CaseIterable, Sendable { case rectangle, roundedRectangle, ellipse }

/// New-object defaults. One color and one stroke width serve every tool; the
/// per-tool style properties combine them with the options that belong to that tool alone.
/// Widths and sizes are image pixels, independent of zoom.
struct EditorToolDefaults: Codable, Equatable, Sendable {
    static let widthRange = 1.0...64.0
    /// Six stroke widths (2, 3, 4, 5, 7, and 10 pt) in Retina pixels, finest where widths are
    /// used most.
    static let widthPresets: [Double] = [4, 6, 8, 10, 14, 20]

    /// Text sizes paired with the width presets: one stop sizes every tool. A counter's digits
    /// use its stop's text size, in a circle `counterScale` times as wide, so two digits fit.
    static let textSizePresets: [Double] = [28, 32, 36, 40, 48, 64]
    static let counterScale = 1.6
    static let counterSizePresets: [Double] = textSizePresets.map { $0 * counterScale }

    /// The digit size of a counter `diameter` wide, the inverse of `counterSizePresets`.
    static func counterTextSize(forDiameter diameter: Double) -> Double { diameter / counterScale }

    /// The preset nearest to `width`, so glyphs can show any stored width as one of six weights.
    static func widthLevel(of width: Double) -> Int {
        nearest(width, in: widthPresets)
    }

    private static func nearest(_ value: Double, in presets: [Double]) -> Int {
        presets.indices.min { abs(presets[$0] - value) < abs(presets[$1] - value) } ?? 0
    }

    // Per-object styles. Annotations store these, so their fields must stay decodable.

    struct Arrow: Codable, Equatable, Sendable {
        var color = RGBAColor.annotationBlue
        var width = 8.0
        var style = ArrowStyle.standard
    }

    /// A filled rectangle fills with its outline color.
    struct Rectangle: Codable, Equatable, Sendable {
        var strokeColor = RGBAColor.annotationBlue
        var width = 8.0
        var fillColor: RGBAColor?
    }

    struct Ellipse: Codable, Equatable, Sendable {
        var strokeColor = RGBAColor.annotationBlue
        var width = 8.0
    }

    struct Line: Codable, Equatable, Sendable {
        var color = RGBAColor.annotationBlue
        var width = 8.0
    }

    struct Text: Codable, Equatable, Sendable {
        static let sizeRange = 8.0...200.0
        var color = RGBAColor.annotationBlue
        var size = 36.0
        var weight = TextWeight.semibold
        var design = TextDesign.system
        var treatment = TextTreatment.plain
    }

    struct Redact: Codable, Equatable, Sendable {
        var style = RedactStyle.pixelate
        /// 0...1, mapped by the renderer to an image-pixel block size or blur radius.
        var strength = 0.5
        var solidColor = RGBAColor.black
    }

    struct Spotlight: Codable, Equatable, Sendable {
        static let dimRange = 5.0...90.0
        var shape = SpotlightShape.roundedRectangle
        var dimPercent = 50.0
    }

    struct Counter: Codable, Equatable, Sendable {
        static let sizeRange = 12.0...128.0
        var color = RGBAColor.annotationBlue
        var size = 57.6
    }

    // Stored defaults.

    var color = RGBAColor.annotationBlue
    /// The third of the six presets, 4 pt on Retina: bold enough to read at a glance without
    /// covering the text it points at.
    var width = 8.0
    var arrowStyle = ArrowStyle.standard
    var textWeight = TextWeight.semibold
    var textDesign = TextDesign.system
    var textTreatment = TextTreatment.plain
    var redact = Redact()
    var spotlight = Spotlight()
    /// Counter and text sizes follow the shared thickness stop; setting one picks the stop with
    /// the nearest size.
    var counterSize: Double {
        get { Self.counterSizePresets[Self.widthLevel(of: width)] }
        set { width = Self.widthPresets[Self.nearest(newValue, in: Self.counterSizePresets)] }
    }
    var textSize: Double {
        get { Self.textSizePresets[Self.widthLevel(of: width)] }
        set { width = Self.widthPresets[Self.nearest(newValue, in: Self.textSizePresets)] }
    }

    // The style of a new object of each kind. Setting one adopts its color and width.

    var arrow: Arrow {
        get { Arrow(color: color, width: width, style: arrowStyle) }
        set { color = newValue.color; width = newValue.width; arrowStyle = newValue.style }
    }
    var rectangle: Rectangle {
        get { Rectangle(strokeColor: color, width: width) }
        set { color = newValue.strokeColor; width = newValue.width }
    }
    var filledRectangle: Rectangle {
        get { Rectangle(strokeColor: color, width: width, fillColor: color) }
        set { color = newValue.strokeColor; width = newValue.width }
    }
    var ellipse: Ellipse {
        get { Ellipse(strokeColor: color, width: width) }
        set { color = newValue.strokeColor; width = newValue.width }
    }
    var line: Line {
        get { Line(color: color, width: width) }
        set { color = newValue.color; width = newValue.width }
    }
    var text: Text {
        get { Text(color: color, size: textSize, weight: textWeight, design: textDesign, treatment: textTreatment) }
        set {
            color = newValue.color; textSize = newValue.size; textWeight = newValue.weight
            textDesign = newValue.design; textTreatment = newValue.treatment
        }
    }
    var counter: Counter {
        get { Counter(color: color, size: counterSize) }
        set { color = newValue.color; counterSize = newValue.size }
    }

    var isValid: Bool {
        Self.widthRange.contains(width) && color.isValid && redact.solidColor.isValid
            && Text.sizeRange.contains(textSize) && (0...1).contains(redact.strength)
            && Spotlight.dimRange.contains(spotlight.dimPercent) && Counter.sizeRange.contains(counterSize)
    }
}

enum GIFFrameRate: Int, Codable, CaseIterable, Sendable {
    case fps10 = 10, fps15 = 15, fps24 = 24
}

/// Copy and save closing apply to both editors; tools belong to the image editor and playback
/// and GIF frame rate to the video editor.
struct EditorPreferences: Codable, Equatable, Sendable {
    var closesAfterCopy = false
    var closesAfterSave = false
    var tools = EditorToolDefaults()
    /// The last tool from the tool strip (any tool but Crop), selected when an editor opens.
    var tool = EditorTool.rectangle
    /// Starts playback as soon as the video editor opens. Off by default, like QuickTime, so
    /// trimming and cropping start from a still frame.
    var playsOnOpen = false
    /// Restarts playback from the trim start at the trim end, instead of stopping there.
    var loopsPlayback = false
    var gifFrameRate = GIFFrameRate.fps15

    var isValid: Bool { tools.isValid && tool != .crop }
}
