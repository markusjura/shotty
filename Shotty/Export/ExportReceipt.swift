import CryptoKit
import Foundation

/// A finished save of one capture revision.
struct ExportReceipt: Equatable, Sendable {
    let captureID: UUID
    let revision: Int
    let destinationURL: URL
    let fingerprint: FileFingerprint
}

/// Where a capture was saved last, so the editor's Save can update that file.
struct ExportedFile: Codable, Equatable, Sendable {
    let url: URL
    let fingerprint: FileFingerprint
}

/// Notices another app changing a saved file, so a later save never overwrites it unasked.
/// Screenshots compare a content hash, which catches edits that keep the size and date. Clips
/// compare size and modification date, since hashing hundreds of megabytes of video would slow
/// every save.
enum FileFingerprint: Codable, Equatable, Sendable {
    case sha256(String)
    case attributes(size: Int, modified: Date)

    init(hashing data: Data) {
        self = .sha256(Self.hex(SHA256.hash(data: data)))
    }

    init(hashingFileAt url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        self = .sha256(Self.hex(hash.finalize()))
    }

    /// Reads the file system directly. `URL.resourceValues` caches on the URL, so a URL kept from an
    /// earlier save would report the file as it was then.
    init(attributesOf url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        self = .attributes(size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
                           modified: attributes[.modificationDate] as? Date ?? .distantPast)
    }

    /// True while the file at `url` reads the same as when this fingerprint was taken.
    func matchesFile(at url: URL) -> Bool {
        let current = switch self {
        case .sha256: try? FileFingerprint(hashingFileAt: url)
        case .attributes: try? FileFingerprint(attributesOf: url)
        }
        return current == self
    }

    private static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }
}
