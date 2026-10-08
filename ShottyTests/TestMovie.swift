import AVFoundation
import CoreVideo
import XCTest

/// Small H.264 movies for tests, shaped like Shotty's recordings. Frames are split into four
/// quadrants: red top left, green top right, blue bottom left, and bottom right white for the
/// first second, then black. Optional AAC tone tracks stand in for system audio and microphone.
enum TestMovie {
    struct Color: Equatable, CustomStringConvertible {
        let red: Int, green: Int, blue: Int
        static let red = Color(red: 255, green: 0, blue: 0)
        static let green = Color(red: 0, green: 255, blue: 0)
        static let blue = Color(red: 0, green: 0, blue: 255)
        static let white = Color(red: 255, green: 255, blue: 255)
        static let black = Color(red: 0, green: 0, blue: 0)

        /// Video compression shifts colors a little, so channels match within `tolerance`.
        func matches(_ other: Color, tolerance: Int = 48) -> Bool {
            abs(red - other.red) <= tolerance && abs(green - other.green) <= tolerance && abs(blue - other.blue) <= tolerance
        }

        var description: String { "(\(red), \(green), \(blue))" }
    }

    /// Writes a movie to `url`, which must not exist.
    static func make(at url: URL, width: Int = 160, height: Int = 120, seconds: Double = 2, fps: Int32 = 30,
                     audioTracks: Int = 0) async throws {
        guard audioTracks > 0 else { return try await writeVideo(to: url, width: width, height: height, seconds: seconds, fps: fps) }
        let folder = url.deletingLastPathComponent()
        let video = folder.appendingPathComponent("video-\(UUID()).mp4")
        let tone = folder.appendingPathComponent("tone-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: video); try? FileManager.default.removeItem(at: tone) }
        try await writeVideo(to: video, width: width, height: height, seconds: seconds, fps: fps)
        try writeTone(to: tone, seconds: seconds)
        let composition = AVMutableComposition()
        // A track doesn't keep its asset alive, so both assets stay in scope until the export.
        let videoAsset = AVURLAsset(url: video), toneAsset = AVURLAsset(url: tone)
        let videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        let videoTrack = try XCTUnwrap(videoTracks.first)
        let range = try await videoTrack.load(.timeRange)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(range, of: videoTrack, at: .zero)
        let toneTracks = try await toneAsset.loadTracks(withMediaType: .audio)
        let toneTrack = try XCTUnwrap(toneTracks.first)
        let toneRange = try await toneTrack.load(.timeRange).intersection(range)
        for _ in 0..<audioTracks {
            try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
                .insertTimeRange(toneRange, of: toneTrack, at: .zero)
        }
        let session = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await session.export(to: url, as: .mp4)
        withExtendedLifetime((videoAsset, toneAsset)) {}
    }

    private static func writeVideo(to url: URL, width: Int, height: Int, seconds: Double, fps: Int32) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<Int((seconds * Double(fps)).rounded()) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            let time = CMTime(value: CMTimeValue(frame), timescale: fps)
            let buffer = try pixelBuffer(width: width, height: height, laterThanOneSecond: time.seconds >= 1)
            guard adaptor.append(buffer, withPresentationTime: time) else { throw try XCTUnwrap(writer.error) }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw try XCTUnwrap(writer.error) }
    }

    private static func pixelBuffer(width: Int, height: Int, laterThanOneSecond: Bool) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixels = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels))
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixels)
        /// One BGRA row: `left` up to the middle, `right` after it.
        func row(_ left: Color, _ right: Color) -> [UInt8] {
            (0..<width).flatMap { x -> [UInt8] in
                let color = x < width / 2 ? left : right
                return [UInt8(color.blue), UInt8(color.green), UInt8(color.red), 255]
            }
        }
        let top = row(.red, .green), bottom = row(.blue, laterThanOneSecond ? .black : .white)
        for y in 0..<height {
            (y < height / 2 ? top : bottom).withUnsafeBytes { (base + y * bytesPerRow).copyMemory(from: $0.baseAddress!, byteCount: width * 4) }
        }
        return pixels
    }

    private static func writeTone(to url: URL, seconds: Double) throws {
        let rate = 44_100.0
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(rate * seconds)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<Int(frames) { samples[index] = Float(0.2 * sin(2 * .pi * 440 * Double(index) / rate)) }
        try file.write(from: buffer)
        file.close()
    }

    // MARK: Reading results

    /// Duration, frame size, and track counts of the movie at `url`.
    static func describe(_ url: URL) async throws -> (duration: Double, size: CGSize, videoTracks: Int, audioTracks: Int) {
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let size = try await video.first?.load(.naturalSize) ?? .zero
        return (try await asset.load(.duration).seconds, size, video.count, audio.count)
    }

    /// The frame of the movie at `url` nearest to `seconds`.
    static func frame(of url: URL, at seconds: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    /// The color at a point given as fractions of the image's width and height, from the top left.
    static func color(of image: CGImage, x: Double, y: Double) throws -> Color {
        let width = 1, height = 1
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 4,
                                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Draw the image so the requested point lands on the single pixel.
        let px = Double(image.width) * x, py = Double(image.height) * (1 - y)
        context.draw(image, in: CGRect(x: -px + 0.5, y: -py + 0.5, width: Double(image.width), height: Double(image.height)))
        return Color(red: Int(pixel[0]), green: Int(pixel[1]), blue: Int(pixel[2]))
    }
}
