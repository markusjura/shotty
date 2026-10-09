import Foundation

enum CaptureKind: String, Codable, CaseIterable, Sendable {
    case area, window, fullscreen, scrolling, text
}

struct CaptureRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: CaptureKind
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    let sourceScale: Double
    let sourceURL: URL
    var revision: Int
    var copiedRevision: Int?
    var savedRevision: Int?
    var outputFile: ExportedFile?
    var documentState: AnnotationDocument?

    var isCopied: Bool { copiedRevision == revision }
    var isSaved: Bool { savedRevision == revision }

    var snapshot: CaptureSnapshot {
        CaptureSnapshot(captureID: id, revision: revision, sourceURL: sourceURL, sourceScale: sourceScale,
                        createdAt: createdAt, documentState: documentState ?? AnnotationDocument())
    }
}

/// The caller keeps the capture alive until all operations using this snapshot finish.
/// Later document edits must produce a new snapshot without changing this revision's inputs.
struct CaptureSnapshot: Equatable, Sendable {
    let captureID: UUID
    let revision: Int
    let sourceURL: URL
    let sourceScale: Double
    let createdAt: Date
    var documentState = AnnotationDocument()
}
