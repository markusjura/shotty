import AppKit
import Observation
import SwiftUI
import os

@MainActor @Observable
final class AppCoordinator {
    let preferences: AppPreferences
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
    private var outputFailures = Set<UUID>()
    private let stillCapture = StillCaptureService()
    /// Drags need their file as they start, so they render on the main actor with their own renderer.
    @ObservationIgnored private lazy var dragRenderer = DocumentRenderer()

    /// Tests pass preferences backed by their own defaults suite.
    init(preferences: AppPreferences = AppPreferences()) { self.preferences = preferences }

    func launch() async {
        thumbnails.perform = { [weak self] id, action in self?.perform(id, action: action) }
        thumbnails.dragFile = { [weak self] id in
            guard let self, let record = records.first(where: { $0.id == id }) else { return nil }
            return dragFile(record.snapshot)
        }
        thumbnails.dropped = { [weak self] id, keepCard in
            guard let self, preferences.thumbnails.dismissesAfterDrag, !keepCard else { return }
            dismiss(id)
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
        // Captures live only as long as the app. Whatever a crash or kill left behind goes silently.
        do {
            try CaptureScratchSpace.cleanPreviousLaunch()
            try await store.reset()
        } catch {
            Logger(subsystem: "local.markus.Shotty", category: "Launch").error("Couldn't clear the previous session: \(error.localizedDescription, privacy: .public)")
        }
        ready = true
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

    /// `automatic` outputs report failures on the card only, without an alert or activation. An
    /// automatic copy shows no checkmark, so a new card reads Copy until the user copies it.
    func copy(_ id: UUID, options: ExportOptions, ticket: ClipboardWriter.Ticket, automatic: Bool = false) async {
        retain(id); defer { release(id) }
        do {
            let snapshot = try await store.snapshot(for: id)
            var png = options; png.format = .png
            let data = try await exporter.encodedData(snapshot, options: png)
            if clipboard.write(data, type: .png, ticket: ticket, onPaste: pasteHandler(for: id)) {
                try await store.markCopied(snapshot)
                if !automatic { thumbnails.update(id, feedback: .copied) }
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

    /// Removes the card at once; the capture is deleted as soon as no editor or export still holds it.
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

    /// Exports the capture to a file for a drag. A plain file URL works in Finder and in Chromium and
    /// Electron apps such as Slack or ChatGPT, which ignore file promises. Receivers may read the file
    /// long after the drop, when a message is sent, so each drag gets its own folder in the scratch
    /// space, which the next launch clears.
    func dragFile(_ snapshot: CaptureSnapshot) -> URL? {
        let options = preferences.snapshot().exportOptions
        let directory = CaptureScratchSpace.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(ExportService.filename(
            stem: ExportService.filenameStem(date: snapshot.createdAt), scale: snapshot.sourceScale, options: options))
        do {
            let data = try ExportService.encodedData(snapshot, options: options, renderer: dragRenderer)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            try data.write(to: url)
            return url
        } catch {
            outputFailed(snapshot.captureID, error: error, action: "export")
            return nil
        }
    }

    /// Quit asks nothing. Captures in progress are cancelled, a running save
    /// finishes writing, and the session is discarded, so thumbnails simply disappear.
    /// Saved files are never touched.
    func prepareToQuit() async -> Bool {
        guard ready else { return true }
        isClosing = true
        selector.cancel()
        await stopAuxiliaryCapture?()
        await captureTask?.value
        // Exports read session sources; wait for them, but never hang Quit on a stuck one.
        let deadline = ContinuousClock.now + .seconds(10)
        while !holds.isEmpty || pendingAcceptances > 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        do { try await store.reset() } catch {
            Logger(subsystem: "local.markus.Shotty", category: "Quit").error("Couldn't clear the session: \(error.localizedDescription, privacy: .public)")
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
