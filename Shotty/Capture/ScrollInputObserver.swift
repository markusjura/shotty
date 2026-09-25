import AppKit

/// Mouse-only observation does not request Accessibility or Input Monitoring.
/// This bridge distinguishes Shotty's own marked events from all external scroll input.
@MainActor
final class ScrollInputObserver {
    static let injectedEventMarker: Int64 = 0x53484F545459
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func start(onScroll: @escaping @MainActor (ScrollInputSource) -> Void) {
        stop()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { onScroll(Self.source(of: event)) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            MainActor.assumeIsolated { onScroll(Self.source(of: event)) }
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private static func source(of event: NSEvent) -> ScrollInputSource {
        if let cgEvent = event.cgEvent,
           cgEvent.getIntegerValueField(.eventSourceUserData) == injectedEventMarker,
           cgEvent.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier) {
            return .shottyInjected
        }
        return .physical
    }
}
