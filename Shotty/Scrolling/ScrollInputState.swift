/// The native event bridge classifies events using Shotty's injected-event marker.
/// Observing a frame change alone must never be interpreted as physical input.
enum ScrollInputSource: Sendable {
    case physical
    case shottyInjected
}

enum ScrollInputAction: Sendable {
    case startAutomatic
    case toggleAutomaticPause
    case pauseAutomatic
    case scroll(ScrollInputSource)
}

/// A new value represents a new capture. There is deliberately no reset command
/// inside an active session and no transition out of manual-only mode.
struct ScrollInputState: Equatable, Sendable {
    enum Mode: Equatable, Sendable {
        case undecided
        case automaticRunning
        case automaticPaused
        case manualOnly
    }

    private(set) var mode: Mode = .undecided

    var mayInjectScroll: Bool { mode == .automaticRunning }
    var offersAutoScroll: Bool { mode == .undecided }

    /// Start is sent only by explicit Auto Scroll button activation after permission
    /// and target checks. Space maps to toggleAutomaticPause, never startAutomatic.
    mutating func handle(_ action: ScrollInputAction) {
        switch action {
        case .startAutomatic:
            if mode == .undecided { mode = .automaticRunning }
        case .toggleAutomaticPause:
            if mode == .automaticRunning { mode = .automaticPaused }
            else if mode == .automaticPaused { mode = .automaticRunning }
        case .pauseAutomatic:
            if mode == .automaticRunning { mode = .automaticPaused }
        case .scroll(.physical):
            mode = .manualOnly
        case .scroll(.shottyInjected):
            break
        }
    }
}
