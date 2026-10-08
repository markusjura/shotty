import AppKit

/// An open editor window: the image editor for a screenshot or the video editor for a clip. The
/// app routes menu commands and editor shortcuts to the focused one, and stays a regular app with
/// a Dock icon while any is open.
@MainActor
protocol CaptureEditor: NSWindowController {
    var didClose: (() -> Void)? { get set }
    /// Whether `command` applies in this editor, which enables its menu item and shortcut.
    func handles(_ command: CommandID) -> Bool
    func execute(_ command: CommandID)
}
