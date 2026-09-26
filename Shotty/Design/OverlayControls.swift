import SwiftUI

/// Light capsule for controls floating over captured content, such as Start Capture,
/// Auto Scroll, Cancel, Done, and Undo Dismiss. It stays legible over light and dark pixels.
struct OverlayCapsuleButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        OverlayCapsule(configuration: configuration, isProminent: isProminent)
    }

    private struct OverlayCapsule: View {
        let configuration: ButtonStyleConfiguration
        let isProminent: Bool
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Font(Chrome.controlFont))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Color(nsColor: isEnabled ? Chrome.controlLabel : Chrome.controlLabelDisabled))
                .padding(.horizontal, 12)
                .frame(height: Chrome.pillHeight)
                .overlayCapsuleBackground(isPressed: configuration.isPressed, isProminent: isProminent)
                .contentShape(Capsule())
        }
    }
}

extension ButtonStyle where Self == OverlayCapsuleButtonStyle {
    static var overlayCapsule: Self { .init() }
    static var overlayCapsuleProminent: Self { .init(isProminent: true) }
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
