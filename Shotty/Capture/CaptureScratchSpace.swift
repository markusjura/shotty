import Foundation

/// Transient files: frozen selection rasters, recordings in progress, and the files copies and
/// drags hand to other apps. Receivers may read a copied or dragged file long after the drop, so
/// those stay until the next launch clears the folder. Kept captures live in `CaptureSessionStore`.
enum CaptureScratchSpace {
    static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(Bundle.main.appName)-CaptureScratch", isDirectory: true)
    }
    static func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }
    static func cleanPreviousLaunch() throws {
        try prepare()
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// A fresh folder for one file, so every copy and drag keeps its own name.
    static func makeFolder() throws -> URL {
        try prepare()
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        return folder
    }
}
