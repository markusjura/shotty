import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import os

/// Owns the session: screenshots and recordings in progress, retained captures of both kinds,
/// their thumbnails, and every output. Editors and the app delegate reach captures only through here.
@MainActor @Observable
final class AppCoordinator {
    let preferences: AppPreferences
    let store = CaptureSessionStore()
    let exporter = ExportService()
    let clipExporter = ClipExporter()
    let clipboard = ClipboardWriter()
    let selector = CaptureSelector()
    let recording = RecordingController()
    @ObservationIgnored lazy var recordingSelector = RecordingSelector(preferences: preferences)
    @ObservationIgnored lazy var thumbnails = ThumbnailCoordinator(preferences: preferences)
    private(set) var records: [SessionRecord] = []
    private(set) var ready = false
    /// True while a screenshot or recording target is being selected, and while a screenshot is taken.
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
    /// True while recognized text is on screen, in its result panel or a review window.
    var textResultsOpen: (() -> Bool)?
    var hasEditor: ((UUID) -> Bool)?
    private var captureTask: Task<Void, Never>?
    private var holds: [UUID: Int] = [:]
    private var dismissed = Set<UUID>()
    private var outputFailures = Set<UUID>()
    private let stillCapture = StillCaptureService()
    /// Drags need their file as they start, so they render on the main actor with their own renderer.
    @ObservationIgnored private lazy var dragRenderer = DocumentRenderer()
    /// Rendered clips ready for a drag, by capture. A drag must hand over its file the moment it starts.
    private var prepared: [UUID: (revision: Int, options: RenderOptions, url: URL)] = [:]
    private var preparing: [UUID: Task<Void, Never>] = [:]

    /// True while relaunching would interrupt the user or lose work: before launch finishes, while
    /// selecting, capturing, recording, or recognizing text, while recognized text is on screen, and
    /// while any capture is retained. Quit discards the whole session, so a capture with a visible or
    /// hidden thumbnail, in an editor, or being exported counts.
    var hasWork: Bool {
        !ready || isCapturing || recording.isActive || pendingAcceptances > 0 || !records.isEmpty || !holds.isEmpty
            || auxiliaryCaptureActive?() == true || textResultsOpen?() == true
    }

    /// True while a selection, screenshot, recording, Capture Text, or scrolling capture is under way.
    /// Only one runs at a time.
    var isBusy: Bool { isCapturing || recording.isActive || auxiliaryCaptureActive?() == true }

    /// Tests pass preferences backed by their own defaults suite.
    init(preferences: AppPreferences = AppPreferences()) { self.preferences = preferences }

    func launch() async {
        thumbnails.perform = { [weak self] id, action in self?.perform(id, action: action) }
        thumbnails.dragItem = { [weak self] id in
            switch self?.records.first(where: { $0.id == id }) {
            case .image(let record): self?.dragFile(record.snapshot).map { $0 as NSURL }
            case .clip(let record): self?.dragItem(record.snapshot)
            case nil: nil
            }
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
        recording.finished = { [weak self] movie, kind, settings, ticket in
            await self?.accept(movie, kind: kind, settings: settings, ticket: ticket)
        }
        recording.failed = { [weak self] error in self?.showError(error, title: "Couldn't record") }
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
        guard ready, !isClosing, !isBusy else { NSSound.beep(); return }
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
                await copy(record.id, settings: settings, ticket: ticket, automatic: true)
            }
            if settings.capture.outputs.contains(.saveImage) {
                await save(record.id, settings: settings, dismissAfter: false, automatic: true)
            }
            if preferences.general.playsSounds { NSSound(named: "Tink")?.play() }
            return true
        } catch { showError(error, title: "Couldn't retain capture"); return false }
    }

    /// Starts a recording of `kind`, or stops the one in progress, so one shortcut both starts and stops.
    func record(_ kind: RecordingKind) {
        if recording.isActive { recording.stop(); return }
        guard ready, !isClosing, !isBusy else { NSSound.beep(); return }
        guard CGPreflightScreenCaptureAccess() else { requestCapturePermission(); return }
        let ticket = clipboard.begin()
        isCapturing = true
        recordingSelector.begin(kind: kind) { [weak self] result in
            guard let self else { return }
            isCapturing = false
            switch result {
            case .success(let target):
                guard !isClosing else { return }
                // Space switches between area and window while selecting, so the target decides the kind.
                let kind: RecordingKind = switch target {
                case .region: .area
                case .window: .window
                case .display: .screen
                }
                // Settings changed from the Record bar apply to this recording.
                recording.start(target, kind: kind, settings: preferences.snapshot(), ticket: ticket)
            case .failure(let error):
                if !(error is CancellationError) { showError(error, title: "Couldn't start recording") }
            }
        }
    }

    func stopRecording() { recording.stop() }

    /// Takes a finished recording into the session and runs the outputs chosen when it started.
    /// The movie's folder is removed afterwards, whether or not the session could keep it.
    @discardableResult
    func accept(_ movie: URL, kind: RecordingKind, settings: CaptureOutputSnapshot, ticket: ClipboardWriter.Ticket) async -> Bool {
        pendingAcceptances += 1
        defer {
            pendingAcceptances -= 1
            try? FileManager.default.removeItem(at: movie.deletingLastPathComponent())
        }
        do {
            let record = try await store.create(movie: movie, kind: kind, format: settings.recording.format)
            await refreshRecords()
            let outputs = settings.recording.outputs
            if outputs.contains(.showThumbnail) { await showThumbnail(record.id) }
            if outputs.contains(.openEditor) { openEditor?(record.id) }
            if outputs.contains(.copyClip) { await copy(record.id, settings: settings, ticket: ticket, automatic: true) }
            if outputs.contains(.saveClip) { await save(record.id, settings: settings, dismissAfter: false, automatic: true) }
            if preferences.general.playsSounds { NSSound(named: "Glass")?.play() }
            prepare(record.id, after: .zero)
            return true
        } catch { showError(error, title: "Couldn't keep the recording"); return false }
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
    nonisolated static func unexportedCount(of ids: [UUID], in records: [SessionRecord]) -> Int {
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.filter { id in byID[id].map { !$0.isSaved && !$0.isCopied } ?? true }.count
    }

    /// Pass `source` while a new screenshot is still in memory; otherwise the store reads it back.
    /// A clip's card also shows its length.
    private func showThumbnail(_ id: UUID, source: CGImage? = nil) async {
        do {
            let image = if let source { try await store.thumbnail(of: source) } else { try await store.thumbnail(for: id) }
            var duration: String?
            if case .clip(let record) = try await store.record(id) { duration = ClipTime.duration(record.snapshot.outputDuration) }
            thumbnails.add(id, image: image, duration: duration)
        } catch { showError(error, title: "Couldn't show capture") }
    }

    func perform(_ id: UUID, action: ThumbnailCoordinator.Action) {
        guard !isClosing else { NSSound.beep(); return }
        switch action {
        case .open: openEditor?(id)
        case .copy:
            let ticket = clipboard.begin(), settings = preferences.snapshot()
            Task { await copy(id, settings: settings, ticket: ticket) }
        case .save:
            let settings = preferences.snapshot()
            Task { await save(id, settings: settings, dismissAfter: preferences.thumbnails.dismissesAfterSave) }
        case .saveAs: Task { await saveAs(id) }
        case .dismiss: dismiss(id)
        }
    }

    /// Puts the capture on the clipboard: a screenshot as PNG data, a clip as its rendered file.
    /// `automatic` outputs report failures on the card only, without an alert or activation. An
    /// automatic copy shows no checkmark, so a new card reads Copy until the user copies it.
    func copy(_ id: UUID, settings: CaptureOutputSnapshot, ticket: ClipboardWriter.Ticket, automatic: Bool = false) async {
        retain(id); defer { release(id) }
        do {
            let revision: Int, written: Bool
            switch try await store.record(id) {
            case .image(let record):
                var png = settings.exportOptions; png.format = .png
                let data = try await exporter.encodedData(record.snapshot, options: png)
                revision = record.revision
                written = clipboard.write(data, type: .png, ticket: ticket, onPaste: pasteHandler(for: id))
            case .clip(let record):
                // Most copies find their render ready; one that has to wait says so on the card.
                let progress = automatic ? nil : Task {
                    try? await Task.sleep(for: .milliseconds(300))
                    if !Task.isCancelled { thumbnails.update(id, feedback: .rendering) }
                }
                defer { progress?.cancel() }
                let file = try await clipExporter.rendered(record.snapshot, options: settings.renderOptions)
                progress?.cancel()
                revision = record.revision
                written = clipboard.write(file: file, ticket: ticket, onPaste: pasteHandler(for: id))
            }
            if written {
                try await store.markCopied(id, revision: revision)
                if !automatic { thumbnails.update(id, feedback: .copied) }
                await refreshRecords()
            } else {
                // Something else was copied meanwhile; never overwrite it.
                thumbnails.update(id, feedback: .message("Not copied: the clipboard changed. Use Copy."))
                if !thumbnails.cards.contains(where: { $0.id == id }) { await showThumbnail(id) }
            }
        } catch { outputFailed(id, error: error, action: "copy", automatic: automatic) }
    }

    /// Saves into the capture's folder under the first free name; screenshots and clips each have their own.
    func save(_ id: UUID, settings: CaptureOutputSnapshot, dismissAfter: Bool, automatic: Bool = false) async {
        retain(id); defer { release(id) }
        thumbnails.update(id, feedback: .saving)
        do {
            let receipt = switch try await store.record(id) {
            case .image(let record): try await exporter.export(record.snapshot, to: settings.saveDirectory, options: settings.exportOptions)
            case .clip(let record): try await clipExporter.export(record.snapshot, to: settings.clipDirectory, options: settings.renderOptions)
            }
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

    /// Saves the capture's current revision where the user picks, as a thumbnail's Save As does.
    @discardableResult
    func saveAs(_ id: UUID) async -> Bool {
        retain(id); defer { release(id) }
        do {
            switch try await store.record(id) {
            case .image(let record): return await saveAs(record.snapshot)
            case .clip(let record): return await saveAs(record.snapshot)
            }
        } catch { outputFailed(id, error: error, action: "save"); return false }
    }

    /// Saves `snapshot`, such as the image editor's current revision, as PNG or JPEG.
    @discardableResult
    func saveAs(_ snapshot: CaptureSnapshot) async -> Bool {
        let settings = preferences.snapshot()
        let name = ExportService.filename(stem: ExportService.filenameStem(date: snapshot.createdAt), scale: snapshot.sourceScale,
                                          options: settings.exportOptions)
        return await saveAs(snapshot.captureID, types: [.png, .jpeg], in: settings.saveDirectory, name: name) { [exporter] destination in
            var options = settings.exportOptions
            options.format = ["jpg", "jpeg"].contains(destination.pathExtension.lowercased()) ? .jpeg : .png
            // The panel already confirmed replacing an existing file.
            let expected = try? await exporter.fingerprint(at: destination)
            return try await exporter.save(snapshot, to: destination, options: options, replacing: expected)
        }
    }

    /// Saves `snapshot`, such as the video editor's current revision, in its clip format.
    @discardableResult
    func saveAs(_ snapshot: ClipSnapshot) async -> Bool {
        let settings = preferences.snapshot()
        let format = snapshot.edit.format
        let name = ClipExporter.filename(stem: ClipExporter.filenameStem(date: snapshot.createdAt), format: format)
        return await saveAs(snapshot.captureID, types: [format == .gif ? .gif : .mpeg4Movie], in: settings.clipDirectory,
                            name: name) { [clipExporter] destination in
            // The panel already confirmed replacing an existing file.
            let expected = try? await clipExporter.fingerprint(at: destination)
            return try await clipExporter.save(snapshot, to: destination, options: settings.renderOptions, replacing: expected)
        }
    }

    /// Asks where to save capture `id`, then hands the destination to `write`.
    private func saveAs(_ id: UUID, types: [UTType], in directory: URL, name: String,
                        write: (URL) async throws -> ExportReceipt) async -> Bool {
        retain(id); thumbnails.lock(true)
        defer { release(id); thumbnails.lock(false) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.directoryURL = directory
        panel.nameFieldStringValue = name
        NSApp.activate()
        guard await panel.begin() == .OK, let destination = panel.url else { return false }
        thumbnails.update(id, feedback: .saving)
        do {
            let receipt = try await write(destination)
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
    /// Refreshes what depends on a clip's edits once the video editor stores them as its next revision.
    func editsChanged(_ id: UUID) async {
        await refreshRecords()
        if thumbnails.cards.contains(where: { $0.id == id }),
           let image = try? await store.thumbnail(for: id), let snapshot = try? await store.clipSnapshot(for: id) {
            thumbnails.replace(id, image: image, duration: ClipTime.duration(snapshot.outputDuration))
        }
        // Edits often come in runs, such as several trims; render once they settle.
        prepare(id, after: .seconds(1))
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
        prepared[id] = nil
        preparing.removeValue(forKey: id)?.cancel()
        Task {
            do {
                try await store.remove(id)
                await clipExporter.forget(id)
                await refreshRecords()
            } catch { showError(error, title: "Couldn't dismiss capture") }
        }
    }

    // MARK: Drags

    /// Exports the capture to a file for a drag. A plain file URL works in Finder and in Chromium and
    /// Electron apps such as Slack or ChatGPT, which ignore file promises. Receivers may read the file
    /// long after the drop, when a message is sent, so each drag gets its own folder in the scratch
    /// space, which the next launch clears.
    func dragFile(_ snapshot: CaptureSnapshot) -> URL? {
        let options = preferences.snapshot().exportOptions
        let name = ExportService.filename(stem: ExportService.filenameStem(date: snapshot.createdAt), scale: snapshot.sourceScale,
                                          options: options)
        do {
            let data = try ExportService.encodedData(snapshot, options: options, renderer: dragRenderer)
            let url = try CaptureScratchSpace.makeFolder().appendingPathComponent(name)
            try data.write(to: url)
            return url
        } catch {
            outputFailed(snapshot.captureID, error: error, action: "export")
            return nil
        }
    }

    /// What a drag of the clip `snapshot` carries. A plain file URL works in Finder and in Chromium and
    /// Electron apps such as Slack or ChatGPT, which ignore file promises, so a rendered file is
    /// preferred. An unedited MP4 is cloned on the spot. Only an edit still rendering, or one rendered
    /// with other settings, falls back to a file promise, which Finder, Mail, and Messages fulfil once
    /// the render finishes. The render keeps going, so the next drag hands over a file.
    func dragItem(_ snapshot: ClipSnapshot) -> NSPasteboardWriting? {
        let options = preferences.snapshot().renderOptions
        if let file = prepared[snapshot.captureID], file.revision == snapshot.revision, file.options == options,
           FileManager.default.fileExists(atPath: file.url.path) {
            return file.url as NSURL
        }
        let name = ClipExporter.filename(stem: ClipExporter.filenameStem(date: snapshot.createdAt), format: snapshot.edit.format)
        do {
            let folder = try CaptureScratchSpace.makeFolder()
            if snapshot.edit.isPassthrough(sourceSize: snapshot.pixelSize, sourceDuration: snapshot.duration) {
                let url = folder.appendingPathComponent(name)
                try FileManager.default.copyItem(at: snapshot.sourceURL, to: url)
                return url as NSURL
            }
            // The drop can dismiss the clip, deleting its recording, before the receiver asks for the
            // file. The promise renders from a clone instead, which APFS makes instantly.
            var clone = snapshot
            clone.sourceURL = folder.appendingPathComponent(snapshot.sourceURL.lastPathComponent)
            try FileManager.default.copyItem(at: snapshot.sourceURL, to: clone.sourceURL)
            let promise = ClipFilePromise(snapshot: clone, options: options, exporter: clipExporter, filename: name)
            let provider = NSFilePromiseProvider(fileType: (snapshot.edit.format == .gif ? UTType.gif : .mpeg4Movie).identifier,
                                                 delegate: promise)
            provider.userInfo = promise
            prepare(snapshot.captureID, after: .zero)
            return provider
        } catch {
            outputFailed(snapshot.captureID, error: error, action: "export")
            return nil
        }
    }

    /// Renders the clip's current revision in the background after `delay`, so a drag can hand
    /// over a finished file. A newer call for the same clip replaces a pending one and waits for a
    /// render already under way, so a run of edits never renders a long clip several times at once.
    private func prepare(_ id: UUID, after delay: Duration) {
        let previous = preparing[id]
        previous?.cancel()
        let options = preferences.snapshot().renderOptions
        preparing[id] = Task {
            await previous?.value
            do { try await Task.sleep(for: delay) } catch { return }
            guard let snapshot = try? await store.clipSnapshot(for: id),
                  let url = try? await clipExporter.rendered(snapshot, options: options),
                  records.first(where: { $0.id == id })?.revision == snapshot.revision else { return }
            prepared[id] = (snapshot.revision, options, url)
        }
    }

    /// Quit asks nothing. Captures and recordings in progress are discarded, a running save
    /// finishes writing, and the session is discarded, so thumbnails simply disappear.
    /// Saved files are never touched.
    func prepareToQuit() async -> Bool {
        guard ready else { return true }
        isClosing = true
        selector.cancel()
        recordingSelector.cancel()
        await recording.shutdown()
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
        alert.informativeText = "Screen Recording access lets Shotty capture images, record clips, and recognize text locally on this Mac."
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
