import AppKit
import SwiftUI

/// The recording bars' chrome: one dark capsule holding flat controls, as the system screenshot
/// bar and CleanShot X do. An island is always dark, whatever the appearance, so it stays apart
/// from the captured content it floats over. Show it in a panel whose appearance is `darkAqua`,
/// so dynamic colors such as `Chrome.record` resolve to their dark values.
struct Island<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 2) { content }
            .padding(.horizontal, 4)
            .frame(height: Chrome.islandHeight)
            .background(Color(nsColor: Chrome.islandFill), in: Capsule())
            .overlay(Capsule().strokeBorder(Color(nsColor: Chrome.islandRim), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 8, y: 3)
            .buttonStyle(.island)
            .foregroundStyle(Color(nsColor: Chrome.islandLabel))
            .font(Font(Chrome.controlFont))
            // Room for the shadow, which the hosting panel must not clip.
            .padding(Chrome.islandShadowInset)
    }
}

/// A hairline between groups on an island.
struct IslandDivider: View {
    var body: some View {
        Rectangle().fill(Color(nsColor: Chrome.islandRim))
            .frame(width: 1, height: 16)
            .padding(.horizontal, 3)
    }
}

/// Flat 28 pt capsules inside an island. Hovering and pressing lay white over the fill.
struct IslandButtonStyle: ButtonStyle {
    enum Emphasis {
        /// A plain action such as Cancel, Pause, or Discard.
        case plain
        /// A switch while it is on, such as the microphone while it records.
        case on
        /// A switch while it is off.
        case off
        /// Record and Stop: a red wash with a red label.
        case record
    }

    var emphasis = Emphasis.plain
    var isIconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        IslandButton(configuration: configuration, emphasis: emphasis, isIconOnly: isIconOnly)
    }

    private struct IslandButton: View {
        let configuration: ButtonStyleConfiguration
        let emphasis: Emphasis
        let isIconOnly: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .labelStyle(isIconOnly ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .foregroundStyle(label)
                .padding(.horizontal, isIconOnly ? 0 : 10)
                .frame(width: isIconOnly ? Chrome.islandControlHeight : nil, height: Chrome.islandControlHeight)
                .background(fill, in: Capsule())
                .overlay(Capsule().fill(.white.opacity(configuration.isPressed ? 0.14 : isHovered ? 0.08 : 0)))
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
        }

        private var fill: Color {
            switch emphasis {
            case .plain, .off: .clear
            case .on: .white.opacity(0.2)
            case .record: Color(nsColor: Chrome.record).opacity(0.22)
            }
        }

        private var label: Color {
            let base = Color(nsColor: Chrome.islandLabel)
            guard isEnabled else { return base.opacity(0.4) }
            switch emphasis {
            case .plain, .on: return base
            case .off: return base.opacity(0.5)
            case .record: return Color(nsColor: Chrome.record)
            }
        }
    }
}

extension ButtonStyle where Self == IslandButtonStyle {
    static var island: Self { .init() }
    static var islandIcon: Self { .init(isIconOnly: true) }
    static var islandRecord: Self { .init(emphasis: .record) }
    /// A switch that shows its state, such as the audio toggles.
    static func islandSwitch(isOn: Bool, isIconOnly: Bool = false) -> Self {
        .init(emphasis: isOn ? .on : .off, isIconOnly: isIconOnly)
    }
}
