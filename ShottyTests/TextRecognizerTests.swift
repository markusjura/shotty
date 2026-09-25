import AppKit
import XCTest
@testable import Shotty

final class TextRecognizerTests: XCTestCase {
    func testJoiningMergesOnlySoftWrappedLines() {
        let result = RecognizedTextResult(lines: [
            RecognizedLine(text: "A sentence that", confidence: 0.9, wrapsToNextLine: true),
            RecognizedLine(text: "wraps here.", confidence: 0.9, wrapsToNextLine: false),
            RecognizedLine(text: "Separate line", confidence: 0.3, wrapsToNextLine: false),
        ])
        XCTAssertEqual(result.text(preservingLineBreaks: true), "A sentence that\nwraps here.\nSeparate line")
        XCTAssertEqual(result.text(preservingLineBreaks: false), "A sentence that wraps here.\nSeparate line")
        XCTAssertEqual(result.lowConfidenceLines.map(\.text), ["Separate line"])
        XCTAssertTrue(RecognizedTextResult(lines: [RecognizedLine(text: "  ", confidence: 1, wrapsToNextLine: false)]).isEmpty)
    }

    func testSavedTextIsUTF8AndNeverOverwritesAnExistingFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("shotty-text-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try TextRecognizer.saveText("Grüße 👋", in: directory, template: "{type} {date}", date: date)
        let second = try TextRecognizer.saveText("second", in: directory, template: "{type} {date}", date: date)
        XCTAssertEqual(first.pathExtension, "txt")
        XCTAssertEqual(second.lastPathComponent, first.deletingPathExtension().lastPathComponent + "-2.txt")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "Grüße 👋")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }

    func testRecognizesRenderedLinesInReadingOrderOnDevice() async throws {
        let size = CGSize(width: 900, height: 260)
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                              bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(origin: .zero, size: size))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]
        ("Shotty reads this" as NSString).draw(at: CGPoint(x: 40, y: 150), withAttributes: attributes)
        ("Second line 2026" as NSString).draw(at: CGPoint(x: 40, y: 50), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        let image = try XCTUnwrap(context.makeImage())

        let result = try await TextRecognizer.recognize(image, preferences: TextCapturePreferences())
        XCTAssertEqual(result.text(preservingLineBreaks: true), "Shotty reads this\nSecond line 2026")
    }
}
