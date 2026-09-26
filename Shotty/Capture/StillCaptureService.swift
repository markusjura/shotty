import CoreGraphics
import Foundation
import ScreenCaptureKit

enum CaptureFailure: LocalizedError {
    case permissionRequired, noImage, targetUnavailable

    var errorDescription: String? {
        switch self {
        case .permissionRequired: "Allow Screen Recording for Shotty in System Settings, then relaunch Shotty."
        case .noImage: "ScreenCaptureKit returned no image. Retry the capture."
        case .targetUnavailable: "The selected window or display is no longer available. Select it again."
        }
    }
}

/// Owns capture work independently of AppKit. Callers retain this exact image for frozen output.
actor StillCaptureService {
    private let budget = RasterBudget()

    func window(id: CGWindowID, shadow: Bool) async throws -> CGImage {
        try preflight()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == id }) else {
            throw CaptureFailure.targetUnavailable
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadows = !shadow
        // The selected window only: a child window captured with children returns its parent group.
        configuration.includeChildWindows = false
        configuration.dynamicRange = .sdr
        // Account conservatively for shadow padding before asking the framework to allocate.
        let scale = CGFloat(filter.pointPixelScale)
        let padding = shadow ? 256.0 : 0
        _ = try budget.byteCount(width: Int(ceil(filter.contentRect.width * scale + padding)),
                                 height: Int(ceil(filter.contentRect.height * scale + padding)))
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard let image = output.sdrImage else { throw CaptureFailure.noImage }
        _ = try budget.byteCount(width: image.width, height: image.height)
        return image
    }

    /// Everything on the display, Shotty's own windows included, except `excludedWindowIDs`
    /// (the capture overlays, when present).
    func display(id: CGDirectDisplayID, excluding excludedWindowIDs: Set<CGWindowID> = []) async throws -> CGImage {
        try preflight()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == id }) else {
            throw CaptureFailure.targetUnavailable
        }
        let filter = SCContentFilter(display: display, excludingWindows: content.windows.filter { excludedWindowIDs.contains($0.windowID) })
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.dynamicRange = .sdr
        configuration.width = Int(CGFloat(display.width) * CGFloat(filter.pointPixelScale))
        configuration.height = Int(CGFloat(display.height) * CGFloat(filter.pointPixelScale))
        _ = try budget.byteCount(width: configuration.width, height: configuration.height)
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard let image = output.sdrImage else { throw CaptureFailure.noImage }
        _ = try budget.byteCount(width: image.width, height: image.height)
        return image
    }

    private func preflight() throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permissionRequired }
    }
}
