@preconcurrency import AVFoundation
import AppKit
import Observation
import SwiftUI

/// The video editor of one clip.
@MainActor
final class ClipEditorWindowController: NSWindowController, NSWindowDelegate, CaptureEditor {
    /// Fits the crop bar from Crop through Apply.
    static let minimumSize = CGSize(width: 720, height: 420)
    let model: ClipEditorModel
    private var closing = false
    var didClose: (() -> Void)?

    init(record: ClipRecord, coordinator: AppCoordinator, commands: CommandRegistry) {
        model = ClipEditorModel(record: record, coordinator: coordinator, commands: commands)
        let window = NSWindow(contentRect: Self.initialFrame(for: record),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Shotty · \(record.pixelWidth) × \(record.pixelHeight) · \(ClipTime.duration(record.duration))"
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        // An empty unified toolbar places the traffic lights at x 19, 42, 65 and centers them in the
        // 51 pt bar. The SwiftUI bar draws everything else beneath the titlebar.
        window.toolbar = NSToolbar(identifier: "editor")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ClipEditorView(model: model).ignoresSafeArea())
        window.center()
        model.close = { [weak self] in self?.finishAndClose() }
    }
    required init?(coder: NSCoder) { nil }

    /// The window wraps the video at the size the player will show it: actual size when the
    /// screen has room, otherwise scaled down to fit.
    private static func initialFrame(for record: ClipRecord) -> CGRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame.insetBy(dx: 32, dy: 32) ?? CGRect(x: 0, y: 0, width: 1100, height: 780)
        let scale = screen?.backingScaleFactor ?? 2
        let chrome = CGSize(width: 2 * PlayerLayout.margin,
                            height: 2 * PlayerLayout.margin + 2 * EditorBar.height + EditorBar.timelineHeight + 3)
        let video = CGSize(width: CGFloat(record.pixelWidth) / scale, height: CGFloat(record.pixelHeight) / scale)
        let zoom = min(1, (visible.width - chrome.width) / video.width, (visible.height - chrome.height) / video.height)
        return CGRect(x: 0, y: 0, width: max(video.width * zoom + chrome.width, minimumSize.width),
                      height: max(video.height * zoom + chrome.height, minimumSize.height))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        let id = model.document.record.id
        let record = model.coordinator.records.first { $0.id == id }
        if !model.coordinator.isThumbnailRetained(id), record?.savedRevision != model.document.revision {
            let alert = NSAlert(); alert.messageText = "Keep your edited clip?"
            alert.addButton(withTitle: "Keep as Thumbnail"); alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Discard"); alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn: finishAndClose()
            case .alertSecondButtonReturn: model.saveAndClose = true; model.save()
            case .alertThirdButtonReturn:
                model.coordinator.discardEditedCapture(id); closing = true; sender.close()
            default: break
            }
        } else { finishAndClose() }
        return false
    }

    func finishAndClose() {
        guard !closing else { return }
        model.pause()
        Task {
            do {
                _ = try await model.document.flush()
                await model.coordinator.keepEditedCapture(model.document.record.id)
                closing = true; window?.close()
            } catch {
                window?.makeKeyAndOrderFront(nil)  // A Drag Me drop hides the window before closing.
                model.coordinator.showError(error, title: "Couldn't keep edits")
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        model.tearDown()
        didClose?()
    }
    func windowDidBecomeKey(_ notification: Notification) { model.commands.contextDidChange() }
    func windowDidResignKey(_ notification: Notification) { model.commands.contextDidChange() }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.document.undoManager }

    /// Crop, Copy, Save, Save As, and Done mean the same in both editors and share their bindings.
    func handles(_ command: CommandID) -> Bool {
        command.group == .videoEditor || [.toolCrop, .copy, .save, .saveAs, .done].contains(command)
    }
    func execute(_ command: CommandID) { model.execute(command) }
}

/// Playback, trim, crop, and output state of one editor window. Edits go through the document,
/// so each is one undo step and a new revision.
@MainActor @Observable
final class ClipEditorModel {
    enum Output: Equatable {
        case copying, saving, copied, saved
    }

    let document: ClipEditorDocument
    let coordinator: AppCoordinator
    let commands: CommandRegistry
    @ObservationIgnored let player: AVPlayer
    @ObservationIgnored weak var canvas: PlayerCanvasView?
    /// Source seconds under the playhead.
    private(set) var currentTime = 0.0
    private(set) var isPlaying = false
    /// Frames across the whole recording for the timeline.
    private(set) var filmstrip: [CGImage] = []
    private(set) var isCropping = false
    var cropDraft: CGRect? { didSet { canvas?.needsDisplay = true } }
    private(set) var cropAspect: CGFloat?
    /// The kept range while a trim handle is dragged; committed on release.
    private(set) var trimPreview: ClosedRange<Double>?
    private(set) var output: Output?
    var busy: Bool { output == .copying || output == .saving }
    var saveAndClose = false
    var close: (() -> Void)?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var frameDuration = 1.0 / 30
    @ObservationIgnored private var resumesAfterScrub = false
    @ObservationIgnored private var outputReset: Task<Void, Never>?

    init(record: ClipRecord, coordinator: AppCoordinator, commands: CommandRegistry) {
        self.coordinator = coordinator
        self.commands = commands
        document = ClipEditorDocument(record: record, store: coordinator.store)
        let asset = AVURLAsset(url: record.sourceURL)
        let item = AVPlayerItem(asset: asset)
        // Sped-up speech keeps its pitch, as it does in the output.
        item.audioTimePitchAlgorithm = .spectral
        player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        currentTime = trimRange.lowerBound
        player.seek(to: Self.time(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item,
                                                             queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.playedToEnd() }
        }
        syncPlayer()
        document.onChange = { [weak self] in self?.documentChanged() }
        Task { await load(asset) }
    }

    var trimRange: ClosedRange<Double> { document.edit.trimRange(duration: document.record.duration) }
    var hasAudio: Bool { document.record.hasAudio }
    /// Output pixel dimensions after crop and size.
    var outputSize: CGSize { document.edit.renderSize(source: document.record.pixelSize) }

    private func load(_ asset: AVURLAsset) async {
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let rate = try? await track.load(.nominalFrameRate), rate > 1 {
            frameDuration = 1 / Double(rate)
        }
        if coordinator.preferences.editor.playsOnOpen { play() }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 120)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 4)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 4)
        let duration = document.record.duration, count = 24
        let times = (0..<count).map { Self.time(duration * (Double($0) + 0.5) / Double(count)) }
        var frames: [CGImage] = []
        for await result in generator.images(for: times) {
            if let image = try? result.image { frames.append(image) }
        }
        filmstrip = frames
    }

    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        outputReset?.cancel()
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 6000) }

    // MARK: Playback

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, trimPreview == nil else { return }
        currentTime = seconds
    }

    /// The player stops at the trim end, its forward playback end time. Playback then loops from
    /// the trim start if the preference asks for it; otherwise it stays paused on the last frame,
    /// and Play starts over from the trim start.
    private func playedToEnd() {
        guard isPlaying else { return }
        guard coordinator.preferences.editor.loopsPlayback else {
            pause()
            // The periodic observer may have last fired a frame early; `play()` checks for the end.
            tick(player.currentTime().seconds)
            return
        }
        seek(to: trimRange.lowerBound)
        player.playImmediately(atRate: Float(document.edit.speed.rawValue))
    }

    /// Mirrors the edits the player can show itself: where playback ends, its speed, and sound.
    /// A GIF has no sound, so its preview is muted too.
    private func syncPlayer() {
        let edit = document.edit
        player.currentItem?.forwardPlaybackEndTime = edit.trimEnd.map(Self.time) ?? .invalid
        player.isMuted = edit.removesAudio || edit.format == .gif
        if isPlaying { player.rate = Float(edit.speed.rawValue) }
    }

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        let range = trimRange
        if currentTime < range.lowerBound || currentTime >= range.upperBound - frameDuration { seek(to: range.lowerBound) }
        isPlaying = true
        player.playImmediately(atRate: Float(document.edit.speed.rawValue))
    }

    func pause() {
        isPlaying = false
        player.pause()
    }

    func seek(to seconds: Double) {
        currentTime = min(max(seconds, 0), document.record.duration)
        player.seek(to: Self.time(currentTime), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Moves `frames` frames, pausing first, within the kept range.
    func step(by frames: Int) {
        pause()
        seek(to: min(max(currentTime + Double(frames) * frameDuration, trimRange.lowerBound), trimRange.upperBound - frameDuration))
    }

    func beginScrub() {
        resumesAfterScrub = isPlaying
        pause()
    }

    func endScrub() { if resumesAfterScrub { play() } }

    // MARK: Trim

    /// Shows the frame at the dragged handle while the range follows it.
    func previewTrim(start: Double? = nil, end: Double? = nil) {
        if trimPreview == nil { beginScrub() }
        let current = trimPreview ?? trimRange
        let minimum = VideoEdit.minimumDuration
        var range = current
        if let start { range = min(max(0, start), current.upperBound - minimum)...current.upperBound }
        if let end { range = current.lowerBound...max(min(end, document.record.duration), current.lowerBound + minimum) }
        trimPreview = range
        let shown = start != nil ? range.lowerBound : max(range.lowerBound, range.upperBound - frameDuration)
        currentTime = shown
        player.seek(to: Self.time(shown), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func commitTrimPreview() {
        guard let range = trimPreview else { return }
        trimPreview = nil
        setTrim(range)
        endScrub()
    }

    private func setTrim(_ range: ClosedRange<Double>) {
        var edit = document.edit
        edit.trimStart = range.lowerBound <= frameDuration / 2 ? 0 : range.lowerBound
        edit.trimEnd = range.upperBound >= document.record.duration - frameDuration / 2 ? nil : range.upperBound
        document.commit(edit, actionName: "Trim")
        seek(to: min(max(currentTime, trimRange.lowerBound), trimRange.upperBound))
    }

    // MARK: Edits

    func setSpeed(_ speed: PlaybackSpeed) {
        var edit = document.edit; edit.speed = speed
        document.commit(edit, actionName: "Change Speed")
    }

    /// GIFs have no audio, so the audio control has nothing to change for them.
    var canToggleAudio: Bool { hasAudio && document.edit.format != .gif }

    func toggleAudio() {
        guard canToggleAudio else { return }
        var edit = document.edit; edit.removesAudio.toggle()
        document.commit(edit, actionName: edit.removesAudio ? "Remove Audio" : "Restore Audio")
    }

    func setSize(_ size: OutputSize) {
        var edit = document.edit; edit.size = size
        document.commit(edit, actionName: "Change Size")
    }

    func setFormat(_ format: ClipFormat) {
        var edit = document.edit; edit.setFormat(format)
        document.commit(edit, actionName: "Change Format")
    }

    private func documentChanged() {
        syncPlayer()
        canvas?.refresh()
        let id = document.record.id
        Task {
            _ = try? await document.flush()
            await coordinator.editsChanged(id)
        }
    }

    // MARK: Crop

    func beginCrop() {
        guard !isCropping else { return }
        isCropping = true
        cropAspect = nil
        cropDraft = document.edit.cropRect(in: document.record.pixelSize)
        canvas?.refresh()
    }

    func applyCrop() {
        guard isCropping else { return }
        let bounds = CGRect(origin: .zero, size: document.record.pixelSize)
        if let draft = cropDraft, draft.width >= 2, draft.height >= 2 {
            var edit = document.edit
            edit.crop = draft.integral == bounds ? nil : draft.intersection(bounds).integral
            document.commit(edit, actionName: "Crop")
        }
        endCrop()
    }

    func cancelCrop() { endCrop() }

    private func endCrop() {
        isCropping = false
        cropDraft = nil
        canvas?.refresh()
        if let canvas { canvas.window?.makeFirstResponder(canvas) }
    }

    func setCropAspect(_ aspect: CGFloat?) {
        cropAspect = aspect
        if let cropDraft { self.cropDraft = CropGeometry.applyingAspect(aspect, to: cropDraft, within: sourceBounds) }
    }

    func setCropSize(width: CGFloat? = nil, height: CGFloat? = nil) {
        guard let cropDraft else { return }
        self.cropDraft = CropGeometry.resized(cropDraft, width: width, height: height, aspect: cropAspect, within: sourceBounds)
    }

    private var sourceBounds: CGRect { CGRect(origin: .zero, size: document.record.pixelSize) }

    // MARK: Commands

    func execute(_ command: CommandID) {
        switch command {
        case .toolCrop: isCropping ? applyCrop() : beginCrop()
        case .trimStart:
            setTrim(min(currentTime, trimRange.upperBound - VideoEdit.minimumDuration)...trimRange.upperBound)
        case .trimEnd:
            setTrim(trimRange.lowerBound...max(currentTime, trimRange.lowerBound + VideoEdit.minimumDuration))
        case .toggleAudio: toggleAudio()
        case .copy: copy()
        case .save: save(asNew: NSEvent.modifierFlags.contains(.option))
        case .saveAs: save(asNew: true)
        case .done: isCropping ? applyCrop() : close?()
        case .loopPlayback: coordinator.preferences.editor.loopsPlayback.toggle()
        default: break
        }
    }

    // MARK: Output

    func copy() {
        guard !busy else { return }
        let ticket = coordinator.clipboard.begin()
        let shouldClose = coordinator.preferences.editor.closesAfterCopy != NSEvent.modifierFlags.contains(.option)
        let options = coordinator.preferences.snapshot().renderOptions
        let id = document.record.id
        coordinator.retain(id)
        output = .copying
        Task {
            defer { coordinator.release(id) }
            do {
                let snapshot = try await document.flush()
                let file = try await coordinator.clipExporter.rendered(snapshot, options: options)
                if coordinator.clipboard.write(file: file, ticket: ticket, onPaste: coordinator.pasteHandler(for: id)) {
                    try await coordinator.store.markCopied(id, revision: snapshot.revision)
                    await coordinator.refreshRecords()
                    finishOutput(.copied)
                    if shouldClose { close?() }
                } else { output = nil }
            } catch {
                output = nil
                coordinator.showError(error, title: "Couldn't copy clip")
            }
        }
    }

    func save(asNew: Bool = false) {
        guard !busy else { return }
        output = .saving
        let id = document.record.id
        coordinator.retain(id)
        Task {
            defer { saveAndClose = false; coordinator.release(id) }
            do {
                let snapshot = try await document.flush()
                let settings = coordinator.preferences.snapshot()
                let associated = await coordinator.store.records().first { $0.id == id }?.outputFile
                    .flatMap { $0.url.pathExtension == snapshot.edit.format.fileExtension ? $0 : nil }
                if asNew {
                    guard await coordinator.saveAs(snapshot) else { output = nil; return }
                } else if let associated {
                    do {
                        let receipt = try await coordinator.clipExporter.save(snapshot, to: associated.url, options: settings.renderOptions,
                                                                              replacing: associated.fingerprint)
                        try await coordinator.store.markSaved(receipt)
                    } catch ClipExporter.Failure.externallyModified {
                        let alert = NSAlert(); alert.messageText = "The saved clip changed outside Shotty"
                        alert.informativeText = "Replace that file with this version, or save another copy."
                        alert.addButton(withTitle: "Save As…"); alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
                        switch alert.runModal() {
                        case .alertFirstButtonReturn:
                            guard await coordinator.saveAs(snapshot) else { output = nil; return }
                        case .alertSecondButtonReturn:
                            let fingerprint = try await coordinator.clipExporter.fingerprint(at: associated.url)
                            let receipt = try await coordinator.clipExporter.save(snapshot, to: associated.url, options: settings.renderOptions,
                                                                                  replacing: fingerprint)
                            try await coordinator.store.markSaved(receipt)
                        default: output = nil; return
                        }
                    }
                } else {
                    let receipt = try await coordinator.clipExporter.export(snapshot, to: settings.clipDirectory,
                                                                            options: settings.renderOptions)
                    try await coordinator.store.markSaved(receipt)
                }
                await coordinator.refreshRecords()
                finishOutput(.saved)
                if coordinator.preferences.editor.closesAfterSave || saveAndClose { close?() }
            } catch {
                output = nil
                coordinator.showError(error, title: "Couldn't save clip")
            }
        }
    }

    /// A checkmark replaces the button for a moment.
    private func finishOutput(_ done: Output) {
        output = done
        outputReset?.cancel()
        outputReset = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            if self?.output == done { self?.output = nil }
        }
    }
}

private struct ClipEditorView: View {
    @Bindable var model: ClipEditorModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if model.isCropping { cropBar } else { editBar }
            }
            .labelStyle(.iconOnly)
            .padding(.leading, EditorBar.leadingInset).padding(.trailing, EditorBar.edgeInset)
            .frame(height: EditorBar.height)
            .background(EditorBarBackground(isTranslucent: translucentBars))
            Divider()
            PlayerCanvas(model: model)
            Divider()
            TimelineBar(model: model)
            Divider()
            outputBar
        }
        // The hosting view sets the window's minimum size from this, so the bars never clip.
        .frame(minWidth: ClipEditorWindowController.minimumSize.width, minHeight: ClipEditorWindowController.minimumSize.height)
    }

    private var translucentBars: Bool { model.coordinator.preferences.general.usesTranslucentWindows }

    @ViewBuilder private var editBar: some View {
        let edit = model.document.edit
        Button("Crop", systemImage: "crop") { model.beginCrop() }
            .buttonStyle(.editorBarIcon)
            .help(help(.toolCrop))
        HStack(spacing: EditorBar.buttonSpacing) {
            choice("Speed", symbol: "gauge.with.dots.needle.67percent", PlaybackSpeed.allCases.map { ($0.title, $0) },
                   selection: edit.speed) { model.setSpeed($0) }
            Button(edit.removesAudio ? "Restore Audio" : "Remove Audio",
                   systemImage: model.canToggleAudio && !edit.removesAudio ? "speaker.wave.2" : "speaker.slash") { model.toggleAudio() }
                .buttonStyle(.editorBarIcon)
                .disabled(!model.canToggleAudio)
                .help(!model.hasAudio ? "This clip has no audio"
                      : edit.format == .gif ? "GIFs have no audio"
                      : help(.toggleAudio, title: edit.removesAudio ? "Restore Audio" : "Remove Audio"))
            choice("Size", symbol: "arrow.up.left.and.arrow.down.right", OutputSize.allCases.map { ($0.title, $0) },
                   selection: edit.size) { model.setSize($0) }
        }
        .padding(.leading, EditorBar.groupSpacing)
        Spacer(minLength: EditorBar.groupSpacing)
        Button("Done") { model.close?() }.buttonStyle(.editorBarProminent).help(help(.done))
    }

    private var cropBar: some View {
        CropBar(size: model.cropDraft?.size ?? .zero, aspect: model.cropAspect,
                aspects: [("Freeform", nil), ("16:9", 16 / 9), ("4:3", 4 / 3), ("Square", 1), ("9:16", 9 / 16)],
                resize: { model.setCropSize(width: $0, height: $1) },
                setAspect: { model.setCropAspect($0) },
                cancel: { model.cancelCrop() },
                apply: { model.applyCrop() })
    }

    /// A menu of `choices` that shows the chosen one beside `symbol`, such as the playback speed.
    private func choice<Value: Equatable>(_ title: String, symbol: String, _ choices: [(title: String, value: Value)],
                                          selection: Value, select: @escaping (Value) -> Void) -> some View {
        let value = choices.first { $0.value == selection }?.title ?? ""
        return OptionButton(title) {
            Label(value, systemImage: symbol).labelStyle(.titleAndIcon).monospacedDigit()
        } menu: {
            let menu = OptionMenu.make(showsState: true)
            for choice in choices {
                menu.addItem(OptionMenu.item(choice.title, isOn: choice.value == selection) { select(choice.value) })
            }
            return menu
        }
        .accessibilityValue(value)
    }

    private var outputBar: some View {
        ZStack {
            // Format and size on the left, output on the right, with the drag handle between them.
            HStack(spacing: EditorBar.buttonSpacing) {
                FormatStrip(model: model)
                Text(verbatim: "\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
                    .font(EditorBar.font).monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                Spacer()
                OutputButton(model: model, kind: .copy).help(help(.copy, title: "Copy Clip"))
                OutputButton(model: model, kind: .save).help("\(help(.save)). Option-click to save as.")
            }
            .buttonStyle(.editorBarIcon)
            .labelStyle(.iconOnly)
            EditorDragHandle(noun: "clip", placeholderSymbol: "film") {
                guard let writer = model.coordinator.dragItem(model.document.snapshot) else { return nil }
                model.pause()
                // A small frame of the clip, as the editor itself disappears.
                let preview = model.filmstrip.first.map { frame in
                    let scale = min(120 / CGFloat(frame.width), 120 / CGFloat(frame.height), 1)
                    return NSImage(cgImage: frame, size: CGSize(width: CGFloat(frame.width) * scale, height: CGFloat(frame.height) * scale))
                }
                return (writer, preview)
            } dropped: {
                model.close?()
            }
            .frame(width: 115, height: EditorBar.buttonHeight)
        }
        .padding(.horizontal, EditorBar.edgeInset)
        .frame(height: EditorBar.height)
        .background(EditorBarBackground(isTranslucent: translucentBars))
    }

    private func help(_ command: CommandID, title: String? = nil) -> String {
        [title ?? command.title, model.commands.shortcut(for: command)?.displayString].compactMap { $0 }.joined(separator: " ")
    }
}

/// Play and pause, the timeline, and the playhead time. A view of its own, so the playhead's
/// 60 Hz updates redraw only this bar.
private struct TimelineBar: View {
    let model: ClipEditorModel

    var body: some View {
        let edit = model.document.edit
        let range = model.trimRange
        // Output time: from the trim start, at the clip's speed.
        let elapsed = (min(max(model.currentTime, range.lowerBound), range.upperBound) - range.lowerBound) / edit.speed.rawValue
        HStack(spacing: 12) {
            Button(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlay() }
                .buttonStyle(.editorBarIcon)
                .labelStyle(.iconOnly)
                .help("\(model.isPlaying ? "Pause" : "Play") Space")
            TimelineStrip(model: model)
                .frame(height: 44)
            Text(verbatim: "\(ClipTime.format(elapsed, tenths: true)) / \(ClipTime.format(edit.outputDuration(sourceDuration: model.document.record.duration), tenths: true))")
                .font(EditorBar.font).monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, EditorBar.edgeInset)
        .frame(height: EditorBar.timelineHeight)
        .background(EditorBarBackground(isTranslucent: model.coordinator.preferences.general.usesTranslucentWindows))
    }
}

/// MP4 and GIF as one capsule strip; the active format is an accent capsule. Pressing darkens a
/// choice like the other bar buttons.
private struct FormatStrip: View {
    let model: ClipEditorModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ClipFormat.allCases, id: \.self) { format in
                let active = model.document.edit.format == format
                Button { model.setFormat(format) } label: {
                    Text(format.title).font(EditorBar.font)
                        .frame(width: 46, height: EditorBar.toolHeight)
                        .contentShape(Capsule())
                }
                .buttonStyle(EditorCapsuleButtonStyle(fill: active ? .accentColor : .clear))
                .foregroundStyle(active ? Color.white : .primary)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(1)
        .background(EditorBar.groupFill, in: Capsule())
        .help("Copy, save, and drag as MP4 or GIF")
    }
}

/// Copy or Save: a spinner while the clip renders and a checkmark once it is done.
private struct OutputButton: View {
    enum Kind { case copy, save }
    let model: ClipEditorModel
    let kind: Kind

    var body: some View {
        let (working, done): (ClipEditorModel.Output, ClipEditorModel.Output) = kind == .copy ? (.copying, .copied) : (.saving, .saved)
        Button {
            if kind == .copy { model.copy() } else { model.save(asNew: NSEvent.modifierFlags.contains(.option)) }
        } label: {
            if model.output == working {
                ProgressView().controlSize(.small)
            } else {
                Label(kind == .copy ? "Copy Clip" : "Save",
                      systemImage: model.output == done ? "checkmark" : kind == .copy ? "doc.on.doc" : "square.and.arrow.down")
            }
        }
        .disabled(model.busy)
    }
}
