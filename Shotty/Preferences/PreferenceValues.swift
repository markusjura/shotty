import CoreGraphics
import Foundation

// Typed, persisted preference sections. Each section is one Codable value stored by
// AppPreferences; `isValid` rejects writes that would leave the app unusable.

enum AppearancePreference: String, Codable, CaseIterable, Sendable {
    case system, light, dark
}

struct GeneralPreferences: Codable, Equatable, Sendable {
    var appearance = AppearancePreference.system
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
    static let annotationRed = RGBAColor(red: 1, green: 0.231, blue: 0.188)

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

struct CapturePreferences: Codable, Equatable, Sendable {
    static let jpegQualityRange = 0.5...1.0

    var outputs: Set<ScreenshotOutput> = [.showThumbnail]
    var destination = SaveDestination.downloads
    var filenameTemplate = ExportService.defaultFilenameTemplate
    var format = ImageFormatPreference.png
    var jpegQuality = 0.9
    /// JPEG has no alpha; transparent pixels are composited onto this color.
    var jpegBackground = RGBAColor.white
    var colorHandling = ColorHandlingPreference.preserveSource
    var outputScale = OutputScalePreference.native
    var fullscreenTarget = FullscreenTarget.pointerDisplay
    var showsCursor = false
    var freezesScreen = true
    var includesWindowShadow = true
    var adjustsBeforeCapture = false
    var showsCrosshair = false
    var showsMagnifier = false

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
    case slow, adaptive, fast

    /// Desired progress per settled frame as a fraction of the selected axis extent.
    var stepFraction: Double {
        switch self {
        case .slow: 0.1
        case .adaptive: 0.2
        case .fast: 0.3
        }
    }
}

enum ScrollAxisPreference: String, Codable, CaseIterable, Sendable {
    case automatic, vertical, horizontal

    var axis: ScrollAxis? {
        switch self {
        case .automatic: nil
        case .vertical: .vertical
        case .horizontal: .horizontal
        }
    }
}

struct ScrollingPreferences: Codable, Equatable, Sendable {
    /// Upper bounds are the tested 30,000-pixel / 120-second envelope.
    static let axisPixelRange = 5_000...30_000
    static let durationRange = 30...120

    var pace = ScrollPace.adaptive
    var axis = ScrollAxisPreference.automatic
    var maximumAxisPixels = 30_000
    var maximumDurationSeconds = 120

    var isValid: Bool {
        Self.axisPixelRange.contains(maximumAxisPixels) && Self.durationRange.contains(maximumDurationSeconds)
    }

    var limits: ScrollLimits {
        ScrollLimits(maximumAxisPixels: maximumAxisPixels, maximumDuration: TimeInterval(maximumDurationSeconds))
    }
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

    static let maximumPreviewHeight: CGFloat = 160
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

    var placement = ThumbnailPlacement.leftCenter
    var size = ThumbnailSize.medium
    var display = ThumbnailDisplayPolicy.followPointer
    var autoClose = ThumbnailAutoClose.never
    var autoCloseDelaySeconds = 10
    var dismissesAfterSave = true
    var dismissesAfterDrag = true

    var isValid: Bool { Self.autoCloseDelayRange.contains(autoCloseDelaySeconds) }
}

// MARK: - Editor

enum EditorTool: String, Codable, CaseIterable, Sendable {
    case select, arrow, rectangle, ellipse, line, text, redact, spotlight, counter, crop
}

enum ArrowStyle: String, Codable, CaseIterable, Sendable { case standard, double, curved }
enum TextWeight: String, Codable, CaseIterable, Sendable { case regular, semibold, bold }
enum TextDesign: String, Codable, CaseIterable, Sendable { case system, monospaced }
enum TextTreatment: String, Codable, CaseIterable, Sendable { case plain, outlined, label }
enum RedactStyle: String, Codable, CaseIterable, Sendable { case pixelate, blur, solid }
enum SpotlightShape: String, Codable, CaseIterable, Sendable { case rectangle, roundedRectangle, ellipse }

/// New-object defaults per tool. Widths and sizes are image pixels, independent of zoom.
struct EditorToolDefaults: Codable, Equatable, Sendable {
    static let widthRange = 1.0...64.0

    struct Arrow: Codable, Equatable, Sendable {
        var color = RGBAColor.annotationRed
        var width = 4.0
        var style = ArrowStyle.standard
    }

    struct Rectangle: Codable, Equatable, Sendable {
        var strokeColor = RGBAColor.annotationRed
        var width = 4.0
        var fillColor: RGBAColor?
        var cornerRadius = 0.0
    }

    struct Ellipse: Codable, Equatable, Sendable {
        var strokeColor = RGBAColor.annotationRed
        var width = 4.0
        var fillColor: RGBAColor?
    }

    struct Line: Codable, Equatable, Sendable {
        var color = RGBAColor.annotationRed
        var width = 4.0
    }

    struct Text: Codable, Equatable, Sendable {
        static let sizeRange = 8.0...200.0
        var color = RGBAColor.annotationRed
        var size = 24.0
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
        var dimPercent = 45.0
    }

    struct Counter: Codable, Equatable, Sendable {
        static let sizeRange = 12.0...96.0
        var color = RGBAColor.annotationRed
        var size = 28.0
    }

    var arrow = Arrow()
    var rectangle = Rectangle()
    var ellipse = Ellipse()
    var line = Line()
    var text = Text()
    var redact = Redact()
    var spotlight = Spotlight()
    var counter = Counter()

    /// Select and Crop have no persisted style.
    static let styledTools: [EditorTool] = [.arrow, .rectangle, .ellipse, .line, .text, .redact, .spotlight, .counter]

    func isDefault(_ tool: EditorTool) -> Bool {
        let base = EditorToolDefaults()
        switch tool {
        case .select, .crop: return true
        case .arrow: return arrow == base.arrow
        case .rectangle: return rectangle == base.rectangle
        case .ellipse: return ellipse == base.ellipse
        case .line: return line == base.line
        case .text: return text == base.text
        case .redact: return redact == base.redact
        case .spotlight: return spotlight == base.spotlight
        case .counter: return counter == base.counter
        }
    }

    mutating func reset(_ tool: EditorTool) {
        let base = EditorToolDefaults()
        switch tool {
        case .select, .crop: break
        case .arrow: arrow = base.arrow
        case .rectangle: rectangle = base.rectangle
        case .ellipse: ellipse = base.ellipse
        case .line: line = base.line
        case .text: text = base.text
        case .redact: redact = base.redact
        case .spotlight: spotlight = base.spotlight
        case .counter: counter = base.counter
        }
    }

    var isValid: Bool {
        let widths = [arrow.width, rectangle.width, ellipse.width, line.width]
        let colors = [arrow.color, rectangle.strokeColor, ellipse.strokeColor, line.color, text.color,
                      redact.solidColor, counter.color] + [rectangle.fillColor, ellipse.fillColor].compactMap { $0 }
        return widths.allSatisfy(Self.widthRange.contains) && colors.allSatisfy(\.isValid)
            && rectangle.cornerRadius >= 0 && rectangle.cornerRadius.isFinite
            && Text.sizeRange.contains(text.size) && (0...1).contains(redact.strength)
            && Spotlight.dimRange.contains(spotlight.dimPercent) && Counter.sizeRange.contains(counter.size)
    }
}

struct EditorPreferences: Codable, Equatable, Sendable {
    var closesAfterCopy = false
    var closesAfterSave = false
    var tools = EditorToolDefaults()

    var isValid: Bool { tools.isValid }
}
