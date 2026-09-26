import CoreGraphics
import Foundation
import ScreenCaptureKit
import os

struct FrozenCaptureLimits: Sendable {
    var maximumResidentBytes = 256 * 1_024 * 1_024
    var maximumDiskBytes = 1_024 * 1_024 * 1_024
    var maximumWindows = 80
    var maximumDimension = 16_384
    /// Internal profiling control, never a product setting.
    var maximumConcurrentCaptures = 3

    /// Covers the captured raster plus the provider copy used to write it. Framework
    /// and WindowServer allocations are outside this application-owned buffer budget.
    func validateRaster(width: Int, height: Int, bytesPerRow: Int) throws -> Int {
        let (bytes, overflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, bytesPerRow > 0, width <= maximumDimension,
              height <= maximumDimension, !overflow else { throw FrozenCaptureFailure.resourceLimit }
        guard maximumResidentBytes > 1_024 * 1_024,
              bytes <= (maximumResidentBytes - 1_024 * 1_024) / 2 else { throw FrozenCaptureFailure.resourceLimit }
        return bytes
    }

    /// Pre-capture budget for an SDR screenshot of `pointSize` at `scale`. Studio's
    /// SCScreenshotManager `.sdr` output measured 8 bits per component, 32 bits per pixel,
    /// 128-byte row alignment and at most 224 px of shadow padding. This rounds rows up
    /// to 256 bytes and pads shadows by 256 px; `FrozenRasterFile.store` still validates
    /// the actual raster and provider bytes after capture.
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

struct FrozenCaptureMeasurements: Sendable {
    let windowCount: Int
    let rasterCount: Int
    let displayCount: Int
    let diskBytes: Int
    let largestRasterBytes: Int
    let elapsedSeconds: TimeInterval
    let maximumConcurrentCaptures: Int
    let peakReservedResidentBytes: Int
}

/// Reservations include each in-flight raster, its provider copy, profile and up to
/// 1 MiB of provider allocation padding. Completed profiles remain charged separately.
struct FrozenCaptureBatch: Sendable {
    struct Reservation: Sendable {
        let index: Int
        let rasterBytes: Int
        let residentBytes: Int
    }

    let reservations: [Reservation]
    let residentBytes: Int

    init(estimates: ArraySlice<Int>, retainedProfileBytes: Int, storedDiskBytes: Int, limits: FrozenCaptureLimits) throws {
        guard (1...3).contains(limits.maximumConcurrentCaptures),
              retainedProfileBytes >= 0, retainedProfileBytes <= limits.maximumResidentBytes else {
            throw FrozenCaptureFailure.resourceLimit
        }
        guard storedDiskBytes >= 0, storedDiskBytes <= limits.maximumDiskBytes else { throw FrozenCaptureFailure.diskLimit }
        let profileAllowance = 1_024 * 1_024
        var memory = limits.maximumResidentBytes - retainedProfileBytes
        var disk = limits.maximumDiskBytes - storedDiskBytes
        var reservations: [Reservation] = []
        for index in estimates.indices {
            if reservations.count == limits.maximumConcurrentCaptures { break }
            let bytes = estimates[index]
            guard bytes > 0, memory > profileAllowance, bytes <= (memory - profileAllowance) / 2 else {
                if reservations.isEmpty { throw FrozenCaptureFailure.resourceLimit }
                break
            }
            guard bytes <= disk else {
                if reservations.isEmpty { throw FrozenCaptureFailure.diskLimit }
                break
            }
            let minimum = bytes * 2 + profileAllowance
            let reserved = minimum + min(profileAllowance, memory - minimum)
            reservations.append(Reservation(index: index, rasterBytes: bytes, residentBytes: reserved))
            memory -= reserved
            disk -= bytes
        }
        self.reservations = reservations
        residentBytes = limits.maximumResidentBytes - retainedProfileBytes - memory
    }

    /// Structured cancellation waits for every sibling before the outer transaction
    /// deletes files. Only metadata returns from an operation; native images stay local.
    func run<Result: Sendable>(_ operation: @escaping @Sendable (Reservation) async throws -> Result) async throws -> [Result] {
        try Task.checkCancellation()
        return try await withThrowingTaskGroup(of: (Int, Result).self) { group in
            for reservation in reservations {
                group.addTask {
                    try Task.checkCancellation()
                    return (reservation.index, try await operation(reservation))
                }
            }
            var results: [(Int, Result)] = []
            for try await result in group { results.append(result) }
            try Task.checkCancellation()
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

/// All acquisition finishes before this value is returned. An overlay and its
/// eventual export must both load the same descriptor, never capture another frame.
/// Call close at session end. Deinitialization also removes the private directory.
actor FrozenCaptureSet {
    private static let logger = Logger(subsystem: "local.markus.Shotty", category: "FrozenCapture")
    nonisolated let windows: [FrozenWindowSnapshot]
    nonisolated let displays: [FrozenDisplaySnapshot]
    nonisolated let measurements: FrozenCaptureMeasurements
    private let directory: URL
    private var isClosed = false

    private init(directory: URL, windows: [FrozenWindowSnapshot], displays: [FrozenDisplaySnapshot],
                 measurements: FrozenCaptureMeasurements) {
        self.directory = directory
        self.windows = windows
        self.displays = displays
        self.measurements = measurements
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    /// At most three acquisitions run together, each with a reserved share of both
    /// budgets. Large rasters fall back to sequential capture when necessary.
    /// Shotty's own windows stay visible, such as Settings and thumbnails; only the capture
    /// overlays in `excludingWindowIDs` are left out. Fixture IDs must still be on-screen,
    /// normal-layer windows. Nil means the full eligible set, not a shortlist.
    static func acquire(shadow: Bool, includeAlternateShadow: Bool = false,
                        displayIDs: Set<CGDirectDisplayID>? = nil,
                        fixtureWindowIDs: Set<CGWindowID>? = nil,
                        excludingWindowIDs: Set<CGWindowID> = [],
                        limits: FrozenCaptureLimits = .init()) async throws -> FrozenCaptureSet {
        let started = ProcessInfo.processInfo.systemUptime
        guard CGPreflightScreenCaptureAccess() else { throw CaptureFailure.permissionRequired }
        guard limits.maximumDiskBytes > 0, limits.maximumResidentBytes > 0,
              limits.maximumWindows >= 0 else { throw FrozenCaptureFailure.resourceLimit }
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        let selectedDisplays = content.displays.filter { displayIDs?.contains($0.displayID) ?? true }
        guard !selectedDisplays.isEmpty,
              displayIDs.map({ $0 == Set(selectedDisplays.map(\.displayID)) }) ?? true else {
            throw CaptureFailure.targetUnavailable
        }
        let selectedWindows = content.windows.filter { window in
            guard window.isOnScreen, window.windowLayer == 0, !window.frame.isEmpty,
                  selectedDisplays.contains(where: { $0.frame.intersects(window.frame) }) else { return false }
            if let fixtureWindowIDs { return fixtureWindowIDs.contains(window.windowID) }
            return window.owningApplication != nil && !excludingWindowIDs.contains(window.windowID)
        }
        guard fixtureWindowIDs.map({ $0 == Set(selectedWindows.map(\.windowID)) }) ?? true else {
            throw CaptureFailure.targetUnavailable
        }
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
            var windows: [FrozenWindowSnapshot] = []
            var displays: [FrozenDisplaySnapshot] = []
            var diskBytes = 0
            var profileBytes = 0
            var largestRaster = 0
            var jobs: [CaptureJob] = []
            for window in selectedWindows {
                for includesShadow in includeAlternateShadow ? [shadow, !shadow] : [shadow] {
                    let filter = SCContentFilter(desktopIndependentWindow: window)
                    jobs.append(CaptureJob(filter: filter, shadow: includesShadow, target: .window(window.windowID, window.frame)))
                }
            }
            let overlays = content.windows.filter { excludingWindowIDs.contains($0.windowID) }
            for display in selectedDisplays {
                let filter = SCContentFilter(display: display, excludingWindows: overlays)
                jobs.append(CaptureJob(filter: filter, shadow: false, target: .display(display.displayID, display.frame)))
            }
            let requests = jobs
            let estimates = try requests.map { job in
                do {
                    return try limits.validateSDRCapture(pointSize: job.filter.contentRect.size,
                                                         scale: Double(job.filter.pointPixelScale), shadow: job.shadow)
                } catch {
                    logger.error("Frozen estimate rejected \(job.diagnosticLabel, privacy: .public)")
                    throw error
                }
            }
            var nextIndex = 0
            var maximumConcurrentCaptures = 0
            var peakReservedResidentBytes = 0
            while nextIndex < requests.count {
                try Task.checkCancellation()
                let batch: FrozenCaptureBatch
                do {
                    batch = try FrozenCaptureBatch(estimates: estimates[nextIndex...], retainedProfileBytes: profileBytes,
                                                   storedDiskBytes: diskBytes, limits: limits)
                } catch {
                    logger.error("Frozen batch rejected \(requests[nextIndex].diagnosticLabel, privacy: .public) estimate=\(estimates[nextIndex]) retainedProfiles=\(profileBytes) storedDisk=\(diskBytes)")
                    throw error
                }
                maximumConcurrentCaptures = max(maximumConcurrentCaptures, batch.reservations.count)
                peakReservedResidentBytes = max(peakReservedResidentBytes, profileBytes + batch.residentBytes)
                let rasters = try await batch.run { reservation in
                    let job = requests[reservation.index]
                    var availableLimits = limits
                    availableLimits.maximumResidentBytes = reservation.residentBytes
                    return try await capture(filter: job.filter, shadow: job.shadow, directory: directory,
                                             remainingDiskBytes: reservation.rasterBytes, limits: availableLimits,
                                             isWindow: job.isWindow, label: job.diagnosticLabel)
                }
                for (reservation, raster) in zip(batch.reservations, rasters) {
                    let job = requests[reservation.index]
                    diskBytes += raster.byteCount
                    profileBytes += raster.colorSpace.count
                    largestRaster = max(largestRaster, raster.byteCount)
                    switch job.target {
                    case .window(let id, let frame):
                        windows.append(FrozenWindowSnapshot(windowID: id, frame: frame, pointPixelScale: job.filter.pointPixelScale,
                                                            includesShadow: job.shadow, raster: raster))
                    case .display(let id, let frame):
                        displays.append(FrozenDisplaySnapshot(displayID: id, frame: frame, pointPixelScale: job.filter.pointPixelScale, raster: raster))
                    }
                }
                nextIndex += batch.reservations.count
            }
            try Task.checkCancellation()
            // Prevent binding invocation-time frames to pixels acquired after a move.
            let latest = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let latestEligibleIDs = Set(latest.windows.filter { window in
                guard window.isOnScreen, window.windowLayer == 0, !window.frame.isEmpty,
                      selectedDisplays.contains(where: { $0.frame.intersects(window.frame) }) else { return false }
                if let fixtureWindowIDs { return fixtureWindowIDs.contains(window.windowID) }
                return window.owningApplication != nil && !excludingWindowIDs.contains(window.windowID)
            }.map(\.windowID))
            let initialWindowIDs = Set(selectedWindows.map(\.windowID))
            let initialDisplayIDs = Set(selectedDisplays.map(\.displayID))
            let latestDisplayIDs = Set(latest.displays.map(\.displayID))
            let changedWindows = selectedWindows.filter { initial in
                !latest.windows.contains { $0.windowID == initial.windowID && $0.isOnScreen && $0.frame == initial.frame }
            }
            let changedDisplays = selectedDisplays.filter { initial in
                !latest.displays.contains { $0.displayID == initial.displayID && $0.frame == initial.frame && $0.width == initial.width && $0.height == initial.height }
            }
            guard latestEligibleIDs == initialWindowIDs,
                  displayIDs != nil || latestDisplayIDs == initialDisplayIDs,
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
            return FrozenCaptureSet(directory: directory, windows: windows, displays: displays,
                                    measurements: FrozenCaptureMeasurements(windowCount: selectedWindows.count,
                                        rasterCount: windows.count + displays.count, displayCount: displays.count,
                                        diskBytes: diskBytes, largestRasterBytes: largestRaster,
                                        elapsedSeconds: ProcessInfo.processInfo.systemUptime - started,
                                        maximumConcurrentCaptures: maximumConcurrentCaptures,
                                        peakReservedResidentBytes: peakReservedResidentBytes))
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
    /// another capture. Parent-side reads happen before launch or after the batch joins.
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

    private static func capture(filter: SCContentFilter, shadow: Bool, directory: URL,
                                remainingDiskBytes: Int, limits: FrozenCaptureLimits,
                                isWindow: Bool, label: String) async throws -> FrozenRasterDescriptor {
        try Task.checkCancellation()
        let estimatedBytes = try limits.validateSDRCapture(pointSize: filter.contentRect.size,
                                                           scale: Double(filter.pointPixelScale), shadow: shadow)
        guard estimatedBytes <= remainingDiskBytes else { throw FrozenCaptureFailure.diskLimit }
        let configuration = SCScreenshotConfiguration()
        configuration.showsCursor = false
        configuration.ignoreShadows = !shadow
        // Window capture is the selected window only. Capturing a child window with children
        // included returns its parent group, which no longer matches the window's frame.
        configuration.includeChildWindows = false
        configuration.dynamicRange = .sdr
        // Zero dimensions retain ScreenCaptureKit's native-size output, including shadows.
        let output = try await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        guard let image = output.sdrImage else { throw CaptureFailure.noImage }
        // The selection overlay draws unshadowed rasters exactly onto the window frame.
        if isWindow, !shadow, !matchesWindowFrame(image, filter: filter) {
            logger.error("Frozen window raster does not match its frame \(label, privacy: .public) actual=\(image.width)x\(image.height)")
            throw FrozenCaptureFailure.targetChanged
        }
        do {
            return try autoreleasepool {
                try FrozenRasterFile.store(image, directory: directory, remainingDiskBytes: remainingDiskBytes, limits: limits)
            }
        } catch let error as FrozenCaptureFailure {
            // Compares the pre-capture estimate with what ScreenCaptureKit returned, for example
            // when child windows or shadows extend the image beyond the window's own frame.
            let provider = image.dataProvider?.data.map(CFDataGetLength) ?? -1
            logger.error("Frozen raster rejected \(label, privacy: .public) estimate=\(estimatedBytes) actual=\(image.width)x\(image.height) row=\(image.bytesPerRow) bytes=\(image.bytesPerRow * image.height) provider=\(provider) reservation=\(limits.maximumResidentBytes) disk=\(remainingDiskBytes) error=\(String(describing: error), privacy: .public)")
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
        guard providerByteCount >= byteCount else {
            throw FrozenCaptureFailure.rasterFormat("provider has \(CFDataGetLength(raw)) bytes, expected \(byteCount); \(format)")
        }
        // ScreenCaptureKit's provider may include extra allocation pages after the
        // last scanline. Account for those resident bytes, but persist only the raster.
        guard providerByteCount <= limits.maximumResidentBytes - 1_024 * 1_024 - byteCount else {
            throw FrozenCaptureFailure.resourceLimit
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
            try handle.write(contentsOf: (raw as Data).prefix(byteCount))
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
