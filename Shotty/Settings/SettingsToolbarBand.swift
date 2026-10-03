import AppKit
import SwiftUI

extension View {
    /// System Settings' toolbar states over a pane: while the pointer is over the pane's part of
    /// the toolbar, including while dragging the window by it, or while the window is inactive, a
    /// `SettingsColor.toolbarLine` hairline appears under the toolbar. The toolbar itself keeps the
    /// canvas color in every state and both sidebar modes. Apply to the detail column.
    func settingsToolbarBand() -> some View {
        modifier(SettingsToolbarBand())
    }
}

private struct SettingsToolbarBand: ViewModifier {
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.pixelLength) private var pixelLength
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            GeometryReader { proxy in
                HoverTracker { isHovering = $0 }
                    .frame(height: proxy.safeAreaInsets.top)
                    .overlay(alignment: .bottom) {
                        // One device pixel just below the toolbar, as in System Settings.
                        if isHovering || !appearsActive {
                            SettingsColor.toolbarLine.frame(height: pixelLength).offset(y: pixelLength).allowsHitTesting(false)
                        }
                    }
                    .offset(y: -proxy.safeAreaInsets.top)
            }
        }
    }
}

/// Reports the pointer entering and leaving its frame without taking clicks, so the toolbar and
/// window dragging above it keep working.
private struct HoverTracker: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }
    func updateNSView(_ view: TrackingView, context: Context) { view.changed = changed }

    final class TrackingView: NSView {
        var changed: (Bool) -> Void = { _ in }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }

        override func mouseEntered(with event: NSEvent) { changed(true) }
        override func mouseExited(with event: NSEvent) { changed(false) }
    }
}

/// The translucent sidebar: a behind-window material under a white wash, tuned to Raycast's
/// translucent sidebar (light #F3F3F3, dark #1B1D1D; inactive #F5F5F5 and #1F2020 over a dark desktop).
struct SidebarMaterial: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        BehindWindowMaterial().overlay(Color.white.opacity(wash))
    }

    private var wash: Double {
        switch (colorScheme, appearsActive) {
        case (.dark, true): 0
        case (.dark, false): 0.02
        case (_, true): 0.3
        case (_, false): 0.42
        }
    }
}

private struct BehindWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underPageBackground
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
