import CoreGraphics
import Foundation
import Vision

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

    /// Writes UTF-8 text with the image filename rules; existing files get -2, -3, and so on.
    static func saveText(_ text: String, in directory: URL, template: String, date: Date) throws -> URL {
        let stem = ExportService.filenameStem(template: template, date: date, kind: .text)
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
