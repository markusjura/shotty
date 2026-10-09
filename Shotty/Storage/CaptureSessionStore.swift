@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os

/// The running session's captures: screenshots as PNG files and recordings as MP4 files, everything
/// else in memory. Nothing outlives the app. Launch and Quit both call `reset`, so a crash only loses
/// captures. The coordinator owns UI/editor/export/Undo references and calls remove only after the
/// last releases.
actor CaptureSessionStore {
    enum Failure: LocalizedError {
        case invalidImage, invalidMovie, missingCapture, imageEncoding, thumbnail

        var errorDescription: String? {
            switch self {
            case .invalidImage: "The capture has invalid image dimensions or display scale."
            case .invalidMovie: "The recording has no video. Record again."
            case .missingCapture: "This capture is no longer in the active session."
            case .imageEncoding: "The capture could not be stored. Check available disk space and try again."
            case .thumbnail: "The clip's preview could not be created."
            }
        }
    }

    nonisolated let directory: URL
    private var entries: [SessionRecord] = []
    private var prepared = false
    private let documentRenderer = DocumentRenderer()
    private let signposter = OSSignposter(subsystem: "local.markus.Shotty", category: "CaptureStorage")

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("\(Bundle.main.appName)/Session", isDirectory: true)
    }

    init(directory: URL = CaptureSessionStore.defaultDirectory) {
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
    }

    func records() -> [SessionRecord] { entries }

    func record(_ id: UUID) throws -> SessionRecord {
        guard let record = entries.first(where: { $0.id == id }) else { throw Failure.missingCapture }
        return record
    }

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
            let url = directory.appendingPathComponent("\(id.uuidString).png")
            try AtomicFile.write(to: url, beforePublish: { try Task.checkCancellation() }) { staged in
                guard let encoder = CGImageDestinationCreateWithURL(staged as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw Failure.imageEncoding
                }
                CGImageDestinationAddImage(encoder, image, nil)
                guard CGImageDestinationFinalize(encoder) else { throw Failure.imageEncoding }
            }
            let record = CaptureRecord(id: id, kind: kind, createdAt: Date(), pixelWidth: image.width,
                                       pixelHeight: image.height, sourceScale: Double(scale), sourceURL: url, revision: 0)
            entries.append(.image(record))
            return record
        }
    }

    /// Moves a finished recording into the session. `format` is the output format new clips start with.
    func create(movie: URL, kind: RecordingKind, format: ClipFormat) async throws -> ClipRecord {
        try prepareDirectory()
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString).mp4")
        try FileManager.default.moveItem(at: movie, to: url)
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.invalidMovie }
            let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
            let size = natural.applying(transform)
            let duration = try await asset.load(.duration).seconds
            let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
            guard duration.isFinite, duration > 0, abs(size.width) >= 1, abs(size.height) >= 1 else { throw Failure.invalidMovie }
            let record = ClipRecord(id: id, kind: kind, createdAt: Date(), pixelWidth: Int(abs(size.width).rounded()),
                                    pixelHeight: Int(abs(size.height).rounded()), duration: duration, hasAudio: hasAudio,
                                    sourceURL: url, revision: 0, edit: VideoEdit(format: format))
            entries.append(.clip(record))
            return record
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    func snapshot(for id: UUID) throws -> CaptureSnapshot { try imageRecord(id).snapshot }
    func clipSnapshot(for id: UUID) throws -> ClipSnapshot { try clipRecord(id).snapshot }

    /// Longest side of a thumbnail, in pixels.
    private static let thumbnailPixels = 560

    /// The capture as its card shows it: a screenshot with its edits, or a clip's first kept frame
    /// as cropped.
    func thumbnail(for id: UUID) async throws -> CGImage {
        let interval = signposter.beginInterval("CaptureThumbnail", id: signposter.makeSignpostID())
        defer { signposter.endInterval("CaptureThumbnail", interval) }
        try Task.checkCancellation()
        let record: CaptureRecord
        switch try self.record(id) {
        case .image(let image): record = image
        case .clip(let clip): return try await Self.frame(of: clip.snapshot, maximumPixels: CGFloat(Self.thumbnailPixels))
        }
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

    /// One frame of `snapshot` at its trim start, cropped, with its longest side at most `maximumPixels`.
    nonisolated static func frame(of snapshot: ClipSnapshot, maximumPixels: CGFloat) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: snapshot.sourceURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 10)
        let crop = snapshot.edit.cropRect(in: snapshot.pixelSize)
        // Decode large enough that the cropped part still reaches `maximumPixels`.
        let factor = min(1, maximumPixels / max(crop.width, crop.height))
        generator.maximumSize = CGSize(width: snapshot.pixelSize.width * factor, height: snapshot.pixelSize.height * factor)
        let start = snapshot.edit.trimRange(duration: snapshot.duration).lowerBound
        let image = try await generator.image(at: CMTime(seconds: start, preferredTimescale: 600)).image
        guard crop.size != snapshot.pixelSize else { return image }
        let scale = CGFloat(image.width) / snapshot.pixelSize.width
        let rect = CGRect(x: crop.minX * scale, y: crop.minY * scale, width: crop.width * scale, height: crop.height * scale).integral
        guard let cropped = image.cropping(to: rect) else { throw Failure.thumbnail }
        return cropped
    }

    /// Editor-only decode. Thumbnail queues must use thumbnail(for:) instead.
    func image(for id: UUID) throws -> CGImage {
        let interval = signposter.beginInterval("CaptureDecode", id: signposter.makeSignpostID())
        defer { signposter.endInterval("CaptureDecode", interval) }
        try Task.checkCancellation()
        let record = try imageRecord(id)
        guard record.pixelWidth <= ExportService.maximumPixels / record.pixelHeight else { throw ExportService.Failure.resourceLimit }
        let url = record.sourceURL
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw Failure.imageEncoding }
        return image
    }

    func markCopied(_ id: UUID, revision: Int) throws {
        try update(id, revision: revision) { $0.markCopied(revision) }
    }

    func markSaved(_ receipt: ExportReceipt) throws {
        try update(receipt.captureID, revision: receipt.revision) { $0.markSaved(receipt) }
    }

    /// Only document metadata changes. The original source is never rewritten.
    @discardableResult
    func updateDocument(for id: UUID, state: AnnotationDocument, revision: Int) throws -> CaptureRecord {
        guard let index = entries.firstIndex(where: { $0.id == id }), case .image(var current) = entries[index],
              revision >= current.revision else { throw Failure.missingCapture }
        _ = try state.validated(in: CGRect(x: 0, y: 0, width: current.pixelWidth, height: current.pixelHeight))
        if revision == current.revision {
            guard state == (current.documentState ?? AnnotationDocument()) else { throw DocumentRenderer.Failure.invalidDocument }
            return current
        }
        current.revision = revision
        current.documentState = state
        entries[index] = .image(current)
        return current
    }

    /// Stores a clip's edits as `revision`. An older revision arriving late is ignored, so the newest
    /// edits always win. The recorded movie is never rewritten.
    @discardableResult
    func updateEdit(for id: UUID, edit: VideoEdit, revision: Int) throws -> ClipRecord {
        guard let index = entries.firstIndex(where: { $0.id == id }), case .clip(var current) = entries[index] else {
            throw Failure.missingCapture
        }
        guard revision > current.revision else { return current }
        current.revision = revision
        current.edit = edit
        entries[index] = .clip(current)
        return current
    }

    func remove(_ id: UUID) throws {
        let entry = try record(id)
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: entry.sourceURL)
    }

    private func imageRecord(_ id: UUID) throws -> CaptureRecord {
        guard case .image(let record) = try record(id) else { throw Failure.missingCapture }
        return record
    }

    private func clipRecord(_ id: UUID) throws -> ClipRecord {
        guard case .clip(let record) = try record(id) else { throw Failure.missingCapture }
        return record
    }

    private func update(_ id: UUID, revision: Int, change: (inout SessionRecord) -> Void) throws {
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
}
