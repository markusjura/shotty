import Foundation

/// Writes one looping GIF from GIFs that Image I/O encoded for consecutive runs of frames. Image I/O
/// keeps every frame of a GIF in memory until it finalizes the file, so a long clip is encoded in
/// runs and joined here. The first run gives the file its header, loop count, and global palette;
/// later runs give only their frames, each carrying its run's palette as a local one.
struct GIFWriter {
    enum Failure: Error { case malformed }

    private let handle: FileHandle
    private var started = false

    /// Creates the file at `url`, which must not exist yet.
    init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path),
              FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteFileExists) }
        handle = try FileHandle(forWritingTo: url)
    }

    /// Appends the frames of `gif`, a complete GIF file.
    mutating func append(_ gif: Data) throws {
        let bytes = [UInt8](gif)
        guard bytes.count >= 13, bytes.starts(with: Array("GIF".utf8)) else { throw Failure.malformed }
        let screen = bytes[10]
        let paletteEnd = 13 + Self.paletteSize(flags: screen)
        guard bytes.count >= paletteEnd else { throw Failure.malformed }
        let palette = bytes[13..<paletteEnd]
        // Extensions such as frame delays need GIF89a; Image I/O labels its files GIF87a.
        var output = started ? [] : Array("GIF89a".utf8) + bytes[6..<paletteEnd]
        var index = paletteEnd
        while index < bytes.count {
            switch bytes[index] {
            case 0x3B: // Trailer.
                try handle.write(contentsOf: output)
                started = true
                return
            case 0x21: // Extension: label, then data sub-blocks.
                let end = try Self.subBlocksEnd(bytes, from: index + 2)
                // Later runs keep only frame timing; the loop count comes from the first.
                if !started || bytes[index + 1] == 0xF9 { output += bytes[index..<end] }
                index = end
            case 0x2C: // Image: descriptor, optional local palette, LZW code size, data sub-blocks.
                guard index + 10 <= bytes.count else { throw Failure.malformed }
                let flags = bytes[index + 9]
                let dataStart = index + 10 + Self.paletteSize(flags: flags)
                let end = try Self.subBlocksEnd(bytes, from: dataStart + 1)
                if started, flags & 0x80 == 0 {
                    // Keep interlacing, and describe the run's global palette as this frame's own.
                    guard !palette.isEmpty else { throw Failure.malformed }
                    output += bytes[index..<index + 9]
                    output.append(0x80 | (flags & 0x40) | (screen & 0x07))
                    output += palette
                    output += bytes[dataStart..<end]
                } else {
                    output += bytes[index..<end]
                }
                index = end
            default:
                throw Failure.malformed
            }
        }
        throw Failure.malformed
    }

    /// Ends the animation and closes the file.
    func finish() throws {
        try handle.write(contentsOf: [0x3B])
        try handle.close()
    }

    /// Bytes of the palette that `flags` announces, a screen's or a frame's; both keep the palette
    /// flag in bit 7 and its size in bits 0 to 2.
    private static func paletteSize(flags: UInt8) -> Int {
        flags & 0x80 == 0 ? 0 : 3 << (Int(flags & 0x07) + 1)
    }

    /// The index just past the empty sub-block that ends the sub-blocks starting at `start`.
    private static func subBlocksEnd(_ bytes: [UInt8], from start: Int) throws -> Int {
        var index = start
        while index < bytes.count {
            let length = Int(bytes[index])
            index += 1 + length
            if length == 0 { return index }
        }
        throw Failure.malformed
    }
}
