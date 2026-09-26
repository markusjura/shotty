import AppKit
import SwiftUI

/// Brief nonactivating feedback for Capture Text. It never takes focus from the frontmost app.
@MainActor
final class TextResultPanel {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let isDefault: Bool
        let perform: @MainActor () -> Void

        init(_ title: String, isDefault: Bool = false, perform: @escaping @MainActor () -> Void) {
            self.title = title
            self.isDefault = isDefault
            self.perform = perform
        }
    }

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// `autoHide` closes the panel after a few seconds; errors and skipped copies stay visible.
    func show(symbol: String, message: String, detail: String? = nil, actions: [Action], autoHide: Bool) {
        hideTask?.cancel()
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = TextResultView(symbol: symbol, message: message, detail: detail, actions: actions) { [weak self] in self?.close() }
        panel.contentView = NSHostingView(rootView: view)
        panel.setContentSize(panel.contentView?.fittingSize ?? CGSize(width: 360, height: 80))
        position(panel)
        panel.orderFrontRegardless()
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        guard autoHide else { return }
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.close()
        }
    }

    func close() {
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 80),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.title = "Capture Text"
        return panel
    }

    /// Bottom center of the display under the pointer.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrameOrigin(CGPoint(x: visible.midX - panel.frame.width / 2, y: visible.minY + 48))
    }
}

private struct TextResultView: View {
    let symbol: String
    let message: String
    let detail: String?
    let actions: [TextResultPanel.Action]
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(message).font(.headline)
                if let detail { Text(detail).secondaryNote().fixedSize(horizontal: false, vertical: true) }
                HStack {
                    ForEach(actions) { action in
                        if action.isDefault {
                            Button(action.title) { close(); action.perform() }.buttonStyle(.borderedProminent)
                        } else {
                            Button(action.title) { close(); action.perform() }
                        }
                    }
                    Button("Close", action: close)
                }
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .floatingSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}
