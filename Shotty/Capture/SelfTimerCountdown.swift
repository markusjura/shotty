import AppKit
import SwiftUI

/// Self-Timer's wait between the selection and the screenshot. The region stays outlined and an
/// island beside it counts the seconds down, styled like the recording controls. The screen stays
/// live and the island never takes key focus, so a menu can be opened or a hover state set up for
/// the screenshot, by pointer or keyboard.
@MainActor
enum SelfTimerCountdown {
    /// Counts `seconds` down beside `region`, given in global AppKit points, then removes what it
    /// showed. Returns the IDs of those windows: ordered out a moment ago, they can still show up in
    /// a frame, so the capture must leave them out. The island's Cancel button calls `cancel`, which
    /// should cancel the calling task; this then throws `CancellationError`.
    static func run(seconds: Double, over region: CGRect, cancel: @escaping @MainActor () -> Void) async throws -> Set<CGWindowID> {
        let screens = NSScreen.screens.filter { $0.frame.intersects(region) }
        var panels = screens.map { screen in
            let outline = NonKeyPanel.overlay(frame: screen.frame, content: RegionOutlineView(region: region, on: screen))
            outline.ignoresMouseEvents = true
            return outline
        }
        // The island starts at the interval and drops by one each second: 2.5 seconds count 2.5, 1.5, 0.5.
        var remaining = seconds
        let island = NSHostingView(rootView: SelfTimerIsland(remaining: remaining, total: seconds, cancel: cancel))
        let center = CGPoint(x: region.midX, y: region.midY)
        if let screen = screens.first(where: { $0.frame.contains(center) }) ?? screens.first {
            let size = island.fittingSize
            let origin = SelectionGeometry.islandOrigin(size: size, for: region, within: screen.visibleFrame)
            panels.append(NonKeyPanel.overlay(frame: CGRect(origin: origin, size: size), content: island))
        }
        defer { panels.forEach { $0.orderOut(nil) } }
        panels.forEach { $0.orderFrontRegardless() }
        let clock = ContinuousClock()
        let end = clock.now + .seconds(seconds)
        while remaining > 0 {
            island.rootView = SelfTimerIsland(remaining: remaining, total: seconds, cancel: cancel)
            remaining = max(0, remaining - 1)
            try await clock.sleep(until: end - .seconds(remaining))
        }
        return Set(panels.map { CGWindowID($0.windowNumber) })
    }
}

/// Cancel and the seconds left on one island, with Cancel on the left as on the Record bar.
private struct SelfTimerIsland: View {
    let remaining: Double
    /// The interval the countdown started at, which is its widest text.
    let total: Double
    let cancel: @MainActor () -> Void

    var body: some View {
        Island {
            Button("Cancel", systemImage: "xmark", action: cancel)
                .buttonStyle(.islandIcon)
                .help("Cancel")
            IslandDivider()
            let format = SecondsFormat()
            HStack(spacing: 6) {
                Image(systemName: "timer")
                // As wide as the starting value, so the island keeps its size as the count drops.
                Text(format.format(total)).hidden().overlay { Text(format.format(remaining)) }.monospacedDigit()
            }
            .padding(.horizontal, 10)
            .frame(height: Chrome.islandControlHeight)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(remaining == 1 ? "Capturing in 1 second" : "Capturing in \(format.format(remaining)) seconds")
        }
        .fixedSize()
    }
}
