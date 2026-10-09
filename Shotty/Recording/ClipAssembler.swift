@preconcurrency import AVFoundation
import Foundation

/// Joins a recording's segments into one movie without re-encoding its video. Most players,
/// including browsers and chat apps, play only the first audio track, so a movie with more is
/// mixed down to one. macOS 27 already mixes the microphone into the system audio track.
enum ClipAssembler {
    static func assemble(_ segments: [URL], into url: URL) async throws {
        guard !segments.isEmpty else { throw RecordingFailure.nothingRecorded }
        // Tracks don't keep their assets alive, so the assets stay in scope until the exports finish.
        let assets = segments.map { AVURLAsset(url: $0) }
        var audioTrackCount = 0
        for asset in assets { audioTrackCount = max(audioTrackCount, try await asset.loadTracks(withMediaType: .audio).count) }
        if segments.count == 1, audioTrackCount <= 1 {
            try FileManager.default.moveItem(at: segments[0], to: url)
            return
        }
        let joined = try await join(assets, audioTracks: audioTrackCount)
        let movie: AVAsset
        if audioTrackCount > 1 {
            let mixed = url.deletingLastPathComponent().appendingPathComponent("mixed-audio.m4a")
            try await mixAudio(of: joined, into: mixed)
            movie = try await replacingAudio(of: joined, with: AVURLAsset(url: mixed))
        } else {
            movie = joined
        }
        guard let session = AVAssetExportSession(asset: movie, presetName: AVAssetExportPresetPassthrough) else {
            throw ClipRenderer.Failure.exportUnavailable
        }
        try await session.export(to: url, as: .mp4)
        withExtendedLifetime(assets) {}
        for segment in segments { try? FileManager.default.removeItem(at: segment) }
    }

    /// The segments back to back, with one composition track per audio source.
    private static func join(_ assets: [AVURLAsset], audioTracks: Int) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ClipRenderer.Failure.exportUnavailable
        }
        let audio = (0..<audioTracks).compactMap { _ in
            composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        }
        var cursor = CMTime.zero
        for asset in assets {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { continue }
            let range = try await track.load(.timeRange)
            try video.insertTimeRange(range, of: track, at: cursor)
            for (index, source) in try await asset.loadTracks(withMediaType: .audio).enumerated() where index < audio.count {
                // Audio may start a moment after video; keep it within the video's range.
                let available = try await source.load(.timeRange).intersection(range)
                if !available.isEmpty {
                    try audio[index].insertTimeRange(available, of: source, at: cursor + (available.start - range.start))
                }
            }
            cursor = cursor + range.duration
        }
        guard cursor > .zero else { throw RecordingFailure.nothingRecorded }
        return composition
    }

    /// An audio-only export mixes every audio track into one; a video export would keep them apart.
    private static func mixAudio(of composition: AVMutableComposition, into url: URL) async throws {
        let audioOnly = AVMutableComposition()
        for track in try await composition.loadTracks(withMediaType: .audio) {
            let range = try await track.load(.timeRange)
            try audioOnly.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(range, of: track, at: range.start)
        }
        guard let session = AVAssetExportSession(asset: audioOnly, presetName: AVAssetExportPresetAppleM4A) else {
            throw ClipRenderer.Failure.exportUnavailable
        }
        try await session.export(to: url, as: .m4a)
    }

    private static func replacingAudio(of composition: AVMutableComposition, with audio: AVURLAsset) async throws -> AVMutableComposition {
        let movie = AVMutableComposition()
        for track in try await composition.loadTracks(withMediaType: .video) {
            let range = try await track.load(.timeRange)
            try movie.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(range, of: track, at: range.start)
        }
        if let mixed = try await audio.loadTracks(withMediaType: .audio).first {
            let range = try await mixed.load(.timeRange).intersection(CMTimeRange(start: .zero, duration: movie.duration))
            try movie.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(range, of: mixed, at: .zero)
        }
        withExtendedLifetime(audio) {}
        return movie
    }
}
