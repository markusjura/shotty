import CoreGraphics
import Foundation

/// ScreenCaptureKit uses a top-left global origin; AppKit uses a bottom-left origin.
struct DisplayGeometry: Equatable, Sendable {
    let appKitFrame: CGRect
    let captureFrame: CGRect

    func capturePoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: captureFrame.minX + point.x - appKitFrame.minX,
                y: captureFrame.minY + appKitFrame.maxY - point.y)
    }

    func appKitPoint(fromCapture point: CGPoint) -> CGPoint {
        CGPoint(x: appKitFrame.minX + point.x - captureFrame.minX,
                y: appKitFrame.maxY - (point.y - captureFrame.minY))
    }
}

struct RasterBudget: Sendable {
    var maximumDimension = 30_000
    var maximumBytes = 256 * 1_024 * 1_024

    /// Bytes of a raster at 4 bytes per pixel. Throws when it exceeds the budget.
    func byteCount(width: Int, height: Int) throws -> Int {
        guard width > 0, height > 0, width <= maximumDimension, height <= maximumDimension else { throw Failure.invalidDimensions }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow, !byteOverflow, bytes <= maximumBytes else { throw Failure.memoryLimit }
        return bytes
    }

    enum Failure: LocalizedError {
        case invalidDimensions, memoryLimit

        var errorDescription: String? {
            switch self {
            case .invalidDimensions: "The capture dimensions are outside the supported range. Select a smaller region."
            case .memoryLimit: "This capture exceeds the current memory limit. Select a smaller region."
            }
        }
    }
}
