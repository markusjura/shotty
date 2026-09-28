import Foundation
import Observation

/// Main-actor editing state. Each completed gesture is one undo operation and one ordered disk commit.
/// Call flush before Done or export; a failed write leaves the editable state available for retry.
@MainActor @Observable
final class EditorDocument {
    private(set) var state: AnnotationDocument
    private(set) var revision: Int
    private(set) var isPersisting = false
    private(set) var persistenceError: Error?
    let undoManager = UndoManager()
    let record: CaptureRecord
    var onChange: (@MainActor () -> Void)?

    @ObservationIgnored private let store: CaptureSessionStore
    @ObservationIgnored private var persistenceTask: Task<Void, Never>?
    @ObservationIgnored private var persistedRevision: Int
    @ObservationIgnored private var pendingWrites = 0

    var sourceBounds: CGRect { CGRect(x: 0, y: 0, width: record.pixelWidth, height: record.pixelHeight) }
    var snapshot: CaptureSnapshot {
        CaptureSnapshot(captureID: record.id, revision: revision, sourceURL: record.sourceURL,
                        sourceScale: record.sourceScale, createdAt: record.createdAt, documentState: state)
    }

    init(record: CaptureRecord, store: CaptureSessionStore) {
        self.record = record
        self.store = store
        state = record.documentState ?? AnnotationDocument()
        revision = record.revision
        persistedRevision = record.revision
        undoManager.groupsByEvent = false
    }

    func commit(_ next: AnnotationDocument, actionName: String = "Edit") {
        guard next != state else { return }
        do { _ = try next.validated(in: sourceBounds) }
        catch { persistenceError = error; onChange?(); return }
        let previous = state
        let startsGroup = !undoManager.isUndoing && !undoManager.isRedoing
        if startsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated { target.commit(previous, actionName: actionName) }
        }
        undoManager.setActionName(actionName)
        if startsGroup { undoManager.endUndoGrouping() }
        state = next
        revision += 1
        persist(snapshot)
        onChange?()
    }

    func undo() { if undoManager.canUndo { undoManager.undo() } }
    func redo() { if undoManager.canRedo { undoManager.redo() } }

    /// Freezes the exact requested revision before awaiting its disk write. Later edits stay separate.
    func flush() async throws -> CaptureSnapshot {
        let requested = snapshot
        if persistenceTask == nil, persistedRevision < requested.revision { persist(requested) }
        let pending = persistenceTask
        await pending?.value
        guard persistedRevision >= requested.revision else {
            throw persistenceError ?? DocumentRenderer.Failure.invalidDocument
        }
        return requested
    }

    private func persist(_ snapshot: CaptureSnapshot) {
        let previous = persistenceTask
        pendingWrites += 1; isPersisting = true
        persistenceTask = Task { [weak self, store] in
            await previous?.value
            do {
                _ = try await store.updateDocument(for: snapshot.captureID, state: snapshot.documentState, revision: snapshot.revision)
                guard let self else { return }
                self.persistedRevision = max(self.persistedRevision, snapshot.revision)
                self.persistenceError = nil
            } catch {
                self?.persistenceError = error
            }
            guard let self else { return }
            self.pendingWrites -= 1
            self.isPersisting = self.pendingWrites > 0
            if self.pendingWrites == 0 { self.persistenceTask = nil }
            self.onChange?()
        }
    }
}
