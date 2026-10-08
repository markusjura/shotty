import AppKit
import SwiftUI

/// Metrics and styles for the editor's top and bottom bars:
/// 51 pt translucent bars, 26 pt capsule buttons filled with a light tint, and a 24 pt capsule
/// strip for the drawing tools.
enum EditorBar {
    static let height: CGFloat = 51
    static let buttonHeight: CGFloat = 26
    /// The one font for text and symbols in the bars: button titles, option values, and zoom.
    static let font = Font.system(size: 13, weight: .medium)
    @MainActor static let nsFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let iconButtonWidth: CGFloat = 36
    static let toolHeight: CGFloat = 24
    static let toolWidth: CGFloat = 35
    /// Leading inset of the first control, clear of the traffic lights (which end at 79 pt).
    static let leadingInset: CGFloat = 96
    static let edgeInset: CGFloat = 13
    static let buttonSpacing: CGFloat = 6
    static let groupSpacing: CGFloat = 12
    /// Fits the top bar with its widest tool options (Text) through Done.
    static let minimumWindowWidth: CGFloat = 900

    /// Button fill: white at 20% in Dark Mode, which reads as #656666 on the bar. AppKit views
    /// such as the Drag Me handle draw with `buttonTint`.
    static let buttonTint = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.1)
    }
    static let buttonFill = Color(nsColor: buttonTint)
    /// Black laid over a capsule while it is pressed or its menu is open.
    static let pressedDarkening: CGFloat = 0.15
    /// Tool strip fill, half the button tint.
    static let groupFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.05)
    })
}

/// The bars' background: a translucent system material that dims with the window, or, when
/// General turns translucent windows off, opaque grays that match the material over a mid-gray
/// backdrop (light #DFDFDF, dark #3D3D3D; inactive #EBEBEB and #2F2F2F).
struct EditorBarBackground: View {
    let isTranslucent: Bool
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        if isTranslucent {
            BarMaterial()
        } else {
            Color(nsColor: appearsActive ? .settings(light: 0xDFDFDF, dark: 0x3D3D3D) : .settings(light: 0xEBEBEB, dark: 0x2F2F2F))
        }
    }
}

private struct BarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { }
}

extension View {
    /// The bars' capsule: `fill` behind the view, darkened while pressed.
    func editorBarCapsule(_ fill: Color = EditorBar.buttonFill, isPressed: Bool = false) -> some View {
        background(fill, in: Capsule())
            .overlay(Capsule().fill(.black.opacity(isPressed ? EditorBar.pressedDarkening : 0)))
    }
}

/// Puts a label that sizes itself on the bars' capsule. Tools and option buttons use it;
/// `isOpen` keeps an option button darkened while its menu is showing.
struct EditorCapsuleButtonStyle: ButtonStyle {
    var fill = EditorBar.buttonFill
    var isOpen = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.editorBarCapsule(fill, isPressed: configuration.isPressed || isOpen)
    }
}

/// A 26 pt capsule: tinted by default, accent-filled when prominent.
struct EditorBarButtonStyle: ButtonStyle {
    var isProminent = false
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EditorBar.font)
            .foregroundStyle(isProminent ? Color.white : .primary)
            .padding(.horizontal, width == nil ? 12 : 0)
            .frame(width: width, height: EditorBar.buttonHeight)
            .editorBarCapsule(isProminent ? .accentColor : EditorBar.buttonFill, isPressed: configuration.isPressed)
            .contentShape(Capsule())
    }
}

extension ButtonStyle where Self == EditorBarButtonStyle {
    /// Text capsule such as Done.
    static var editorBar: Self { .init() }
    static var editorBarProminent: Self { .init(isProminent: true) }
    /// Icon-only capsule such as Copy and Save.
    static var editorBarIcon: Self { .init(width: EditorBar.iconButtonWidth) }
}
