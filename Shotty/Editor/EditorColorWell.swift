import AppKit
import SwiftUI

/// A native color well groups the panel's continuous changes into one document edit.
struct EditorColorWell: NSViewRepresentable {
    @Binding var color: Color
    let model: EditorWindowModel
    let label: String

    func makeNSView(context: Context) -> GestureColorWell {
        let well = GestureColorWell()
        well.colorWellStyle = .minimal
        well.target = context.coordinator
        well.action = #selector(Coordinator.changed(_:))
        well.begin = { model.styleGesture(true) }
        well.end = { model.styleGesture(false) }
        return well
    }

    func updateNSView(_ well: GestureColorWell, context: Context) {
        context.coordinator.parent = self
        well.color = NSColor(color)
        well.setAccessibilityLabel(label)
    }

    static func dismantleNSView(_ well: GestureColorWell, coordinator: Coordinator) { well.deactivate() }
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor final class Coordinator: NSObject {
        var parent: EditorColorWell
        init(_ parent: EditorColorWell) { self.parent = parent }
        @objc func changed(_ sender: NSColorWell) { parent.color = Color(nsColor: sender.color) }
    }
}

final class GestureColorWell: NSColorWell {
    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 24) }
    var begin: (() -> Void)?
    var end: (() -> Void)?
    private var editing = false

    override func activate(_ exclusive: Bool) {
        if !editing { editing = true; begin?() }
        NSColorPanel.shared.showsAlpha = false
        NotificationCenter.default.addObserver(self, selector: #selector(panelClosed), name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
        super.activate(exclusive)
    }

    override func deactivate() {
        super.deactivate()
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
        if editing { editing = false; end?() }
    }

    @objc private func panelClosed() { deactivate() }
}
