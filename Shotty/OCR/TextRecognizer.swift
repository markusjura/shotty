import CoreGraphics
import CoreText
import Foundation
import Vision
import os

struct RecognizedLine: Equatable, Sendable {
    let text: String
    let confidence: Float
    /// Vision's judgment that the next line continues this one after a soft wrap.
    let wrapsToNextLine: Bool
}

/// On-device recognition output in Vision's reading order. Low-confidence lines are
/// reported to the user; they are never rewritten.
struct RecognizedTextResult: Equatable, Sendable {
    static let lowConfidenceThreshold: Float = 0.5

    let lines: [RecognizedLine]

    var isEmpty: Bool { lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    var lowConfidenceLines: [RecognizedLine] { lines.filter { $0.confidence < Self.lowConfidenceThreshold } }

    /// Joining only merges lines Vision marks as soft-wrapped; separate lines stay separate.
    func text(preservingLineBreaks: Bool) -> String {
        var result = ""
        for (index, line) in lines.enumerated() {
            result += line.text
            guard index < lines.count - 1 else { break }
            result += !preservingLineBreaks && line.wrapsToNextLine ? " " : "\n"
        }
        return result
    }
}

enum TextRecognizer {
    /// Accurate on-device recognition. Manual languages keep their configured order.
    static func recognize(_ image: CGImage, preferences: TextCapturePreferences) async throws -> RecognizedTextResult {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = preferences.detectsLanguageAutomatically
        if !preferences.detectsLanguageAutomatically {
            request.recognitionLanguages = preferences.languages.map { Locale.Language(identifier: $0) }
        }
        let observations = try await request.perform(on: image)
        try Task.checkCancellation()
        return RecognizedTextResult(lines: observations.compactMap { observation in
            observation.topCandidates(1).first.map {
                RecognizedLine(text: $0.string, confidence: $0.confidence,
                               wrapsToNextLine: observation.shouldWrapToNextLine ?? false)
            }
        })
    }

    /// Has macOS compile Vision's text models for Shotty before a capture needs them. macOS compiles
    /// them for each app on first use after every system update, which takes about a minute even on
    /// an M4 Max, and keeps them afterwards, when recognition takes a fraction of a second. Launch runs
    /// this in the background, so the first Capture Text after an update doesn't wait.
    static func prepare(preferences: TextCapturePreferences) async {
        let started = ContinuousClock.now
        // Latin text compiles the models every capture uses. Automatic language detection needs two
        // more, which Arabic and Devanagari text compile, and Vision also loads them for many Latin
        // screenshots. Each line needs its own image: in a shared one, Vision skipped the Devanagari
        // line. A capture waits while any model compiles, so the models every capture needs go first.
        for line in ["Shotty recognizes text", "التعرف على النص", "पाठ की पहचान"] {
            guard let sample = sampleText(line) else { continue }
            _ = try? await recognize(sample, preferences: preferences)
        }
        Logger(subsystem: "local.markus.Shotty", category: "CaptureText")
            .info("Prepared text recognition in \(started.duration(to: .now), privacy: .public)")
    }

    /// One line of black text on white.
    private static func sampleText(_ line: String) -> CGImage? {
        guard let font = CTFontCreateUIFontForLanguage(.system, 32, nil),
              let context = CGContext(data: nil, width: 480, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 480, height: 64))
        context.textPosition = CGPoint(x: 16, y: 20)
        // Core Text falls back to fonts with the Arabic and Devanagari glyphs.
        let text = NSAttributedString(string: line, attributes: [.init(kCTFontAttributeName as String): font])
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        return context.makeImage()
    }

    /// Writes UTF-8 text with the image filename rules; existing files get -2, -3, and so on.
    static func saveText(_ text: String, in directory: URL, date: Date) throws -> URL {
        let stem = ExportService.filenameStem(date: date)
        let data = Data(text.utf8)
        var suffix = 1
        while true {
            let url = directory.appendingPathComponent("\(stem)\(suffix == 1 ? "" : "-\(suffix)").txt")
            do {
                try AtomicFile.write(data, to: url)
                return url
            } catch let error as POSIXError where error.code == .EEXIST {
                suffix += 1
            }
        }
    }
}
