import Carbon.HIToolbox
import Foundation
import Observation

/// Registers the registry's global-scope bindings with `RegisterEventHotKey`. No event tap and
/// no Accessibility or Input Monitoring permission is involved. Registrations follow registry
/// changes automatically and are suspended while a shortcut recorder is active.
/// Keep one instance for the app's lifetime; `stop()` releases every registration.
@MainActor
final class GlobalHotKeyCenter {
    private nonisolated static let signature: OSType = 0x5348_5459 // "SHTY"

    private let registry: CommandRegistry
    private let handler: @MainActor (CommandID) -> Void
    private var eventHandler: EventHandlerRef?
    private var registered: [UInt32: (command: CommandID, reference: EventHotKeyRef)] = [:]
    private var layoutObserver: NSObjectProtocol?

    /// `handler` runs on the main actor, only for commands the registry reports as available.
    init(registry: CommandRegistry, handler: @escaping @MainActor (CommandID) -> Void) {
        self.registry = registry
        self.handler = handler
    }

    isolated deinit { stop() }

    var isRunning: Bool { eventHandler != nil }

    func start() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            guard hotKeyID.signature == GlobalHotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let identifier = hotKeyID.id
            // The application event target dispatches on the main thread.
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKeyCenter>.fromOpaque(userData).takeUnretainedValue().fire(identifier)
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
            eventHandler = nil
            registry.reportRegistration(failures: Set(registry.globalBindings.keys))
            return
        }
        layoutObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.registry.keyboardLayoutDidChange() }
        }
        synchronize()
    }

    func stop() {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        if let layoutObserver { DistributedNotificationCenter.default().removeObserver(layoutObserver) }
        layoutObserver = nil
    }

    private func fire(_ identifier: UInt32) {
        guard let command = registered[identifier]?.command, registry.recordingCommand == nil,
              registry.isAvailable(command) else { return }
        handler(command)
    }

    /// Re-registers everything; the set is small and changes only from Settings.
    private func synchronize() {
        guard isRunning else { return }
        let bindings = withObservationTracking {
            registry.recordingCommand == nil ? registry.globalBindings : [:]
        } onChange: { [weak self] in
            Task { @MainActor in self?.synchronize() }
        }
        unregisterAll()
        var failures: Set<CommandID> = []
        for (index, command) in CommandID.allCases.enumerated() {
            guard let shortcut = bindings[command] else { continue }
            let identifier = UInt32(index + 1)
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers,
                                             EventHotKeyID(signature: Self.signature, id: identifier),
                                             GetApplicationEventTarget(), 0, &reference)
            if status == noErr, let reference {
                registered[identifier] = (command, reference)
            } else {
                failures.insert(command)
            }
        }
        // Suspension during recording is not a failure; keep the last real result.
        if registry.recordingCommand == nil { registry.reportRegistration(failures: failures) }
    }

    private func unregisterAll() {
        for entry in registered.values { UnregisterEventHotKey(entry.reference) }
        registered.removeAll()
    }
}
