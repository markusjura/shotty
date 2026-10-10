import AppKit
import Observation
import os

/// Runs Capture Text after selection: recognition off the main actor, then the copy, save, and review
/// outputs frozen in the capture's settings. As in CleanShot X, a successful copy shows nothing; the
/// HUD over the selection appears only while recognition is slow, when no text was found, or when an
/// output failed. Text that reached neither the clipboard nor a file opens in Review, so it is never
/// lost. Empty results and errors leave the clipboard unchanged; a cancelled or superseded recognition
/// never publishes.
@MainActor @Observable
final class TextCaptureController {
    @ObservationIgnored private weak var coordinator: AppCoordinator?
    @ObservationIgnored private let hud = TextCaptureHUD()
    @ObservationIgnored private let review = TextReviewWindow()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let logger = Logger(subsystem: "local.markus.Shotty", category: "CaptureText")
    @ObservationIgnored private let recognize: @Sendable (CGImage, TextCapturePreferences) async throws -> RecognizedTextResult

    /// True while recognition and its automatic outputs run; the review window does not block new captures.
    private(set) var isActive = false

    /// True while a review window shows recognized text.
    var isShowingResults: Bool { review.isOpen }

    /// Tests pass a recognizer with a fixed result.
    init(coordinator: AppCoordinator,
         recognize: @escaping @Sendable (CGImage, TextCapturePreferences) async throws -> RecognizedTextResult = TextRecognizer.recognize) {
        self.coordinator = coordinator
        self.recognize = recognize
    }

    /// `region` is where the selection was on screen, in AppKit coordinates.
    func start(_ image: CGImage, region: CGRect, settings: CaptureOutputSnapshot, ticket: ClipboardWriter.Ticket) {
        cancelRecognition()
        generation += 1
        let current = generation
        isActive = true
        let createdAt = Date()
        let recognize = recognize
        task = Task { [weak self] in
            // Recognition takes a fraction of a second once macOS has compiled Vision's models for
            // Shotty. After a system update, launch spends about a minute compiling them, and a capture
            // in that time waits; only then does progress show.
            let progress = Task { [weak self] in
                // Recognition can finish after the sleep but before this runs; its cancel still counts.
                guard (try? await Task.sleep(for: .seconds(1))) != nil, !Task.isCancelled, let self, current == generation
                else { return }
                hud.showProgress(over: region) { [weak self] in self?.cancelRecognition() }
            }
            let started = ContinuousClock.now
            let outcome: Result<RecognizedTextResult, Error>
            do { outcome = .success(try await recognize(image, settings.text)) }
            catch { outcome = .failure(error) }
            progress.cancel()
            guard let self, current == generation, !Task.isCancelled else { return }
            let lines = (try? outcome.get())?.lines.count ?? 0
            logger.info("Recognized \(lines) lines in \(image.width)x\(image.height) px in \(started.duration(to: .now), privacy: .public)")
            await finish(outcome, region: region, settings: settings, ticket: ticket, createdAt: createdAt, generation: current)
            if current == generation {
                isActive = false
                task = nil
            }
        }
    }

    /// For quit: cancels recognition and its outputs, waits for them, and closes feedback.
    /// A superseded generation never shows feedback afterwards.
    func stop() async {
        let running = task
        cancelRecognition()
        await running?.value
        hud.close()
        review.close()
    }

    private func cancelRecognition() {
        generation += 1
        task?.cancel()
        task = nil
        isActive = false
        hud.close()
    }

    private func finish(_ outcome: Result<RecognizedTextResult, Error>, region: CGRect, settings: CaptureOutputSnapshot,
                        ticket: ClipboardWriter.Ticket, createdAt: Date, generation current: Int) async {
        guard let coordinator, current == generation else { return }
        let result: RecognizedTextResult
        switch outcome {
        case .failure(let error):
            logger.error("Text recognition failed: \(error.localizedDescription, privacy: .public)")
            hud.show("Couldn't recognize text", symbol: "exclamationmark.triangle", over: region)
            return
        case .success(let recognized) where recognized.isEmpty:
            hud.show("No text found", symbol: "text.magnifyingglass", over: region)
            return
        case .success(let recognized):
            result = recognized
        }

        let text = result.text(preservingLineBreaks: settings.text.preservesLineBreaks)
        let outputs = settings.text.outputs
        var delivered = false
        var problem: String?
        if outputs.contains(.copyText) {
            // The ticket refuses to replace something copied since the capture started.
            if coordinator.clipboard.write(text, ticket: ticket) { delivered = true }
            else { problem = "Not copied: the clipboard changed" }
        }
        if outputs.contains(.saveText) {
            let directory = settings.saveDirectory
            do {
                _ = try await Task.detached { try TextRecognizer.saveText(text, in: directory, date: createdAt) }.value
                delivered = true
            } catch {
                logger.error("Couldn't save recognized text: \(error.localizedDescription, privacy: .public)")
                problem = problem ?? "Couldn't save the text file"
            }
            // Stop or a newer capture during the save must not show feedback.
            guard current == generation, !Task.isCancelled else { return }
        }
        if coordinator.preferences.general.playsSounds { NSSound(named: "Tink")?.play() }
        if outputs.contains(.openReview) || !delivered {
            hud.close()
            review.show(result, settings: settings, createdAt: createdAt, clipboard: coordinator.clipboard, note: problem)
        } else if let problem {
            hud.show(problem, symbol: "exclamationmark.triangle", over: region)
        } else {
            hud.close()
            TextCaptureHUD.announce(outputs.contains(.copyText) ? "Text copied" : "Text saved")
        }
    }
}
