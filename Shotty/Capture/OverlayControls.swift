import SwiftUI

/// Light capsule used for controls floating over captured content, such as Start Capture,
/// Auto Scroll, Cancel, and Done. It stays legible over light and dark pixels alike.
struct OverlayCapsuleButtonStyle: ButtonStyle {
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        OverlayCapsule(configuration: configuration, isProminent: isProminent)
    }

    private struct OverlayCapsule: View {
        let configuration: ButtonStyleConfiguration
        let isProminent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorSchemeContrast) private var contrast

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(.black.opacity(isEnabled ? 0.85 : 0.4))
                .padding(.horizontal, 14)
                .frame(height: 30)
                .background(Color(white: isProminent ? 1 : 0.9).opacity(configuration.isPressed ? 0.75 : 0.96), in: Capsule())
                .overlay(Capsule().strokeBorder(.black.opacity(contrast == .increased ? 0.6 : 0.12)))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .contentShape(Capsule())
        }
    }
}

extension ButtonStyle where Self == OverlayCapsuleButtonStyle {
    static var overlayCapsule: Self { .init() }
    static var overlayCapsuleProminent: Self { .init(isProminent: true) }
}
