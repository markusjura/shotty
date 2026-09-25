import AppKit
import ApplicationServices
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
    var includeShadow = true
    var inputStatus = "Mouse observation has not been tested."
    var observingInput = false
    private let capture = StillCaptureService()
    private var fixture: FixtureWindow?
    private var frozenImage: CGImage?
    private var operation: Task<Void, Never>?
    private let inputObserver = ScrollInputObserver()
    private var observationTimeout: Task<Void, Never>?

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

    func refreshPermission() { hasScreenRecording = CGPreflightScreenCaptureAccess() }

    func captureFixture() {
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
        guard let frozenImage else { return }
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

    func stop() {
        cancel()
        stopObservingInput()
        fixture?.stop()
    }

    func openPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}

/// Exercises the real PNG encoder without writing captured desktop data into the repository.
enum FrozenExportCheck {
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

    private static func pixelHash(_ image: CGImage) throws -> SHA256.Digest {
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
        return SHA256.hash(data: pixels)
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
    @State private var harness = FoundationHarness()

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
                if harness.observingInput {
                    Button("Stop Mouse Observation") { harness.stopObservingInput() }
                } else {
                    Button("Observe Mouse Scrolls") { harness.observeInput() }
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
        .frame(minWidth: 820, minHeight: 580)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in harness.refreshPermission() }
        .onDisappear { harness.stop() }
    }
}
