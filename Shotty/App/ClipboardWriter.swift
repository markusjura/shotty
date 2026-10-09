import AppKit

/// Automatic output can finish only while it still owns its invocation's clipboard.
@MainActor
final class ClipboardWriter {
    struct Ticket: Equatable { fileprivate let generation: Int }
    private let pasteboard: NSPasteboard
    private var generation = 0
    private var expectedChangeCount = 0
    /// The pending paste handler and the clipboard contents it belongs to.
    private var pasteWatch: (changeCount: Int, onPaste: @MainActor () -> Void)?
    private var keyMonitor: Any?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func begin() -> Ticket {
        generation += 1
        expectedChangeCount = pasteboard.changeCount
        return Ticket(generation: generation)
    }

    /// `onPaste` runs once when the user presses ⌘V in another app while this image is still on
    /// the clipboard. Clipboard managers read every copy on their own, so a read is not a paste.
    /// Seeing keystrokes in other apps needs Accessibility access.
    @discardableResult
    func write(_ data: Data, type: NSPasteboard.PasteboardType, ticket: Ticket, onPaste: (@MainActor () -> Void)? = nil) -> Bool {
        write(ticket: ticket, onPaste: onPaste) { $0.setData(data, forType: type) }
    }

    /// Puts `file` on the clipboard as a file, which Finder, Mail, Messages, and chat apps paste as an
    /// attachment. Clips are copied this way; `onPaste` works as for images.
    @discardableResult
    func write(file: URL, ticket: Ticket, onPaste: (@MainActor () -> Void)? = nil) -> Bool {
        write(ticket: ticket, onPaste: onPaste) { $0.writeObjects([file as NSURL]) }
    }

    private func write(ticket: Ticket, onPaste: (@MainActor () -> Void)?, contents: (NSPasteboard) -> Bool) -> Bool {
        guard ticket.generation == generation, expectedChangeCount == pasteboard.changeCount else { return false }
        pasteboard.clearContents()
        let success = contents(pasteboard)
        expectedChangeCount = pasteboard.changeCount
        pasteWatch = success ? onPaste.map { (pasteboard.changeCount, $0) } : nil
        updateKeyMonitor()
        return success
    }

    /// A ⌘V key-down in another app. Anything copied since the write ends the watch.
    func handleKeyDown(_ event: NSEvent) {
        guard let watch = pasteWatch else { return }
        guard pasteboard.changeCount == watch.changeCount else { pasteWatch = nil; updateKeyMonitor(); return }
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command,
              event.charactersIgnoringModifiers?.lowercased() == "v" else { return }
        pasteWatch = nil
        updateKeyMonitor()
        watch.onPaste()
    }

    /// The global monitor exists only while a paste is awaited.
    private func updateKeyMonitor() {
        if pasteWatch == nil, let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        } else if pasteWatch != nil, keyMonitor == nil {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
                MainActor.assumeIsolated { self?.handleKeyDown(event) }
            }
        }
    }

    @discardableResult
    func write(_ string: String, ticket: Ticket) -> Bool {
        write(Data(string.utf8), type: .string, ticket: ticket)
    }
}

