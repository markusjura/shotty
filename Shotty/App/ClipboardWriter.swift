import AppKit

/// Automatic output can finish only while it still owns its invocation's clipboard.
@MainActor
final class ClipboardWriter {
    struct Ticket: Equatable { fileprivate let generation: Int }
    private let pasteboard: NSPasteboard
    private var generation = 0
    private var expectedChangeCount = 0
    /// The pasteboard does not own its data provider; this keeps the current one alive.
    private var provider: PasteDetector?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func begin() -> Ticket {
        generation += 1
        expectedChangeCount = pasteboard.changeCount
        return Ticket(generation: generation)
    }

    /// With `onPaste`, the data is handed over only when another app reads it, which is what a
    /// paste does, and `onPaste` runs once at that moment. Apps that read the clipboard on their
    /// own, such as clipboard managers, count as a paste too.
    @discardableResult
    func write(_ data: Data, type: NSPasteboard.PasteboardType, ticket: Ticket, onPaste: (@MainActor () -> Void)? = nil) -> Bool {
        guard ticket.generation == generation, expectedChangeCount == pasteboard.changeCount else { return false }
        pasteboard.clearContents()
        provider = nil
        let success: Bool
        if let onPaste {
            let detector = PasteDetector(data: data, onPaste: onPaste)
            let item = NSPasteboardItem()
            success = item.setDataProvider(detector, forTypes: [type]) && pasteboard.writeObjects([item])
            provider = detector
        } else {
            success = pasteboard.setData(data, forType: type)
        }
        expectedChangeCount = pasteboard.changeCount
        return success
    }

    @discardableResult
    func write(_ string: String, ticket: Ticket) -> Bool {
        write(Data(string.utf8), type: .string, ticket: ticket)
    }
}

/// Supplies promised clipboard data on first read and reports that read as a paste.
private final class PasteDetector: NSObject, NSPasteboardItemDataProvider {
    private let data: Data
    private var onPaste: (@MainActor () -> Void)?

    init(data: Data, onPaste: @escaping @MainActor () -> Void) {
        self.data = data
        self.onPaste = onPaste
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        item.setData(data, forType: type)
        guard let callback = onPaste else { return }
        onPaste = nil
        Task { @MainActor in callback() }
    }
}
