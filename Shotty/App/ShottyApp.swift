import SwiftUI

@main
struct ShottyApp: App {
    @NSApplicationDelegateAdaptor(ShottyApplicationDelegate.self) private var delegate

    var body: some Scene {
        // A window rather than a Settings scene, which SwiftUI always keeps at a fixed size.
        Window("Settings", id: SettingsView.windowID) {
            SettingsView(preferences: delegate.coordinator.preferences, commands: delegate.commands)
        }
        .windowToolbarStyle(.unifiedCompact)
        .defaultSize(width: 660, height: 608)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(.suppressed)
        .commands {
            SwiftUI.CommandGroup(replacing: .appSettings) { SettingsButton() }
            SwiftUI.CommandGroup(after: .appInfo) {
                ForEach(CommandGroup.capture.commands, id: \.self) { commandButton($0) }
            }
            SwiftUI.CommandGroup(after: .pasteboard) {
                ForEach(CommandGroup.editor.commands.filter { $0.tool == nil && !Self.zoomCommands.contains($0) }, id: \.self) {
                    commandButton($0)
                }
            }
            // Tool keys stay routed by the focused editor canvas; plain-letter menu equivalents
            // would fire while typing, so these items carry no shortcut.
            CommandMenu("Tools") {
                ForEach(CommandGroup.editor.commands.filter { $0.tool != nil }, id: \.self) { commandButton($0, shortcut: false) }
            }
            SwiftUI.CommandGroup(after: .toolbar) {
                ForEach(CommandGroup.thumbnails.commands, id: \.self) { commandButton($0) }
                Divider()
                ForEach(Self.zoomCommands, id: \.self) { commandButton($0) }
            }
        }
        MenuBarExtra("Shotty", systemImage: "viewfinder", isInserted: Binding(
            get: { delegate.coordinator.preferences.general.showsMenuBarIcon },
            set: { delegate.coordinator.preferences.general.showsMenuBarIcon = $0 })) {
            ForEach(CommandGroup.capture.commands, id: \.self) { commandButton($0) }
            Divider()
            ForEach(CommandGroup.thumbnails.commands, id: \.self) { commandButton($0) }
            Divider()
            SettingsButton()
            Button("Quit Shotty") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }

    /// Editor zoom lives in the View menu with the thumbnail commands, not with the other editor commands.
    private static let zoomCommands: [CommandID] = [.zoomIn, .zoomOut, .zoomToFit, .actualSize]

    /// A menu item for a command, with its current shortcut and availability.
    private func commandButton(_ command: CommandID, shortcut: Bool = true) -> some View {
        Button(command.title) { delegate.execute(command) }
            .keyboardShortcut(shortcut ? delegate.commands.shortcut(for: command)?.keyboardShortcut : nil)
            .disabled(!delegate.commands.isAvailable(command))
    }
}

@MainActor
final class ShottyApplicationDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    let commands = CommandRegistry()
    private lazy var textCapture = TextCaptureController(coordinator: coordinator)
    private lazy var scrollingCapture = ScrollingCaptureController(coordinator: coordinator)
    private var hotKeys: GlobalHotKeyCenter?
    private var terminating = false
    private var editors: [UUID: EditorWindowController] = [:]
    private var openingEditors = Set<UUID>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        coordinator.thumbnails.commands = commands
        coordinator.recognizeText = { [weak self] image, settings, ticket in self?.textCapture.start(image, settings: settings, ticket: ticket) }
        coordinator.startScrolling = { [weak self] region, display, settings, ticket in
            self?.scrollingCapture.start(region: region, displayID: display, settings: settings, ticket: ticket)
        }
        coordinator.auxiliaryCaptureActive = { [weak self] in self?.textCapture.isActive == true || self?.scrollingCapture.isActive == true }
        coordinator.stopAuxiliaryCapture = { [weak self] in await self?.textCapture.stop(); await self?.scrollingCapture.stop() }
        coordinator.openEditor = { [weak self] in self?.openEditor($0) }
        coordinator.hasEditor = { [weak self] in self?.editors[$0] != nil || self?.openingEditors.contains($0) == true }
        commands.availability = { [weak self] command in
            guard let self, coordinator.ready else { return false }
            switch command.scope {
            case .global:
                if command.captureKind != nil { return !coordinator.isCapturing && coordinator.auxiliaryCaptureActive?() != true }
                return !coordinator.records.isEmpty
            case .editor, .editorTool: return editors.values.contains { $0.window === NSApp.keyWindow }
            }
        }
        observePreferences()
        hotKeys = GlobalHotKeyCenter(registry: commands) { [weak self] in self?.execute($0) }
        hotKeys?.start()
        Task { await coordinator.launch() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate()
        // Open Settings through its app menu command, the one bridge from AppKit to the SwiftUI window.
        if let menu = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { menu in
            menu.items.contains { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }
        }), let index = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }) {
            menu.performActionForItem(at: index)
        }
        return false
    }

    func execute(_ command: CommandID) {
        guard commands.isAvailable(command) else { return }
        if let kind = command.captureKind { coordinator.capture(kind); return }
        switch command {
        case .showThumbnails: coordinator.showAllThumbnails()
        case .hideThumbnails: coordinator.hideThumbnails()
        case .openLatest:
            if let record = coordinator.records.last { coordinator.openEditor?(record.id) }
        case .saveAll: coordinator.saveAll()
        case .dismissAll: coordinator.dismissAllThumbnails()
        default:
            editors.values.first { $0.window === NSApp.keyWindow }?.model.execute(command)
        }
    }

    private func openEditor(_ id: UUID) {
        if let editor = editors[id] { NSApp.activate(); editor.window?.makeKeyAndOrderFront(nil); return }
        guard !openingEditors.contains(id) else { return }
        openingEditors.insert(id); coordinator.retain(id)
        Task { [self] in
            defer { openingEditors.remove(id); coordinator.release(id) }
            do {
                guard let record = await coordinator.store.records().first(where: { $0.id == id }) else { return }
                let image = try await coordinator.store.image(for: id)
                let editor = EditorWindowController(record: record, image: image, coordinator: coordinator, commands: commands)
                editors[id] = editor
                editor.didClose = { [weak self] in
                    self?.editors.removeValue(forKey: id); self?.coordinator.editorClosed(id)
                }
                NSApp.activate(); editor.window?.makeKeyAndOrderFront(nil)
            } catch { coordinator.showError(error, title: "Couldn't open editor") }
        }
    }

    private func observePreferences() {
        withObservationTracking {
            NSApp.appearance = coordinator.preferences.general.appearance.nsAppearance
            NSApp.setActivationPolicy(coordinator.preferences.general.activationPolicy)
            _ = coordinator.preferences.thumbnails
            coordinator.thumbnails.refresh()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observePreferences() }
        }
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
