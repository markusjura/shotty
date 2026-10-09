import CoreGraphics
import Foundation

enum RecordingKind: String, Codable, CaseIterable, Sendable {
    case area, window, screen
}

/// A recorded clip in the session. The recorded movie is never rewritten; `edit` describes how
/// copy, save, and drag render it.
struct ClipRecord: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: RecordingKind
    let createdAt: Date
    let pixelWidth: Int
    let pixelHeight: Int
    /// Seconds.
    let duration: Double
    let hasAudio: Bool
    let sourceURL: URL
    var revision: Int
    var copiedRevision: Int?
    var savedRevision: Int?
    var outputFile: ExportedFile?
    var edit: VideoEdit

    var isCopied: Bool { copiedRevision == revision }
    var isSaved: Bool { savedRevision == revision }
    var pixelSize: CGSize { CGSize(width: pixelWidth, height: pixelHeight) }

    var snapshot: ClipSnapshot {
        ClipSnapshot(captureID: id, revision: revision, sourceURL: sourceURL, createdAt: createdAt,
                     pixelSize: pixelSize, duration: duration, hasAudio: hasAudio, edit: edit)
    }
}

/// One revision of a clip, as copy, save, and drag render it. The caller keeps the clip alive
/// until every operation using this snapshot finishes, or points `sourceURL` at a clone of the recording.
struct ClipSnapshot: Equatable, Sendable {
    let captureID: UUID
    let revision: Int
    var sourceURL: URL
    let createdAt: Date
    let pixelSize: CGSize
    let duration: Double
    let hasAudio: Bool
    var edit: VideoEdit

    var outputDuration: Double { edit.outputDuration(sourceDuration: duration) }
}
