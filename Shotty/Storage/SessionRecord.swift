import Foundation

/// One capture in the session: a screenshot or a recorded clip. Both track copies and saves the
/// same way, so thumbnails, Save All, and Dismiss All treat them alike. Editors and exporters take
/// the record of their own kind.
enum SessionRecord: Identifiable, Equatable, Sendable {
    case image(CaptureRecord)
    case clip(ClipRecord)

    var id: UUID {
        switch self {
        case .image(let record): record.id
        case .clip(let record): record.id
        }
    }

    var revision: Int {
        switch self {
        case .image(let record): record.revision
        case .clip(let record): record.revision
        }
    }

    var copiedRevision: Int? {
        switch self {
        case .image(let record): record.copiedRevision
        case .clip(let record): record.copiedRevision
        }
    }

    var savedRevision: Int? {
        switch self {
        case .image(let record): record.savedRevision
        case .clip(let record): record.savedRevision
        }
    }

    var isCopied: Bool { copiedRevision == revision }
    var isSaved: Bool { savedRevision == revision }

    var outputFile: ExportedFile? {
        switch self {
        case .image(let record): record.outputFile
        case .clip(let record): record.outputFile
        }
    }

    var sourceURL: URL {
        switch self {
        case .image(let record): record.sourceURL
        case .clip(let record): record.sourceURL
        }
    }

    mutating func markCopied(_ revision: Int) {
        switch self {
        case .image(var record): record.copiedRevision = revision; self = .image(record)
        case .clip(var record): record.copiedRevision = revision; self = .clip(record)
        }
    }

    mutating func markSaved(_ receipt: ExportReceipt) {
        let file = ExportedFile(url: receipt.destinationURL, fingerprint: receipt.fingerprint)
        switch self {
        case .image(var record): record.savedRevision = receipt.revision; record.outputFile = file; self = .image(record)
        case .clip(var record): record.savedRevision = receipt.revision; record.outputFile = file; self = .clip(record)
        }
    }
}
