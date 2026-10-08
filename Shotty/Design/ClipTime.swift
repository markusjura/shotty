import Foundation

/// Times as video players show them.
enum ClipTime {
    /// A running time, rounded down: `0:07` or `1:02:03`, and with `tenths`, `0:07.4`.
    static func format(_ seconds: TimeInterval, tenths: Bool) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        let total = tenths ? (value * 10).rounded(.down) / 10 : value.rounded(.down)
        let whole = Int(total)
        let (hours, minutes, secs) = (whole / 3600, whole / 60 % 60, whole % 60)
        var text = hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
        if tenths { text += String(format: ".%d", Int(((total - Double(whole)) * 10).rounded()) % 10) }
        return text
    }

    /// A clip's length for its thumbnail badge: the nearest second, and never `0:00`.
    static func duration(_ seconds: TimeInterval) -> String {
        format(max(1, seconds.isFinite ? seconds.rounded() : 1), tenths: false)
    }
}
