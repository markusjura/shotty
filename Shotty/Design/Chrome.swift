import AppKit
import SwiftUI

/// Design tokens for Shotty's own floating chrome: thumbnails, capture overlays, scrolling
/// controls, and Capture Text's feedback. This chrome sits on arbitrary captured pixels, so it uses
/// fixed light controls with dark labels. Windows, forms, and the editor toolbar use standard
/// system colors and controls instead.
///
/// Colors are `NSColor` so AppKit drawing and SwiftUI share one value; `Color(nsColor:)`
/// bridges them in views.
@MainActor
enum Chrome {
    // MARK: Color

    /// Light control surface for overlay pills.
    static let controlFill = NSColor(white: 0.85, alpha: 0.96)
    static let controlFillPressed = NSColor(white: 0.7, alpha: 0.96)
    /// Label on `controlFill`; dark gray reads softer than black at small sizes.
    static let controlLabel = NSColor(white: 0.14, alpha: 1)
    static let controlLabelDisabled = NSColor(white: 0.14, alpha: 0.4)
    /// A capture region: an opaque white border with a light grey wash inside. The wash greys white
    /// slightly and brightens darks and colors; it only vanishes on content of its own grey (about
    /// 179). The screen around it keeps its own colors.
    static let selectionBorder = NSColor.white
    static let selectionTint = NSColor(white: 0.70, alpha: 0.22)
    /// Wash over a hovered card's blurred capture, as CleanShot X does: white turns mid gray, so the
    /// light controls stand out on any capture while its colors still show through. The same in both
    /// appearances, since it sits on captured pixels.
    static let cardScrim = NSColor.black.withAlphaComponent(0.5)
    /// Tint over the blurred capture in a card's bottom stripe, measured from CleanShot X's recording
    /// thumbnails: white turns (120, 120, 124) and near black (34, 34, 37), so the stripe stays a mid
    /// dark gray that white text reads on over any capture.
    static let cardStripe = NSColor(srgbRed: 44 / 255, green: 44 / 255, blue: 50 / 255, alpha: 0.64)
    /// Small dark readouts such as selection dimensions.
    static let readoutFill = NSColor.black.withAlphaComponent(0.78)

    /// Hairline around cards and floating surfaces; stronger with Increase Contrast.
    static var hairline: NSColor {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? NSColor(white: 0.5, alpha: 1) : NSColor(white: 0.6, alpha: 0.55)
    }
    static var hairlineWidth: CGFloat { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1 }
    /// Thumbnail card edge, drawn over the capture like a macOS window frame. The one-pixel outer line
    /// separates the card from light backdrops; it is darker in Dark Mode, as on windows. Falls back
    /// to `hairline` with Increase Contrast.
    static var cardEdge: NSColor {
        guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return hairline }
        return NSColor(name: nil) { appearance in
            NSColor(white: 0, alpha: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.7 : 0.2)
        }
    }
    /// The 1 pt rim inside `cardEdge`. It lifts dark captures off dark backdrops and vanishes on light
    /// ones, so both appearances use it.
    static let cardRim = NSColor(white: 1, alpha: 0.1)

    // MARK: Window level

    /// Thumbnails and capture overlays sit just below the cursor: above app
    /// windows, full-screen apps, the menu bar, and other apps' floating panels.
    static let floatingLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 2)

    // MARK: Shape and type

    static let cardRadius: CGFloat = 13
    static let pillHeight: CGFloat = 28
    static let cardPillSize = CGSize(width: 52, height: 27)
    static let iconButtonDiameter: CGFloat = 22
    static let controlFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// Copy and Save on thumbnail cards: a size smaller than `controlFont`, for compact pills.
    static let cardPillFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    // MARK: Motion

    static let fadeDuration: TimeInterval = 0.15
    static let moveDuration: TimeInterval = 0.2
    /// Crossfades the next change of `layer` and its sublayers, unless Reduce Motion is on.
    static func crossfade(_ layer: CALayer?) {
        guard let layer, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = fadeDuration
        layer.add(transition, forKey: "crossfade")
    }
}

extension View {
    /// Secondary explanatory text under a control or message.
    func secondaryNote() -> some View {
        font(.callout).foregroundStyle(.secondary)
    }
}

extension Chrome {
    /// Draws a capture region in view coordinates: the wash inside it and a 1 pt border just
    /// outside, so neither touches the pixels being captured.
    static func drawSelection(_ rect: CGRect) {
        selectionTint.setFill()
        rect.fill()
        selectionBorder.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()
    }
}
