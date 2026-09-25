import CoreGraphics
import Foundation

/// ScreenCaptureKit uses a top-left global origin; AppKit uses a bottom-left origin.
struct DisplayGeometry: Equatable, Sendable {
    let id: CGDirectDisplayID
    let appKitFrame: CGRect
    let captureFrame: CGRect
    let pixelSize: CGSize

    func capturePoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: captureFrame.minX + point.x - appKitFrame.minX,
                y: captureFrame.minY + appKitFrame.maxY - point.y)
    }

    func appKitPoint(fromCapture point: CGPoint) -> CGPoint {
        CGPoint(x: appKitFrame.minX + point.x - captureFrame.minX,
                y: appKitFrame.maxY - (point.y - captureFrame.minY))
    }

    /// Outward rounding covers fractional edge pixels without exceeding the source.
    func pixelRect(forAppKit rect: CGRect) -> CGRect? {
        let clipped = rect.standardized.intersection(appKitFrame)
        guard !clipped.isNull, !clipped.isEmpty,
              appKitFrame.width > 0, appKitFrame.height > 0 else { return nil }
        let sx = pixelSize.width / appKitFrame.width
        let sy = pixelSize.height / appKitFrame.height
        let pixelRect = CGRect(x: (clipped.minX - appKitFrame.minX) * sx,
                               y: (appKitFrame.maxY - clipped.maxY) * sy,
                               width: clipped.width * sx, height: clipped.height * sy)
        return pixelRect.integral.intersection(CGRect(origin: .zero, size: pixelSize))
    }
}

struct RasterBudget: Sendable {
    var maximumDimension = 30_000
    var maximumBytes = 256 * 1_024 * 1_024

    func byteCount(width: Int, height: Int, bytesPerPixel: Int = 4) throws -> Int {
        guard width > 0, height > 0, width <= maximumDimension,
              height <= maximumDimension, bytesPerPixel > 0 else { throw Failure.invalidDimensions }
        let (pixels, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: bytesPerPixel)
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
