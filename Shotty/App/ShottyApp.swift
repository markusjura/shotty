import SwiftUI

@main
struct ShottyApp: App {
    var body: some Scene {
        Window("Shotty Foundation", id: "foundation") {
            FoundationHarnessView()
        }
        MenuBarExtra("Shotty", systemImage: "viewfinder") {
            HarnessMenu()
        }
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
