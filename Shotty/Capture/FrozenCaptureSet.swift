import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

struct FrozenCaptureLimits: Sendable {
    /// One raster. A shadowed full-screen window on a 5K display needs about 65 MiB.
    var maximumRasterBytes = 128 * 1_024 * 1_024
    /// Every raster of one set, stored in its private scratch directory.
    var maximumDiskBytes = 1_024 * 1_024 * 1_024
    var maximumWindows = 80
    var maximumDimension = 16_384

    /// Returns the raster's byte count after checking its dimensions and size.
    func validateRaster(width: Int, height: Int, bytesPerRow: Int) throws -> Int {
        let (bytes, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, bytesPerRow > 0, width <= maximumDimension, height <= maximumDimension,
              !overflow, bytes <= maximumRasterBytes else { throw FrozenCaptureFailure.resourceLimit }
        return bytes
    }

    /// Pre-capture budget for an SDR screenshot of `pointSize` at `scale`. Studio's
    /// SCScreenshotManager `.sdr` output measured 8 bits per component, 32 bits per pixel,
    /// 128-byte row alignment and at most 224 px of shadow padding. This rounds rows up
    /// to 256 bytes and pads shadows by 256 px; `FrozenRasterFile.store` still validates
    /// the actual raster after capture.
    func validateSDRCapture(pointSize: CGSize, scale: Double, shadow: Bool) throws -> Int {
        let padding = shadow ? 256.0 : 0
        let width = ceil(Double(pointSize.width) * scale + padding)
        let height = ceil(Double(pointSize.height) * scale + padding)
        let dimensionLimit = Double(min(maximumDimension, Int.max / 16))
        guard width.isFinite, height.isFinite, width > 0, height > 0,
              width <= dimensionLimit, height <= dimensionLimit else { throw FrozenCaptureFailure.resourceLimit }
        return try validateRaster(width: Int(width), height: Int(height),
                                  bytesPerRow: ((Int(width) * 4 + 255) / 256) * 256)
    }
}

enum FrozenCaptureFailure: LocalizedError {
    case resourceLimit, diskLimit, unsupportedRaster, targetChanged, closed
    case rasterFormat(String)

    var errorDescription: String? {
        switch self {
        case .resourceLimit: "The frozen window set exceeds the capture memory or window limit. Close some windows and retry."
        case .diskLimit: "The frozen window set exceeds its temporary storage limit. Close some windows and retry."
        case .unsupportedRaster: "The captured pixel format or color profile could not be preserved."
        case .rasterFormat(let details): "The captured raster could not be preserved: \(details)"
        case .targetChanged: "A window or display changed during freezing. Retry the capture."
        case .closed: "This frozen capture has already ended. Start a new capture."
        }
    }
}

struct FrozenRasterDescriptor: Sendable {
    let id: UUID
    let width: Int
    let height: Int
    let byteCount: Int
    fileprivate let bitsPerComponent: Int
    fileprivate let bitsPerPixel: Int
    fileprivate let bytesPerRow: Int
    fileprivate let bitmapInfo: UInt32
    fileprivate let colorSpace: Data
    fileprivate let renderingIntent: Int32
    fileprivate let shouldInterpolate: Bool

    fileprivate var filename: String { id.uuidString + ".pixels" }
}

struct FrozenWindowSnapshot: Sendable {
    let windowID: CGWindowID
    /// Global top-left ScreenCaptureKit coordinates, before shadow padding.
    let frame: CGRect
    let pointPixelScale: Float
    let includesShadow: Bool
    let raster: FrozenRasterDescriptor
}

struct FrozenDisplaySnapshot: Sendable {
    let displayID: CGDirectDisplayID
    let frame: CGRect
    let pointPixelScale: Float
    let raster: FrozenRasterDescriptor
}

/// All acquisition finishes before this value is returned. An overlay and its
/// eventual export must both load the same descriptor, never capture another frame.
/// Call close at session end. Deinitialization also removes the private directory.
actor FrozenCaptureSet {
    private static let logger = Logger(subsystem: "local.markus.Shotty", category: "FrozenCapture")
    /// Captures in flight at once.
    private static let concurrentCaptures = 3
    nonisolated let windows: [FrozenWindowSnapshot]
    nonisolated let displays: [FrozenDisplaySnapshot]
    private let directory: URL
    private var isClosed = false

    private init(directory: URL, windows: [FrozenWindowSnapshot], displays: [FrozenDisplaySnapshot]) {
        self.directory = directory
        self.windows = windows
        self.displays = displays
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// Freezes every display and, with `includingWindows`, every eligible window with and without
    /// its shadow, with up to `concurrentCaptures` at once. The stored set must fit `maximumDiskBytes`.
    /// Shotty's own windows stay visible, such as Settings and thumbnails; only the capture
    /// overlays in `excludingWindowIDs` are left out.
    static func acquire(includingWindows: Bool, excludingWindowIDs: Set<CGWindowID>) async throws -> FrozenCaptureSet {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permissionRequired }
        try Task.checkCancellation()
        let limits = FrozenCaptureLimits()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let selectedDisplays = content.displays
        guard !selectedDisplays.isEmpty else { throw CaptureFailure.targetUnavailable }
        // On-screen normal application windows on the frozen displays, overlays excluded.
        func eligible(_ windows: [SCWindow]) -> [SCWindow] {
            guard includingWindows else { return [] }
            return windows.filter { window in
                window.isOnScreen && window.windowLayer == 0 && !window.frame.isEmpty && window.owningApplication != nil
                    && !excludingWindowIDs.contains(window.windowID)
                    && selectedDisplays.contains { $0.frame.intersects(window.frame) }
            }
        }
        let selectedWindows = eligible(content.windows)
        guard selectedWindows.count <= limits.maximumWindows else { throw FrozenCaptureFailure.resourceLimit }
        try CaptureScratchSpace.prepare()
        let directory = CaptureScratchSpace.directory.appendingPathComponent("Shotty-freeze-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        do {
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var privateDirectory = directory
            try privateDirectory.setResourceValues(resourceValues)
            var jobs: [CaptureJob] = []
            for window in selectedWindows {
                // The unshadowed raster previews the window exactly on its frame; Option at
                // confirmation can pick either variant for the output.
                for includesShadow in [false, true] {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    jobs.append(CaptureJob(filter: filter, shadow: includesShadow, target: .window(window.windowID, window.frame)))
                }
            }
            let overlays = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
            for display in selectedDisplays {
                let filter = SCContentFilter(display: display, excludingWindows: overlays)
                jobs.append(CaptureJob(filter: filter, shadow: false, target: .display(display.displayID, display.frame)))
            }
            let estimates = try jobs.map { job in
                do {
                    return try limits.validateSDRCapture(pointSize: job.filter.contentRect.size,
                                                         scale: Double(job.filter.pointPixelScale), shadow: job.shadow)
                } catch {
                    logger.error("Frozen estimate rejected \(job.diagnosticLabel, privacy: .public)")
                    throw error
                }
            }
            // Each capture may store at most its estimate and returns the unused rest when it finishes.
            // Leaving the group, even by throwing, waits for every capture, so the cleanup below never
            // deletes files that a capture still writes.
            let rasters = try await withThrowingTaskGroup(of: (Int, FrozenRasterDescriptor).self) { group in
                var rasters: [(Int, FrozenRasterDescriptor)] = []
                // Stored bytes of finished captures plus the estimates of running ones.
                var diskBytes = 0
                for (index, (job, estimate)) in zip(jobs, estimates).enumerated() {
                    while index - rasters.count >= concurrentCaptures || diskBytes + estimate > limits.maximumDiskBytes,
                          let (done, raster) = try await group.next() {
                        diskBytes -= estimates[done] - raster.byteCount
                        rasters.append((done, raster))
                    }
                    guard diskBytes + estimate <= limits.maximumDiskBytes else {
                        logger.error("Frozen set rejected \(job.diagnosticLabel, privacy: .public) estimate=\(estimate) disk=\(diskBytes)")
                        throw FrozenCaptureFailure.diskLimit
                    }
                    diskBytes += estimate
                    group.addTask { (index, try await capture(job, directory: directory, remainingDiskBytes: estimate, limits: limits)) }
                }
                for try await raster in group { rasters.append(raster) }
                return rasters.sorted { $0.0 < $1.0 }.map(\.1)
            }
            var windows: [FrozenWindowSnapshot] = []
            var displays: [FrozenDisplaySnapshot] = []
            for (job, raster) in zip(jobs, rasters) {
                switch job.target {
                case .window(let id, let frame):
                    windows.append(FrozenWindowSnapshot(windowID: id, frame: frame, pointPixelScale: job.filter.pointPixelScale,
                                                        includesShadow: job.shadow, raster: raster))
                case .display(let id, let frame):
                    displays.append(FrozenDisplaySnapshot(displayID: id, frame: frame, pointPixelScale: job.filter.pointPixelScale, raster: raster))
                }
            }
            try Task.checkCancellation()
            // Prevent binding invocation-time frames to pixels acquired after a move.
            let latest = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let latestEligibleIDs = Set(eligible(latest.windows).map(\.windowID))
            let initialWindowIDs = Set(selectedWindows.map(\.windowID))
            let initialDisplayIDs = Set(selectedDisplays.map(\.displayID))
            let latestDisplayIDs = Set(latest.displays.map(\.displayID))
            let changedWindows = selectedWindows.filter { initial in
                !latest.windows.contains { $0.windowID == initial.windowID && $0.isOnScreen && $0.frame == initial.frame }
            }
            let changedDisplays = selectedDisplays.filter { initial in
                !latest.displays.contains { $0.displayID == initial.displayID && $0.frame == initial.frame && $0.width == initial.width && $0.height == initial.height }
            }
            guard latestEligibleIDs == initialWindowIDs, latestDisplayIDs == initialDisplayIDs,
                  changedWindows.isEmpty, changedDisplays.isEmpty else {
                let windows = changedWindows.map { initial in
                    let current = latest.windows.first { $0.windowID == initial.windowID }
                    return "\(initial.windowID):\(initial.frame)->\(String(describing: current?.frame)),onScreen=\(String(describing: current?.isOnScreen))"
                }
                let displays = changedDisplays.map { initial in
                    let current = latest.displays.first { $0.displayID == initial.displayID }
                    return "\(initial.displayID):\(initial.frame),\(initial.width)x\(initial.height)->\(String(describing: current?.frame)),\(String(describing: current?.width))x\(String(describing: current?.height))"
                }
                logger.error("Frozen validation rejected: addedWindows=\(latestEligibleIDs.subtracting(initialWindowIDs).sorted(), privacy: .public) removedWindows=\(initialWindowIDs.subtracting(latestEligibleIDs).sorted(), privacy: .public) changedWindows=\(windows, privacy: .public) displayIDsBefore=\(initialDisplayIDs.sorted(), privacy: .public) displayIDsAfter=\(latestDisplayIDs.sorted(), privacy: .public) changedDisplays=\(displays, privacy: .public)")
                throw FrozenCaptureFailure.targetChanged
            }
            try Task.checkCancellation()
            return FrozenCaptureSet(directory: directory, windows: windows, displays: displays)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// File mapping is lazy; the caller should retain only its current selected image.
    /// Returned images remain usable after close because their providers own the mapping.
    func image(for descriptor: FrozenRasterDescriptor) throws -> CGImage {
        guard !isClosed else { throw FrozenCaptureFailure.closed }
        guard windows.contains(where: { $0.raster.id == descriptor.id }) || displays.contains(where: { $0.raster.id == descriptor.id }) else {
            throw CaptureFailure.targetUnavailable
        }
        return try FrozenRasterFile.load(descriptor, directory: directory)
    }

    func close() throws {
        guard !isClosed else { return }
        try FileManager.default.removeItem(at: directory)
        isClosed = true
    }

    /// True when an unshadowed window raster is its frame at the filter's scale, allowing for rounding.
    private static func matchesWindowFrame(_ image: CGImage, filter: SCContentFilter) -> Bool {
        let scale = CGFloat(filter.pointPixelScale)
        return abs(CGFloat(image.width) - filter.contentRect.width * scale) <= 1
            && abs(CGFloat(image.height) - filter.contentRect.height * scale) <= 1
    }

    /// ScreenCaptureKit does not annotate SCContentFilter as Sendable. Each job owns
    /// a distinct filter, configured before launch and never mutated or shared with
    /// another capture. Parent-side reads happen before launch or after the group joins.
    private struct CaptureJob: @unchecked Sendable {
        enum Target: Sendable {
            case window(CGWindowID, CGRect)
            case display(CGDirectDisplayID, CGRect)
        }
        let filter: SCContentFilter
        let shadow: Bool
        let target: Target

        var isWindow: Bool { if case .window = target { true } else { false } }

        /// Identifiers and geometry only; never titles or application names.
        var diagnosticLabel: String {
            let size = filter.contentRect.size
            let kind = switch target {
            case .window(let id, _): "window \(id)"
            case .display(let id, _): "display \(id)"
            }
            return "\(kind) \(Int(size.width))x\(Int(size.height))pt scale=\(filter.pointPixelScale) shadow=\(shadow)"
        }
    }

    private static func capture(_ job: CaptureJob, directory: URL, remainingDiskBytes: Int,
                                limits: FrozenCaptureLimits) async throws -> FrozenRasterDescriptor {
        try Task.checkCancellation()
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadows = !job.shadow
        // Window capture is the selected window only. Capturing a child window with children
        // included returns its parent group, which no longer matches the window's frame.
        configuration.includeChildWindows = false
        configuration.dynamicRange = .sdr
        // Zero dimensions retain ScreenCaptureKit's native-size output, including shadows.
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: job.filter, configuration: configuration)
        try Task.checkCancellation()
        guard let image = output.sdrImage else { throw CaptureFailure.noImage }
        // The selection overlay draws unshadowed rasters exactly onto the window frame.
        if job.isWindow, !job.shadow, !matchesWindowFrame(image, filter: job.filter) {
            logger.error("Frozen window raster does not match its frame \(job.diagnosticLabel, privacy: .public) actual=\(image.width)x\(image.height)")
            throw FrozenCaptureFailure.targetChanged
        }
        do {
            return try autoreleasepool {
                try FrozenRasterFile.store(image, directory: directory, remainingDiskBytes: remainingDiskBytes, limits: limits)
            }
        } catch let error as FrozenCaptureFailure {
            // Compares the pre-capture estimate with what ScreenCaptureKit returned, for example
            // when child windows or shadows extend the image beyond the window's own frame.
            logger.error("Frozen raster rejected \(job.diagnosticLabel, privacy: .public) estimate=\(remainingDiskBytes) actual=\(image.width)x\(image.height) row=\(image.bytesPerRow) bytes=\(image.bytesPerRow * image.height) error=\(String(describing: error), privacy: .public)")
            throw error
        }
    }
}

/// Raw immutable provider bytes avoid an encoder pass and preserve row padding,
/// channel layout and the captured color space without a conversion through sRGB.
enum FrozenRasterFile {
    static func store(_ image: CGImage, directory: URL, remainingDiskBytes: Int,
                      limits: FrozenCaptureLimits) throws -> FrozenRasterDescriptor {
        let byteCount = try limits.validateRaster(width: image.width, height: image.height, bytesPerRow: image.bytesPerRow)
        guard byteCount <= remainingDiskBytes else { throw FrozenCaptureFailure.diskLimit }
        // Format metadata is safe to report; no pixel bytes, window titles or paths.
        let format = "\(image.width)x\(image.height), row \(image.bytesPerRow), \(image.bitsPerComponent)/\(image.bitsPerPixel) bits"
        guard !image.isMask else { throw FrozenCaptureFailure.rasterFormat("image mask; \(format)") }
        guard image.decode == nil else { throw FrozenCaptureFailure.rasterFormat("explicit decode map; \(format)") }
        guard let colorSpace = image.colorSpace else { throw FrozenCaptureFailure.rasterFormat("missing color space; \(format)") }
        guard let space = colorSpace.copyPropertyList() else {
            throw FrozenCaptureFailure.rasterFormat("unserializable color space model \(colorSpace.model.rawValue), \(colorSpace.numberOfComponents) components; \(format)")
        }
        guard let raw = image.dataProvider?.data else { throw FrozenCaptureFailure.rasterFormat("missing provider bytes; \(format)") }
        let providerByteCount = CFDataGetLength(raw)
        // ScreenCaptureKit's provider may include extra allocation pages after the last scanline;
        // only the raster is stored.
        guard providerByteCount >= byteCount else {
            throw FrozenCaptureFailure.rasterFormat("provider has \(providerByteCount) bytes, expected \(byteCount); \(format)")
        }
        let profile = try PropertyListSerialization.data(fromPropertyList: space, format: .binary, options: 0)
        guard profile.count <= 1_024 * 1_024 else { throw FrozenCaptureFailure.rasterFormat("color profile exceeds 1 MiB; \(format)") }
        let descriptor = FrozenRasterDescriptor(id: UUID(), width: image.width, height: image.height, byteCount: byteCount,
            bitsPerComponent: image.bitsPerComponent, bitsPerPixel: image.bitsPerPixel, bytesPerRow: image.bytesPerRow,
            bitmapInfo: image.bitmapInfo.rawValue, colorSpace: profile, renderingIntent: image.renderingIntent.rawValue,
            shouldInterpolate: image.shouldInterpolate)
        let url = directory.appendingPathComponent(descriptor.filename)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            // Writes straight from the provider; bridging it to Data would first copy the whole raster.
            try withExtendedLifetime(raw) {
                try handle.write(contentsOf: UnsafeRawBufferPointer(start: CFDataGetBytePtr(raw), count: byteCount))
            }
            try Task.checkCancellation()
            return descriptor
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    static func load(_ descriptor: FrozenRasterDescriptor, directory: URL) throws -> CGImage {
        let raw = try Data(contentsOf: directory.appendingPathComponent(descriptor.filename), options: .alwaysMapped)
        let plist = try PropertyListSerialization.propertyList(from: descriptor.colorSpace, options: [], format: nil)
        guard raw.count == descriptor.byteCount, let space = CGColorSpace(propertyListPlist: plist as CFPropertyList),
              let provider = CGDataProvider(data: raw as CFData),
              let intent = CGColorRenderingIntent(rawValue: descriptor.renderingIntent),
              let image = CGImage(width: descriptor.width, height: descriptor.height,
                  bitsPerComponent: descriptor.bitsPerComponent, bitsPerPixel: descriptor.bitsPerPixel,
                  bytesPerRow: descriptor.bytesPerRow, space: space, bitmapInfo: CGBitmapInfo(rawValue: descriptor.bitmapInfo),
                  provider: provider, decode: nil, shouldInterpolate: descriptor.shouldInterpolate, intent: intent) else {
            throw FrozenCaptureFailure.unsupportedRaster
        }
        return image
    }
}
