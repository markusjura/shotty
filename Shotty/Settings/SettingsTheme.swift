import AppKit
import SwiftUI

/// Settings colors, taken from Raycast's settings window. Each token has a light and a dark value.
enum SettingsColor {
    static let canvas = dynamic(light: 0xFFFFFF, dark: 0x141515)
    static let section = dynamic(light: 0xF9F9F9, dark: 0x1A1B1B)
    static let rowSeparator = dynamic(light: 0xEDEDED, dark: 0x262727)
    static let opaqueSidebar = dynamic(light: 0xF3F3F3, dark: 0x1A1B1C)
    /// The selected sidebar row, and its dimmer fill while the window is inactive.
    static let sidebarSelection = dynamic(light: 0xDADADA, dark: 0x333433)
    static let inactiveSidebarSelection = dynamic(light: 0xEBEBEB, dark: 0x272928)
    /// Fill of buttons such as Choose… and the shortcut recorder, as Raycast's settings buttons.
    static let controlFill = dynamic(light: 0xE0E0E0, dark: 0x323333)
    static let primaryText = dynamic(light: 0x000000, dark: 0xFFFFFF)
    static let secondaryText = dynamic(light: 0x646464, dark: 0xA4A4A4)
    /// The line under the toolbar while it is hovered or the window is inactive: the system
    /// separator in light mode, and the window's inactive outer border over the canvas in dark mode.
    static let toolbarLine = Color(nsColor: NSColor(name: nil) { appearance in
        isDark(appearance) ? NSColor(srgbHex: 0x272828) : .separatorColor
    })

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: .settings(light: light, dark: dark))
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

extension NSColor {
    /// A settings color for AppKit drawing, resolved for the current appearance.
    static func settings(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(srgbHex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        }
    }
}

private extension NSColor {
    convenience init(srgbHex hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The grouped settings layout of macOS System Settings, drawn by Shotty so it can use
/// `SettingsColor`. The native grouped form fills sections with a fixed translucent system color
/// that no public modifier changes. Panes keep writing plain `Form`, `Section`, and controls.
struct SettingsFormStyle: FormStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(sections: configuration.content) { section in
                    if !section.header.isEmpty {
                        // Semibold, as System Settings' section headers; `.headline` is bold.
                        section.header
                            .font(.headline.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                    }
                    VStack(spacing: 0) {
                        ForEach(subviews: section.content) { row in
                            if row.id != section.content.first?.id {
                                SettingsColor.rowSeparator.frame(height: 1).padding(.horizontal, 10)
                            }
                            row.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 36)
                        }
                    }
                    .padding(.vertical, 0.5)
                    .background(SettingsColor.section, in: RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 30)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
        }
        // Rows end at the toolbar instead of scrolling under its title and buttons.
        .clipped()
        .scrollContentBackground(.hidden)
        .background(SettingsColor.canvas)
        .foregroundStyle(SettingsColor.primaryText)
        .toggleStyle(SettingsToggleStyle())
        .labeledContentStyle(SettingsLabeledContentStyle())
        .horizontalRadioGroupLayout()
        // Buttons are flat fills, like Raycast's settings buttons. Menu pickers and menus set
        // `.buttonStyle(.borderless)` themselves, which shows them as text and chevrons, like
        // Raycast's dropdowns; a custom button style doesn't reach their pop-up buttons.
        .buttonStyle(SettingsButtonStyle())
    }
}

/// A flat button in `SettingsColor.controlFill`, as Raycast's settings buttons. The prominent
/// variant fills with the accent color, for the one action a row asks the user to take.
struct SettingsButtonStyle: ButtonStyle {
    var isProminent = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isProminent ? Color.accentColor : SettingsColor.controlFill, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).fill(SettingsColor.primaryText.opacity(configuration.isPressed ? 0.08 : 0)))
            .foregroundStyle(isProminent ? Color.white : SettingsColor.primaryText)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// A label on the leading edge and a switch on the trailing edge, as in a grouped form.
private struct SettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label.accessibilityHidden(true)
            Spacer()
            // The hidden label names the switch for accessibility; the visible one is skipped.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
        }
    }
}

/// The label on the leading edge and the content on the trailing edge, as in a grouped form.
/// Pickers lay out through this style too, so plain values set `settingsValue()` themselves.
private struct SettingsLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer()
            configuration.content
        }
    }
}

extension View {
    /// Secondary explanatory text in Settings, in the settings secondary color.
    func settingsNote() -> some View {
        font(.callout).foregroundStyle(SettingsColor.secondaryText)
    }

    /// A read-only value beside a label, in the settings secondary color.
    func settingsValue() -> some View {
        foregroundStyle(SettingsColor.secondaryText)
    }
}

/// A Settings sidebar row as in Raycast's settings: an accent icon and primary text, with a gray
/// fill when selected, and the blue update dot at the trailing edge when asked. The List keeps its
/// own selection, so clicks, arrow keys, and VoiceOver work as usual; only the system highlight is
/// turned off, by `HidesSelectionHighlight`.
struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let isSelected: Bool
    var showsUpdateDot = false
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        Label {
            // Semibold when selected, as in macOS sidebars.
            Text(pane.title)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundStyle(SettingsColor.primaryText)
        } icon: {
            Image(systemName: pane.symbol).foregroundStyle(Color.accentColor)
        }
        .font(.system(size: NSFont.systemFontSize))
        // The List gives the selected row increased prominence, which restyles its text and lags
        // the selection by one change. The row draws its own selection, so it opts out.
        .environment(\.backgroundProminence, .standard)
        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
        .overlay(alignment: .trailing) {
            if showsUpdateDot { UpdateDot().padding(.trailing, 4) }
        }
        .padding(.horizontal, 5)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .fill(appearsActive ? SettingsColor.sidebarSelection : SettingsColor.inactiveSidebarSelection)
            }
        }
        // The sidebar list insets rows 6 pt more than the system selection; widen to its frame.
        .padding(.horizontal, -6)
        .listRowBackground(HidesSelectionHighlight())
    }
}

/// Turns off the system selection highlight of the table that hosts it, keeping the selection itself.
private struct HidesSelectionHighlight: NSViewRepresentable {
    func makeNSView(context: Context) -> FinderView { FinderView() }
    func updateNSView(_ view: FinderView, context: Context) {}

    final class FinderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var ancestor = superview
            while let view = ancestor, !(view is NSTableView) { ancestor = view.superview }
            (ancestor as? NSTableView)?.selectionHighlightStyle = .none
        }
    }
}
