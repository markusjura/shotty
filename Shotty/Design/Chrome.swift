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

    /// Light control surface, matching CleanShot's overlay pills.
    static let controlFill = NSColor(white: 0.85, alpha: 0.96)
    static let controlFillPressed = NSColor(white: 0.7, alpha: 0.96)
    /// Label on `controlFill`; dark gray reads softer than black at small sizes.
    static let controlLabel = NSColor(white: 0.14, alpha: 1)
    static let controlLabelDisabled = NSColor(white: 0.14, alpha: 0.4)
    /// Dims everything outside a selected capture region.
    static let scrim = NSColor.black.withAlphaComponent(0.3)
    /// Small dark readouts such as selection dimensions.
    static let readoutFill = NSColor.black.withAlphaComponent(0.78)

    /// Hairline around cards and floating surfaces; stronger with Increase Contrast.
    static var hairline: NSColor {
        NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            ? NSColor(white: 0.5, alpha: 1) : NSColor(white: 0.6, alpha: 0.55)
    }
    static var hairlineWidth: CGFloat { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 2 : 1 }

    // MARK: Shape and type

    static let cardRadius: CGFloat = 13
    static let panelRadius: CGFloat = 12
    static let pillHeight: CGFloat = 28
    static let cardPillSize = CGSize(width: 52, height: 27)
    static let iconButtonDiameter: CGFloat = 22
    static let controlFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// Copy and Save on thumbnail cards: smaller and heavier, matching CleanShot's pills.
    static let cardPillFont = NSFont.systemFont(ofSize: 12, weight: .semibold)

    // MARK: Motion

    static let fadeDuration: TimeInterval = 0.15
    static let moveDuration: TimeInterval = 0.2
    /// Zero when Reduce Motion is on, so callers can always animate.
    static func duration(_ value: TimeInterval) -> TimeInterval {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : value
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
