import SwiftUI

/// The menu bar menu's update item, shown only while an update needs the user.
struct UpdateMenuItem: View {
    let updater: AppUpdater

    var body: some View {
        switch updater.status {
        case .available(let release):
            Button("Update to Shotty \(release.version)") { updater.showUpdate() }
            Divider()
        case .ready(_, asksForRelaunch: true):
            Button("Relaunch to Update") { updater.relaunch() }
            Divider()
        case .idle, .checking, .failed, .downloading, .ready:
            EmptyView()
        }
    }
}

/// The Updates section of General settings.
struct UpdateSettingsSection: View {
    @Bindable var updater: AppUpdater

    var body: some View {
        Section("Updates") {
            UpdateStatusRow(updater: updater)
            Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
            Toggle("Install updates automatically", isOn: $updater.installsAutomatically)
                .disabled(!updater.checksAutomatically)
        }
    }
}

/// The version and what the updater is doing, with the one action that fits. Every state shows a
/// title and a detail line, so switching states never changes the row's height.
private struct UpdateStatusRow: View {
    let updater: AppUpdater

    var body: some View {
        // Redraws each minute, so "checked just now" ages into "checked 5 minutes ago".
        TimelineView(.everyMinute) { context in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail = detail(now: context.date) { Text(detail).settingsNote() }
                }
                Spacer()
                action
            }
            .padding(.vertical, 6)
        }
    }

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }
    private var current: String { "\(Bundle.main.appName) \(version)" }

    private var title: String {
        switch updater.status {
        case .idle, .checking, .failed, .downloading: current
        case .available(let release): "Shotty \(release.version) is available"
        case .ready(let release, _): "Shotty \(release.version) is ready"
        }
    }

    private func detail(now: Date) -> AttributedString? {
        switch updater.status {
        case .idle:
            // Shotty Dev without a test feed never checks, so it shows the version alone.
            guard updater.isRunning else { return nil }
            guard let checked = updater.lastChecked else { return "Not checked yet" }
            let when = Self.phrase(for: checked, now: now)
            // With automatic checks off, an old result may no longer be true.
            let isFresh = updater.checksAutomatically || now.timeIntervalSince(checked) < 24 * 60 * 60
            return AttributedString(isFresh ? "Up to date · checked \(when)" : "Last checked \(when)")
        case .checking: return "Checking for updates"
        case .failed(let offline): return offline ? "Couldn't check for updates. You're offline." : "Couldn't check for updates."
        case .downloading(let release): return AttributedString("Downloading Shotty \(release.version)")
        case .available(let release): return withNotes("You have \(version)", release)
        case .ready(let release, let asksForRelaunch):
            return withNotes(asksForRelaunch ? "Relaunch to finish updating" : "Installs when you're away", release)
        }
    }

    @ViewBuilder private var action: some View {
        switch updater.status {
        case .idle, .failed:
            if updater.isRunning {
                Button(updater.status == .idle ? "Check Now" : "Try Again") { updater.checkForUpdates() }
            }
        case .checking, .downloading:
            ProgressView().controlSize(.small)
        case .available:
            Button("Install") { updater.showUpdate() }.buttonStyle(SettingsButtonStyle(isProminent: true))
        case .ready(_, let asksForRelaunch):
            // Blue once Shotty stops waiting for an idle moment and needs the user.
            Button("Relaunch") { updater.relaunch() }
                .buttonStyle(SettingsButtonStyle(isProminent: asksForRelaunch))
        }
    }

    /// The detail text followed by a What's New link, when the release has a page.
    private func withNotes(_ text: String, _ release: AppUpdater.Release) -> AttributedString {
        var result = AttributedString(text)
        guard let url = release.notesURL else { return result }
        var link = AttributedString("What's New")
        link.link = url
        result += " · " + link
        return result
    }

    /// "just now" for the first minute, then "5 minutes ago", "yesterday", "12 days ago".
    private static func phrase(for date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

/// The blue dot that marks an update needing the user, in the Settings sidebar.
struct UpdateDot: View {
    var body: some View {
        Circle().fill(Color(nsColor: .systemBlue)).frame(width: 7, height: 7).accessibilityLabel("Update available")
    }
}
