import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// The running session's captures: source pixels as PNG files, everything else in memory.
/// Nothing outlives the app. Launch and Quit both call `reset`, so a crash only loses captures.
/// The coordinator owns UI/editor/export/Undo references and calls remove only after the last releases.
actor CaptureSessionStore {
    enum Failure: LocalizedError {
        case invalidImage, missingCapture, imageEncoding

        var errorDescription: String? {
            switch self {
            case .invalidImage: "The capture has invalid image dimensions or display scale."
            case .missingCapture: "This capture is no longer in the active session."
            case .imageEncoding: "The capture could not be stored. Check available disk space and try again."
            }
        }
    }

    nonisolated let directory: URL
    private var entries: [CaptureRecord] = []
    private var prepared = false
    private let documentRenderer = DocumentRenderer()
    private let signposter = OSSignposter(subsystem: "local.markus.Shotty", category: "CaptureStorage")

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shotty/Session", isDirectory: true)
    }

    init(directory: URL = CaptureSessionStore.defaultDirectory) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
    }

    func records() -> [CaptureRecord] { entries }

    /// Forgets every capture and deletes the directory's contents, including files left by a
    /// crashed launch.
    func reset() throws {
        entries = []
        try prepareDirectory()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func create(image: CGImage, kind: CaptureKind, scale: CGFloat) throws -> CaptureRecord {
        let interval = signposter.beginInterval("CreateCapture", id: signposter.makeSignpostID())
        defer { signposter.endInterval("CreateCapture", interval) }
        try prepareDirectory()
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
            entries.append(record)
            return record
        }
    }

    func snapshot(for id: UUID) throws -> CaptureSnapshot { try record(id).snapshot }

    /// Longest side of a thumbnail, in pixels.
    private static let thumbnailPixels = 560

    func thumbnail(for id: UUID) throws -> CGImage {
        let interval = signposter.beginInterval("CaptureThumbnail", id: signposter.makeSignpostID())
        defer { signposter.endInterval("CaptureThumbnail", interval) }
        try Task.checkCancellation()
        let record = try record(id)
        if let state = record.documentState, state != AnnotationDocument() {
            return try thumbnail(of: documentRenderer.render(source: image(for: id), state: state))
        }
        let url = record.sourceURL
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: Self.thumbnailPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw Failure.imageEncoding }
        return image
    }

    /// Scales `image` like thumbnail(for:). A new capture uses this while its pixels are still in
    /// memory, which avoids decoding the PNG just written.
    func thumbnail(of image: CGImage) throws -> CGImage {
        let factor = min(1, Double(Self.thumbnailPixels) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * factor).rounded()))
        let height = max(1, Int((Double(image.height) * factor).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.imageEncoding }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let thumbnail = context.makeImage() else { throw Failure.imageEncoding }
        return thumbnail
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
        guard let index = entries.firstIndex(where: { $0.id == id }), revision >= entries[index].revision else {
            throw Failure.missingCapture
        }
        let current = entries[index]
        _ = try state.validated(in: CGRect(x: 0, y: 0, width: current.pixelWidth, height: current.pixelHeight))
        if revision == current.revision {
            guard state == (current.documentState ?? AnnotationDocument()) else { throw DocumentRenderer.Failure.invalidDocument }
            return current
        }
        entries[index].revision = revision
        entries[index].documentState = state
        return entries[index]
    }

    func remove(_ id: UUID) throws {
        let entry = try record(id)
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: entry.sourceURL)
    }

    private func record(_ id: UUID) throws -> CaptureRecord {
        guard let record = entries.first(where: { $0.id == id }) else { throw Failure.missingCapture }
        return record
    }

    private func update(_ id: UUID, revision: Int, change: (inout CaptureRecord) -> Void) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }), (0...entries[index].revision).contains(revision)
        else { throw Failure.missingCapture }
        change(&entries[index])
    }

    private func prepareDirectory() throws {
        guard !prepared else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var url = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        prepared = true
    }

    private func sourceURL(_ id: UUID) -> URL { directory.appendingPathComponent("\(id.uuidString).png") }
}
