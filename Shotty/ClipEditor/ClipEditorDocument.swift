import Foundation
import Observation

/// One clip's edits while its editor is open. Each change is a new revision with its own undo
/// step; revisions reach the session store in order, so copy and save always render what the
/// editor shows.
@MainActor @Observable
final class ClipEditorDocument {
    let record: ClipRecord
    private(set) var edit: VideoEdit
    private(set) var revision: Int
    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let store: CaptureSessionStore
    @ObservationIgnored private var persistence: Task<Void, Error>?

    init(record: ClipRecord, store: CaptureSessionStore) {
        self.record = record
        self.store = store
        edit = record.edit
        revision = record.revision
    }

    var snapshot: ClipSnapshot {
        ClipSnapshot(captureID: record.id, revision: revision, sourceURL: record.sourceURL, createdAt: record.createdAt,
                     pixelSize: record.pixelSize, duration: record.duration, hasAudio: record.hasAudio, edit: edit)
    }

    /// Applies `new` as the next revision. Undo restores the previous edits as a further revision.
    func commit(_ new: VideoEdit, actionName: String) {
        guard new != edit else { return }
        let old = edit
        edit = new
        revision += 1
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated { document.commit(old, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        persist()
        onChange?()
    }

    /// Waits until every revision so far is stored, then returns the current one.
    func flush() async throws -> ClipSnapshot {
        try await persistence?.value
        return snapshot
    }

    private func persist() {
        let (id, edit, revision, store, previous) = (record.id, edit, revision, store, persistence)
        persistence = Task {
            _ = try? await previous?.value
            try await store.updateEdit(for: id, edit: edit, revision: revision)
        }
    }
}
