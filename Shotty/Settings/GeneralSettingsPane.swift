import ServiceManagement
import SwiftUI

struct GeneralSettingsPane: View {
    @Bindable var preferences: AppPreferences
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $preferences.general.appearance) {
                    Text("System").tag(AppearancePreference.system)
                    Text("Light").tag(AppearancePreference.light)
                    Text("Dark").tag(AppearancePreference.dark)
                }
                .pickerStyle(.radioGroup)
            }
            Section {
                Toggle("Show in menu bar", isOn: $preferences.general.showsMenuBarIcon)
                Toggle("Show in Dock", isOn: $preferences.general.showsDockIcon)
                Toggle("Open at login", isOn: Binding(get: { loginStatus == .enabled || loginStatus == .requiresApproval }, set: setLogin))
                if loginStatus == .requiresApproval {
                    LabeledContent("Login item") {
                        HStack {
                            Button("Approve in System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                        }
                        .accessibilityElement(children: .contain)
                    }
                }
                if let loginError {
                    Text(loginError).secondaryNote()
                }
            }
            Section {
                Toggle("Play sounds", isOn: $preferences.general.playsSounds)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    /// Registration happens only from this explicit toggle.
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Login item could not be changed: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}
