import SwiftUI

@main
struct ShottyApp: App {
    @NSApplicationDelegateAdaptor(HarnessApplicationDelegate.self) private var delegate

    var body: some Scene {
        Window("Shotty Foundation", id: "foundation") {
            FoundationHarnessView(harness: delegate.harness)
        }
        MenuBarExtra("Shotty", systemImage: "viewfinder") {
            HarnessMenu()
        }
    }
}

/// The temporary harness must await native capture cleanup before macOS exits.
@MainActor
final class HarnessApplicationDelegate: NSObject, NSApplicationDelegate {
    let harness = FoundationHarness()
    private var isTerminating = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        let cleanup = harness.stop()
        Task {
            await cleanup.value
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct HarnessMenu: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Foundation Verification…") {
            openWindow(id: "foundation")
            NSApplication.shared.activate()
        }
        Divider()
        Button("Quit Shotty") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
