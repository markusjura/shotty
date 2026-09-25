import Darwin
import Foundation

/// Stages in the destination directory, flushes bytes, then publishes one complete file.
enum AtomicFile {
    static func write(_ data: Data, to destination: URL, replacing: Bool = false,
                      beforePublish: () throws -> Void = {}) throws {
        try write(to: destination, replacing: replacing, beforePublish: beforePublish) { temporary in
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
        }
    }

    /// Encoders write directly into a private staging file. The callback must finish and close its
    /// writer before returning; this reopens the final file in case the encoder replaced its inode.
    static func write(to destination: URL, replacing: Bool = false,
                      beforePublish: () throws -> Void = {}, writeStaged: (URL) throws -> Void) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".shotty-\(UUID()).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        close(descriptor)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try writeStaged(temporary)
        let written = open(temporary.path, O_RDWR | O_NOFOLLOW)
        guard written >= 0 else { throw posixError() }
        defer { close(written) }
        guard fchmod(written, 0o600) == 0, fsync(written) == 0 else { throw posixError() }
        try beforePublish()
        let result = replacing ? rename(temporary.path, destination.path)
                               : renamex_np(temporary.path, destination.path, UInt32(RENAME_EXCL))
        guard result == 0 else { throw posixError() }
        // A flushed rename survives process interruption. Flush directory metadata as well.
        let directory = open(destination.deletingLastPathComponent().path, O_RDONLY)
        if directory >= 0 { _ = fsync(directory); close(directory) }
    }

    static func posixError() -> POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
}
