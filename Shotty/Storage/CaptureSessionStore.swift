import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// Serial disk and image work; records contain no full-resolution raster or thumbnail cache.
/// The coordinator owns UI/editor/export/Undo references and calls remove only after the last releases.
actor CaptureSessionStore {
    enum Failure: LocalizedError {
        case invalidImage, missingCapture, invalidManifest, recoveryRequired, imageEncoding

        var errorDescription: String? {
            switch self {
            case .invalidImage: "The capture has invalid image dimensions or display scale."
            case .missingCapture: "This capture is no longer in the active session."
            case .invalidManifest: "The saved session cannot be read. Its files have been kept for recovery."
            case .recoveryRequired: "Restore or discard the previous session before capturing."
            case .imageEncoding: "The capture could not be stored. Check available disk space and try again."
            }
        }
    }

    private struct Manifest: Codable {
        var version = 1
        var state: SessionRecovery.State
        var records: [CaptureRecord]
    }

    nonisolated let directory: URL
    private var entries: [CaptureRecord] = []
    private var loaded = false
    private var active = false
    private let documentRenderer = DocumentRenderer()
    private let signposter = OSSignposter(subsystem: "local.markus.Shotty", category: "CaptureStorage")
    private var manifestURL: URL { directory.appendingPathComponent("session.json") }

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shotty/Session", isDirectory: true)
    }

    init(directory: URL = CaptureSessionStore.defaultDirectory) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
    }

    func records() -> [CaptureRecord] { entries }

    /// Read without accepting an interrupted session. `resume` records the user's Restore choice.
    func load() throws -> SessionRecovery {
        guard !active else { return SessionRecovery(state: entries.isEmpty ? .empty : .interrupted, records: entries) }
        try prepareDirectory()
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            entries = []; loaded = true
            return SessionRecovery(state: .empty, records: [])
        }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw Failure.invalidManifest }
        guard manifest.version == 1, Set(manifest.records.map(\.id)).count == manifest.records.count,
              manifest.state != .empty || manifest.records.isEmpty else {
            throw Failure.invalidManifest
        }
        for record in manifest.records {
            guard record.sourceURL.resolvingSymlinksInPath().standardizedFileURL == sourceURL(record.id),
                  record.pixelWidth > 0, record.pixelHeight > 0,
                  record.sourceScale.isFinite, record.sourceScale > 0, record.revision >= 0,
                  record.copiedRevision.map({ (0...record.revision).contains($0) }) ?? true,
                  record.savedRevision.map({ (0...record.revision).contains($0) }) ?? true,
                  FileManager.default.fileExists(atPath: record.sourceURL.path) else { throw Failure.invalidManifest }
            if let state = record.documentState {
                do { _ = try state.validated(in: CGRect(x: 0, y: 0, width: record.pixelWidth, height: record.pixelHeight)) }
                catch { throw Failure.invalidManifest }
            }
        }
        entries = manifest.records; loaded = true
        return SessionRecovery(state: entries.isEmpty ? .empty : manifest.state, records: entries)
    }

    func resume() throws {
        if !loaded { _ = try load() }
        try persist(entries, state: .interrupted)
        active = true
        removeOrphanSources()
    }

    func retainForNextLaunch() throws {
        try requireActive()
        try persist(entries, state: .retained)
        active = false
    }

    func create(image: CGImage, kind: CaptureKind, scale: CGFloat) throws -> CaptureRecord {
        let interval = signposter.beginInterval("CreateCapture", id: signposter.makeSignpostID())
        defer { signposter.endInterval("CreateCapture", interval) }
        try requireActive()
        try Task.checkCancellation()
        guard image.width > 0, image.height > 0, scale.isFinite, scale > 0 else { throw Failure.invalidImage }
        return try autoreleasepool {
            let id = UUID()
            let url = sourceURL(id)
            try AtomicFile.write(to: url, beforePublish: { try Task.checkCancellation() }) { staged in
                guard let encoder = CGImageDestinationCreateWithURL(staged as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw Failure.imageEncoding
                }
                CGImageDestinationAddImage(encoder, image, nil)
                guard CGImageDestinationFinalize(encoder) else { throw Failure.imageEncoding }
            }
            let record = CaptureRecord(id: id, kind: kind, createdAt: Date(), pixelWidth: image.width,
                                       pixelHeight: image.height, sourceScale: Double(scale), sourceURL: url, revision: 0)
            do {
                try Task.checkCancellation()
                try persist(entries + [record], state: .interrupted)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            entries.append(record)
            return record
        }
    }

    func snapshot(for id: UUID) throws -> CaptureSnapshot { try record(id).snapshot }

    func thumbnail(for id: UUID) throws -> CGImage {
        let interval = signposter.beginInterval("CaptureThumbnail", id: signposter.makeSignpostID())
        defer { signposter.endInterval("CaptureThumbnail", interval) }
        try Task.checkCancellation()
        let record = try record(id)
        if let state = record.documentState, state != AnnotationDocument() {
            let rendered = try documentRenderer.render(source: image(for: id), state: state)
            let factor = min(1, 560 / Double(max(rendered.width, rendered.height)))
            let width = max(1, Int((Double(rendered.width) * factor).rounded()))
            let height = max(1, Int((Double(rendered.height) * factor).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: rendered.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.imageEncoding }
            context.interpolationQuality = .high
            context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let thumbnail = context.makeImage() else { throw Failure.imageEncoding }
            return thumbnail
        }
        let url = record.sourceURL
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 560,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw Failure.imageEncoding }
        return image
    }

    /// Editor-only decode. Thumbnail queues must use thumbnail(for:) instead.
    func image(for id: UUID) throws -> CGImage {
        let interval = signposter.beginInterval("CaptureDecode", id: signposter.makeSignpostID())
        defer { signposter.endInterval("CaptureDecode", interval) }
        try Task.checkCancellation()
        let record = try record(id)
        guard record.pixelWidth <= ExportService.maximumPixels / record.pixelHeight else { throw ExportService.Failure.resourceLimit }
        let url = record.sourceURL
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw Failure.imageEncoding }
        return image
    }

    func markCopied(_ snapshot: CaptureSnapshot) throws {
        try update(snapshot.captureID, revision: snapshot.revision) { $0.copiedRevision = snapshot.revision }
    }

    func markSaved(_ receipt: ExportReceipt) throws {
        try update(receipt.captureID, revision: receipt.revision) {
            $0.savedRevision = receipt.revision
            $0.outputFile = ExportedFile(url: receipt.destinationURL, fingerprint: receipt.fingerprint)
        }
    }

    /// Only document metadata changes. The original source is never rewritten.
    @discardableResult
    func updateDocument(for id: UUID, state: AnnotationDocument, revision: Int) throws -> CaptureRecord {
        try requireActive()
        guard let index = entries.firstIndex(where: { $0.id == id }), revision >= entries[index].revision else {
            throw Failure.missingCapture
        }
        let current = entries[index]
        _ = try state.validated(in: CGRect(x: 0, y: 0, width: current.pixelWidth, height: current.pixelHeight))
        if revision == current.revision {
            guard state == (current.documentState ?? AnnotationDocument()) else { throw Failure.invalidManifest }
            return current
        }
        var updated = entries
        updated[index].revision = revision
        updated[index].documentState = state
        try persist(updated, state: .interrupted)
        entries = updated
        return updated[index]
    }

    func remove(_ id: UUID) throws {
        try requireActive()
        let entry = try record(id)
        let remaining = entries.filter { $0.id != id }
        try persist(remaining, state: .interrupted)
        entries = remaining
        try? FileManager.default.removeItem(at: entry.sourceURL)
    }

    /// Commit an empty session before removing sources, so interruption cannot resurrect discarded work.
    func discard() throws {
        try prepareDirectory()
        try persist([], state: .interrupted)
        entries = []; loaded = true; active = true
        removeOrphanSources()
    }

    private func record(_ id: UUID) throws -> CaptureRecord {
        guard let record = entries.first(where: { $0.id == id }) else { throw Failure.missingCapture }
        return record
    }

    private func update(_ id: UUID, revision: Int, change: (inout CaptureRecord) -> Void) throws {
        try requireActive()
        guard let index = entries.firstIndex(where: { $0.id == id }), (0...entries[index].revision).contains(revision)
        else { throw Failure.missingCapture }
        var updated = entries
        change(&updated[index])
        try persist(updated, state: .interrupted)
        entries = updated
    }

    private func requireActive() throws {
        if !loaded {
            let recovery = try load()
            guard recovery.state == .empty else { throw Failure.recoveryRequired }
            try resume()
        }
        guard active else { throw Failure.recoveryRequired }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func sourceURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }

    private func persist(_ records: [CaptureRecord], state: SessionRecovery.State) throws {
        try AtomicFile.write(JSONEncoder().encode(Manifest(state: state, records: records)), to: manifestURL, replacing: true)
    }

    private func removeOrphanSources() {
        let owned = Set(entries.map { $0.sourceURL.resolvingSymlinksInPath().standardizedFileURL })
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where !owned.contains(file.resolvingSymlinksInPath().standardizedFileURL) {
            if (file.pathExtension == "png" && UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil)
                || (file.lastPathComponent.hasPrefix(".shotty-") && file.pathExtension == "tmp") {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}
