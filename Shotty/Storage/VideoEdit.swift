import CoreGraphics
import Foundation

enum PlaybackSpeed: Double, Codable, CaseIterable, Sendable {
    case normal = 1, faster = 1.5, double = 2, quadruple = 4

    var title: String {
        switch self {
        case .normal: "1×"
        case .faster: "1.5×"
        case .double: "2×"
        case .quadruple: "4×"
        }
    }
}

/// The longest side of the output in pixels, or the source size.
enum OutputSize: Int, Codable, CaseIterable, Sendable {
    case original = 0, px1920 = 1920, px1280 = 1280, px960 = 960, px640 = 640

    var title: String { self == .original ? "Original" : "\(rawValue) px" }
}

/// Everything the editor changes about a clip. The recorded movie itself is never rewritten;
/// copy, save, and drag render it through these edits.
struct VideoEdit: Codable, Equatable, Sendable {
    /// Shortest clip the trim handles allow, in source seconds.
    static let minimumDuration = 0.1

    /// Source seconds.
    var trimStart = 0.0
    /// Source seconds; nil keeps the end of the recording.
    var trimEnd: Double?
    /// Source pixels with a top-left origin, as video frames are laid out. Nil keeps the whole frame.
    var crop: CGRect?
    var speed = PlaybackSpeed.normal
    var removesAudio = false
    var size: OutputSize
    var format: ClipFormat

    /// A GIF of a Retina recording at full size runs to tens of megabytes, so GIFs start at 960 px.
    init(format: ClipFormat = .mp4) {
        self.format = format
        size = format == .gif ? .px960 : .original
    }

    /// Switches the output format. Moving to GIF from the original size picks the GIF default size.
    mutating func setFormat(_ format: ClipFormat) {
        if format == .gif, self.format != .gif, size == .original { size = .px960 }
        self.format = format
    }

    /// The kept part of a `duration`-second source, always at least `minimumDuration` long when
    /// the source allows it.
    func trimRange(duration: Double) -> ClosedRange<Double> {
        let end = min(max(trimEnd ?? duration, 0), duration)
        let start = min(max(trimStart, 0), max(0, end - Self.minimumDuration))
        return start...max(start, end)
    }

    /// How long the output plays, after trimming and speeding up.
    func outputDuration(sourceDuration: Double) -> Double {
        let range = trimRange(duration: sourceDuration)
        return (range.upperBound - range.lowerBound) / speed.rawValue
    }

    /// The visible part of a `source`-sized frame.
    func cropRect(in source: CGSize) -> CGRect {
        let bounds = CGRect(origin: .zero, size: source)
        guard let crop else { return bounds }
        let clipped = crop.intersection(bounds).integral.intersection(bounds)
        return clipped.width >= 2 && clipped.height >= 2 ? clipped : bounds
    }

    /// Output pixel dimensions: the crop, scaled down so its longest side fits `size`, rounded to
    /// even numbers because H.264 and HEVC encode whole 2×2 chroma blocks.
    func renderSize(source: CGSize) -> CGSize {
        let visible = cropRect(in: source).size
        let longest = max(visible.width, visible.height)
        let factor = size == .original || longest <= CGFloat(size.rawValue) ? 1 : CGFloat(size.rawValue) / longest
        func even(_ value: CGFloat) -> CGFloat { max(2, (value * factor / 2).rounded() * 2) }
        return CGSize(width: even(visible.width), height: even(visible.height))
    }

    /// True when an MP4 output is the recorded file itself, so it can be copied instead of encoded.
    func isPassthrough(sourceSize: CGSize, sourceDuration: Double) -> Bool {
        let range = trimRange(duration: sourceDuration)
        return format == .mp4 && range.lowerBound <= 0 && range.upperBound >= sourceDuration && speed == .normal
            && !removesAudio && cropRect(in: sourceSize).size == sourceSize && renderSize(source: sourceSize) == sourceSize
    }
}
