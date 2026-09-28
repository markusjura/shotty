import AppKit

/// Shows the shared color panel for a custom annotation color. One session runs at a time; the
/// panel's continuous changes between `begin` and `end` form a single style edit.
@MainActor
final class EditorColorPanel: NSObject {
    static let shared = EditorColorPanel()

    private var change: ((RGBAColor) -> Void)?
    private var end: (() -> Void)?

    func show(_ color: RGBAColor, begin: () -> Void, change: @escaping (RGBAColor) -> Void, end: @escaping () -> Void) {
        finish()
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = true
        panel.setTarget(nil)
        panel.color = NSColor(cgColor: color.cgColor) ?? .black
        begin()
        self.change = change
        self.end = end
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        NotificationCenter.default.addObserver(self, selector: #selector(finish), name: NSWindow.willCloseNotification, object: panel)
        panel.orderFront(nil)
    }

    /// Ends the current session, if any. Call when its editor closes.
    @objc func finish() {
        guard let end else { return }
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
        NSColorPanel.shared.setTarget(nil)
        NSColorPanel.shared.setAction(nil)
        change = nil
        self.end = nil
        end()
    }

    @objc private func changed(_ panel: NSColorPanel) {
        if let color = RGBAColor(panel.color.cgColor) { change?(color) }
    }
}
