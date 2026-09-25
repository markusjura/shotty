import AppKit

/// Direct-manipulation canvas. One transform maps source pixels to view points:
/// view = (image - viewport.origin) * zoom + margin. The enclosing scroll view owns panning.
/// Image content is clipped to the viewport; the margin only holds handles at the image edges.
///
/// Drawing never renders the full source per pointer event. Committed documents with effects get
/// one background full render; during a gesture only the dirty regions of the draft are rendered,
/// through the same `DocumentRenderer` path as export, with generation IDs discarding stale work.
@MainActor
final class EditorCanvas: NSView, NSTextViewDelegate, NSMenuItemValidation {
    let document: EditorDocument
    let preferences: AppPreferences
    let commands: CommandRegistry
    let source: CGImage
    var command: ((CommandID) -> Void)?
    var selectionChanged: (() -> Void)?
    var tool: EditorTool = .select {
        didSet {
            guard tool != oldValue else { return }
            finishText()
            cancelGesture(restoreSelection: true)
            if tool != .crop { cropAspect = nil }
            cropDraft = tool == .crop ? CropGeometry.applyingAspect(cropAspect, to: document.state.crop ?? sourceBounds, within: sourceBounds) : nil
            viewportMayHaveChanged()
            selectionChanged?()
        }
    }
    var selected = Set<UUID>() { didSet { if selected != oldValue { needsDisplay = true; selectionChanged?(); updateAccessibility() } } }
    private(set) var zoom: CGFloat = 0.5
    /// True after `fit()` until an explicit zoom; while true, window resizes and crop changes refit.
    private(set) var isFitting = true
    /// Called after every zoom change, including fitting and pinch.
    var zoomChanged: (() -> Void)?
    private var clipObserver: NSObjectProtocol?
    private var fittedViewport: CGRect?
    var nextCounter = 1
    var cropDraft: CGRect? { didSet { needsDisplay = true } }
    private(set) var cropAspect: CGFloat?

    private enum Gesture {
        case draw(UUID)
        case move(start: CGRect, duplicated: Bool)
        case resize(UUID, EditorHandle)
        case groupResize(SelectionEdges, CGRect)
        case marquee(base: Set<UUID>)
        case pan(CGPoint)
        case crop(edges: SelectionEdges?, start: CGRect, moving: Bool)
    }
    private var gesture: Gesture?
    private var draft: AnnotationDocument?
    private var gestureState: AnnotationDocument?
    private var selectionBeforeGesture = Set<UUID>()
    private var anchor: CGPoint?
    private var windowAnchor: CGPoint?
    private var lastDrag: (point: CGPoint, modifiers: NSEvent.ModifierFlags)?
    private var autopan: Task<Void, Never>?
    private var autopanGeneration = 0
    private var marquee: CGRect?
    private var spaceHeld = false
    private var observedState: AnnotationDocument

    private var textView: CanvasTextView?
    var isEditingText: Bool { textView != nil }
    private var textID: UUID?
    private var textStyle: EditorToolDefaults.Text?
    private var textRect: CGRect?

    // Committed full preview and gesture-time region patches.
    private let previewRenderer = EditorPreviewRenderer()
    private var previewImage: CGImage?
    private var previewAnnotations: [Annotation] = []
    private var previewGeneration = 0
    private var previewTask: Task<Void, Never>?
    private struct PatchKey: Equatable { let base: Int; let annotations: [Annotation]; let rects: [CGRect] }
    private var patches: [(rect: CGRect, image: CGImage)] = []
    private var patchKey: PatchKey?
    private var patchTask: Task<Void, Never>?
    private var pendingPatch: (key: PatchKey, rects: [CGRect])?

    var sourceBounds: CGRect { CGRect(x: 0, y: 0, width: source.width, height: source.height) }
    /// Transient style edits, such as slider ticks, shown ahead of the committed document with live
    /// effect previews and without persistence. Commit once when editing ends; a committed state
    /// change clears the preview automatically.
    private(set) var stylePreview: AnnotationDocument?
    func setStylePreview(_ state: AnnotationDocument?) {
        guard state != stylePreview else { return }
        stylePreview = state
        needsDisplay = true
    }
    var visibleState: AnnotationDocument { draft ?? stylePreview ?? document.state }
    /// Crop mode edits against the whole source; otherwise the committed crop is the visible image.
    var viewport: CGRect { tool == .crop ? sourceBounds : (document.state.crop ?? sourceBounds) }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var undoManager: UndoManager? { document.undoManager }

    init(document: EditorDocument, source: CGImage, preferences: AppPreferences, commands: CommandRegistry) {
        self.document = document; self.source = source; self.preferences = preferences; self.commands = commands
        observedState = document.state
        super.init(frame: .zero)
        nextCounter = 1 + document.state.annotations.compactMap { annotation -> Int? in
            if case .counter(_, let number, _) = annotation.content { number } else { nil }
        }.reduce(0, max)
        setAccessibilityRole(.group); setAccessibilityLabel("Image annotation canvas")
        // AppKit no longer clips views by default; drawing never extends past the canvas.
        clipsToBounds = true
        updateAccessibility()
    }
    required init?(coder: NSCoder) { nil }

    isolated deinit {
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
    }

    /// Window key loss does not necessarily change its first responder, so the window controller
    /// also calls this when resigning key. A later mouse-up cannot commit the cancelled draft.
    func cancelInteraction() {
        spaceHeld = false
        cancelGesture(restoreSelection: true)
        pendingPatch = nil
        patchTask?.cancel()
        patches = []; patchKey = nil
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelInteraction()
            previewTask?.cancel()
            previewImage = nil; previewAnnotations = []
        }
        super.viewWillMove(toWindow: newWindow)
    }

    /// Called for every document notification. Persistence-only notifications keep drafts and
    /// selection; an actual state change (commit, undo, redo) ends any gesture in progress.
    func documentChanged() {
        let state = document.state
        guard state != observedState else { needsDisplay = true; return }
        observedState = state
        stylePreview = nil
        if gesture != nil { cancelGesture(restoreSelection: false) }
        selected.formIntersection(Set(state.annotations.map(\.id)))
        viewportMayHaveChanged(); updatePreview(); needsDisplay = true; updateAccessibility()
    }

    // MARK: Coordinates and zoom

    /// Room outside the image for edge handles and focus, in view points, independent of zoom.
    static let margin: CGFloat = 12

    private func viewPoint(_ image: CGPoint) -> CGPoint {
        CGPoint(x: (image.x - viewport.minX) * zoom + Self.margin, y: (image.y - viewport.minY) * zoom + Self.margin)
    }
    private func viewRect(_ image: CGRect) -> CGRect {
        CGRect(origin: viewPoint(image.origin), size: CGSize(width: image.width * zoom, height: image.height * zoom))
    }
    private func imagePoint(fromView point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - Self.margin) / zoom + viewport.minX, y: (point.y - Self.margin) / zoom + viewport.minY)
    }
    /// Pointer in image pixels, clamped to the editable area so no geometry leaves the image.
    private func imagePoint(window point: CGPoint) -> CGPoint {
        EditorGeometry.clamp(imagePoint(fromView: convert(point, from: nil)), to: viewport)
    }

    private func updateViewport() {
        let size = NSSize(width: viewport.width * zoom + 2 * Self.margin, height: viewport.height * zoom + 2 * Self.margin)
        if frame.size != size { setFrameSize(size) }
        repositionTextView()
        needsDisplay = true
    }

    /// An explicit zoom level, keeping the image point under `point` (or the view center) fixed.
    func setZoom(_ factor: CGFloat, preserving point: CGPoint? = nil) {
        isFitting = false
        applyZoom(factor, preserving: point)
    }

    private func applyZoom(_ factor: CGFloat, preserving point: CGPoint?) {
        finishText()
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let viewAnchor = point ?? CGPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        let image = imagePoint(fromView: viewAnchor)
        let offset = CGPoint(x: viewAnchor.x - clip.bounds.minX, y: viewAnchor.y - clip.bounds.minY)
        // Fit can be below the manual minimum. A subsequent zoom-out must never zoom in.
        let minimum = min(0.025, zoom)
        zoom = min(8, isFitting ? factor : max(minimum, factor))
        updateViewport()
        let moved = viewPoint(image)
        clip.scroll(to: clip.constrainBoundsRect(CGRect(origin: CGPoint(x: moved.x - offset.x, y: moved.y - offset.y),
                                                         size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
        zoomChanged?()
    }

    /// Fits the visible image to the scroll view and keeps fitting until an explicit zoom.
    func fit() {
        guard let scroll = enclosingScrollView, scroll.contentSize.width > 0, scroll.contentSize.height > 0 else { return }
        isFitting = true
        fittedViewport = viewport
        let available = CGSize(width: max(1, scroll.contentSize.width - 2 * Self.margin),
                               height: max(1, scroll.contentSize.height - 2 * Self.margin))
        applyZoom(min(available.width / viewport.width, available.height / viewport.height), preserving: nil)
    }

    /// Crop mode and committed crops change the visible image; a fitted view refits to it.
    private func viewportMayHaveChanged() {
        updateViewport()
        if isFitting, fittedViewport != viewport { fit() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let clipObserver { NotificationCenter.default.removeObserver(clipObserver) }
        clipObserver = nil
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        clipObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.clipResized() }
        }
    }

    /// Window resizes refit only in fit mode; otherwise the clip view re-centers an undersized image.
    private func clipResized() {
        if isFitting { fit(); return }
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        clip.scroll(to: clip.constrainBoundsRect(clip.bounds).origin)
        scroll.reflectScrolledClipView(clip)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        NSColor.controlBackgroundColor.setFill(); dirtyRect.fill()
        context.saveGState()
        context.translateBy(x: Self.margin, y: Self.margin)
        context.scaleBy(x: zoom, y: zoom)
        context.translateBy(x: -viewport.minX, y: -viewport.minY)
        // Pixels outside the visible image, such as source beyond a committed crop, never show.
        context.saveGState()
        context.clip(to: viewport)
        drawContent(in: context)
        context.restoreGState()
        if let crop = cropDraft ?? (tool == .crop ? document.state.crop : nil) {
            let path = CGMutablePath(); path.addRect(sourceBounds); path.addRect(crop)
            context.setFillColor(NSColor.black.withAlphaComponent(0.45).cgColor)
            context.addPath(path); context.fillPath(using: .evenOdd)
            for (_, point) in EditorGeometry.boxHandles(for: crop) { drawHandle(point, context: context) }
        }
        let state = visibleState
        let chosen = state.annotations.filter { selected.contains($0.id) && $0.id != textID }
        context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1 / zoom)
        for annotation in chosen { context.stroke(annotation.bounds) }
        if gesture.map({ if case .marquee = $0 { false } else { true } }) ?? true {
            for (_, point) in selectionHandles(in: state) { drawHandle(point, context: context) }
        }
        if let marquee {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1 / zoom); context.stroke(marquee)
        }
        context.restoreGState()
    }

    /// The composition: base image, then exact region patches of the current draft where they are
    /// ready, otherwise the source with vector annotations as an immediate fallback.
    private func drawContent(in context: CGContext) {
        let overlay = visibleState.annotations.filter { $0.id != textID }
        let hasEffects = Self.hasEffects(overlay) || (previewImage != nil && Self.hasEffects(previewAnnotations))
        guard hasEffects else {
            drawImage(source, in: sourceBounds, context: context)
            drawVectors(overlay, context: context)
            return
        }
        drawImage(previewImage ?? source, in: sourceBounds, context: context)
        let base = previewImage == nil ? [] : previewAnnotations
        let visible = CGRect(origin: imagePoint(fromView: visibleRect.origin),
                             size: CGSize(width: visibleRect.width / zoom, height: visibleRect.height / zoom)).intersection(sourceBounds)
        let dirty = EditorGeometry.dirtyRects(from: base, to: overlay, bounds: sourceBounds)
            .map { $0.intersection(visible).integral.intersection(sourceBounds) }.filter { !$0.isEmpty }
        guard !dirty.isEmpty else { return }
        let key = PatchKey(base: previewGeneration, annotations: overlay, rects: dirty)
        if patchKey == key {
            for patch in patches { drawImage(patch.image, in: patch.rect, context: context) }
            return
        }
        for rect in dirty {
            context.saveGState(); context.clip(to: rect)
            drawImage(source, in: sourceBounds, context: context)
            drawVectors(overlay, context: context)
            // The latest finished patches lag by one render; they replace most of the fallback.
            if patchKey?.base == previewGeneration {
                for patch in patches where patch.rect.intersects(rect) { drawImage(patch.image, in: patch.rect, context: context) }
            }
            context.restoreGState()
        }
        schedulePatches(key: key, rects: dirty)
    }

    private func drawVectors(_ annotations: [Annotation], context: CGContext) {
        for annotation in annotations where annotation.tool != .counter { DocumentRenderer.drawAnnotation(annotation, in: context) }
        for annotation in annotations where annotation.tool == .counter { DocumentRenderer.drawAnnotation(annotation, in: context) }
    }

    private static func hasEffects(_ annotations: [Annotation]) -> Bool {
        annotations.contains { $0.tool == .redact || $0.tool == .spotlight }
    }

    private func drawImage(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = zoom >= 2 ? .none : .high
        context.draw(image, in: CGRect(origin: .zero, size: rect.size)); context.restoreGState()
    }
    private func drawHandle(_ point: CGPoint, context: CGContext) {
        let rect = CGRect(x: point.x - 4 / zoom, y: point.y - 4 / zoom, width: 8 / zoom, height: 8 / zoom)
        context.setFillColor(NSColor.white.cgColor); context.fillEllipse(in: rect)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor); context.setLineWidth(1 / zoom); context.strokeEllipse(in: rect)
    }

    /// One object shows its own handles; several share handles on their union.
    private func selectionHandles(in state: AnnotationDocument) -> [(EditorHandle, CGPoint)] {
        let chosen = state.annotations.filter { selected.contains($0.id) && $0.id != textID }
        if chosen.count == 1 { return EditorGeometry.handles(for: chosen[0]) }
        guard let union = EditorGeometry.union(chosen) else { return [] }
        return EditorGeometry.boxHandles(for: union)
    }

    // MARK: Pointer gestures

    override func mouseDown(with event: NSEvent) {
        finishText()
        window?.makeFirstResponder(self)
        let point = imagePoint(window: event.locationInWindow)
        anchor = point; windowAnchor = event.locationInWindow
        gestureState = document.state; selectionBeforeGesture = selected
        if spaceHeld { gesture = .pan(enclosingScrollView?.contentView.bounds.origin ?? .zero); return }
        if tool == .crop {
            let rect = cropDraft ?? sourceBounds
            let edges = SelectionGeometry.edges(near: point, of: rect, tolerance: 7 / zoom)
            gesture = .crop(edges: edges, start: rect, moving: edges == nil && rect.contains(point))
            return
        }
        let tolerance = 7 / zoom
        if let (handle, _) = selectionHandles(in: document.state).first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= tolerance }) {
            let chosen = document.state.annotations.filter { selected.contains($0.id) }
            if chosen.count == 1 { gesture = .resize(chosen[0].id, handle) }
            else if case .edges(let edges) = handle, let union = EditorGeometry.union(chosen) { gesture = .groupResize(edges, union) }
            return
        }
        let hit = EditorGeometry.hit(point, in: document.state.annotations, tolerance: 6 / zoom)
        if let hit, hit.tool == .text, event.clickCount == 2 || tool == .text {
            selected = [hit.id]; beginText(point: point, existing: hit); resetGesture(); return
        }
        switch tool {
        case .select:
            if let hit {
                if event.modifierFlags.contains(.shift) {
                    if selected.contains(hit.id) { selected.remove(hit.id) } else { selected.insert(hit.id) }
                } else if !selected.contains(hit.id) { selected = [hit.id] }
                var state = document.state
                let duplicated = event.modifierFlags.contains(.option)
                if duplicated {
                    let copies = state.annotations.filter { selected.contains($0.id) }.map { annotation -> Annotation in
                        var copy = annotation; copy.id = UUID(); return copy
                    }
                    state.annotations += copies
                    gestureState = state
                    selected = Set(copies.map(\.id))
                }
                let moving = state.annotations.filter { selected.contains($0.id) }
                gesture = .move(start: EditorGeometry.union(moving) ?? .null, duplicated: duplicated)
            } else {
                let base = event.modifierFlags.contains(.shift) ? selected : []
                selected = base
                gesture = .marquee(base: base)
            }
        case .text:
            beginText(point: point); resetGesture()
        case .counter:
            var state = document.state
            let annotation = Annotation(content: .counter(center: point, number: nextCounter, style: preferences.editor.tools.counter))
            state.annotations.append(annotation)
            nextCounter += 1
            resetGesture()
            commit(state, actionName: "Add Counter")
            selected = [annotation.id]
        default:
            gesture = .draw(UUID())
            selected = []
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard gesture != nil else { return }
        lastDrag = (event.locationInWindow, event.modifierFlags)
        drag(to: event.locationInWindow, modifiers: event.modifierFlags)
        updateAutopan()
    }

    override func flagsChanged(with event: NSEvent) {
        // Shift and Option change constraints mid-gesture without further pointer movement.
        if let lastDrag, gesture != nil {
            self.lastDrag = (lastDrag.point, event.modifierFlags)
            drag(to: lastDrag.point, modifiers: event.modifierFlags)
        }
        super.flagsChanged(with: event)
    }

    private func drag(to windowPoint: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard let anchor, let gesture, let original = gestureState else { return }
        let point = imagePoint(window: windowPoint)
        let delta = CGVector(dx: point.x - anchor.x, dy: point.y - anchor.y)
        var state = original
        switch gesture {
        case .draw(let id):
            if let annotation = makeAnnotation(id: id, start: anchor, end: point, modifiers: modifiers) { state.annotations.append(annotation) }
        case .move(let start, _):
            var offset = CGSize(width: delta.dx, height: delta.dy)
            if modifiers.contains(.shift) { if abs(offset.width) >= abs(offset.height) { offset.height = 0 } else { offset.width = 0 } }
            if !start.isNull { offset = EditorGeometry.clampedOffset(offset, moving: start, within: viewport) }
            state.annotations = state.annotations.map { selected.contains($0.id) ? $0.translated(by: offset) : $0 }
        case .resize(let id, let handle):
            if let index = state.annotations.firstIndex(where: { $0.id == id }) {
                state.annotations[index] = EditorGeometry.resized(state.annotations[index], handle: handle, delta: delta,
                                                                   limit: viewport, constrained: modifiers.contains(.shift))
            }
        case .groupResize(let edges, let start):
            let target = EditorGeometry.resizedBounds(start, edges: edges, delta: delta, limit: viewport,
                                                       constrained: modifiers.contains(.shift))
            guard !target.isNull else { return }
            let scaled = EditorGeometry.scaled(state.annotations.filter { selected.contains($0.id) }, from: start, to: target)
            let byID = Dictionary(uniqueKeysWithValues: scaled.map { ($0.id, $0) })
            state.annotations = state.annotations.map { byID[$0.id] ?? $0 }
        case .marquee(let base):
            let rect = SelectionGeometry.rectangle(from: anchor, to: point, square: false, centered: false)
            marquee = rect
            selected = EditorGeometry.marqueeSelection(base: base, rect: rect, annotations: original.annotations)
            needsDisplay = true
            return
        case .pan(let origin):
            guard let windowAnchor, let scroll = enclosingScrollView else { return }
            scroll.contentView.scroll(to: CGPoint(x: origin.x - windowPoint.x + windowAnchor.x, y: origin.y + windowPoint.y - windowAnchor.y))
            scroll.reflectScrolledClipView(scroll.contentView)
            return
        case .crop(let edges, let start, let moving):
            cropDraft = CropGeometry.dragged(start, edges: edges, moving: moving, from: anchor, to: point,
                                             aspect: cropAspect, within: sourceBounds,
                                             snap: modifiers.contains(.command) ? 0 : 6 / zoom)
            selectionChanged?()
            return
        }
        draft = state
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        stopAutopan()
        guard let finished = gesture else { return }
        let travelled = windowAnchor.map { hypot(event.locationInWindow.x - $0.x, event.locationInWindow.y - $0.y) } ?? 0
        let result = draft
        let before = selectionBeforeGesture
        resetGesture()
        // A click without meaningful movement creates, moves, or duplicates nothing.
        if let result, result != document.state, travelled >= 3 {
            switch finished {
            case .draw(let id):
                commit(result, actionName: "Draw \(tool.rawValue.capitalized)")
                if document.state.annotations.contains(where: { $0.id == id }) { selected = [id] }
            case .move(_, let duplicated): commit(result, actionName: duplicated ? "Duplicate Objects" : "Move Objects")
            default: commit(result, actionName: "Transform Objects")
            }
        } else if case .move(_, true) = finished {
            selected = before
        }
        selected.formIntersection(Set(document.state.annotations.map(\.id)))
        needsDisplay = true
    }

    /// Escape, focus loss, or an external document change. The release that follows does nothing.
    private func cancelGesture(restoreSelection: Bool) {
        stopAutopan()
        if case .crop(_, let start, _) = gesture { cropDraft = start }
        if restoreSelection, gesture != nil { selected = selectionBeforeGesture }
        resetGesture()
    }

    private func resetGesture() {
        draft = nil; gestureState = nil; anchor = nil; windowAnchor = nil; gesture = nil; marquee = nil; lastDrag = nil
        needsDisplay = true
    }

    // MARK: Edge auto-pan

    /// While a drag rests beyond the visible edge, scroll toward it at up to 30 points per frame
    /// and reapply the drag, so objects and marquees can reach offscreen image areas.
    private func updateAutopan() {
        guard autopan == nil, overshoot() != .zero else { return }
        autopanGeneration &+= 1
        let generation = autopanGeneration
        autopan = Task { [weak self] in
            while let self, self.gesture != nil, let lastDrag = self.lastDrag, let scroll = self.enclosingScrollView {
                let step = self.overshoot()
                if step == .zero { break }
                let clip = scroll.contentView
                let target = CGRect(origin: CGPoint(x: clip.bounds.minX + max(-30, min(30, step.width)),
                                                    y: clip.bounds.minY + max(-30, min(30, step.height))), size: clip.bounds.size)
                let destination = clip.constrainBoundsRect(target).origin
                if destination == clip.bounds.origin { break }
                clip.scroll(to: destination)
                scroll.reflectScrolledClipView(clip)
                self.drag(to: lastDrag.point, modifiers: lastDrag.modifiers)
                do { try await Task.sleep(for: .milliseconds(16)) } catch { break }
            }
            if self?.autopanGeneration == generation { self?.autopan = nil }
        }
    }
    private func stopAutopan() { autopanGeneration &+= 1; autopan?.cancel(); autopan = nil }

    private func overshoot() -> CGSize {
        guard let lastDrag, let gesture else { return .zero }
        if case .pan = gesture { return .zero }
        let point = convert(lastDrag.point, from: nil), visible = visibleRect
        return CGSize(width: point.x < visible.minX ? point.x - visible.minX : point.x > visible.maxX ? point.x - visible.maxX : 0,
                      height: point.y < visible.minY ? point.y - visible.minY : point.y > visible.maxY ? point.y - visible.maxY : 0)
    }

    private func makeAnnotation(id: UUID, start: CGPoint, end: CGPoint, modifiers: NSEvent.ModifierFlags) -> Annotation? {
        let defaults = preferences.editor.tools
        let rect = SelectionGeometry.rectangle(from: start, to: end, square: modifiers.contains(.shift),
                                               centered: modifiers.contains(.option)).intersection(viewport)
        var endpoint = end
        if modifiers.contains(.shift), tool == .arrow || tool == .line {
            let length = hypot(end.x - start.x, end.y - start.y)
            let angle = (atan2(end.y - start.y, end.x - start.x) / (.pi / 4)).rounded() * (.pi / 4)
            endpoint = EditorGeometry.clamp(CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length), to: viewport)
        }
        guard !rect.isNull || tool == .arrow || tool == .line else { return nil }
        let content: AnnotationContent
        switch tool {
        case .arrow: content = .arrow(start: start, end: endpoint, bend: nil, style: defaults.arrow)
        case .line: content = .line(start: start, end: endpoint, style: defaults.line)
        case .rectangle: content = .rectangle(rect: rect, style: defaults.rectangle)
        case .ellipse: content = .ellipse(rect: rect, style: defaults.ellipse)
        case .redact: content = .redact(rect: rect.integral.intersection(viewport), style: defaults.redact)
        case .spotlight: content = .spotlight(rect: rect, style: defaults.spotlight)
        default: return nil
        }
        return Annotation(id: id, content: content)
    }

    // MARK: Commands

    private func commit(_ state: AnnotationDocument, actionName: String) {
        guard state != document.state else { return }
        do {
            document.commit(try state.preservingCreationOrder(from: document.state), actionName: actionName)
        } catch { NSSound.beep() }
    }

    func deleteSelected() {
        guard !selected.isEmpty else { return }
        var state = document.state; state.annotations.removeAll { selected.contains($0.id) }
        commit(state, actionName: "Delete Objects"); selected = []
    }
    func duplicateSelected() {
        var state = document.state
        let copies = state.annotations.filter { selected.contains($0.id) }.map { annotation -> Annotation in
            let offset = EditorGeometry.clampedOffset(CGSize(width: 12, height: 12), moving: annotation.bounds, within: viewport)
            var copy = annotation.translated(by: offset); copy.id = UUID(); return copy
        }
        guard !copies.isEmpty else { return }
        state.annotations += copies; commit(state, actionName: "Duplicate Objects"); selected = Set(copies.map(\.id))
    }
    func arrange(_ arrangement: EditorArrangement) {
        var state = document.state
        state.annotations = EditorGeometry.arranged(state.annotations, selected: selected, arrangement)
        commit(state, actionName: "Arrange Objects")
    }
    func editSelectedText() {
        guard selected.count == 1, let annotation = document.state.annotations.first(where: { selected.contains($0.id) }),
              annotation.tool == .text else { return }
        beginText(point: annotation.bounds.origin, existing: annotation)
    }
    func setCropAspect(_ aspect: CGFloat?) {
        cropAspect = aspect
        if let cropDraft { self.cropDraft = CropGeometry.applyingAspect(aspect, to: cropDraft, within: sourceBounds) }
        selectionChanged?()
    }
    func setCropSize(width: CGFloat? = nil, height: CGFloat? = nil) {
        guard let cropDraft else { return }
        self.cropDraft = CropGeometry.resized(cropDraft, width: width, height: height, aspect: cropAspect, within: sourceBounds)
        selectionChanged?()
    }
    func applyCrop() {
        if let cropDraft, cropDraft.width >= 1, cropDraft.height >= 1 {
            var state = document.state
            state.crop = cropDraft == sourceBounds ? nil : cropDraft.intersection(sourceBounds)
            commit(state, actionName: "Crop")
        }
        cropDraft = nil; tool = .select
    }
    func cancelCrop() { cancelGesture(restoreSelection: false); cropDraft = nil; tool = .select }
    func renumber() {
        var state = document.state
        let count = state.annotations.filter { $0.tool == .counter }.count
        var number = max(1, nextCounter)
        guard count > 0 else { return }
        guard number <= Int.max - count else { NSSound.beep(); return }
        do { state = try state.preservingCreationOrder(from: document.state) }
        catch { NSSound.beep(); return }
        let indices = state.annotations.indices.filter { state.annotations[$0].tool == .counter }
            .sorted { state.annotations[$0].creationOrder! < state.annotations[$1].creationOrder! }
        for index in indices {
            if case .counter(let center, _, let style) = state.annotations[index].content {
                state.annotations[index].content = .counter(center: center, number: number, style: style); number += 1
            }
        }
        commit(state, actionName: "Renumber Counters"); nextCounter = number
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        finishText()
        let point = imagePoint(window: event.locationInWindow)
        guard tool != .crop, let hit = EditorGeometry.hit(point, in: document.state.annotations, tolerance: 6 / zoom) else { return nil }
        if !selected.contains(hit.id) { selected = [hit.id] }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        if selected.count == 1, hit.tool == .text { add("Edit Text", #selector(editTextAction)); menu.addItem(.separator()) }
        add("Duplicate", #selector(duplicateAction))
        menu.addItem(.separator())
        add("Bring to Front", #selector(bringToFront)); add("Bring Forward", #selector(bringForward))
        add("Send Backward", #selector(sendBackward)); add("Send to Back", #selector(sendToBack))
        menu.addItem(.separator())
        add("Delete", #selector(delete(_:)))
        return menu
    }
    @objc private func editTextAction() { editSelectedText() }
    @objc private func duplicateAction() { duplicateSelected() }
    @objc func bringToFront() { arrange(.front) }
    @objc func bringForward() { arrange(.forward) }
    @objc func sendBackward() { arrange(.backward) }
    @objc func sendToBack() { arrange(.back) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)): !selected.isEmpty
        case #selector(paste(_:)): NSPasteboard.general.data(forType: Self.pasteboardType) != nil
        default: true
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            spaceHeld = true; return
        }
        if event.keyCode == 53 {
            if gesture != nil { cancelGesture(restoreSelection: true) } else if tool == .crop { cancelCrop() } else { selected = [] }
            return
        }
        if event.keyCode == 36 || event.keyCode == 76, tool == .crop { applyCrop(); return }
        if event.keyCode == 51 || event.keyCode == 117 { deleteSelected(); return }
        if [123, 124, 125, 126].contains(event.keyCode), !selected.isEmpty, gesture == nil {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            var offset = CGSize(width: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0,
                                height: event.keyCode == 126 ? -step : event.keyCode == 125 ? step : 0)
            var state = document.state
            if let union = EditorGeometry.union(state.annotations.filter { selected.contains($0.id) }) {
                offset = EditorGeometry.clampedOffset(offset, moving: union, within: viewport)
            }
            state.annotations = state.annotations.map { selected.contains($0.id) ? $0.translated(by: offset) : $0 }
            commit(state, actionName: "Move Objects"); return
        }
        if let shortcut = Shortcut(event: event), let id = commands.command(matching: shortcut, in: [.editor, .editorTool]) {
            if let tool = id.tool { self.tool = tool; selectionChanged?() } else { command?(id) }
            return
        }
        super.keyDown(with: event)
    }
    override func keyUp(with event: NSEvent) { if event.keyCode == 49 { spaceHeld = false } else { super.keyUp(with: event) } }
    override func resignFirstResponder() -> Bool {
        cancelInteraction()
        return super.resignFirstResponder()
    }
    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), preserving: convert(event.locationInWindow, from: nil))
    }
    override func selectAll(_ sender: Any?) { selected = Set(document.state.annotations.map(\.id)) }
    @objc func delete(_ sender: Any?) { deleteSelected() }
    private static let pasteboardType = NSPasteboard.PasteboardType("local.markus.Shotty.annotations")
    @objc func copy(_ sender: Any?) {
        guard let data = try? JSONEncoder().encode(document.state.annotations.filter { selected.contains($0.id) }) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setData(data, forType: Self.pasteboardType)
    }
    @objc func paste(_ sender: Any?) {
        guard let data = NSPasteboard.general.data(forType: Self.pasteboardType),
              let objects = try? JSONDecoder().decode([Annotation].self, from: data), objects.allSatisfy(\.isValid),
              let union = EditorGeometry.union(objects) else { return }
        // Pasted objects stay inside the visible image even when copied from a larger capture.
        let offset = EditorGeometry.clampedOffset(.zero, moving: union, within: viewport)
        var state = document.state
        let copies = objects.map { annotation -> Annotation in var copy = annotation.translated(by: offset); copy.id = UUID(); return copy }
        state.annotations += copies; commit(state, actionName: "Paste Objects"); selected = Set(copies.map(\.id))
    }
    @objc func cut(_ sender: Any?) { copy(sender); deleteSelected() }

    // MARK: Text

    private func beginText(point: CGPoint, existing: Annotation? = nil) {
        finishText()
        let style: EditorToolDefaults.Text, rect: CGRect, value: String
        if let existing, case .text(let r, let text, let s) = existing.content { style = s; rect = r; value = text }
        else {
            style = preferences.editor.tools.text
            rect = CGRect(x: point.x, y: point.y, width: max(1, min(360, viewport.maxX - point.x)),
                          height: max(1, min(style.size * 1.5, viewport.maxY - point.y)))
            value = ""
        }
        textID = existing?.id ?? UUID(); textRect = rect; textStyle = style
        let view = CanvasTextView(frame: viewRect(rect))
        view.isRichText = false
        view.drawsBackground = style.treatment == .label
        view.backgroundColor = NSColor(cgColor: style.color.cgColor) ?? .clear
        view.allowsUndo = true
        view.font = DocumentRenderer.textFont(style) as NSFont
        view.font = NSFontManager.shared.convert(view.font ?? .systemFont(ofSize: style.size), toSize: style.size * zoom)
        view.textColor = style.treatment == .label ? .white : NSColor(cgColor: style.color.cgColor)
        view.textContainerInset = .zero; view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true; view.string = value; view.delegate = self
        view.finish = { [weak self] in self?.finishText() }
        textView = view; addSubview(view); window?.makeFirstResponder(view); needsDisplay = true
        updateAccessibility()
    }
    private func repositionTextView() {
        guard let textView, let textRect else { return }
        textView.frame = viewRect(CGRect(origin: textRect.origin, size: CGSize(width: textRect.width, height: textView.frame.height / zoom)))
    }
    func textDidChange(_ notification: Notification) { textView?.sizeToFit() }

    /// Commits the edited text, discarding a new empty text, and returns focus to the canvas.
    func finishText() {
        guard let textView, let id = textID, let style = textStyle, var rect = textRect else { return }
        let text = textView.string
        rect.size.height = max(style.size * 1.5, textView.frame.height / zoom)
        rect = rect.intersection(viewport)
        let hadFocus = window?.firstResponder === textView
        textView.typingUndoManager.removeAllActions()
        textView.removeFromSuperview(); self.textView = nil; textID = nil; textStyle = nil; textRect = nil
        var state = document.state
        let index = state.annotations.firstIndex { $0.id == id }
        let edited = Annotation(id: id, content: .text(rect: rect, text: text, style: style))
        switch (index, text.isEmpty) {
        case (let index?, false): state.annotations[index] = edited
        case (let index?, true): state.annotations.remove(at: index)
        case (nil, false): state.annotations.append(edited)
        case (nil, true): break
        }
        commit(state, actionName: "Edit Text")
        if !text.isEmpty { selected = [id] }
        if hadFocus { window?.makeFirstResponder(self) }
        updateAccessibility()
        needsDisplay = true
    }

    private func updateAccessibility() {
        var children: [NSObject] = document.state.annotations.filter { $0.id != textID }.map { annotation in
            let element = CanvasObjectAccessibilityElement()
            element.setAccessibilityRole(.button)
            element.setAccessibilityEnabled(true)
            let name: String
            switch annotation.content {
            case .text(_, let text, _): name = "Text: \(text.prefix(100))"
            case .counter(_, let number, _): name = "Counter \(number)"
            default: name = annotation.tool.rawValue.capitalized
            }
            element.setAccessibilityLabel(name)
            element.setAccessibilityValue("X \(Int(annotation.bounds.minX)), Y \(Int(annotation.bounds.minY)), width \(Int(annotation.bounds.width)), height \(Int(annotation.bounds.height)) pixels")
            element.setAccessibilityHelp(annotation.tool == .text ? "Press to edit text." : "Press to select. Arrow keys move the object; Delete removes it. Options changes its style.")
            element.setAccessibilityParent(self)
            element.setAccessibilitySelected(selected.contains(annotation.id))
            element.screenFrame = { [weak self] in
                guard let self, let window = self.window,
                      let current = self.document.state.annotations.first(where: { $0.id == annotation.id }) else { return .zero }
                return window.convertToScreen(self.convert(self.viewRect(current.bounds), to: nil))
            }
            element.press = { [weak self] in
                guard let self, let current = self.document.state.annotations.first(where: { $0.id == annotation.id }) else { return false }
                self.finishText()
                self.tool = .select
                self.selected = [current.id]
                self.scrollToVisible(self.viewRect(current.bounds).insetBy(dx: -12, dy: -12))
                self.window?.makeFirstResponder(self)
                if current.tool == .text { self.beginText(point: current.bounds.origin, existing: current) }
                return true
            }
            return element
        }
        if let textView { children.append(textView) }
        setAccessibilityChildren(children)
    }

    // MARK: Background rendering

    /// One full render per committed state that contains effects. Older renders are discarded.
    func updatePreview() {
        previewTask?.cancel()
        pendingPatch = nil; patchTask?.cancel(); patches = []; patchKey = nil
        let state = document.state, source = source, renderer = previewRenderer
        guard Self.hasEffects(state.annotations) else {
            previewImage = nil; previewAnnotations = []; previewGeneration += 1; needsDisplay = true; return
        }
        previewTask = Task { [weak self] in
            guard let image = try? await renderer.render(source: source, annotations: state.annotations),
                  let self, !Task.isCancelled, self.document.state == state else { return }
            self.previewImage = image
            self.previewAnnotations = state.annotations
            self.previewGeneration += 1
            self.pendingPatch = nil; self.patchTask?.cancel(); self.patches = []; self.patchKey = nil
            self.needsDisplay = true
        }
    }

    /// Renders dirty regions of the newest draft; one request runs at a time and only the latest
    /// pending request survives, so rendering never queues behind pointer events.
    private func schedulePatches(key: PatchKey, rects: [CGRect]) {
        guard patchTask == nil else { pendingPatch = (key, rects); return }
        pendingPatch = nil
        let source = source, renderer = previewRenderer
        patchTask = Task { [weak self] in
            let result = try? await renderer.render(source: source, annotations: key.annotations, regions: rects)
            guard let self else { return }
            self.patchTask = nil
            if let result, !Task.isCancelled, key.base == self.previewGeneration {
                self.patches = result
                self.patchKey = key
                self.needsDisplay = true
            }
            if let next = self.pendingPatch, next.key != key { self.schedulePatches(key: next.key, rects: next.rects) }
        }
    }
}

private final class CanvasObjectAccessibilityElement: NSAccessibilityElement {
    var screenFrame: (() -> CGRect)?
    var press: (() -> Bool)?
    override func accessibilityFrame() -> NSRect { screenFrame?() ?? .zero }
    override func accessibilityPerformPress() -> Bool { press?() ?? false }
}

final class CanvasTextView: NSTextView {
    /// Typing belongs to the active native text field. Only the completed edit enters document undo.
    let typingUndoManager = UndoManager()
    override var undoManager: UndoManager? { typingUndoManager }
    var finish: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 || (event.keyCode == 36 && event.modifierFlags.contains(.command)) { finish?() }
        else { super.keyDown(with: event) }
    }
}

/// Serial background renderer for the canvas; the crop is applied by the viewport instead.
private actor EditorPreviewRenderer {
    private let renderer = DocumentRenderer()

    func render(source: CGImage, annotations: [Annotation]) throws -> CGImage {
        try renderer.render(source: source, state: AnnotationDocument(annotations: annotations, crop: nil))
    }

    func render(source: CGImage, annotations: [Annotation], regions: [CGRect]) throws -> [(rect: CGRect, image: CGImage)] {
        let state = AnnotationDocument(annotations: annotations, crop: nil)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        return try regions.map { region in
            try Task.checkCancellation()
            return (region.standardized.integral.intersection(bounds), try renderer.render(source: source, state: state, region: region))
        }
    }
}
