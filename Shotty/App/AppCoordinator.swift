import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

@MainActor @Observable
final class AppCoordinator {
    let preferences = AppPreferences()
    let store = CaptureSessionStore()
    let exporter = ExportService()
    let clipboard = ClipboardWriter()
    let selector = CaptureSelector()
    @ObservationIgnored lazy var thumbnails = ThumbnailCoordinator(preferences: preferences)
    private(set) var records: [CaptureRecord] = []
    private(set) var ready = false
    private(set) var isCapturing = false
    private var pendingAcceptances = 0
    /// Set for good once Quit starts. New captures and thumbnail actions are refused, and the
    /// session discard replaces individual removals.
    private(set) var isClosing = false
    private var saveAllTask: Task<Void, Never>?
    var openEditor: ((UUID) -> Void)?
    var recognizeText: ((CGImage, CaptureOutputSnapshot, ClipboardWriter.Ticket) -> Void)?
    var startScrolling: ((CGRect, CGDirectDisplayID, CaptureOutputSnapshot, ClipboardWriter.Ticket) -> Void)?
    var stopAuxiliaryCapture: (() async -> Void)?
    var auxiliaryCaptureActive: (() -> Bool)?
    var hasEditor: ((UUID) -> Bool)?
    private var captureTask: Task<Void, Never>?
    private var holds: [UUID: Int] = [:]
    private var dismissed = Set<UUID>()
    /// One promised drag. The capture stays held until `finishDrag` runs exactly once.
    private struct DragOutcome {
        let captureID: UUID
        weak var promise: CaptureFilePromise?
        var accepted: Bool?
        var keepCard = false
        var saved = false
        var failed = false
    }
    private var dragOutcomes: [UUID: DragOutcome] = [:]
    private var activeDrag: [UUID: UUID] = [:]
    private var outputFailures = Set<UUID>()
    private let stillCapture = StillCaptureService()

    func launch() async {
        thumbnails.perform = { [weak self] id, action in self?.perform(id, action: action) }
        thumbnails.makePromise = { [weak self] id in self?.filePromise(id) }
        thumbnails.dragFinished = { [weak self] id, accepted, keepCard in
            guard let self, let token = activeDrag.removeValue(forKey: id), dragOutcomes[token] != nil else { return }
            dragOutcomes[token]?.accepted = accepted
            dragOutcomes[token]?.keepCard = keepCard
            resolveDrag(token)
        }
        thumbnails.autoClose = { [weak self] id, mode in
            guard let self else { return }
            guard !isClosing else { return }
            if mode == .dismiss { dismiss(id) }
            else if mode == .saveThenDismiss {
                let settings = preferences.snapshot()
                Task { await self.save(id, settings: settings, dismissAfter: true, automatic: true) }
            }
        }
        thumbnails.pausesAutoClose = { [weak self] id in
            self?.hasEditor?(id) == true || self?.outputFailures.contains(id) == true
        }
        do {
            try CaptureScratchSpace.cleanPreviousLaunch()
            let recovery = try await store.load()
            if recovery.state == .interrupted, !recovery.records.isEmpty {
                let alert = NSAlert()
                alert.messageText = "Restore your captures?"
                alert.informativeText = "Shotty closed before the active session finished. Your captures were kept on this Mac."
                alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Discard")
                NSApp.activate()
                if alert.runModal() == .alertSecondButtonReturn { try await store.discard() }
                else { try await store.resume() }
            } else { try await store.resume() }
            await refreshRecords()
            for record in records { await showThumbnail(record.id) }
            ready = true
        } catch {
            let alert = NSAlert(); alert.messageText = "Couldn't restore the capture session"
            alert.informativeText = error.localizedDescription + " You can keep the files and quit, or discard this session."
            alert.addButton(withTitle: "Keep Files and Quit"); alert.addButton(withTitle: "Discard Session")
            if alert.runModal() == .alertSecondButtonReturn {
                do { try await store.discard(); ready = true; await refreshRecords() }
                catch { showError(error, title: "Couldn't discard the session"); NSApp.terminate(nil) }
            } else { NSApp.terminate(nil) }
        }
    }

    func capture(_ kind: CaptureKind) {
        guard ready, !isClosing, !isCapturing, auxiliaryCaptureActive?() != true else { NSSound.beep(); return }
        guard CGPreflightScreenCaptureAccess() else { requestCapturePermission(); return }
        let settings = preferences.snapshot()
        let ticket = clipboard.begin()
        isCapturing = true
        // Ordered out before any pixels are taken, and back once they are, so new cards still appear.
        thumbnails.hiddenForCapture = preferences.thumbnails.hidesDuringCapture
        if kind == .fullscreen {
            let screens = NSScreen.screens
            let targets: [NSScreen]
            switch settings.capture.fullscreenTarget {
            case .allDisplays: targets = screens
            case .mainDisplay: targets = screens.filter { $0.displayID == CGMainDisplayID() }
            case .pointerDisplay: targets = screens.filter { $0.frame.contains(NSEvent.mouseLocation) }
            }
            captureTask = Task {
                defer { isCapturing = false; captureTask = nil; thumbnails.hiddenForCapture = false }
                for screen in targets {
                    guard let id = screen.displayID else { continue }
                    do {
                        let image = try await stillCapture.display(id: id)
                        try Task.checkCancellation()
                        await accept(image, kind: .fullscreen, scale: screen.backingScaleFactor, settings: settings, ticket: ticket)
                    } catch is CancellationError { return }
                    catch { showError(error, title: "Couldn't capture display") }
                }
            }
        } else {
            let config = SelectionConfiguration(freeze: settings.capture.freezesScreen, shadow: settings.capture.includesWindowShadow)
            selector.begin(kind: kind, configuration: config) { [weak self] result in
                guard let self else { return }
                isCapturing = false
                thumbnails.hiddenForCapture = false
                switch result {
                case .success(.image(let image, let selectedKind, let scale)):
                    if selectedKind == .text { recognizeText?(image, settings, ticket) }
                    else {
                        isCapturing = true
                        captureTask = Task {
                            await self.accept(image, kind: selectedKind, scale: scale, settings: settings, ticket: ticket)
                            self.captureTask = nil; self.isCapturing = false
                        }
                    }
                case .success(.scrolling(let region, let display)):
                    startScrolling?(region, display, settings, ticket)
                case .failure(let error):
                    if !(error is CancellationError) { showError(error, title: "Couldn't capture selection") }
                }
            }
        }
    }

    @discardableResult
    func accept(_ image: CGImage, kind: CaptureKind, scale: Double, settings: CaptureOutputSnapshot,
                ticket: ClipboardWriter.Ticket) async -> Bool {
        pendingAcceptances += 1
        defer { pendingAcceptances -= 1 }
        do {
            let record = try await store.create(image: image, kind: kind, scale: scale)
            await refreshRecords()
            if settings.capture.outputs.contains(.showThumbnail) { await showThumbnail(record.id, source: image) }
            if settings.capture.outputs.contains(.openEditor) { openEditor?(record.id) }
            if settings.capture.outputs.contains(.copyImage) {
                await copy(record.id, options: settings.exportOptions, ticket: ticket, automatic: true)
            }
            if settings.capture.outputs.contains(.saveImage) {
                await save(record.id, settings: settings, dismissAfter: false, automatic: true)
            }
            if preferences.general.playsSounds { NSSound(named: "Tink")?.play() }
            return true
        } catch { showError(error, title: "Couldn't retain capture"); return false }
    }

    func refreshRecords() async { records = await store.records() }

    func showAllThumbnails() {
        thumbnails.hidden = false
        Task {
            for record in records where !dismissed.contains(record.id) {
                if !thumbnails.cards.contains(where: { $0.id == record.id }) { await showThumbnail(record.id) }
            }
            thumbnails.refresh()
            thumbnails.focusStack()
        }
    }
    func hideThumbnails() { thumbnails.hidden = true; thumbnails.refresh() }
    /// Dismisses every card. When some hold work that was neither saved nor copied at its current
    /// revision, confirms first with that count, because dismissal is final.
    func dismissAllThumbnails() {
        let ids = thumbnails.cards.map(\.id)
        guard !ids.isEmpty else { return }
        let unexported = Self.unexportedCount(of: ids, in: records)
        if unexported > 0 {
            let alert = NSAlert()
            alert.messageText = ids.count == 1 ? "Dismiss this capture?" : "Dismiss all \(ids.count) captures?"
            alert.informativeText = unexported == 1 ? "1 capture hasn't been saved or copied."
                                                    : "\(unexported) captures haven't been saved or copied."
            alert.addButton(withTitle: "Dismiss All"); alert.addButton(withTitle: "Cancel")
            thumbnails.lock(true)
            NSApp.activate()
            let response = alert.runModal()
            thumbnails.lock(false)
            guard response == .alertFirstButtonReturn else { return }
        }
        // Cards added while the alert was open are not part of the confirmed set.
        for id in ids where thumbnails.cards.contains(where: { $0.id == id }) { dismiss(id) }
    }

    /// Captures among `ids` whose current revision was neither saved nor copied. Unknown IDs count
    /// as unexported, so a stale record list never hides work.
    nonisolated static func unexportedCount(of ids: [UUID], in records: [CaptureRecord]) -> Int {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.filter { id in byID[id].map { !$0.isSaved && !$0.isCopied } ?? true }.count
    }

    /// Pass `source` while the unedited capture is still in memory; otherwise the store reads it back.
    private func showThumbnail(_ id: UUID, source: CGImage? = nil) async {
        do {
            let image = if let source { try await store.thumbnail(of: source) } else { try await store.thumbnail(for: id) }
            thumbnails.add(id, image: image)
        } catch { showError(error, title: "Couldn't show capture") }
    }

    func perform(_ id: UUID, action: ThumbnailCoordinator.Action) {
        guard !isClosing else { NSSound.beep(); return }
        switch action {
        case .open: openEditor?(id)
        case .copy:
            let ticket = clipboard.begin(), options = preferences.snapshot().exportOptions
            Task { await copy(id, options: options, ticket: ticket) }
        case .save:
            let settings = preferences.snapshot()
            Task { await save(id, settings: settings, dismissAfter: preferences.thumbnails.dismissesAfterSave) }
        case .saveAs: Task { await saveAs(id) }
        case .dismiss: dismiss(id)
        }
    }

    /// `automatic` outputs report failures on the card only, without an alert or activation.
    func copy(_ id: UUID, options: ExportOptions, ticket: ClipboardWriter.Ticket, automatic: Bool = false) async {
        retain(id); defer { release(id) }
        do {
            let snapshot = try await store.snapshot(for: id)
            var png = options; png.format = .png
            let data = try await exporter.encodedData(snapshot, options: png)
            if clipboard.write(data, type: .png, ticket: ticket, onPaste: pasteHandler(for: id)) {
                try await store.markCopied(snapshot)
                thumbnails.update(id, feedback: .copied)
                await refreshRecords()
            } else {
                // Something else was copied meanwhile; never overwrite it.
                thumbnails.update(id, feedback: .message("Not copied: the clipboard changed. Use Copy."))
                if !thumbnails.cards.contains(where: { $0.id == id }) { await showThumbnail(id) }
            }
        } catch { outputFailed(id, error: error, action: "copy", automatic: automatic) }
    }

    func save(_ id: UUID, settings: CaptureOutputSnapshot, dismissAfter: Bool, automatic: Bool = false) async {
        retain(id); defer { release(id) }
        thumbnails.update(id, feedback: .saving)
        do {
            let snapshot = try await store.snapshot(for: id)
            let receipt = try await exporter.export(snapshot, to: settings.saveDirectory, options: settings.exportOptions)
            try await store.markSaved(receipt)
            outputFailures.remove(id)
            await refreshRecords()
            if dismissAfter { dismiss(id) } else { thumbnails.update(id, feedback: .saved) }
        } catch { outputFailed(id, error: error, action: "save", automatic: automatic) }
    }

    /// Saves every retained capture as one tracked operation. Failures stay on their cards.
    func saveAll() {
        guard !isClosing, saveAllTask == nil else { NSSound.beep(); return }
        let settings = preferences.snapshot()
        let ids = records.map(\.id).filter { !dismissed.contains($0) }
        // Holding every capture up front keeps Quit from starting between saves.
        for id in ids { retain(id); thumbnails.update(id, feedback: .waitingToSave) }
        saveAllTask = Task {
            defer { for id in ids { release(id) }; saveAllTask = nil }
            for id in ids { await save(id, settings: settings, dismissAfter: false, automatic: true) }
        }
    }

    @discardableResult
    func saveAs(_ id: UUID, snapshot requested: CaptureSnapshot? = nil) async -> Bool {
        retain(id); thumbnails.lock(true)
        defer { release(id); thumbnails.lock(false) }
        do {
            let snapshot: CaptureSnapshot
            if let requested { snapshot = requested } else { snapshot = try await store.snapshot(for: id) }
            let settings = preferences.snapshot()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.png, .jpeg]
            panel.canCreateDirectories = true
            panel.directoryURL = settings.saveDirectory
            panel.nameFieldStringValue = ExportService.filename(stem: ExportService.filenameStem(date: snapshot.createdAt),
                                                                scale: snapshot.sourceScale, options: settings.exportOptions)
            NSApp.activate()
            guard await panel.begin() == .OK, let destination = panel.url else { return false }
            var options = settings.exportOptions
            options.format = ["jpg", "jpeg"].contains(destination.pathExtension.lowercased()) ? .jpeg : .png
            thumbnails.update(id, feedback: .saving)
            let expected = try? await exporter.fingerprint(at: destination)
            let receipt = try await exporter.save(snapshot, to: destination, options: options, replacing: expected)
            try await store.markSaved(receipt)
            outputFailures.remove(id)
            await refreshRecords()
            if preferences.thumbnails.dismissesAfterSave { dismiss(id) } else { thumbnails.update(id, feedback: .saved) }
            return true
        } catch { outputFailed(id, error: error, action: "save"); return false }
    }

    private func outputFailed(_ id: UUID, error: Error, action: String, automatic: Bool = false) {
        outputFailures.insert(id)
        thumbnails.update(id, feedback: .message("Couldn't \(action): \(error.localizedDescription) Retry or choose Save As."))
        Task { if !thumbnails.cards.contains(where: { $0.id == id }) { await showThumbnail(id) } }
        if !automatic { showError(error, title: "Couldn't \(action) capture") }
    }

    /// Dismisses the capture's thumbnail when its copy is pasted, if the user asked for that.
    func pasteHandler(for id: UUID) -> (@MainActor () -> Void)? {
        guard preferences.thumbnails.dismissesAfterPaste else { return nil }
        return { [weak self] in
            guard let self, !isClosing, thumbnails.cards.contains(where: { $0.id == id }) else { return }
            dismiss(id)
        }
    }

    /// Removes the card at once; the capture is deleted as soon as no editor or drag still holds it.
    private func dismiss(_ id: UUID) {
        dismissed.insert(id)
        thumbnails.remove(id)
        removeIfUnreferenced(id)
    }

    func retain(_ id: UUID) { holds[id, default: 0] += 1 }
    func release(_ id: UUID) {
        if let count = holds[id], count > 1 { holds[id] = count - 1 } else { holds.removeValue(forKey: id) }
        removeIfUnreferenced(id)
    }
    func keepEditedCapture(_ id: UUID) async {
        dismissed.remove(id)
        await refreshRecords()
        await showThumbnail(id)
    }
    func isThumbnailRetained(_ id: UUID) -> Bool { !dismissed.contains(id) }
    func discardEditedCapture(_ id: UUID) {
        dismissed.insert(id); thumbnails.remove(id)
    }
    func editorClosed(_ id: UUID) { removeIfUnreferenced(id) }
    private func removeIfUnreferenced(_ id: UUID) {
        // During Quit, discarding the session removes every capture at once.
        guard !isClosing, dismissed.contains(id), holds[id] == nil, hasEditor?(id) != true else { return }
        dismissed.remove(id)
        Task {
            do { try await store.remove(id); await refreshRecords() }
            catch { showError(error, title: "Couldn't dismiss capture") }
        }
    }

    func filePromise(_ id: UUID) -> NSFilePromiseProvider? {
        guard let record = records.first(where: { $0.id == id }) else { return nil }
        return filePromise(snapshot: record.snapshot)
    }

    func filePromise(snapshot: CaptureSnapshot) -> NSFilePromiseProvider {
        let id = snapshot.captureID, token = UUID()
        let settings = preferences.snapshot()
        let promise = CaptureFilePromise(snapshot: snapshot, options: settings.exportOptions, exporter: exporter)
        // The source must survive until the promised write finishes or can no longer start.
        retain(id)
        dragOutcomes[token] = DragOutcome(captureID: id, promise: promise)
        activeDrag[id] = token
        // Runs only when no write ever started, so no save bookkeeping can be pending.
        promise.released = { [weak self] in self?.finishDrag(token) }
        promise.completed = { [weak self] result in
            guard let self else { return }
            Task {
                switch result {
                case .success(let receipt):
                    do {
                        try await store.markSaved(receipt); await refreshRecords()
                        outputFailures.remove(id)
                        dragOutcomes[token]?.saved = true
                    } catch {
                        outputFailed(id, error: error, action: "retain saved state")
                        dragOutcomes[token]?.failed = true
                    }
                case .failure(let error):
                    outputFailed(id, error: error, action: "export")
                    dragOutcomes[token]?.failed = true
                }
                resolveDrag(token)
            }
        }
        return promise.makeProvider()
    }

    /// Settles a drag once both its session outcome and any write are known. A rejected drop
    /// releases immediately unless a write already started. An accepted drop waits for the
    /// receiver's write or, if none arrives, the provider's release.
    private func resolveDrag(_ token: UUID) {
        guard let outcome = dragOutcomes[token], let accepted = outcome.accepted else { return }
        if outcome.saved {
            if accepted, preferences.thumbnails.dismissesAfterDrag, !outcome.keepCard { dismiss(outcome.captureID) }
            finishDrag(token)
        } else if outcome.failed || (!accepted && outcome.promise?.cancelUnused() == true) {
            finishDrag(token)
        }
    }

    /// Terminal step for a drag; safe to call more than once.
    private func finishDrag(_ token: UUID) {
        guard let outcome = dragOutcomes.removeValue(forKey: token) else { return }
        if activeDrag[outcome.captureID] == token { activeDrag.removeValue(forKey: outcome.captureID) }
        release(outcome.captureID)
    }

    /// Quit asks nothing, as in CleanShot. Captures in progress are cancelled, a running save or
    /// started drop finishes writing, and the session is discarded, so thumbnails simply disappear.
    /// Saved files are never touched.
    func prepareToQuit() async -> Bool {
        guard ready else { return true }
        isClosing = true
        selector.cancel()
        await stopAuxiliaryCapture?()
        await captureTask?.value
        for (token, outcome) in dragOutcomes where outcome.promise?.cancelUnused() == true { finishDrag(token) }
        // Exports read session sources; wait for them, but never hang Quit on a stuck one.
        let deadline = ContinuousClock.now + .seconds(10)
        while !holds.isEmpty || pendingAcceptances > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        do { try await store.discard() } catch {
            Logger(subsystem: "local.markus.Shotty", category: "Quit").error("Couldn't discard the session: \(error.localizedDescription, privacy: .public)")
        }
        thumbnails.close()
        return true
    }

    private func requestCapturePermission() {
        let alert = NSAlert(); alert.messageText = "Allow Shotty to capture your screen"
        alert.informativeText = "Screen Recording access lets Shotty capture images and recognize text locally on this Mac."
        alert.addButton(withTitle: "Open Screen Recording Settings"); alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            let requested = PermissionSettingsPane.screenRecordingRequestedKey
            if !UserDefaults.standard.bool(forKey: requested) {
                UserDefaults.standard.set(true, forKey: requested); CGRequestScreenCaptureAccess()
            }
            NSWorkspace.shared.open(SystemSettingsLink.screenRecording)
        }
    }

    func showError(_ error: Error, title: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK"); NSApp.activate(); alert.runModal()
    }
}
