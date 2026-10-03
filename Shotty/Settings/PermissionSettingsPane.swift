import ApplicationServices
import ServiceManagement
import SwiftUI

/// Status is read on appearance and whenever Shotty becomes active after a System Settings visit.
struct PermissionSettingsPane: View {
    let preferences: AppPreferences
    /// Shared with the capture flow so macOS is asked at most once.
    static let screenRecordingRequestedKey = "screenRecordingRequested"

    @State private var screenRecording = CGPreflightScreenCaptureAccess()
    @State private var screenRecordingRequested = UserDefaults.standard.bool(forKey: screenRecordingRequestedKey)
    @State private var accessibility = AXIsProcessTrusted()
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section("Screen Recording") {
                status(screenRecording, granted: "Allowed", missing: screenRecordingRequested ? "Not allowed" : "Not requested")
                Text("Required for every capture.").settingsNote()
                if !screenRecording {
                    HStack {
                        if !screenRecordingRequested {
                            Button("Request Access", action: requestScreenRecording)
                        }
                        Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.screenRecording) }
                    }
                    if screenRecordingRequested {
                        Text("Turn Shotty on in System Settings, then reopen it if asked.")
                            .settingsNote()
                    }
                }
            }
            Section("Accessibility") {
                status(accessibility, granted: "Allowed", missing: "Not allowed")
                Text("Needed for Auto Scroll and for dismissing thumbnails after pasting.")
                    .settingsNote()
                if !accessibility {
                    Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.accessibility) }
                }
            }
            Section("Save location") {
                let url = preferences.capture.destination.url
                let folder = SaveDestinationCheck.status(of: url)
                if folder == .available {
                    LabeledContent("Status") { Text(FileManager.default.displayName(atPath: url.path)).settingsValue() }
                } else {
                    status(false, granted: "", missing: "Unavailable")
                }
                if let message = folder.message { Text(message).settingsNote() }
            }
            Section("Login item") {
                LabeledContent("Status") { Text(loginStatus.summary).settingsValue() }
                if loginStatus == .requiresApproval {
                    Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    /// A status row with a white checkmark on system green when granted, as in System Settings, or a gray cross.
    private func status(_ ok: Bool, granted: String, missing: String) -> some View {
        LabeledContent("Status") {
            Label {
                Text(ok ? granted : missing)
            } icon: {
                if ok {
                    Image(systemName: "checkmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color(nsColor: .systemGreen))
                } else {
                    Image(systemName: "xmark.circle").foregroundStyle(SettingsColor.secondaryText)
                }
            }
            .foregroundStyle(ok ? SettingsColor.primaryText : SettingsColor.secondaryText)
        }
    }

    /// macOS shows its prompt only once; later visits go to System Settings instead.
    private func requestScreenRecording() {
        UserDefaults.standard.set(true, forKey: Self.screenRecordingRequestedKey)
        screenRecordingRequested = true
        screenRecording = CGRequestScreenCaptureAccess()
    }

    private func refresh() {
        screenRecordingRequested = UserDefaults.standard.bool(forKey: Self.screenRecordingRequestedKey)
        screenRecording = CGPreflightScreenCaptureAccess()
        accessibility = AXIsProcessTrusted()
        loginStatus = SMAppService.mainApp.status
    }
}

private extension SMAppService.Status {
    var summary: String {
        switch self {
        case .enabled: "Opens at login"
        case .requiresApproval: "Waiting for approval in System Settings"
        case .notRegistered: "Off"
        case .notFound: "Unavailable for this copy of Shotty"
        @unknown default: "Unknown"
        }
    }
}
