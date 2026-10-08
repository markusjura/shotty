import AppKit
import SwiftUI

/// Design tokens for Shotty's own floating chrome: thumbnails, capture overlays, scrolling
/// controls, and brief result panels. This chrome sits on arbitrary captured pixels, so it uses
/// fixed light controls with dark labels and system materials. Windows, forms, and the editor
/// toolbar use standard system colors and controls instead.
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
    /// Small dark readouts such as selection dimensions.
    static let readoutFill = NSColor.black.withAlphaComponent(0.78)

    /// Hairline around cards and floating surfaces; stronger with Increase Contrast.
    static var hairline: NSColor {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? NSColor(white: 0.5, alpha: 1) : NSColor(white: 0.6, alpha: 0.55)
    }
    static var hairlineWidth: CGFloat { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1 }
    /// Faint outline around thumbnail cards: a soft light edge in
    /// Dark Mode, a soft dark edge in Light Mode. Falls back to `hairline` with Increase Contrast.
    static var cardOutline: NSColor {
        guard !NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast else { return hairline }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 0, alpha: 0.1)
        }
    }

    // MARK: Window level

    /// Thumbnails and capture overlays sit just below the cursor: above app
    /// windows, full-screen apps, the menu bar, and other apps' floating panels.
    static let floatingLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.cursorWindow)) - 2)

    // MARK: Shape and type

    static let cardRadius: CGFloat = 13
    static let panelRadius: CGFloat = 12
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
    /// A floating HUD surface: system material, panel radius, and the shared hairline.
    func floatingSurface() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: Chrome.panelRadius))
            .overlay(RoundedRectangle(cornerRadius: Chrome.panelRadius).strokeBorder(Color(nsColor: .separatorColor)))
    }

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
