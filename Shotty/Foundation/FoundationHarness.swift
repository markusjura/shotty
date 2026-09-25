import AppKit
@preconcurrency import ApplicationServices
import CryptoKit
import ImageIO
import Observation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class FoundationHarness {
    var status = "Milestone 0. Capture, scrolling, and signing verification."
    var preview: NSImage?
    var isBusy = false
    var hasScreenRecording = CGPreflightScreenCaptureAccess()
    var hasAccessibility = AXIsProcessTrusted()
    var includeShadow = true
    var inputStatus = "Mouse observation has not been tested."
    var observingInput = false
    var targets: [ScrollTarget] = []
    var selectedTarget: CGWindowID = 0
    var isScrolling = false
    /// True while stop() waits for old work. Every action that starts work checks it,
    /// so cleanup never tears down a stream, accumulator, or snapshot started after stop().
    private(set) var isStopping = false
    private var cleanup: Task<Void, Never>?
    var scrollStatus = "No scrolling session."
    var scrollPreview: NSImage?
    var hasScrollResult = false
    var regionX = 0.0
    var regionY = 0.0
    var regionWidth = 0.0
    var regionHeight = 0.0
    var scrollAxis: ScrollAxis = .vertical
    var automaticMode: ScrollInputState.Mode = .undecided
    var automaticStatus = "Auto Scroll starts only with its button."
    private let capture = StillCaptureService()
    private var fixture: FixtureWindow?
    private var frozenImage: CGImage?
    private var operation: Task<Void, Never>?
    private let inputObserver = ScrollInputObserver()
    private var observationTimeout: Task<Void, Never>?
    private let liveCapture = LiveCaptureSource()
    private var accumulator: ScrollAccumulator?
    private var scrollOperation: Task<Void, Never>?
    private var scrollTimeout: Task<Void, Never>?
    private var scrollTargetWatch: Task<Void, Never>?
    private var automation: ScrollAutomationDriver?
    private var automaticTarget: ScrollAutomationDriver.Target?
    private var scrollPanel: NSPanel?
    private weak var foundationWindow: NSWindow?

    func verifyStreamFixture() {
        guard let fixture, fixture.window.isVisible, !isBusy, !isScrolling, !isStopping else { return }
        fixture.pauseAnimation()
        isBusy = true
        operation = Task {
            defer { isBusy = false }
            do {
                let id = CGWindowID(fixture.window.windowNumber)
                let still = try await capture.window(id: id, shadow: false)
                let frames = try await liveCapture.start(windowID: id)
                var streamed: CGImage?
                for try await frame in frames {
                    guard frame.isSettled else { continue }
                    streamed = frame.image
                    break
                }
                await liveCapture.stop()
                guard let streamed else { throw CaptureFailure.noImage }
                guard still.width == streamed.width, still.height == streamed.height else { throw FrozenExportCheck.CheckError.pixelsChanged }
                let scale = CGFloat(still.width) / fixture.window.frame.width
                let titleHeight = fixture.window.frame.height - (fixture.window.contentView?.bounds.height ?? 0)
                let result = try FrozenExportCheck.fixtureColors(still: still, streamed: streamed, scale: scale, titleHeight: titleHeight)
                _ = try FrozenExportCheck.run(image: streamed)
                status = "PASS: native dimensions and orientation agree; 14 known fixture colors agree within \(result) channel levels. Streamed PNG round trip is exact."
            } catch {
                await liveCapture.stop()
                status = error.localizedDescription
            }
        }
    }

    func benchmarkFrozenSet() {
        guard !isBusy, !isStopping else { return }
        let shadow = includeShadow
        isBusy = true
        status = "Warming sequential and concurrent frozen capture before matched A/B runs."
        operation = Task {
            defer { isBusy = false }
            func measure(_ concurrency: Int) async throws -> (FrozenCaptureMeasurements, [String]) {
                try Task.checkCancellation()
                let set = try await FrozenCaptureSet.acquire(shadow: shadow, includeAlternateShadow: true,
                    limits: FrozenCaptureLimits(maximumConcurrentCaptures: concurrency))
                let signature = (set.windows.map {
                    "w\($0.windowID)/\($0.includesShadow)/\($0.frame)/\($0.pointPixelScale)/\($0.raster.width)x\($0.raster.height)/\($0.raster.byteCount)"
                } + set.displays.map {
                    "d\($0.displayID)/\($0.frame)/\($0.pointPixelScale)/\($0.raster.width)x\($0.raster.height)/\($0.raster.byteCount)"
                }).sorted()
                let measured = set.measurements
                try await set.close()
                return (measured, signature)
            }
            func latency(_ samples: [FrozenCaptureMeasurements], percentile: Double) -> Int {
                let sorted = samples.map(\.elapsedSeconds).sorted()
                let index = max(0, Int(ceil(Double(sorted.count) * percentile)) - 1)
                return Int((sorted[index] * 1_000).rounded())
            }
            do {
                _ = try await measure(1)
                _ = try await measure(3)
                var sequential: [FrozenCaptureMeasurements] = []
                var concurrent: [FrozenCaptureMeasurements] = []
                var reference: [String]?
                for pair in 0..<5 {
                    status = "Frozen capture A/B pair \(pair + 1) of 5. Keep the window set unchanged."
                    let order = pair.isMultiple(of: 2) ? [1, 3] : [3, 1]
                    let first = try await measure(order[0])
                    let second = try await measure(order[1])
                    guard first.1 == second.1, reference.map({ $0 == first.1 }) ?? true,
                          first.0.windowCount == second.0.windowCount,
                          first.0.rasterCount == second.0.rasterCount,
                          first.0.diskBytes == second.0.diskBytes else {
                        status = "A/B results discarded: window identity, geometry or raster sizes changed. Retry with a stable desktop. Temporary pixels cleaned up."
                        return
                    }
                    reference = first.1
                    sequential.append(order[0] == 1 ? first.0 : second.0)
                    concurrent.append(order[0] == 3 ? first.0 : second.0)
                }
                let measured = sequential[0]
                let sequentialPeak = sequential.map(\.peakReservedResidentBytes).max()! / 1_048_576
                let concurrentPeak = concurrent.map(\.peakReservedResidentBytes).max()! / 1_048_576
                let concurrency = concurrent.map(\.maximumConcurrentCaptures).max()!
                status = "Matched A/B: \(measured.windowCount) windows, \(measured.rasterCount) rasters, \(measured.diskBytes / 1_048_576) MiB. Sequential p50/p95 \(latency(sequential, percentile: 0.5))/\(latency(sequential, percentile: 0.95)) ms, reserved peak \(sequentialPeak) MiB. Up to \(concurrency) concurrent p50/p95 \(latency(concurrent, percentile: 0.5))/\(latency(concurrent, percentile: 0.95)) ms, reserved peak \(concurrentPeak) MiB. Five runs each; p95 is the sample maximum. Cleaned up."
            } catch { status = error.localizedDescription }
        }
    }

    func verifyOccludedFixture() {
        guard let fixture, fixture.window.isVisible, !isBusy, !isStopping else { return }
        fixture.pauseAnimation()
        isBusy = true
        operation = Task {
            defer { isBusy = false }
            let cover = NSWindow(contentRect: fixture.window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            cover.isReleasedWhenClosed = false
            cover.backgroundColor = .systemPurple
            defer { cover.orderOut(nil) }
            do {
                let id = CGWindowID(fixture.window.windowNumber)
                let before = try await capture.window(id: id, shadow: true)
                cover.orderFrontRegardless()
                try await Task.sleep(for: .milliseconds(150))
                let occluded = try await capture.window(id: id, shadow: true)
                guard try FrozenExportCheck.pixelHash(before) == FrozenExportCheck.pixelHash(occluded) else {
                    status = "Occlusion changed pixels. Inspect the fixture before proceeding."
                    return
                }
                let set = try await FrozenCaptureSet.acquire(shadow: true, includeAlternateShadow: true,
                                                             fixtureWindowIDs: [id])
                do {
                    guard let stored = set.windows.first(where: \.includesShadow) else { throw CaptureFailure.noImage }
                    let loaded = try await set.image(for: stored.raster)
                    guard try FrozenExportCheck.pixelHash(loaded) == FrozenExportCheck.pixelHash(occluded) else {
                        throw FrozenExportCheck.CheckError.pixelsChanged
                    }
                    try await set.close()
                    let result = try await Task.detached { try FrozenExportCheck.run(image: loaded) }.value
                    frozenImage = loaded
                    preview = NSImage(cgImage: loaded, size: CGSize(width: loaded.width, height: loaded.height))
                    status = "PASS: isolated pixels survive complete occlusion, private raw storage, cleanup, and PNG export. \(result)"
                } catch {
                    try? await set.close()
                    throw error
                }
            } catch { status = error.localizedDescription }
        }
    }

    struct ScrollTarget: Identifiable, Sendable {
        let id: CGWindowID
        let name: String
        let processID: pid_t
        let frame: CGRect
    }

    func refreshTargets() {
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                targets = content.windows.filter {
                    $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
                }.compactMap { window in
                    guard let app = window.owningApplication else { return nil }
                    return ScrollTarget(id: window.windowID, name: "\(app.applicationName): \(window.title ?? "Window")",
                                        processID: app.processID, frame: window.frame)
                }
                if !targets.contains(where: { $0.id == selectedTarget }) {
                    selectedTarget = targets.first(where: { $0.name.contains("Shotty Scrolling Fixture") })?.id ?? targets.first?.id ?? 0
                }
            } catch { scrollStatus = error.localizedDescription }
        }
    }

    func startScrolling(automatic: Bool = false) {
        guard !isScrolling, !isStopping, selectedTarget != 0 else { return }
        isScrolling = true
        scrollStatus = "Starting scrolling capture."
        hasScrollResult = false
        scrollPreview = nil
        guard let target = targets.first(where: { $0.id == selectedTarget }) else { isScrolling = false; return }
        stopObservingInput()
        let driver = ScrollAutomationDriver(axis: scrollAxis)
        automation = driver
        automaticMode = .undecided
        automaticStatus = "Auto Scroll starts only with its button."
        var injectedEvents = 0
        var externalEvents = 0
        driver.onStateChange = { [weak self, weak driver] in
            guard let self, let driver, self.automation === driver else { return }
            self.automaticMode = driver.inputState.mode
            self.automaticStatus = driver.pauseReason?.rawValue ?? (driver.inputState.mode == .manualOnly
                ? "Manual-only session. External scrolling stopped automation."
                : "Auto Scroll starts only with its button.")
            // An unchanged viewport pauses injection, but acquisition stays alive:
            // a delayed page load or manual scroll can still yield useful pixels.
        }
        inputObserver.start { [weak driver] source in
            switch source {
            case .shottyInjected: injectedEvents += 1
            case .physical: externalEvents += 1
            }
            driver?.handle(.scroll(source))
        }
        scrollTimeout = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            stopScrolling()
        }
        scrollOperation = Task {
            var didStartAutomatic = false
            var previousImage: CGImage?
            var firstMovingImage: CGImage?
            await accumulator?.discard()
            let accumulator = ScrollAccumulator(axis: scrollAxis)
            self.accumulator = accumulator
            defer {
                isScrolling = false
                driver.stop()
                inputObserver.stop()
                scrollTimeout?.cancel()
                scrollTargetWatch?.cancel()
                if let reason = driver.pauseReason { scrollStatus += " \(reason.rawValue)" }
                scrollStatus += " Observed \(injectedEvents) Shotty scroll events and \(externalEvents) external scroll events."
                scrollPanel?.close()
                scrollPanel = nil
                foundationWindow?.orderFront(nil)
            }
            do {
                NSRunningApplication(processIdentifier: target.processID)?.activate()
                let region = CGRect(x: target.frame.minX + regionX, y: target.frame.minY + regionY,
                                    width: regionWidth > 0 ? regionWidth : target.frame.width - regionX,
                                    height: regionHeight > 0 ? regionHeight : target.frame.height - regionY)
                guard target.frame.contains(region), !region.isEmpty else { throw CaptureFailure.targetUnavailable }
                let captureTarget = ScrollAutomationDriver.Target(windowID: target.id, processID: target.processID, globalRegion: region)
                automaticTarget = captureTarget
                scrollTargetWatch = Task { [weak self, weak driver] in
                    // Watch even when ScreenCaptureKit has no new pixels to publish.
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                        guard let self, let driver, self.automation === driver, self.isScrolling else { return }
                        if let reason = self.targetFailure(captureTarget, originalBounds: target.frame) {
                            self.scrollStatus = "\(reason.rawValue) Accepted pixels are retained for inspection."
                            self.stopScrolling()
                            return
                        }
                    }
                }
                let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.frame.contains(region) }) else { throw CaptureFailure.targetUnavailable }
                try showScrollControls(outside: region, display: display)
                NSRunningApplication(processIdentifier: target.processID)?.activate()
                let localRegion = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
                let frames = try await liveCapture.start(displayID: display.displayID, displayLocalRegion: localRegion,
                                                         excluding: ProcessInfo.processInfo.processIdentifier)
                let initialDeadline = CapturedScrollFrame.monotonicNow + 3
                for try await frame in frames {
                    try Task.checkCancellation()
                    if !hasScrollResult && !frame.isSettled {
                        if firstMovingImage == nil { firstMovingImage = frame.image }
                        if CapturedScrollFrame.monotonicNow > initialDeadline {
                            scrollStatus = "The selected region did not become still. Pause animation or select a smaller region."
                            if let firstMovingImage, isSynthetic(target) {
                                let directory = try FrozenExportCheck.writeSyntheticComparison(firstMovingImage, frame.image)
                                status = "Synthetic settling diagnostics: \(directory.path)"
                            }
                            break
                        }
                        continue
                    }
                    let frontProcess = NSWorkspace.shared.frontmostApplication?.processIdentifier
                    if frontProcess == ProcessInfo.processInfo.processIdentifier {
                        driver.handle(.pauseAutomatic)
                        continue
                    }
                    if let reason = targetFailure(captureTarget, originalBounds: target.frame) {
                        scrollStatus = "\(reason.rawValue) Accepted pixels are retained for inspection."
                        break
                    }
                    if driver.inputState.mode == .automaticRunning ||
                        (driver.inputState.mode == .automaticPaused && driver.isAwaitingSettledFrame) {
                        driver.validateTarget()
                        guard frame.isSettled else { continue }
                    }
                    let result = try await accumulator.accept(frame.image)
                    try Task.checkCancellation()
                    if result.paused && !frame.isSettled { continue }
                    if result.paused, let previousImage,
                       isSynthetic(target) {
                        let directory = try FrozenExportCheck.writeSyntheticComparison(previousImage, frame.image)
                        status = "Synthetic alignment diagnostics: \(directory.path)"
                    }
                    if result.didMove || previousImage == nil { previousImage = frame.image }
                    if let preview = result.preview {
                        scrollPreview = NSImage(cgImage: preview, size: CGSize(width: preview.width, height: preview.height))
                    }
                    hasScrollResult = true
                    scrollStatus = "\(Int(result.dimensions.width)) × \(Int(result.dimensions.height)) · \(result.message)"
                    if result.paused { break }
                    if automatic, !didStartAutomatic, let automaticTarget {
                        didStartAutomatic = true
                        guard driver.startAutomatic(target: automaticTarget) else { break }
                        driver.injectNextStepIfReady()
                    }
                    if frame.isSettled, driver.didSettleAndAlign(capturedAt: frame.capturedAt, didMove: result.didMove) {
                        driver.injectNextStepIfReady()
                    }
                }
            } catch is CancellationError {
                scrollStatus += " Acquisition stopped; accepted pixels are retained for inspection."
            } catch { scrollStatus = error.localizedDescription }
            await liveCapture.stop()
            if hasScrollResult, let image = try? await accumulator.finishPreview() {
                scrollPreview = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            }
        }
    }

    private func isSynthetic(_ target: ScrollTarget) -> Bool {
        NSRunningApplication(processIdentifier: target.processID)?.bundleIdentifier == "local.markus.ShottyScrollFixture" ||
            target.name == "Preview: Shotty-PDF-Fixture.pdf"
    }

    private func targetFailure(_ target: ScrollAutomationDriver.Target, originalBounds: CGRect) -> ScrollAutomationDriver.PauseReason? {
        // Interacting with our nonactivating controls must not discard the capture.
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return nil }
        switch ScrollAutomationDriver.Environment.live.windowBounds(target) {
        case .failure(let reason): return reason
        case .success(let bounds): return bounds == originalBounds ? nil : .targetChanged
        }
    }

    private func showScrollControls(outside region: CGRect, display: SCDisplay) throws {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID }) else {
            throw CaptureFailure.targetUnavailable
        }
        let geometry = DisplayGeometry(id: display.displayID, appKitFrame: screen.frame, captureFrame: display.frame,
                                       pixelSize: CGSize(width: display.width, height: display.height))
        let topLeft = geometry.appKitPoint(fromCapture: region.origin)
        let captureRect = CGRect(x: topLeft.x, y: topLeft.y - region.height, width: region.width, height: region.height)
        let size = CGSize(width: 380, height: 280)
        let candidates = NSScreen.screens.flatMap { screen -> [CGRect] in
            let visible = screen.visibleFrame.insetBy(dx: 12, dy: 12)
            return [CGPoint(x: visible.maxX - size.width, y: visible.maxY - size.height),
                    CGPoint(x: visible.minX, y: visible.maxY - size.height),
                    CGPoint(x: visible.maxX - size.width, y: visible.minY),
                    visible.origin].map { CGRect(origin: $0, size: size) }
        }
        guard let placement = candidates.first(where: { !$0.intersects(captureRect) }) else { throw CaptureFailure.targetUnavailable }
        let panel = NSPanel(contentRect: placement, styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Shotty Scroll Verification"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: ScrollVerificationControls(harness: self))
        foundationWindow = NSApp.windows.first(where: { $0.title == "Shotty Foundation" })
        foundationWindow?.orderOut(nil)
        scrollPanel = panel
        panel.orderFrontRegardless()
    }

    func startOrResumeAutomaticScrolling() {
        guard isScrolling, hasScrollResult, let driver = automation, let target = automaticTarget else { return }
        NSRunningApplication(processIdentifier: target.processID)?.activate()
        Task {
            // The temporary harness is an activating window. The production controls use a nonactivating panel.
            for _ in 0..<10 where NSWorkspace.shared.frontmostApplication?.processIdentifier != target.processID {
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard isScrolling, automation === driver else { return }
            if driver.inputState.offersAutoScroll {
                guard driver.startAutomatic(target: target) else { return }
            } else if driver.inputState.mode == .automaticPaused {
                driver.handle(.toggleAutomaticPause)
            }
            driver.injectNextStepIfReady()
        }
    }

    func pauseAutomaticScrolling() { automation?.handle(.pauseAutomatic) }

    func stopScrolling() {
        automation?.stop()
        scrollOperation?.cancel()
    }

    func exportScrollFixture() {
        guard let accumulator, !isScrolling, !isStopping else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Shotty scrolling fixture.png"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await accumulator.exportPNG(to: url)
                    self.scrollStatus = "Saved accepted pixels to \(url.lastPathComponent)."
                } catch { self.scrollStatus = error.localizedDescription }
            }
        }
    }

    func observeInput() {
        var physicalEvents = 0
        inputStatus = "Listening for 30 seconds. Accessibility: \(AXIsProcessTrusted()); Input Monitoring: \(CGPreflightListenEventAccess()). Scroll another app."
        observingInput = true
        inputObserver.start { [weak self] source in
            guard case .physical = source else { return }
            physicalEvents += 1
            self?.inputStatus = "Observed \(physicalEvents) external scroll events. Accessibility: \(AXIsProcessTrusted()); Input Monitoring: \(CGPreflightListenEventAccess())."
        }
        observationTimeout?.cancel()
        observationTimeout = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            stopObservingInput()
        }
    }

    func stopObservingInput() {
        observationTimeout?.cancel()
        observationTimeout = nil
        inputObserver.stop()
        observingInput = false
    }

    func showFixture() {
        if fixture == nil { fixture = FixtureWindow() }
        fixture?.show()
        status = "The fixture changes four times a second. Capture, wait, then verify the frozen export."
    }

    func requestPermission() {
        hasScreenRecording = CGRequestScreenCaptureAccess()
        status = hasScreenRecording ? "Screen Recording is available." : "Enable Shotty in Screen Recording, then quit and reopen Shotty."
    }

    func requestAutomaticScrollingPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        hasAccessibility = AXIsProcessTrustedWithOptions(options)
        if !hasAccessibility,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func refreshPermission() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        hasAccessibility = AXIsProcessTrusted()
    }

    func captureFixture() {
        guard !isStopping else { return }
        guard let fixture, fixture.window.isVisible else {
            status = "Open the synthetic fixture first."
            return
        }
        let windowID = CGWindowID(fixture.window.windowNumber)
        let shadow = includeShadow
        isBusy = true
        operation = Task {
            defer { isBusy = false }
            let start = ContinuousClock.now
            do {
                let image = try await capture.window(id: windowID, shadow: shadow)
                try Task.checkCancellation()
                frozenImage = image
                preview = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
                let elapsed = start.duration(to: .now)
                status = "Frozen \(image.width) × \(image.height) pixels in \(elapsed). The preview and export share this immutable snapshot."
            } catch is CancellationError {
                status = "Capture cancelled."
            } catch { status = error.localizedDescription }
        }
    }

    func verifyFrozenExport() {
        guard let frozenImage, !isStopping else { return }
        isBusy = true
        operation = Task {
            defer { isBusy = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try FrozenExportCheck.run(image: frozenImage)
                }.value
                try Task.checkCancellation()
                status = result
            } catch { status = error.localizedDescription }
        }
    }

    func cancel() {
        operation?.cancel()
    }

    /// Idempotent: repeated calls, such as window close then Quit, share one cleanup.
    @discardableResult
    func stop() -> Task<Void, Never> {
        if let cleanup { return cleanup }
        isStopping = true
        cancel()
        stopObservingInput()
        fixture?.stop()
        stopScrolling()
        let stoppedStillOperation = operation
        let stoppedOperation = scrollOperation
        let task = Task {
            await stoppedStillOperation?.value
            await stoppedOperation?.value
            await liveCapture.stop()
            await accumulator?.discard()
            accumulator = nil
            frozenImage = nil
            preview = nil
            scrollPreview = nil
            hasScrollResult = false
            cleanup = nil
            isStopping = false
        }
        cleanup = task
        return task
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Exercises the real PNG encoder without writing captured desktop data into the repository.
enum FrozenExportCheck {
    static func writeSyntheticComparison(_ before: CGImage, _ after: CGImage) throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("ShottyFrameDiagnostic-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        for (name, image) in [("before", before), ("after", after)] {
            let url = directory.appendingPathComponent(name).appendingPathExtension("png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CheckError.encoding }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw CheckError.encoding }
        }
        return directory
    }

    static func run(image: CGImage) throws -> String {
        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil) else {
            throw CheckError.encoding
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(encoded, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CheckError.encoding }
        let originalHash = try pixelHash(image)
        let exportedHash = try pixelHash(decoded)
        guard originalHash == exportedHash else { throw CheckError.pixelsChanged }
        return "PASS: frozen preview and decoded PNG have identical RGBA pixels (\(image.width) × \(image.height)). No later frame was acquired."
    }

    static func pixelHash(_ image: CGImage) throws -> SHA256.Digest {
        SHA256.hash(data: try normalizedPixels(image))
    }

    /// Independent 8-bit capture pipelines quantize differently. Known flat colors
    /// establish color/orientation accuracy without comparing transient system title chrome.
    @MainActor
    static func fixtureColors(still: CGImage, streamed: CGImage, scale: CGFloat, titleHeight: CGFloat) throws -> Int {
        var maximum = 0
        for image in [still, streamed] {
            let pixels = try normalizedPixels(image)
            for row in 0..<14 {
                guard let expected = NSColor(calibratedHue: CGFloat(row) / 14, saturation: 0.45, brightness: 0.95, alpha: 1)
                    .usingColorSpace(.sRGB) else { throw CheckError.encoding }
                let x = Int(620 * scale), y = Int((titleHeight + CGFloat(row * 30 + 15)) * scale)
                guard x >= 0, y >= 0, x < image.width, y < image.height else { throw CheckError.pixelsChanged }
                let channels = [expected.redComponent, expected.greenComponent, expected.blueComponent, expected.alphaComponent]
                for component in 0..<4 {
                    let delta = abs(Int(pixels[(y * image.width + x) * 4 + component]) - Int((channels[component] * 255).rounded()))
                    maximum = max(maximum, delta)
                }
            }
        }
        guard maximum <= 3 else { throw CheckError.pixelsChanged }
        return maximum
    }

    private static func normalizedPixels(_ image: CGImage) throws -> Data {
        let bytes = try RasterBudget().byteCount(width: image.width, height: image.height)
        var pixels = Data(count: bytes)
        let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw CheckError.encoding }
        return pixels
    }

    enum CheckError: LocalizedError {
        case encoding, pixelsChanged
        var errorDescription: String? {
            switch self {
            case .encoding: "Could not encode or decode the synthetic capture."
            case .pixelsChanged: "Verification failed: PNG pixels differ from the frozen preview."
            }
        }
    }
}

struct FoundationHarnessView: View {
    @Bindable var harness: FoundationHarness

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shotty foundation verification").font(.title2)
            Text("Native harness for milestone 0. This is not the finished capture interface.").foregroundStyle(.secondary)
            HStack {
                Label(harness.hasScreenRecording ? "Screen Recording available" : "Screen Recording required",
                      systemImage: harness.hasScreenRecording ? "checkmark.circle" : "display")
                Spacer()
                if !harness.hasScreenRecording {
                    Button("Request Screen Recording") { harness.requestPermission() }
                    Button("Open System Settings") { harness.openPrivacySettings() }
                }
            }
            Divider()
            HStack {
                Text(harness.hasAccessibility ? "Automatic scrolling: Accessibility available" : "Automatic scrolling: Accessibility required")
                Spacer()
                if !harness.hasAccessibility {
                    Button("Set Up Automatic Scrolling") { harness.requestAutomaticScrollingPermission() }
                }
            }
            HStack {
                if harness.observingInput {
                    Button("Stop Mouse Observation") { harness.stopObservingInput() }
                } else {
                    Button("Observe Mouse Scrolls") { harness.observeInput() }.disabled(harness.isScrolling)
                }
                Text(harness.inputStatus).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Synthetic Fixture") { harness.showFixture() }
                Toggle("Window shadow", isOn: $harness.includeShadow).toggleStyle(.checkbox)
                Button("Freeze Fixture") { harness.captureFixture() }.disabled(harness.isBusy || !harness.hasScreenRecording)
                Button("Verify Frozen PNG") { harness.verifyFrozenExport() }.disabled(harness.isBusy || harness.preview == nil)
                if harness.isBusy { Button("Cancel") { harness.cancel() } }
            }
            HStack {
                Button("Verify Occluded Fixture") { harness.verifyOccludedFixture() }.disabled(harness.isBusy || !harness.hasScreenRecording)
                Button("Measure Frozen Window Set") { harness.benchmarkFrozenSet() }.disabled(harness.isBusy || !harness.hasScreenRecording)
                Button("Verify Stream Pixels") { harness.verifyStreamFixture() }.disabled(harness.isBusy || harness.isScrolling || !harness.hasScreenRecording)
            }
            Divider()
            HStack {
                Button("Refresh Windows") { harness.refreshTargets() }.disabled(!harness.hasScreenRecording || harness.isScrolling)
                Picker("Scroll target", selection: $harness.selectedTarget) {
                    Text("Choose a window").tag(CGWindowID(0))
                    ForEach(harness.targets) { target in Text(target.name).tag(target.id) }
                }.labelsHidden().frame(maxWidth: 360).disabled(harness.isScrolling)
                if harness.isScrolling {
                    Button("Stop Scrolling Capture") { harness.stopScrolling() }
                } else {
                    Button("Start Scrolling Capture") { harness.startScrolling() }.disabled(harness.selectedTarget == 0)
                    Button("Start Auto") { harness.startScrolling(automatic: true) }.disabled(harness.selectedTarget == 0)
                    Button("Export Partial PNG") { harness.exportScrollFixture() }.disabled(!harness.hasScrollResult)
                }
            }
            Text(harness.scrollStatus).font(.caption).textSelection(.enabled)
            HStack {
                Text("Window-relative region (points; zero size uses remaining window)").font(.caption)
                TextField("X", value: $harness.regionX, format: .number).frame(width: 55)
                TextField("Y", value: $harness.regionY, format: .number).frame(width: 55)
                TextField("Width", value: $harness.regionWidth, format: .number).frame(width: 55)
                TextField("Height", value: $harness.regionHeight, format: .number).frame(width: 55)
                Picker("Axis", selection: $harness.scrollAxis) {
                    ForEach(ScrollAxis.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.frame(width: 150)
            }.disabled(harness.isScrolling)
            if harness.isScrolling {
                HStack {
                    if harness.automaticMode == .undecided {
                        Button("Auto Scroll") { harness.startOrResumeAutomaticScrolling() }.disabled(!harness.hasScrollResult)
                    } else if harness.automaticMode == .automaticRunning {
                        Button("Pause Auto Scroll") { harness.pauseAutomaticScrolling() }
                    } else if harness.automaticMode == .automaticPaused {
                        Button("Resume Auto Scroll") { harness.startOrResumeAutomaticScrolling() }
                    }
                    Text(harness.automaticStatus).font(.caption)
                }
            }
            if let image = harness.scrollPreview {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 180)
                    .accessibilityLabel("Accepted scrolling pixels")
            }
            if let image = harness.preview {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel("Frozen synthetic window snapshot")
            } else {
                ContentUnavailableView("No snapshot", systemImage: "viewfinder", description: Text("Open the fixture, then freeze its isolated window."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(harness.status).textSelection(.enabled).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .disabled(harness.isStopping)
        .frame(minWidth: 820, minHeight: 580)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in harness.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
            if (notification.object as? NSWindow)?.title == "Shotty Foundation" { harness.stop() }
        }
    }
}

private struct ScrollVerificationControls: View {
    @Bindable var harness: FoundationHarness

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(harness.scrollStatus).font(.caption).lineLimit(3)
            if let preview = harness.scrollPreview {
                Image(nsImage: preview).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 130)
            }
            Text(harness.automaticStatus).font(.caption).lineLimit(2)
            HStack {
                if harness.automaticMode == .undecided {
                    Button("Auto Scroll") { harness.startOrResumeAutomaticScrolling() }.disabled(!harness.hasScrollResult)
                } else if harness.automaticMode == .automaticRunning {
                    Button("Pause") { harness.pauseAutomaticScrolling() }
                } else if harness.automaticMode == .automaticPaused {
                    Button("Resume") { harness.startOrResumeAutomaticScrolling() }
                }
                Spacer()
                Button("Done") { harness.stopScrolling() }.keyboardShortcut(.cancelAction)
            }
        }.padding(12).frame(width: 356, height: 256)
    }
}
