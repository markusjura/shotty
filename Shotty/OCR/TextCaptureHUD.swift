import AppKit
import SwiftUI

/// Capture Text's on-screen feedback: a capsule over the selection, styled like Shotty's other overlay
/// controls, that shows progress while recognition is slow, or why no text was copied. A successful
/// copy shows nothing, as in CleanShot X; VoiceOver still hears about it. The capsule never takes
/// focus; only the cancel button of the progress capsule takes clicks.
@MainActor
final class TextCaptureHUD {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    /// Shows recognition in progress until `close` or a message replaces it.
    func showProgress(over region: CGRect, cancel: @escaping @MainActor () -> Void) {
        present(Note(message: "Recognizing text…", symbol: nil, cancel: cancel), over: region)
    }

    /// Shows `message` over the selection for a moment.
    func show(_ message: String, symbol: String, over region: CGRect) {
        present(Note(message: message, symbol: symbol, cancel: nil), over: region)
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2.5)) } catch { return }
            self?.close()
        }
    }

    /// Has VoiceOver read `message` without showing anything.
    static func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Fades the capsule out.
    func close() {
        hideTask?.cancel()
        hideTask = nil
        guard let panel, panel.isVisible else { return }
        fade(panel, to: 0) {
            // A message shown during the fade keeps the panel.
            if panel.alphaValue == 0 { panel.orderOut(nil) }
        }
    }

    private func present(_ note: Note, over region: CGRect) {
        hideTask?.cancel()
        hideTask = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let content = NSHostingView(rootView: note)
        panel.contentView = content
        panel.ignoresMouseEvents = note.cancel == nil
        panel.setFrame(Self.frame(size: content.fittingSize, over: region), display: false)
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        fade(panel, to: 1)
        Self.announce(note.message)
    }

    /// Centered on the selection, and kept on the screen it was on.
    private static func frame(size: CGSize, over region: CGRect) -> CGRect {
        let center = CGPoint(x: region.midX, y: region.midY)
        let visible = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame ?? region
        let x = min(max(center.x - size.width / 2, visible.minX), visible.maxX - size.width)
        let y = min(max(center.y - size.height / 2, visible.minY), visible.maxY - size.height)
        return CGRect(origin: CGPoint(x: x.rounded(), y: y.rounded()), size: size)
    }

    private func fade(_ panel: NSPanel, to alpha: CGFloat, completion: (@MainActor () -> Void)? = nil) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = alpha
            completion?()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Chrome.fadeDuration
            panel.animator().alphaValue = alpha
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }

    private func makePanel() -> NSPanel {
        let panel = NonKeyPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = Chrome.floatingLevel
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // The panel fades itself; AppKit's window animation would also zoom it.
        panel.animationBehavior = .none
        return panel
    }

    /// A symbol, or a spinner while in progress, and the message, in the light overlay capsule.
    private struct Note: View {
        let message: String
        let symbol: String?
        let cancel: (@MainActor () -> Void)?

        var body: some View {
            HStack(spacing: 8) {
                if let symbol { Image(systemName: symbol).accessibilityHidden(true) } else { ProgressView().controlSize(.small) }
                Text(message)
                if let cancel {
                    Button("Cancel", systemImage: "xmark", action: cancel)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .help("Cancel")
                }
            }
            // One line at its natural width; otherwise the panel's sizing wraps the message.
            .fixedSize()
            .font(Font(Chrome.controlFont))
            .foregroundStyle(Color(nsColor: Chrome.controlLabel))
            .padding(.horizontal, 14)
            .frame(height: Chrome.pillHeight + 4)
            .overlayCapsuleBackground()
            // The capsule is always light, so the spinner must be the light appearance's dark one.
            .environment(\.colorScheme, .light)
            // Room for the capsule's shadow inside the panel.
            .padding(10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(message)
        }
    }
}
