import AppKit

/// Renders each clip revision once, into its own scratch folder, and hands that file to copy,
/// drag, and save. Saving copies the rendered file into place, so a save after a copy or drag
/// costs only a file clone.
actor ClipExporter {
    enum Failure: LocalizedError {
        case destinationExists(URL), externallyModified(URL)

        var errorDescription: String? {
            switch self {
            case .destinationExists(let url): "A file named \(url.lastPathComponent) already exists. Choose another name or confirm Replace."
            case .externallyModified(let url): "\(url.lastPathComponent) changed outside Shotty. Choose Replace, Save As, or Cancel."
            }
        }
    }

    /// A revision names one set of edits, so it identifies the output together with the options.
    private struct Key: Hashable {
        let id: UUID
        let revision: Int
        let options: RenderOptions
    }

    private var renders: [Key: Task<URL, Error>] = [:]

    /// The rendered file for `snapshot`. Concurrent and repeated calls share one render; a failed
    /// render is retried by the next call. A render first clones the recording, before any other call
    /// can join it, so it finishes even when the session deletes the clip meanwhile. A drag's file
    /// promise relies on that. APFS clones instantly and without using space.
    func rendered(_ snapshot: ClipSnapshot, options: RenderOptions) async throws -> URL {
        let key = Key(id: snapshot.captureID, revision: snapshot.revision, options: options)
        if let task = renders[key] { return try await task.value }
        let folder = try CaptureScratchSpace.makeFolder()
        var input = snapshot
        input.sourceURL = folder.appendingPathComponent("recording").appendingPathExtension(snapshot.sourceURL.pathExtension)
        do { try FileManager.default.copyItem(at: snapshot.sourceURL, to: input.sourceURL) } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        let task = Task<URL, Error> { [input] in
            defer { try? FileManager.default.removeItem(at: input.sourceURL) }
            let url = folder.appendingPathComponent(Self.filename(stem: Self.filenameStem(date: snapshot.createdAt),
                                                                  format: snapshot.edit.format))
            do {
                try await ClipRenderer.render(input, options: options, to: url)
                return url
            } catch {
                try? FileManager.default.removeItem(at: folder)
                throw error
            }
        }
        renders[key] = task
        do { return try await task.value } catch {
            renders[key] = nil
            throw error
        }
    }

    /// Forgets renders of a removed clip. Files stay until the next launch, since receivers may
    /// still read them.
    func forget(_ id: UUID) {
        renders = renders.filter { $0.key.id != id }
    }

    /// Saves into `directory` under the first free name; never overwrites.
    func export(_ snapshot: ClipSnapshot, to directory: URL, options: RenderOptions) async throws -> ExportReceipt {
        let rendered = try await rendered(snapshot, options: options)
        let stem = Self.filenameStem(date: snapshot.createdAt)
        var suffix = 1
        while true {
            try Task.checkCancellation()
            let url = directory.appendingPathComponent(Self.filename(stem: stem, collision: suffix, format: snapshot.edit.format))
            do {
                try publish(rendered, to: url, replacing: nil)
                return try receipt(snapshot, url: url)
            } catch let error as POSIXError where error.code == .EEXIST { suffix += 1 }
        }
    }

    /// Pass the last receipt's fingerprint for associated saves. For an explicit Replace choice,
    /// read a fresh fingerprint and pass it here. Omitting it never overwrites any existing file.
    func save(_ snapshot: ClipSnapshot, to destination: URL, options: RenderOptions,
              replacing expected: FileFingerprint? = nil) async throws -> ExportReceipt {
        if let expected { try verify(destination, expected: expected) }
        let rendered = try await rendered(snapshot, options: options)
        do { try publish(rendered, to: destination, replacing: expected) }
        catch let error as POSIXError where error.code == .EEXIST { throw Failure.destinationExists(destination) }
        return try receipt(snapshot, url: destination)
    }

    func fingerprint(at url: URL) throws -> FileFingerprint { try FileFingerprint(attributesOf: url) }

    private func publish(_ rendered: URL, to destination: URL, replacing expected: FileFingerprint?) throws {
        try AtomicFile.write(to: destination, replacing: expected != nil, beforePublish: {
            try Task.checkCancellation()
            if let expected { try self.verify(destination, expected: expected) }
        }) { stage in
            try FileManager.default.removeItem(at: stage)
            try FileManager.default.copyItem(at: rendered, to: stage)
        }
    }

    private func verify(_ url: URL, expected: FileFingerprint) throws {
        guard expected.matchesFile(at: url) else { throw Failure.externallyModified(url) }
    }

    private func receipt(_ snapshot: ClipSnapshot, url: URL) throws -> ExportReceipt {
        ExportReceipt(captureID: snapshot.captureID, revision: snapshot.revision, destinationURL: url,
                      fingerprint: try FileFingerprint(attributesOf: url))
    }

    /// `stem-2.mp4`, with a collision number from the second file on.
    nonisolated static func filename(stem: String, collision: Int = 1, format: ClipFormat) -> String {
        "\(stem)\(collision == 1 ? "" : "-\(collision)").\(format.fileExtension)"
    }

    /// Names like `clip-2026-10-03-14.17.05`.
    nonisolated static func filenameStem(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "'clip-'yyyy-MM-dd-HH.mm.ss"
        return formatter.string(from: date)
    }
}

/// Writes a clip whose render was not ready when its drag started, once the receiver asks for it.
/// The drop may have dismissed the clip by then, so `snapshot` reads a clone of the recording.
final class ClipFilePromise: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let snapshot: ClipSnapshot
    private let options: RenderOptions
    private let exporter: ClipExporter
    private let filename: String

    init(snapshot: ClipSnapshot, options: RenderOptions, exporter: ClipExporter, filename: String) {
        self.snapshot = snapshot
        self.options = options
        self.exporter = exporter
        self.filename = filename
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { filename }

    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        let (snapshot, options, exporter) = (snapshot, options, exporter)
        nonisolated(unsafe) let completion = completionHandler
        Task {
            do {
                let rendered = try await exporter.rendered(snapshot, options: options)
                try FileManager.default.copyItem(at: rendered, to: url)
                completion(nil)
            } catch { completion(error) }
        }
    }
}
