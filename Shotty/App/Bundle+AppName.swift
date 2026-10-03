import Foundation

extension Bundle {
    /// "Shotty", or "Shotty Dev" for Debug builds. Names the app's own folders, so the installed
    /// build and the development build never share captures.
    nonisolated var appName: String { object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Shotty" }
}
