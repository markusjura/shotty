import SwiftUI

/// Light capsule for controls floating over captured content, such as Start Capture, Auto Scroll,
/// Done, and "N more". It stays legible over light and dark pixels. Icon-only buttons are circles.
/// The recording bars use `Island` instead.
struct OverlayCapsuleButtonStyle: ButtonStyle {
    var isProminent = false
    var isIconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        OverlayCapsule(configuration: configuration, isProminent: isProminent, isIconOnly: isIconOnly)
    }

    private struct OverlayCapsule: View {
        let configuration: ButtonStyleConfiguration
        let isProminent: Bool
        let isIconOnly: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Font(Chrome.controlFont))
                .labelStyle(isIconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .foregroundStyle(Color(nsColor: isEnabled ? Chrome.controlLabel : Chrome.controlLabelDisabled))
                .padding(.horizontal, isIconOnly ? 0 : 12)
                .frame(width: isIconOnly ? Chrome.pillHeight : nil, height: Chrome.pillHeight)
                .overlayCapsuleBackground(isPressed: configuration.isPressed, isProminent: isProminent)
                .contentShape(Capsule())
        }
    }
}

extension ButtonStyle where Self == OverlayCapsuleButtonStyle {
    static var overlayCapsule: Self { .init() }
    static var overlayCapsuleProminent: Self { .init(isProminent: true) }
    static var overlayIcon: Self { .init(isIconOnly: true) }
}

extension View {
    /// The capsule surface shared by overlay buttons and other controls placed beside them.
    func overlayCapsuleBackground(isPressed: Bool = false, isProminent: Bool = false) -> some View {
        let fill = isPressed ? Chrome.controlFillPressed : isProminent ? .white : Chrome.controlFill
        return background(Color(nsColor: fill), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: Chrome.hairline), lineWidth: Chrome.hairlineWidth / 2))
            .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
    }
}

/// Picks a label style at runtime. Overlay and island buttons use it.
struct AnyLabelStyle: LabelStyle {
    private let body: (Configuration) -> AnyView

    init(_ style: some LabelStyle) { body = { AnyView(style.makeBody(configuration: $0)) } }

    func makeBody(configuration: Configuration) -> some View { body(configuration) }
}
