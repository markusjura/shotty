import CoreGraphics
import ImageIO
import XCTest
@testable import Shotty

@MainActor
final class ExportServiceTests: XCTestCase {
    private func fixture() async throws -> (directory: URL, snapshot: CaptureSnapshot) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-export-tests-\(UUID())")
        let store = CaptureSessionStore(directory: directory.appendingPathComponent("session"))
        let context = try XCTUnwrap(CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 80,
                                             space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // Transparent background exercises JPEG's white matte; the right half is opaque red.
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 0, width: 10, height: 10))
        let record = try await store.create(image: XCTUnwrap(context.makeImage()), kind: .window, scale: 2)
        return (directory, record.snapshot)
    }

    func testNativeAndLogicalExportsPreserveOrConvertProfileAndMatteJPEG() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ExportService()
        let native = try decode(await service.encodedData(fixture.snapshot))
        XCTAssertEqual(native.width, 20)
        XCTAssertEqual(native.height, 10)
        XCTAssertEqual(native.colorSpace?.name, CGColorSpace.displayP3)
        let logical = try decode(await service.encodedData(fixture.snapshot, options: .init(scale: .logical, color: .sRGB)))
        XCTAssertEqual(logical.width, 10)
        XCTAssertEqual(logical.height, 5)
        XCTAssertEqual(logical.colorSpace?.name, CGColorSpace.sRGB)
        let jpegBytes = try await service.encodedData(fixture.snapshot, options: .init(format: .jpeg))
        let jpeg = try decode(jpegBytes)
        XCTAssertEqual(jpeg.colorSpace?.name, CGColorSpace.displayP3)
        XCTAssertEqual(Array(jpegBytes.prefix(2)), [0xFF, 0xD8])
        let white = try sample(jpeg, x: 1, y: 1)
        XCTAssertGreaterThan(white[0], 245)
        XCTAssertGreaterThan(white[1], 245)
        XCTAssertGreaterThan(white[2], 245)
        XCTAssertEqual(white[3], 255)
        XCTAssertEqual(try sample(native, x: 1, y: 1)[3], 0)
        let darkJPEG = try decode(await service.encodedData(fixture.snapshot, options: .init(format: .jpeg, jpegBackground: .black)))
        let dark = try sample(darkJPEG, x: 1, y: 1)
        XCTAssertLessThan(dark[0], 10)
        XCTAssertLessThan(dark[1], 10)
        XCTAssertLessThan(dark[2], 10)
        XCTAssertEqual(dark[3], 255)
    }

    func testCollisionSuffixesAndNoSilentOverwrite() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ExportService()
        let original = fixture.directory.appendingPathComponent("Example.png")
        let sentinel = Data("existing file".utf8)
        try sentinel.write(to: original)
        let second = try await service.export(fixture.snapshot, to: fixture.directory, filenameTemplate: "Example")
        let third = try await service.export(fixture.snapshot, to: fixture.directory, filenameTemplate: "Example")
        XCTAssertEqual(second.destinationURL.lastPathComponent, "Example-2.png")
        XCTAssertEqual(third.destinationURL.lastPathComponent, "Example-3.png")
        XCTAssertEqual(try Data(contentsOf: original), sentinel)
        do {
            _ = try await service.save(fixture.snapshot, to: original)
            XCTFail("Save As cannot silently overwrite")
        } catch ExportService.Failure.destinationExists(let url) { XCTAssertEqual(url, original) }
        XCTAssertEqual(try Data(contentsOf: original), sentinel)
        XCTAssertEqual(second.revision, fixture.snapshot.revision)
    }

    func testChangedAssociatedOutputRequiresExplicitReplacement() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ExportService()
        let saved = try await service.export(fixture.snapshot, to: fixture.directory)
        var changed = try Data(contentsOf: saved.destinationURL)
        changed[changed.count - 1] ^= 1
        try changed.write(to: saved.destinationURL)
        do {
            _ = try await service.save(fixture.snapshot, to: saved.destinationURL, replacing: saved.fingerprint)
            XCTFail("Same-length external edits must be detected")
        } catch ExportService.Failure.externallyModified(let url) { XCTAssertEqual(url, saved.destinationURL) }
        XCTAssertEqual(try Data(contentsOf: saved.destinationURL), changed)
        let current = try await service.fingerprint(at: saved.destinationURL)
        let replaced = try await service.save(fixture.snapshot, to: saved.destinationURL, replacing: current)
        XCTAssertEqual(replaced.fingerprint, saved.fingerprint)
        _ = try decode(Data(contentsOf: replaced.destinationURL))
    }

    func testFailedPublicationLeavesSourceAndNoTemporaryFiles() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let service = ExportService()
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted()
        do {
            _ = try await service.save(fixture.snapshot, to: fixture.directory.appendingPathComponent("absent/image.png"))
            XCTFail("Missing destination folder must fail")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).sorted(), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.snapshot.sourceURL.path))
        _ = try await service.export(fixture.snapshot, to: fixture.directory)
    }

    func testExternalChangeDuringStagingPreventsPublication() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-atomic-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("saved.png")
        let existing = Data("previous export".utf8)
        let changed = Data("external change".utf8)
        try existing.write(to: destination)
        let expected = try FileFingerprint.read(at: destination)
        do {
            try AtomicFile.write(Data("new export".utf8), to: destination, replacing: true, beforePublish: {
                try changed.write(to: destination)
                guard try FileFingerprint.read(at: destination) == expected else {
                    throw ExportService.Failure.externallyModified(destination)
                }
            })
            XCTFail("An output changed before publication must remain untouched")
        } catch ExportService.Failure.externallyModified {}
        XCTAssertEqual(try Data(contentsOf: destination), changed)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["saved.png"])
    }

    func testFilenameTemplateUsesOnlySupportedFieldsAndNormalizesFilesystemCharacters() {
        let date = Date(timeIntervalSince1970: 0)
        let zone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(ExportService.filenameStem(template: ExportService.defaultFilenameTemplate, date: date, kind: .area, timeZone: zone),
                       "Shotty 1970-01-01 at 00.00.00")
        XCTAssertEqual(ExportService.filenameStem(template: "../{type}: {date}/\n", date: date, kind: .window, timeZone: zone),
                       "-window- 1970-01-01--")
        XCTAssertEqual(ExportService.filenameStem(template: "...", date: date, kind: .area, timeZone: zone),
                       "Shotty 1970-01-01 at 00.00.00")
    }

    private func decode(_ bytes: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(bytes as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func sample(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let success = bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(success)
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<(offset + 4)])
    }
}
