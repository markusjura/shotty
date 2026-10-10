import SwiftUI

@main
struct ShottyApp: App {
    @NSApplicationDelegateAdaptor(ShottyApplicationDelegate.self) private var delegate

    var body: some Scene {
        // A window rather than a Settings scene, which SwiftUI always keeps at a fixed size.
        Window("Settings", id: SettingsView.windowID) {
            SettingsView(preferences: delegate.coordinator.preferences, commands: delegate.commands, updater: delegate.updater)
                .onAppear { delegate.settingsIsOpen = true }
                .onDisappear { delegate.settingsIsOpen = false }
        }
        // System Settings' toolbar height and control size.
        .windowToolbarStyle(.unified)
        .defaultSize(width: 660, height: 608)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            SwiftUI.CommandGroup(replacing: .appSettings) { SettingsButton() }
            SwiftUI.CommandGroup(after: .appInfo) {
                ForEach(CommandGroup.capture.commands, id: \.self) { commandButton($0) }
                Divider()
                ForEach(CommandGroup.record.commands, id: \.self) { commandButton($0) }
            }
            SwiftUI.CommandGroup(after: .pasteboard) {
                ForEach(CommandGroup.editor.commands.filter { $0.scope == .editor && !Self.zoomCommands.contains($0) }, id: \.self) {
                    commandButton($0)
                }
            }
            // Plain-key commands stay routed by the focused editor; plain-letter menu equivalents
            // would fire while typing, so these items carry no shortcut.
            CommandMenu("Tools") {
                ForEach(CommandGroup.editor.commands.filter { $0.tool != nil }, id: \.self) { commandButton($0, shortcut: false) }
            }
            CommandMenu("Clip") {
                ForEach(CommandGroup.videoEditor.commands.filter { $0.scope == .editorKey }, id: \.self) {
                    commandButton($0, shortcut: false)
                }
            }
            SwiftUI.CommandGroup(after: .toolbar) {
                ForEach(CommandGroup.thumbnails.commands, id: \.self) { commandButton($0) }
                Divider()
                ForEach(Self.zoomCommands, id: \.self) { commandButton($0) }
                Divider()
                // A checkmarked item, like QuickTime's View > Loop, that flips the video editor preference.
                Toggle(CommandID.loopPlayback.title, isOn: Binding(
                    get: { delegate.coordinator.preferences.editor.loopsPlayback },
                    set: { _ in delegate.execute(.loopPlayback) }))
                    .keyboardShortcut(delegate.commands.shortcut(for: .loopPlayback)?.keyboardShortcut)
                    .disabled(!delegate.commands.isAvailable(.loopPlayback))
            }
        }
        MenuBarExtra(isInserted: Binding(
            get: { delegate.coordinator.preferences.general.showsMenuBarIcon },
            set: { delegate.coordinator.preferences.general.showsMenuBarIcon = $0 })) {
            MenuBarContent(delegate: delegate)
        } label: {
            MenuBarLabel(recording: delegate.coordinator.recording, showsUpdateDot: delegate.updater.needsAttention)
        }
    }

    /// Editor zoom lives in the View menu with the thumbnail commands, not with the other editor commands.
    private static let zoomCommands: [CommandID] = [.zoomIn, .zoomOut, .zoomToFit, .actualSize]

    /// A menu item for a command, with its current shortcut and availability.
    private func commandButton(_ command: CommandID, shortcut: Bool = true) -> some View {
        Button(delegate.menuTitle(for: command)) { delegate.execute(command) }
            .keyboardShortcut(shortcut ? delegate.commands.shortcut(for: command)?.keyboardShortcut : nil)
            .disabled(!delegate.commands.isAvailable(command))
    }
}

/// The menu bar item: a `viewfinder`, or a stop square while recording. A blue dot marks an update
/// that needs the user. macOS shows its own screen recording item, a stop square in a circle,
/// beside it. The label must stay static between state changes: a `TimelineView` here re-renders
/// the status item in an endless loop.
private struct MenuBarLabel: View {
    let recording: RecordingController
    let showsUpdateDot: Bool

    var body: some View {
        Image(nsImage: recording.isActive ? Self.recordingIcon : showsUpdateDot ? Self.iconWithDot : Self.icon)
    }

    /// Larger and heavier than the default status item symbol, so it matches system items such as
    /// Time Machine and Display in size and stroke weight.
    private static let icon = symbol("viewfinder", description: "Shotty")
    private static let recordingIcon = symbol("stop.fill", description: "Shotty is recording")

    /// The icon with a blue dot in its top right corner. A template image can't carry color, so this
    /// one draws the glyph itself in the menu bar's label color, resolved each time it draws.
    private static let iconWithDot: NSImage = {
        let image = NSImage(size: icon.size, flipped: false) { bounds in
            icon.draw(in: bounds)
            NSColor.labelColor.set()
            bounds.fill(using: .sourceAtop)
            let dot = CGRect(x: bounds.maxX - 6, y: bounds.maxY - 6, width: 6, height: 6)
            // A clear ring keeps the dot apart from the viewfinder corner it overlaps.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.cacheMode = .never
        image.accessibilityDescription = "Shotty, update available"
        return image
    }()

    private static func symbol(_ name: String, description: String) -> NSImage {
        let symbol = NSImage(systemSymbolName: name, accessibilityDescription: description)!
        let image = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))!
        image.isTemplate = true
        return image
    }
}

/// The menu bar menu: the screenshot commands, then the recording commands. While recording it
/// offers Stop, Pause, and Discard instead.
private struct MenuBarContent: View {
    let delegate: ShottyApplicationDelegate

    var body: some View {
        let recording = delegate.coordinator.recording
        if recording.isActive {
            item(.stopRecording)
            Button(recording.isPaused ? "Resume Recording" : "Pause Recording") { recording.togglePause() }
                .disabled(recording.phase != .recording && recording.phase != .paused)
            Button("Discard Recording") { recording.cancel() }
        } else {
            ForEach(CommandGroup.capture.commands, id: \.self) { item($0) }
            Divider()
            ForEach(CommandGroup.record.commands.filter { $0 != .stopRecording }, id: \.self) { item($0) }
        }
        Divider()
        UpdateMenuItem(updater: delegate.updater)
        SettingsButton()
        Button("Quit Shotty") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func item(_ command: CommandID) -> some View {
        Button(command.title) { delegate.execute(command) }
            .keyboardShortcut(delegate.commands.shortcut(for: command)?.keyboardShortcut)
            .disabled(!delegate.commands.isAvailable(command))
    }
}

@MainActor
final class ShottyApplicationDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    let commands = CommandRegistry()
    lazy var updater = AppUpdater(environment: .init(isBusy: { [coordinator] in coordinator.hasWork }))
    private lazy var textCapture = TextCaptureController(coordinator: coordinator)
    private lazy var scrollingCapture = ScrollingCaptureController(coordinator: coordinator)
    private var hotKeys: GlobalHotKeyCenter?
    private var terminating = false
    /// While any editor is open, Shotty is a regular app with its menu bar, Dock icon, and app switcher entry.
    private var editors: [UUID: any CaptureEditor] = [:] { didSet { updateActivationPolicy() } }
    private var openingEditors = Set<UUID>()
    /// Open Settings makes Shotty a regular app, so the window gets a Dock icon, a Cmd-Tab entry,
    /// and the app menu, and window switchers list it like any other window.
    var settingsIsOpen = false {
        didSet { updateActivationPolicy() }
    }
    #if DEBUG
    private var installedLaunchObservation: NSKeyValueObservation?
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tooltips, such as the editor tool names, appear after 0.7 s instead of AppKit's 1 s.
        // A global NSInitialToolTipDelay set by the user still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 700])
        guard NSClassFromString("XCTestCase") == nil else { return }
        #if DEBUG
        keepOneShottyRunning()
        #endif
        coordinator.thumbnails.commands = commands
        coordinator.recognizeText = { [weak self] image, region, settings, ticket in
            self?.textCapture.start(image, region: region, settings: settings, ticket: ticket)
        }
        let text = coordinator.preferences.text
        Task.detached(priority: .utility) { await TextRecognizer.prepare(preferences: text) }
        coordinator.startScrolling = { [weak self] region, display, settings, ticket in
            self?.scrollingCapture.start(region: region, displayID: display, settings: settings, ticket: ticket)
        }
        coordinator.auxiliaryCaptureActive = { [weak self] in self?.textCapture.isActive == true || self?.scrollingCapture.isActive == true }
        coordinator.stopAuxiliaryCapture = { [weak self] in await self?.textCapture.stop(); await self?.scrollingCapture.stop() }
        coordinator.textResultsOpen = { [weak self] in self?.textCapture.isShowingResults == true }
        coordinator.openEditor = { [weak self] in self?.openEditor($0) }
        coordinator.hasEditor = { [weak self] in self?.editors[$0] != nil || self?.openingEditors.contains($0) == true }
        commands.availability = { [weak self] command in
            guard let self, coordinator.ready else { return false }
            let recording = coordinator.recording
            switch command.scope {
            case .global:
                if command == .stopRecording { return recording.isActive }
                if command.captureKind != nil { return !coordinator.isBusy }
                // A record command also stops the recording in progress.
                if command.recordingKind != nil { return recording.isActive ? recording.phase != .finishing : !coordinator.isBusy }
                return !coordinator.records.isEmpty
            case .editor, .editorKey: return keyEditor?.handles(command) == true
            }
        }
        observePreferences()
        hotKeys = GlobalHotKeyCenter(registry: commands) { [weak self] in self?.execute($0) }
        hotKeys?.start()
        // Creating the updater starts Sparkle's schedule; the menu bar may have created it already.
        _ = updater
        Task { await coordinator.launch() }
        // Shotty starts silently, so a first launch would otherwise show nothing. Open Settings
        // once on Permissions, where the user grants the Screen Recording access every capture needs.
        if !UserDefaults.standard.bool(forKey: Self.launchedBeforeKey) {
            UserDefaults.standard.set(true, forKey: Self.launchedBeforeKey)
            UserDefaults.standard.set(SettingsPane.permissions.rawValue, forKey: SettingsView.paneKey)
            showSettings()
        }
    }

    private static let launchedBeforeKey = "launchedBefore"

    #if DEBUG
    /// Shotty Dev and the installed Shotty share hotkeys, so only the one opened last keeps running.
    /// Launching Shotty Dev quits the installed build, and launching the installed build quits
    /// Shotty Dev. Only Debug builds carry this, so the installed build has no launch-time checks.
    private func keepOneShottyRunning() {
        let installedID = "local.markus.Shotty"
        NSRunningApplication.runningApplications(withBundleIdentifier: installedID).forEach { $0.terminate() }
        installedLaunchObservation = NSWorkspace.shared.observe(\.runningApplications, options: [.new]) { _, change in
            guard change.newValue?.contains(where: { $0.bundleIdentifier == installedID }) == true else { return }
            // Quit from a run loop pass, not a main-queue block: quitting waits on a main-actor
            // task, which can't run while the main queue is busy with this block.
            RunLoop.main.perform { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        }
    }
    #endif

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    /// Opens Settings through its app menu command, the one bridge from AppKit to the SwiftUI window.
    private func showSettings() {
        NSApp.activate()
        if let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { menu in
            menu.items.contains { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }
        }), let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }) {
            menu.performActionForItem(at: index)
        }
    }

    func execute(_ command: CommandID) {
        guard commands.isAvailable(command) else { return }
        if let kind = command.captureKind { coordinator.capture(kind); return }
        if let kind = command.recordingKind { coordinator.record(kind); return }
        switch command {
        case .stopRecording: coordinator.stopRecording()
        case .showThumbnails: coordinator.showAllThumbnails()
        case .hideThumbnails: coordinator.hideThumbnails()
        case .openLatest:
            if let record = coordinator.records.last { coordinator.openEditor?(record.id) }
        case .saveAll: coordinator.saveAll()
        case .dismissAll: coordinator.dismissAllThumbnails()
        default: keyEditor?.execute(command)
        }
    }

    private var keyEditor: (any CaptureEditor)? { editors.values.first { $0.window === NSApp.keyWindow } }

    /// Menu titles follow the focused editor, so Copy names what it copies. Menus re-render on
    /// `CommandRegistry.contextDidChange()`, which editors call as they gain and lose focus.
    func menuTitle(for command: CommandID) -> String {
        guard command == .copy else { return command.title }
        return keyEditor is ClipEditorWindowController ? "Copy Clip" : "Copy Image"
    }

    /// Opens the image editor for a screenshot or the video editor for a clip.
    private func openEditor(_ id: UUID) {
        if let editor = editors[id] { bringForward(editor.window); return }
        guard !openingEditors.contains(id) else { return }
        openingEditors.insert(id); coordinator.retain(id)
        Task { [self] in
            defer { openingEditors.remove(id); coordinator.release(id) }
            do {
                let editor: any CaptureEditor
                switch await coordinator.store.records().first(where: { $0.id == id }) {
                case .image(let record):
                    let image = try await coordinator.store.image(for: id)
                    editor = EditorWindowController(record: record, image: image, coordinator: coordinator, commands: commands)
                case .clip(let record):
                    editor = ClipEditorWindowController(record: record, coordinator: coordinator, commands: commands)
                case nil: return
                }
                editors[id] = editor
                editor.didClose = { [weak self] in
                    self?.editors.removeValue(forKey: id); self?.coordinator.editorClosed(id)
                }
                bringForward(editor.window)
            } catch { coordinator.showError(error, title: "Couldn't open editor") }
        }
    }

    /// Clicks on thumbnails don't activate Shotty, and an editor opened after a capture or recording
    /// appears while another app is active. macOS refuses a plain `activate()` then, so the editor
    /// would show without keyboard focus and its shortcuts wouldn't reach it. Ordering the window
    /// front regardless still shows it if activation fails anyway.
    private func bringForward(_ window: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func observePreferences() {
        withObservationTracking {
            NSApp.appearance = coordinator.preferences.general.appearance.nsAppearance
            updateActivationPolicy()
            _ = coordinator.preferences.thumbnails
            coordinator.thumbnails.refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePreferences() }
        }
    }

    private func updateActivationPolicy() {
        // Read the preference unconditionally so preference observation keeps tracking it.
        let preferred = coordinator.preferences.general.activationPolicy
        let policy = settingsIsOpen || !editors.isEmpty ? .regular : preferred
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Activate after becoming a regular app so Settings comes forward with the app menu. Only
        // Settings activates, so a login launch with the Dock icon on doesn't take focus.
        if settingsIsOpen { NSApp.activate() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task {
            let approved = await coordinator.prepareToQuit()
            if approved { hotKeys?.stop() }
            terminating = false
            sender.reply(toApplicationShouldTerminate: approved)
        }
        return .terminateLater
    }
}
