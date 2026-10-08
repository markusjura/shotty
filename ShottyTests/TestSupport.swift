import XCTest
@testable import Shotty

/// A temporary folder removed when the test ends.
func makeTemporaryFolder(_ test: XCTestCase) throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ShottyTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
    return folder
}

extension SessionRecord {
    /// The screenshot, for tests that reopen it in an editor.
    var image: CaptureRecord? { if case .image(let record) = self { record } else { nil } }
}
