import AppKit

/// Automatic output can finish only while it still owns its invocation's clipboard.
@MainActor
final class ClipboardWriter {
    struct Ticket: Equatable { fileprivate let generation: Int }
    private let pasteboard: NSPasteboard
    private var generation = 0
    private var expectedChangeCount = 0

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    func begin() -> Ticket {
        generation += 1
        expectedChangeCount = pasteboard.changeCount
        return Ticket(generation: generation)
    }

    @discardableResult
    func write(_ data: Data, type: NSPasteboard.PasteboardType, ticket: Ticket) -> Bool {
        guard ticket.generation == generation, expectedChangeCount == pasteboard.changeCount else { return false }
        pasteboard.clearContents()
        let success = pasteboard.setData(data, forType: type)
        expectedChangeCount = pasteboard.changeCount
        return success
    }

    @discardableResult
    func write(_ string: String, ticket: Ticket) -> Bool {
        write(Data(string.utf8), type: .string, ticket: ticket)
    }
}
