import AVFoundation
import AppKit
import SwiftUI

/// An audio input Shotty can record from.
struct Microphone: Equatable, Sendable {
    /// The `AVCaptureDevice.uniqueID`, which ScreenCaptureKit takes as `microphoneCaptureDeviceID`.
    let id: String
    let name: String

    /// Connected inputs, the system default first and the rest in the order macOS lists them.
    static func available() -> [Microphone] {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                       position: .unspecified).devices
        let defaultID = AVCaptureDevice.default(for: .audio)?.uniqueID
        let all = devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
        return all.filter { $0.id == defaultID } + all.filter { $0.id != defaultID }
    }
}

extension RecordingPreferences {
    /// The input a recording uses: the one picked last while it is connected, else the system
    /// default. Pass `Microphone.available()`.
    func microphone(in available: [Microphone]) -> Microphone? {
        available.first { $0.id == microphoneID } ?? available.first
    }

    /// Records from the input `id`, or no microphone for nil, as picked in the Record bar. Picking
    /// none keeps the last input, so turning the microphone on again returns to it.
    mutating func pickMicrophone(_ id: String?) {
        recordsMicrophone = id != nil
        if let id { microphoneID = id }
    }
}

/// The microphone switch of the Record bar. It names the input it records from, or says it records
/// none, and opens a menu to pick another input or none. White while it records, like the other
/// audio switch.
struct MicrophoneButton: View {
    @Bindable var preferences: AppPreferences
    @State private var available = Microphone.available()
    @State private var anchor = MenuAnchor.Reference()

    var body: some View {
        let isOn = preferences.recording.recordsMicrophone
        let title = isOn ? preferences.recording.microphone(in: available)?.name ?? "Microphone" : "No Microphone"
        Button {
            guard let view = anchor.view else { return }
            available = Microphone.available()
            // Left-aligned below the button, clear of its shadow, like a pull-down menu.
            menu().popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY + 5), in: view)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isOn ? "mic.fill" : "mic.slash")
                Text(title).lineLimit(1).frame(maxWidth: 180)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.6)
            }
        }
        .buttonStyle(isOn ? .overlayCapsuleProminent : .overlayCapsule)
        .background(MenuAnchor(reference: anchor))
        .help("Microphone: \(isOn ? title : "Off")")
        .accessibilityLabel("Microphone")
        .accessibilityValue(isOn ? title : "Off")
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
            available = Microphone.available()
        }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
            available = Microphone.available()
        }
    }

    /// No microphone, then every connected input, with a checkmark on what the button shows.
    private func menu() -> NSMenu {
        let recording = preferences.recording
        let current = recording.recordsMicrophone ? recording.microphone(in: available)?.id : nil
        let menu = OptionMenu.make(showsState: true)
        menu.addItem(OptionMenu.item("No Microphone", isOn: current == nil) { preferences.recording.pickMicrophone(nil) })
        if !available.isEmpty { menu.addItem(.separator()) }
        for microphone in available {
            menu.addItem(OptionMenu.item(microphone.name, isOn: microphone.id == current) {
                preferences.recording.pickMicrophone(microphone.id)
            })
        }
        return menu
    }
}
