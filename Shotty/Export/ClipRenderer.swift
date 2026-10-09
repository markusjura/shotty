@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct RenderOptions: Hashable, Sendable {
    var codec = VideoCodecPreference.h264
    var gifFrameRate = 15
}

/// Turns a clip snapshot into an MP4 or GIF file through AVFoundation. Stateless; the exporter
/// decides where files go and caches them.
enum ClipRenderer {
    enum Failure: LocalizedError {
        case noVideo, exportUnavailable, gifEncoding

        var errorDescription: String? {
            switch self {
            case .noVideo: "The clip's recording has no video track."
            case .exportUnavailable: "This Mac can't encode the clip with the chosen settings. Try H.264."
            case .gifEncoding: "The GIF could not be written. Check available disk space and try again."
            }
        }
    }

    /// Memory one run of GIF frames may take. Image I/O holds about 12 bytes per pixel of every
    /// frame until it finalizes a GIF.
    private static let gifRunBytes = 512 << 20

    /// Writes `snapshot` to `url`, which must not exist yet.
    static func render(_ snapshot: ClipSnapshot, options: RenderOptions, to url: URL) async throws {
        try Task.checkCancellation()
        if snapshot.edit.isPassthrough(sourceSize: snapshot.pixelSize, sourceDuration: snapshot.duration) {
            // A clone on APFS: instant and no extra space.
            try FileManager.default.copyItem(at: snapshot.sourceURL, to: url)
            return
        }
        let composition = try await makeComposition(snapshot)
        switch snapshot.edit.format {
        case .mp4: try await encodeMovie(composition, codec: options.codec, to: url)
        case .gif: try await encodeGIF(composition, frameRate: options.gifFrameRate, to: url)
        }
    }

    struct Composition: @unchecked Sendable {
        let asset: AVMutableComposition
        let video: AVVideoComposition
        let duration: CMTime
    }

    /// The trimmed, sped-up, cropped, and scaled clip as a composition the encoders and the
    /// editor's frame generator share.
    static func makeComposition(_ snapshot: ClipSnapshot) async throws -> Composition {
        let source = AVURLAsset(url: snapshot.sourceURL)
        guard let sourceVideo = try await source.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let edit = snapshot.edit
        let trim = edit.trimRange(duration: snapshot.duration)
        let range = CMTimeRange(start: CMTime(seconds: trim.lowerBound, preferredTimescale: 6000),
                                end: CMTime(seconds: trim.upperBound, preferredTimescale: 6000))
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.exportUnavailable
        }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        if !edit.removesAudio {
            for track in try await source.loadTracks(withMediaType: .audio) {
                let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try audio?.insertTimeRange(range, of: track, at: .zero)
            }
        }
        if edit.speed != .normal {
            composition.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration),
                                       toDuration: CMTimeMultiplyByFloat64(range.duration, multiplier: 1 / edit.speed.rawValue))
        }
        let crop = edit.cropRect(in: snapshot.pixelSize)
        let renderSize = edit.renderSize(source: snapshot.pixelSize)
        let scale = renderSize.width / crop.width
        var layer = AVVideoCompositionLayerInstruction.Configuration(assetTrack: video)
        // Points move by the crop origin first, then scale; frames use a top-left origin.
        layer.setTransform(CGAffineTransform(scaleX: scale, y: renderSize.height / crop.height)
            .translatedBy(x: -crop.minX, y: -crop.minY), at: .zero)
        let instruction = AVVideoCompositionInstruction(configuration: .init(
            layerInstructions: [AVVideoCompositionLayerInstruction(configuration: layer)],
            timeRange: CMTimeRange(start: .zero, duration: composition.duration)))
        let rate = try await sourceVideo.load(.nominalFrameRate)
        let fps = Int32(min(60, max(10, rate.isFinite && rate > 0 ? rate.rounded() : 30)))
        let videoComposition = AVVideoComposition(configuration: .init(
            frameDuration: CMTime(value: 1, timescale: fps), instructions: [instruction], renderSize: renderSize))
        return Composition(asset: composition, video: videoComposition, duration: composition.duration)
    }

    private static func encodeMovie(_ composition: Composition, codec: VideoCodecPreference, to url: URL) async throws {
        let preset = codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: composition.asset, presetName: preset) else { throw Failure.exportUnavailable }
        session.videoComposition = composition.video
        // Sped-up speech keeps its pitch.
        session.audioTimePitchAlgorithm = .spectral
        session.shouldOptimizeForNetworkUse = true
        try await session.export(to: url, as: .mp4)
    }

    /// Frames at `frameRate`, looping forever, as chat apps and pull requests expect. Image I/O
    /// shares one palette across a GIF's frames and stores only what changes between them, which
    /// keeps GIFs small, but it holds every frame until it finalizes the file. Frames are therefore
    /// encoded in runs that fit `gifRunBytes` and joined by `GIFWriter`. Each frame is generated on
    /// its own, since a batch request decodes far ahead of the encoder.
    private static func encodeGIF(_ composition: Composition, frameRate: Int, to url: URL) async throws {
        let size = composition.video.renderSize
        let count = max(1, Int((composition.duration.seconds * Double(frameRate)).rounded(.down)))
        let framesPerRun = max(1, gifRunBytes / max(1, Int(size.width * size.height) * 12))
        let generator = AVAssetImageGenerator(asset: composition.asset)
        generator.videoComposition = composition.video
        let tolerance = CMTime(seconds: 0.5 / Double(frameRate), preferredTimescale: 6000)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        // GIF delays are whole hundredths of a second. Rounding each frame's start instead of its
        // length mixes 6 and 7 at 15 fps, so the GIF keeps the clip's pace.
        let centiseconds = { (frame: Int) in Int((Double(frame) * 100 / Double(frameRate)).rounded()) }
        var writer = try GIFWriter(url: url)
        for start in stride(from: 0, to: count, by: framesPerRun) {
            let frames = start..<min(count, start + framesPerRun)
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else {
                throw Failure.gifEncoding
            }
            CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
            for index in frames {
                try Task.checkCancellation()
                let time = CMTime(seconds: Double(index) / Double(frameRate), preferredTimescale: 6000)
                let frame = try await generator.image(at: time).image
                let delay = Double(centiseconds(index + 1) - centiseconds(index)) / 100
                CGImageDestinationAddImage(destination, frame, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
            }
            guard CGImageDestinationFinalize(destination) else { throw Failure.gifEncoding }
            try writer.append(data as Data)
        }
        try writer.finish()
    }
}
