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

    /// Button fill: white at 20% in Dark Mode, which reads as #656666 on the bar.
    static let buttonFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.2) : NSColor(white: 0, alpha: 0.1)
    })
    /// Tool strip fill, half the button tint.
    static let groupFill = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.1) : NSColor(white: 0, alpha: 0.05)
    })
}

/// A translucent system material that dims with the window. The sidebar material reads as
/// 67 active and 37 inactive (8-bit gray) in Dark Mode.
struct EditorBarBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { }
}

/// A 26 pt capsule: tinted by default, accent-filled when prominent or selected.
struct EditorBarButtonStyle: ButtonStyle {
    var isProminent = false
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(EditorBar.font)
            .foregroundStyle(isProminent ? Color.white : .primary)
            .padding(.horizontal, width == nil ? 12 : 0)
            .frame(width: width, height: EditorBar.buttonHeight)
            .background(isProminent ? Color.accentColor : EditorBar.buttonFill, in: Capsule())
            .overlay(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.15 : 0)))
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
