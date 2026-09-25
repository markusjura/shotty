import XCTest
@testable import Shotty

final class AtomicFileTests: XCTestCase {
    func testStreamingFailureAndCancellationPreserveDestinationAndRemoveStages() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-staged-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("source.png")
        let original = Data("existing image".utf8)
        try original.write(to: destination)

        for cancelBeforePublish in [false, true] {
            do {
                try AtomicFile.write(to: destination, replacing: true, beforePublish: {
                    if cancelBeforePublish { throw CancellationError() }
                }) { stage in
                    let permissions = try FileManager.default.attributesOfItem(atPath: stage.path)[.posixPermissions] as? Int
                    XCTAssertEqual(permissions, 0o600)
                    try Data("partially or fully encoded image".utf8).write(to: stage)
                    if !cancelBeforePublish { throw CocoaError(.fileWriteUnknown) }
                }
                XCTFail("The staged write must fail")
            } catch {}
            XCTAssertEqual(try Data(contentsOf: destination), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.png"])
        }
    }

    func testStreamingPublicationProtectsEncoderReplacementAndDoesNotOverwrite() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-staged-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("source.png")
        let encoded = Data("encoded output".utf8)
        try AtomicFile.write(to: destination) { stage in
            // Some encoders replace their destination inode; publication must flush/protect that file.
            try FileManager.default.removeItem(at: stage)
            try encoded.write(to: stage)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: stage.path)
        }
        XCTAssertEqual(try Data(contentsOf: destination), encoded)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int, 0o600)
        do {
            try AtomicFile.write(to: destination) { try Data("replacement".utf8).write(to: $0) }
            XCTFail("An existing output requires explicit replacement")
        } catch let error as POSIXError { XCTAssertEqual(error.code, .EEXIST) }
        XCTAssertEqual(try Data(contentsOf: destination), encoded)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["source.png"])
    }
}
