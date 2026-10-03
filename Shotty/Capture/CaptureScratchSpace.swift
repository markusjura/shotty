import Foundation

/// Only transient capture rasters live here. Durable documents use CaptureSessionStore.
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
}
