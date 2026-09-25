import Foundation

enum SaveDestinationStatus: Equatable, Sendable {
    case available, missing, notFolder, notWritable

    var message: String? {
        switch self {
        case .available: nil
        case .missing: "This folder no longer exists or its volume is disconnected. Choose another folder."
        case .notFolder: "This location is not a folder. Choose another folder."
        case .notWritable: "Shotty cannot write to this folder. Choose another folder or change its permissions."
        }
    }
}

enum SaveDestinationCheck {
    /// Metadata only; cheap enough for status displays.
    static func status(of url: URL) -> SaveDestinationStatus {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return .missing }
        guard isDirectory.boolValue else { return .notFolder }
        return FileManager.default.isWritableFile(atPath: url.path) ? .available : .notWritable
    }

    /// Proves write access by creating and removing a hidden probe file.
    /// Call only for an explicit folder choice, not on every status refresh.
    static func verifyWritable(_ url: URL) -> SaveDestinationStatus {
        let metadata = status(of: url)
        guard metadata == .available else { return metadata }
        let probe = url.appendingPathComponent(".shotty-write-check-\(UUID().uuidString)")
        do {
            try Data().write(to: probe, options: .withoutOverwriting)
            try? FileManager.default.removeItem(at: probe)
            return .available
        } catch {
            return .notWritable
        }
    }
}
