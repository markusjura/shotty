import AppKit
import Observation
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    let model: EditorWindowModel
    private var closing = false
    var didClose: (() -> Void)?

    init(record: CaptureRecord, image: CGImage, coordinator: AppCoordinator, commands: CommandRegistry) {
        model = EditorWindowModel(record: record, image: image, coordinator: coordinator, commands: commands)
        let window = NSWindow(contentRect: Self.initialFrame(for: record),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Shotty · \(record.pixelWidth) × \(record.pixelHeight)"
        window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        // An empty unified toolbar places the traffic lights at x 19, 42, 65 and centers them in the
        // 51 pt bar, as in CleanShot. The SwiftUI bar draws everything else beneath the titlebar.
        window.toolbar = NSToolbar(identifier: "editor")
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.minSize = NSSize(width: 720, height: 400)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: EditorWindowView(model: model).ignoresSafeArea())
        window.center()
        model.close = { [weak self] in self?.finishAndClose() }
    }
    required init?(coder: NSCoder) { nil }

    /// Like CleanShot, the window wraps the image at the zoom the canvas will fit it to: actual size
    /// when the screen has room, otherwise scaled down to fit it.
    private static func initialFrame(for record: CaptureRecord) -> CGRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame.insetBy(dx: 32, dy: 32) ?? CGRect(x: 0, y: 0, width: 1100, height: 780)
        let scale = screen?.backingScaleFactor ?? 2
        let chrome = CGSize(width: 2 * EditorCanvas.margin, height: 2 * EditorCanvas.margin + 2 * EditorBar.height + 2)
        let image = CGSize(width: CGFloat(record.pixelWidth) / scale, height: CGFloat(record.pixelHeight) / scale)
        let zoom = min(1, (visible.width - chrome.width) / image.width, (visible.height - chrome.height) / image.height)
        return CGRect(x: 0, y: 0, width: max(image.width * zoom + chrome.width, 720),
                      height: max(image.height * zoom + chrome.height, 400))
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closing { return true }
        let id = model.document.record.id
        let record = model.coordinator.records.first { $0.id == id }
        if !model.coordinator.isThumbnailRetained(id), record?.savedRevision != model.document.revision {
            let alert = NSAlert(); alert.messageText = "Keep your edited capture?"
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
        model.canvas.finishText()
        Task {
            do {
                _ = try await model.document.flush()
                await model.coordinator.keepEditedCapture(model.document.record.id)
                closing = true; window?.close()
            } catch {
                window?.makeKeyAndOrderFront(nil)  // A Drag Me drop hides the window before closing.
                model.coordinator.showError(error, title: "Couldn't retain edits")
            }
        }
    }
    func windowWillClose(_ notification: Notification) { didClose?() }
    func windowDidBecomeKey(_ notification: Notification) { model.commands.contextDidChange() }
    func windowDidResignKey(_ notification: Notification) {
        model.commands.contextDidChange()
        model.canvas.cancelInteraction()
        model.canvas.finishText()
    }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.document.undoManager }
}

@MainActor @Observable
final class EditorWindowModel {
    let document: EditorDocument
    let canvas: EditorCanvas
    let coordinator: AppCoordinator
    let commands: CommandRegistry
    var tool: EditorTool = .select {
        willSet { if newValue != tool { styleGesture(false) } }
        didSet { canvas.tool = tool }
    }
    var selectionVersion = 0
    var zoomLabel = "100%"
    var busy = false
    var saveAndClose = false
    var close: (() -> Void)?
    private var styleDraft: AnnotationDocument?
    private var defaultsDraft: EditorToolDefaults?
    private var isStyling = false

    init(record: CaptureRecord, image: CGImage, coordinator: AppCoordinator, commands: CommandRegistry) {
        self.coordinator = coordinator; self.commands = commands
        let document = EditorDocument(record: record, store: coordinator.store)
        self.document = document
        canvas = EditorCanvas(document: document, source: image, preferences: coordinator.preferences, commands: commands)
        document.onChange = { [weak self] in
            self?.canvas.documentChanged(); self?.selectionVersion += 1
        }
        canvas.selectionChanged = { [weak self] in
            guard let self else { return }
            if isStyling { styleGesture(false) }
            selectionVersion += 1
            if tool != canvas.tool { tool = canvas.tool }
        }
        canvas.zoomChanged = { [weak self] in self?.updateZoomLabel() }
        canvas.command = { [weak self] in self?.execute($0) }
    }

    var selectedAnnotations: [Annotation] {
        _ = selectionVersion
        return (styleDraft ?? document.state).annotations.filter { canvas.selected.contains($0.id) }
    }
    var styleTool: EditorTool { selectedAnnotations.first?.tool ?? tool }
    var defaults: EditorToolDefaults {
        var values = defaultsDraft ?? coordinator.preferences.editor.tools
        guard let annotation = selectedAnnotations.first else { return values }
        switch annotation.content {
        case .arrow(_, _, _, let s): values.arrow = s
        case .rectangle(_, let s): values.rectangle = s
        case .ellipse(_, let s): values.ellipse = s
        case .line(_, _, let s): values.line = s
        case .text(_, _, let s): values.text = s
        case .redact(_, let s): values.redact = s
        case .spotlight(_, let s): values.spotlight = s
        case .counter(_, _, let s): values.counter = s
        }
        return values
    }

    func hasMixedValues<Value: Equatable>(_ key: KeyPath<EditorToolDefaults, Value>) -> Bool {
        let selected = selectedAnnotations.filter { $0.tool == styleTool }
        guard let first = selected.first else { return false }
        let baseline = values(for: first, base: defaults)[keyPath: key]
        return selected.dropFirst().contains { values(for: $0, base: defaults)[keyPath: key] != baseline }
    }

    private func values(for annotation: Annotation, base: EditorToolDefaults) -> EditorToolDefaults {
        var values = base
        switch annotation.content {
        case .arrow(_, _, _, let style): values.arrow = style
        case .rectangle(_, let style): values.rectangle = style
        case .ellipse(_, let style): values.ellipse = style
        case .line(_, _, let style): values.line = style
        case .text(_, _, let style): values.text = style
        case .redact(_, let style): values.redact = style
        case .spotlight(_, let style): values.spotlight = style
        case .counter(_, _, let style): values.counter = style
        }
        return values
    }

    /// Styles the selection, if any. The choice always becomes the default for new objects.
    private func updateStyles(_ transform: (inout EditorToolDefaults) -> Void) {
        var stored = defaultsDraft ?? coordinator.preferences.editor.tools; transform(&stored)
        if isStyling { defaultsDraft = stored } else { coordinator.preferences.editor.tools = stored }
        guard !selectedAnnotations.isEmpty else { return }
        var state = styleDraft ?? document.state
        let selected = canvas.selected
        var changed = defaults; transform(&changed)
        let dimChanged = changed.spotlight.dimPercent != defaults.spotlight.dimPercent
        for i in state.annotations.indices {
            let annotation = state.annotations[i]
            guard selected.contains(annotation.id) else {
                if dimChanged, case .spotlight(let rect, var style) = annotation.content {
                    style.dimPercent = changed.spotlight.dimPercent
                    state.annotations[i].content = .spotlight(rect: rect, style: style)
                }
                continue
            }
            var values = values(for: annotation, base: coordinator.preferences.editor.tools); transform(&values)
            switch annotation.content {
            case .arrow(let a, let b, let bend, _):
                let control = values.arrow.style == .curved ? (bend ?? EditorGeometry.defaultBend(start: a, end: b)) : nil
                state.annotations[i].content = .arrow(start: a, end: b, bend: control, style: values.arrow)
            case .rectangle(let rect, _): state.annotations[i].content = .rectangle(rect: rect, style: values.rectangle)
            case .ellipse(let rect, _): state.annotations[i].content = .ellipse(rect: rect, style: values.ellipse)
            case .line(let a, let b, _): state.annotations[i].content = .line(start: a, end: b, style: values.line)
            case .text(let rect, let text, _): state.annotations[i].content = .text(rect: rect, text: text, style: values.text)
            case .redact(let rect, _): state.annotations[i].content = .redact(rect: rect, style: values.redact)
            case .spotlight(let rect, _): state.annotations[i].content = .spotlight(rect: rect, style: values.spotlight)
            case .counter(let center, let n, _): state.annotations[i].content = .counter(center: center, number: n, style: values.counter)
            }
        }
        if isStyling { styleDraft = state; canvas.setStylePreview(state); selectionVersion += 1 }
        else { document.commit(state, actionName: "Change Style") }
    }

    func styleGesture(_ editing: Bool) {
        isStyling = editing
        if !editing, let values = defaultsDraft {
            defaultsDraft = nil
            coordinator.preferences.editor.tools = values
        }
        if !editing, let state = styleDraft {
            styleDraft = nil; canvas.setStylePreview(nil)
            document.commit(state, actionName: "Change Style")
        }
    }
    func binding<Value>(_ keyPath: WritableKeyPath<EditorToolDefaults, Value>) -> Binding<Value> {
        Binding(get: { self.defaults[keyPath: keyPath] }, set: { value in self.updateStyles { $0[keyPath: keyPath] = value } })
    }
    func colorBinding(_ keyPath: WritableKeyPath<EditorToolDefaults, RGBAColor>) -> Binding<Color> {
        Binding(get: { Color(cgColor: self.defaults[keyPath: keyPath].cgColor) }, set: { color in
            guard let value = RGBAColor(NSColor(color).cgColor) else { return }
            self.setColor(value, keyPath)
        })
    }
    /// A filled shape keeps its fill in step with its outline color.
    func setColor(_ color: RGBAColor, _ keyPath: WritableKeyPath<EditorToolDefaults, RGBAColor>) {
        updateStyles { values in
            values[keyPath: keyPath] = color
            if keyPath == \.rectangle.strokeColor, values.rectangle.fillColor != nil { values.rectangle.fillColor = color }
            if keyPath == \.ellipse.strokeColor, values.ellipse.fillColor != nil { values.ellipse.fillColor = color }
        }
    }
    /// Fills each shape with its own outline color, or removes the fill.
    func setFilled(_ filled: Bool, for tool: EditorTool) {
        updateStyles { values in
            switch tool {
            case .rectangle: values.rectangle.fillColor = filled ? values.rectangle.strokeColor : nil
            case .ellipse: values.ellipse.fillColor = filled ? values.ellipse.strokeColor : nil
            default: break
            }
        }
    }
    /// `value` is image pixels per display backing pixel (1 = actual pixels); nil fits the window.
    func setZoom(_ value: CGFloat?) {
        if let value { canvas.setZoom(value / (canvas.window?.backingScaleFactor ?? 2)) } else { canvas.fit() }
    }
    private func updateZoomLabel() {
        zoomLabel = "\(Int((canvas.zoom * (canvas.window?.backingScaleFactor ?? 2) * 100).rounded()))%"
    }
    func execute(_ command: CommandID) {
        if let tool = command.tool { self.tool = tool; return }
        switch command {
        case .copyImage: copy()
        case .save: save(asNew: NSEvent.modifierFlags.contains(.option))
        case .saveAs: save(asNew: true)
        case .done:
            if canvas.isEditingText { canvas.finishText() }
            else if tool == .crop { canvas.applyCrop(); tool = .select }
            else { close?() }
        case .duplicate: canvas.duplicateSelected()
        case .zoomIn: canvas.setZoom(canvas.zoom * 1.25)
        case .zoomOut: canvas.setZoom(canvas.zoom / 1.25)
        case .zoomToFit: setZoom(nil)
        case .actualSize: setZoom(1)
        default: break
        }
    }
    func copy() {
        canvas.finishText()
        let ticket = coordinator.clipboard.begin()
        let shouldClose = coordinator.preferences.editor.closesAfterCopy != NSEvent.modifierFlags.contains(.option)
        let options = coordinator.preferences.snapshot().exportOptions
        coordinator.retain(document.record.id)
        Task {
            defer { coordinator.release(document.record.id) }
            do {
                let snapshot = try await document.flush()
                var png = options; png.format = .png
                let data = try await coordinator.exporter.encodedData(snapshot, options: png)
                if coordinator.clipboard.write(data, type: .png, ticket: ticket, onPaste: coordinator.pasteHandler(for: document.record.id)) {
                    try await coordinator.store.markCopied(snapshot); await coordinator.refreshRecords()
                    if shouldClose { close?() }
                }
            } catch { coordinator.showError(error, title: "Couldn't copy image") }
        }
    }
    func save(asNew: Bool = false) {
        guard !busy else { return }
        canvas.finishText(); busy = true
        coordinator.retain(document.record.id)
        Task {
            defer { busy = false; saveAndClose = false; coordinator.release(document.record.id) }
            do {
                let snapshot = try await document.flush()
                let settings = coordinator.preferences.snapshot()
                let associated = await coordinator.store.records().first { $0.id == snapshot.captureID }?.outputFile
                if asNew { guard await coordinator.saveAs(snapshot.captureID, snapshot: snapshot) else { return } }
                else if let associated {
                    var options = settings.exportOptions
                    options.format = ["jpg", "jpeg"].contains(associated.url.pathExtension.lowercased()) ? .jpeg : .png
                    do {
                        let receipt = try await coordinator.exporter.save(snapshot, to: associated.url, options: options, replacing: associated.fingerprint)
                        try await coordinator.store.markSaved(receipt)
                    } catch ExportService.Failure.externallyModified {
                        let alert = NSAlert(); alert.messageText = "The saved image changed outside Shotty"
                        alert.informativeText = "Replace that file with this revision, or save another copy."
                        alert.addButton(withTitle: "Save As…"); alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
                        switch alert.runModal() {
                        case .alertFirstButtonReturn: guard await coordinator.saveAs(snapshot.captureID, snapshot: snapshot) else { return }
                        case .alertSecondButtonReturn:
                            let fingerprint = try await coordinator.exporter.fingerprint(at: associated.url)
                            let receipt = try await coordinator.exporter.save(snapshot, to: associated.url, options: options, replacing: fingerprint)
                            try await coordinator.store.markSaved(receipt)
                        default: return
                        }
                    }
                } else {
                    let receipt = try await coordinator.exporter.export(snapshot, to: settings.saveDirectory, options: settings.exportOptions)
                    try await coordinator.store.markSaved(receipt)
                }
                await coordinator.refreshRecords()
                if coordinator.preferences.editor.closesAfterSave || saveAndClose { close?() }
            } catch { coordinator.showError(error, title: "Couldn't save image") }
        }
    }
}

private struct EditorWindowView: View {
    @Bindable var model: EditorWindowModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if model.tool == .crop {
                    cropBar
                } else {
                    // Crop changes the whole image, so it sits apart from the drawing tools, as in CleanShot.
                    ToolButton(model: model, tool: .crop, isStandalone: true)
                    ToolStrip(model: model).padding(.leading, EditorBar.groupSpacing)
                    // Select without an editable selection has no options; hide rather than disable.
                    if model.styleTool != .select {
                        EditorOptions(model: model).padding(.leading, EditorBar.groupSpacing)
                    }
                    Spacer(minLength: EditorBar.groupSpacing)
                    HStack(spacing: EditorBar.buttonSpacing) {
                        Button("Copy Image", systemImage: "doc.on.doc") { model.copy() }
                            .help(help(.copyImage))
                        Button("Save", systemImage: "square.and.arrow.down") { model.save(asNew: NSEvent.modifierFlags.contains(.option)) }
                            .help("\(help(.save)). Option-click to save as.")
                            .disabled(model.busy)
                    }
                    .buttonStyle(.editorBarIcon)
                    Button("Done") { model.close?() }.buttonStyle(.editorBarProminent).padding(.leading, 10)
                }
            }
            .labelStyle(.iconOnly)
            .padding(.leading, EditorBar.leadingInset).padding(.trailing, EditorBar.edgeInset)
            .frame(height: EditorBar.height)
            .background(EditorBarBackground())
            Divider()
            CanvasContainer(canvas: model.canvas)
            Divider()
            ZStack {
                HStack {
                    ZoomMenu(model: model)
                    Spacer()
                }
                EditorDragHandle(model: model).frame(width: 115, height: 31)
            }
            .padding(.horizontal, EditorBar.edgeInset)
            .frame(height: EditorBar.height)
            .background(EditorBarBackground())
        }
    }

    @ViewBuilder private var cropBar: some View {
        // Canvas state is AppKit-owned; its callback invalidates these controls.
        let _ = model.selectionVersion
        let cropSize = model.canvas.cropDraft?.size ?? .zero
        HStack(spacing: 6) {
            Text("Crop").fontWeight(.medium)
            TextField("Width", value: Binding(get: { Double(cropSize.width) }, set: { model.canvas.setCropSize(width: $0) }), format: .number).frame(width: 70)
            Text("×")
            TextField("Height", value: Binding(get: { Double(cropSize.height) }, set: { model.canvas.setCropSize(height: $0) }), format: .number).frame(width: 70)
            Picker("Aspect", selection: Binding(get: { model.canvas.cropAspect }, set: { model.canvas.setCropAspect($0) })) {
                Text("Freeform").tag(CGFloat?.none)
                Text("Square").tag(CGFloat?.some(1))
                Text("16:9").tag(CGFloat?.some(16 / 9))
                Text("4:3").tag(CGFloat?.some(4 / 3))
            }.pickerStyle(.menu).labelsHidden().fixedSize()
            Spacer()
            Button("Cancel") { model.canvas.cancelCrop(); model.tool = .select }.buttonStyle(.editorBar)
            Button("Apply") { model.canvas.applyCrop(); model.tool = .select }
                .keyboardShortcut(.defaultAction).buttonStyle(.editorBarProminent)
        }
    }

    private func help(_ command: CommandID) -> String {
        [command.title, model.commands.shortcut(for: command)?.displayString].compactMap { $0 }.joined(separator: " ")
    }
}

/// CleanShot's zoom control: the current percentage, even while fitting, with zoom steps,
/// Fit Canvas, and three fixed levels.
private struct ZoomMenu: View {
    let model: EditorWindowModel
    var body: some View {
        Menu {
            item("Zoom In", .zoomIn)
            item("Zoom Out", .zoomOut)
            Divider()
            item("Fit Canvas", .zoomToFit)
            Divider()
            Button("50%") { model.setZoom(0.5) }
            item("100%", .actualSize)
            Button("200%") { model.setZoom(2) }
        } label: {
            Text(model.zoomLabel).font(.system(size: 13, weight: .medium)).monospacedDigit()
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(width: 70, height: EditorBar.buttonHeight)
        .background(EditorBar.buttonFill, in: Capsule())
        .help("Zoom")
    }

    private func item(_ title: String, _ command: CommandID) -> some View {
        Button(title) { model.execute(command) }
            .keyboardShortcut(model.commands.shortcut(for: command)?.keyboardShortcut)
    }
}

/// The drawing tools as one capsule strip. Thin separators divide tools, except beside the
/// active tool, whose accent capsule fills the strip's height.
private struct ToolStrip: View {
    let model: EditorWindowModel
    var body: some View {
        let tools = EditorTool.allCases.filter { $0 != .crop }
        HStack(spacing: 0) {
            ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                if index > 0 {
                    Rectangle().fill(.primary.opacity(0.15)).frame(width: 1, height: 12)
                        .opacity(model.tool == tool || model.tool == tools[index - 1] ? 0 : 1)
                }
                ToolButton(model: model, tool: tool, isStandalone: false)
            }
        }
        .background(EditorBar.groupFill, in: Capsule())
    }
}

/// One tool. The active tool is an accent capsule; Crop stands alone as a tinted capsule.
private struct ToolButton: View {
    let model: EditorWindowModel
    let tool: EditorTool
    let isStandalone: Bool

    var body: some View {
        let active = model.tool == tool
        Button { model.tool = tool } label: {
            ToolIcon(tool: tool)
                .font(.system(size: 14, weight: .medium))
                .frame(width: isStandalone ? EditorBar.iconButtonWidth : EditorBar.toolWidth,
                       height: isStandalone ? EditorBar.buttonHeight : EditorBar.toolHeight)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.white : .primary)
        .background(active ? Color.accentColor : isStandalone ? EditorBar.buttonFill : .clear, in: Capsule())
        .help([CommandID.tool(tool).title, model.commands.shortcut(for: .tool(tool))?.displayString].compactMap { $0 }.joined(separator: " "))
        .accessibilityLabel(CommandID.tool(tool).title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

private struct CanvasContainer: NSViewRepresentable {
    let canvas: EditorCanvas
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasHorizontalScroller = true; scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true; scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        scroll.documentView = canvas
        DispatchQueue.main.async { canvas.fit(); canvas.window?.makeFirstResponder(canvas); canvas.updatePreview() }
        return scroll
    }
    func updateNSView(_ nsView: NSScrollView, context: Context) { }
}

/// Centers a document smaller than the visible area instead of pinning it to the origin.
/// Larger documents scroll normally. The document's own coordinates are unchanged.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        let constrained = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView?.frame else { return constrained }
        return Self.centered(constrained, document: document)
    }

    /// Centers each axis on which `bounds` is larger than `document`.
    nonisolated static func centered(_ bounds: CGRect, document: CGRect) -> CGRect {
        var result = bounds
        if bounds.width > document.width { result.origin.x = document.midX - bounds.width / 2 }
        if bounds.height > document.height { result.origin.y = document.midY - bounds.height / 2 }
        return result
    }
}

private struct ToolIcon: View {
    let tool: EditorTool
    var body: some View { Image(systemName: symbol) }
    private var symbol: String {
        switch tool {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .text: "textformat"
        case .redact: "checkerboard.rectangle"
        case .spotlight: "rectangle.center.inset.filled"
        case .counter: "1.circle"
        case .crop: "crop"
        }
    }
}
