import AppKit
import UniformTypeIdentifiers

/// Writes one flattened export when a drop destination fulfils the promise. The provider owns
/// this object; the coordinator holds it weakly and resolves the drag through `completed`,
/// `cancelUnused()`, or `released` when the provider goes away without a write.
@MainActor
final class CaptureFilePromise: NSObject, NSFilePromiseProviderDelegate {
    enum State: Equatable { case pending, writing, finished, cancelled }

    let snapshot: CaptureSnapshot
    let options: ExportOptions
    let exporter: ExportService
    nonisolated let filename: String
    private(set) var state = State.pending
    /// Called at most once, on the main actor, after the receiver's write finishes.
    var completed: ((Result<ExportReceipt, Error>) -> Void)?
    /// Fallback when the provider is released without ever starting a write. A started write
    /// is settled by `completed` and the owner's bookkeeping instead.
    var released: (@MainActor @Sendable () -> Void)?
    isolated deinit {
        if state == .pending || state == .cancelled { released?() }
    }

    init(snapshot: CaptureSnapshot, options: ExportOptions, exporter: ExportService, template: String) {
        self.snapshot = snapshot
        self.options = options
        self.exporter = exporter
        filename = ExportService.filename(stem: ExportService.filenameStem(template: template, date: snapshot.createdAt, kind: snapshot.kind),
                                          scale: snapshot.sourceScale, options: options)
    }

    func makeProvider() -> NSFilePromiseProvider {
        let value = RetainedFilePromiseProvider(fileType: options.format == .png ? UTType.png.identifier : UTType.jpeg.identifier, delegate: self)
        value.owner = self
        return value
    }

    /// Rejects any later write request so the caller can release the capture's source.
    /// Returns false when a write is running or finished; its completion is the terminal event.
    @discardableResult
    func cancelUnused() -> Bool {
        guard state == .pending else { return state == .cancelled }
        state = .cancelled
        return true
    }

    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        filename
    }

    nonisolated func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { .main }

    /// AppKit calls this on the main queue returned above. The write is marked as started
    /// synchronously, so a cancellation can never race a request that already arrived.
    /// The handler runs exactly once, after the file exists or the write is refused.
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        // AppKit's handler is not annotated Sendable; it is called once below.
        nonisolated(unsafe) let finish = completionHandler
        MainActor.assumeIsolated {
            guard state == .pending else { return finish(CocoaError(.userCancelled)) }
            state = .writing
            Task { @MainActor in
                let result: Result<ExportReceipt, Error>
                do { result = .success(try await exporter.save(snapshot, to: url, options: options)) }
                catch { result = .failure(error) }
                state = .finished
                let completed = self.completed
                self.completed = nil
                completed?(result)
                if case .failure(let error) = result { finish(error) } else { finish(nil) }
            }
        }
    }
}

private final class RetainedFilePromiseProvider: NSFilePromiseProvider {
    var owner: CaptureFilePromise?
}
