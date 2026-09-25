import AppKit
import Observation

/// Runs Capture Text after selection: recognition off the main actor, then the independent
/// copy, review, and save outputs frozen in the capture's settings. Empty results and errors
/// leave the clipboard unchanged; a cancelled or superseded recognition never publishes.
@MainActor @Observable
final class TextCaptureController {
    @ObservationIgnored private weak var coordinator: AppCoordinator?
    @ObservationIgnored private let panel = TextResultPanel()
    @ObservationIgnored private let review = TextReviewWindow()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    /// True while recognition and its automatic outputs run; the review window does not block new captures.
    private(set) var isActive = false

    init(coordinator: AppCoordinator) { self.coordinator = coordinator }

    func start(_ image: CGImage, settings: CaptureOutputSnapshot, ticket: ClipboardWriter.Ticket) {
        cancelRecognition()
        generation += 1
        let current = generation
        isActive = true
        let createdAt = Date()
        panel.show(symbol: "text.viewfinder", message: "Recognizing text…",
                   actions: [.init("Cancel") { [weak self] in self?.cancelRecognition() }], autoHide: false)
        task = Task { [weak self] in
            let outcome: Result<RecognizedTextResult, Error>
            do { outcome = .success(try await TextRecognizer.recognize(image, preferences: settings.text)) }
            catch { outcome = .failure(error) }
            guard let self, current == generation, !Task.isCancelled else { return }
            await finish(outcome, image: image, settings: settings, ticket: ticket, createdAt: createdAt, generation: current)
            if current == generation {
                isActive = false
                task = nil
            }
        }
    }

    /// For quit: cancels recognition and its outputs, waits for them, and closes feedback.
    /// A superseded generation never shows panels afterwards.
    func stop() async {
        let running = task
        cancelRecognition()
        await running?.value
        panel.close()
        review.close()
    }

    private func cancelRecognition() {
        generation += 1
        task?.cancel()
        task = nil
        isActive = false
        panel.close()
    }

    private func finish(_ outcome: Result<RecognizedTextResult, Error>, image: CGImage, settings: CaptureOutputSnapshot,
                        ticket: ClipboardWriter.Ticket, createdAt: Date, generation current: Int) async {
        guard let coordinator, current == generation else { return }
        let reselect = TextResultPanel.Action("Reselect") { [weak coordinator] in coordinator?.capture(.text) }
        let result: RecognizedTextResult
        switch outcome {
        case .failure(let error):
            let retry = TextResultPanel.Action("Retry", isDefault: true) { [weak self, weak coordinator] in
                guard let coordinator else { return }
                self?.start(image, settings: settings, ticket: coordinator.clipboard.begin())
            }
            panel.show(symbol: "exclamationmark.triangle", message: "Couldn't recognize text",
                       detail: "\(error.localizedDescription) The clipboard was not changed.", actions: [retry, reselect], autoHide: false)
            return
        case .success(let recognized) where recognized.isEmpty:
            panel.show(symbol: "text.magnifyingglass", message: "No text found",
                       detail: "The clipboard was not changed. Try selecting a tighter area.", actions: [reselect], autoHide: false)
            return
        case .success(let recognized):
            result = recognized
        }

        let text = result.text(preservingLineBreaks: settings.text.preservesLineBreaks)
        let outputs = settings.text.outputs
        var details: [String] = []
        var actions: [TextResultPanel.Action] = [.init("Review", isDefault: true) { [weak self, weak coordinator] in
            guard let self, let coordinator else { return }
            review.show(result, settings: settings, createdAt: createdAt, clipboard: coordinator.clipboard)
        }]
        var needsAttention = false
        let message: String
        if outputs.contains(.copyText) {
            if coordinator.clipboard.write(text, ticket: ticket) {
                message = "Copied \(text.count) characters"
            } else {
                message = "Text recognized"
                details.append("Something else was copied meanwhile, so the clipboard was not replaced.")
                actions.append(.init("Copy") { [weak coordinator] in
                    guard let coordinator else { return }
                    coordinator.clipboard.write(text, ticket: coordinator.clipboard.begin())
                })
                needsAttention = true
            }
        } else {
            message = "Text recognized"
        }
        if outputs.contains(.saveText) {
            let directory = settings.saveDirectory, template = settings.capture.filenameTemplate
            do {
                let url = try await Task.detached {
                    try TextRecognizer.saveText(text, in: directory, template: template, date: createdAt)
                }.value
                details.append("Saved \(url.lastPathComponent).")
            } catch {
                details.append("Couldn't save the text file: \(error.localizedDescription) Use Review to save it elsewhere.")
                needsAttention = true
            }
            // Stop or a newer capture during the save must not reopen feedback.
            guard current == generation, !Task.isCancelled else { return }
        }
        let uncertain = result.lowConfidenceLines.count
        if uncertain > 0 {
            details.append("\(uncertain) \(uncertain == 1 ? "line was" : "lines were") recognized with low confidence.")
            needsAttention = true
        }
        if coordinator.preferences.general.playsSounds { NSSound(named: "Tink")?.play() }
        if outputs.contains(.openReview) {
            review.show(result, settings: settings, createdAt: createdAt, clipboard: coordinator.clipboard)
            // A skipped copy, failed save, or uncertain lines still need to be explained.
            guard needsAttention else { panel.close(); return }
        }
        panel.show(symbol: "text.viewfinder", message: message, detail: details.isEmpty ? nil : details.joined(separator: " "),
                   actions: actions, autoHide: !needsAttention)
    }
}
