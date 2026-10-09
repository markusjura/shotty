import AVFoundation
import ApplicationServices
import ServiceManagement
import SwiftUI

/// Status is read on appearance and whenever Shotty becomes active after a System Settings visit.
struct PermissionSettingsPane: View {
    let preferences: AppPreferences
    /// Shared with the capture and recording flows so macOS is asked at most once.
    static let screenRecordingRequestedKey = "screenRecordingRequested"

    @State private var screenRecording = CGPreflightScreenCaptureAccess()
    @State private var screenRecordingRequested = UserDefaults.standard.bool(forKey: screenRecordingRequestedKey)
    @State private var microphone = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibility = AXIsProcessTrusted()
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section("Screen Recording") {
                status(screenRecording, granted: "Allowed", missing: screenRecordingRequested ? "Not allowed" : "Not requested")
                    .settingsRowNote("Required for every capture and recording.")
                if !screenRecording {
                    HStack {
                        if !screenRecordingRequested {
                            Button("Request Access", action: requestScreenRecording)
                        }
                        Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.screenRecording) }
                    }
                    .settingsRowNote(screenRecordingRequested ? "Turn Shotty on in System Settings, then reopen it if asked." : nil)
                }
            }
            Section("Microphone") {
                status(microphone == .authorized, granted: "Allowed", missing: microphone == .notDetermined ? "Not requested" : "Not allowed")
                    .settingsRowNote("Needed only for recording your microphone.")
                if microphone == .notDetermined {
                    Button("Request Access") {
                        Task {
                            _ = await AVCaptureDevice.requestAccess(for: .audio)
                            microphone = AVCaptureDevice.authorizationStatus(for: .audio)
                        }
                    }
                } else if microphone != .authorized {
                    Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.microphone) }
                }
            }
            Section("Accessibility") {
                status(accessibility, granted: "Allowed", missing: "Not allowed")
                    .settingsRowNote("Needed for Auto Scroll and for dismissing thumbnails after pasting.")
                if !accessibility {
                    Button("Open System Settings") { SystemSettingsLink.open(SystemSettingsLink.accessibility) }
                }
            }
            Section("Save location") {
                folder("Screenshots", preferences.capture.destination.url)
                folder("Recordings", preferences.recording.destination.url)
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

    /// A save folder's name, or why it can't be used.
    @ViewBuilder private func folder(_ title: String, _ url: URL) -> some View {
        let folder = SaveDestinationCheck.status(of: url)
        if folder == .available {
            LabeledContent(title) { Text(FileManager.default.displayName(atPath: url.path)).settingsValue() }
        } else {
            status(false, title: title, granted: "", missing: "Unavailable").settingsRowNote(folder.message)
        }
    }

    /// A status row with an outlined green checkmark when granted, as in Raycast's settings, or a gray cross.
    /// Both glyphs are outlined circles of one size, so the row keeps its alignment when the status changes.
    private func status(_ ok: Bool, title: String = "Status", granted: String, missing: String) -> some View {
        LabeledContent(title) {
            Label {
                Text(ok ? granted : missing)
            } icon: {
                Image(systemName: ok ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(ok ? SettingsColor.success : SettingsColor.secondaryText)
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
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
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
