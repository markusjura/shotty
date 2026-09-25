import XCTest
@testable import Shotty

final class DismissAllTests: XCTestCase {
    func testOnlyCurrentRevisionsNeitherSavedNorCopiedCountAsUnexported() {
        func record(revision: Int, copied: Int?, saved: Int?) -> CaptureRecord {
            CaptureRecord(id: UUID(), kind: .area, createdAt: Date(), pixelWidth: 1, pixelHeight: 1, sourceScale: 1,
                          sourceURL: URL(fileURLWithPath: "/dev/null"), revision: revision,
                          copiedRevision: copied, savedRevision: saved, outputFile: nil, documentState: nil)
        }
        let saved = record(revision: 2, copied: nil, saved: 2)
        let copied = record(revision: 1, copied: 1, saved: nil)
        let editedAfterSave = record(revision: 3, copied: 2, saved: 2)
        let untouched = record(revision: 0, copied: nil, saved: nil)
        let records = [saved, copied, editedAfterSave, untouched]
        XCTAssertEqual(AppCoordinator.unexportedCount(of: records.map(\.id), in: records), 2)
        XCTAssertEqual(AppCoordinator.unexportedCount(of: [saved.id, copied.id], in: records), 0)
        XCTAssertEqual(AppCoordinator.unexportedCount(of: [UUID()], in: records), 1, "Unknown captures are never assumed exported")
    }
}
