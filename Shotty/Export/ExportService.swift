import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ExportOptions: Equatable, Sendable {
    enum Format: String, Sendable { case png, jpeg }
    enum Scale: Sendable { case native, logical }
    enum Color: Sendable { case preserve, sRGB }

    var format: Format = .png
    var scale: Scale = .native
    var color: Color = .preserve
    var jpegQuality: Double = 0.9
    var jpegBackground: RGBAColor = .white

    var fileExtension: String { format == .png ? "png" : "jpg" }
}

/// One serial renderer/encoder shared by copy and save. No clipboard/UI access.
actor ExportService {
    private let documentRenderer = DocumentRenderer()
    enum Failure: LocalizedError {
        case unreadableSource, encoding, invalidScale, resourceLimit, destinationExists(URL), externallyModified(URL)

        var errorDescription: String? {
            switch self {
            case .unreadableSource: "The capture source could not be opened. The capture has been kept; try again."
            case .encoding: "The image could not be encoded. Try PNG or save to another folder."
            case .invalidScale: "The capture has an invalid display scale."
            case .resourceLimit: "This image exceeds the export memory limit. Save a smaller capture."
            case .destinationExists(let url): "A file named \(url.lastPathComponent) already exists. Choose another name or confirm Replace."
            case .externallyModified(let url): "\(url.lastPathComponent) changed outside Shotty. Choose Replace, Save As, or Cancel."
            }
        }
    }

    /// Bound an individual decoded raster to 256 MiB of RGBA pixels before decoding.
    static let maximumPixels = 64 * 1_024 * 1_024

    func fingerprint(at url: URL) throws -> FileFingerprint { try FileFingerprint(hashingFileAt: url) }

    func encodedData(_ snapshot: CaptureSnapshot, options: ExportOptions = .init()) throws -> Data {
        try Self.encodedData(snapshot, options: options, renderer: documentRenderer)
    }

    /// The encoder itself, for main-actor callers that need the bytes before they return, such as a
    /// drag that must hand over a file as it starts. Each caller passes a renderer it uses serially.
    nonisolated static func encodedData(_ snapshot: CaptureSnapshot, options: ExportOptions,
                                        renderer: DocumentRenderer) throws -> Data {
        try Task.checkCancellation()
        // An unedited capture exported as native PNG is its stored source; decoding and re-encoding
        // it would reproduce the same bytes.
        if snapshot.documentState == AnnotationDocument(), options.format == .png, options.color == .preserve,
           options.scale == .native || snapshot.sourceScale == 1 {
            guard let source = try? Data(contentsOf: snapshot.sourceURL) else { throw Failure.unreadableSource }
            return source
        }
        return try autoreleasepool {
            let image = try renderedImage(snapshot, options: options, renderer: renderer)
            try Task.checkCancellation()
            let data = NSMutableData()
            let type = options.format == .png ? UTType.png : .jpeg
            guard let encoder = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
                throw Failure.encoding
            }
            let properties: [CFString: Any] = options.format == .jpeg
                ? [kCGImageDestinationLossyCompressionQuality: min(1, max(0, options.jpegQuality.isFinite ? options.jpegQuality : 0.9))]
                : [:]
            CGImageDestinationAddImage(encoder, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(encoder) else { throw Failure.encoding }
            try Task.checkCancellation()
            return data as Data
        }
    }

    private nonisolated static func renderedImage(_ snapshot: CaptureSnapshot, options: ExportOptions,
                                                  renderer: DocumentRenderer) throws -> CGImage {
        try Task.checkCancellation()
        guard snapshot.sourceScale.isFinite, snapshot.sourceScale > 0 else { throw Failure.invalidScale }
        guard let source = CGImageSourceCreateWithURL(snapshot.sourceURL as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int else { throw Failure.unreadableSource }
        try validateDimensions(width: sourceWidth, height: sourceHeight)
        guard let original = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { throw Failure.unreadableSource }
        let image = try renderer.render(source: original, state: snapshot.documentState)
        let divisor = options.scale == .logical ? snapshot.sourceScale : 1
        let scaledWidth = (Double(image.width) / divisor).rounded()
        let scaledHeight = (Double(image.height) / divisor).rounded()
        guard scaledWidth.isFinite, scaledHeight.isFinite,
              scaledWidth <= Double(Self.maximumPixels), scaledHeight <= Double(Self.maximumPixels) else { throw Failure.resourceLimit }
        let width = max(1, Int(scaledWidth)), height = max(1, Int(scaledHeight))
        try validateDimensions(width: width, height: height)
        if options.format == .png, options.color == .preserve, width == image.width, height == image.height { return image }
        let colorSpace: CGColorSpace
        if options.color == .preserve, let original = image.colorSpace, original.model == .rgb {
            colorSpace = original
        } else {
            guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.encoding }
            colorSpace = sRGB
        }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure.encoding }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        if options.format == .jpeg {
            var background = options.jpegBackground.isValid ? options.jpegBackground : .white
            background.alpha = 1
            context.setFillColor(background.cgColor)
            context.fill(bounds)
        }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        guard let rendered = context.makeImage() else { throw Failure.encoding }
        return rendered
    }

    /// A no-overwrite rename resolves races with other apps and other export service instances.
    func export(_ snapshot: CaptureSnapshot, to directory: URL, options: ExportOptions = .init()) throws -> ExportReceipt {
        let data = try encodedData(snapshot, options: options)
        let stem = Self.filenameStem(date: snapshot.createdAt)
        var suffix = 1
        while true {
            try Task.checkCancellation()
            let filename = Self.filename(stem: stem, collision: suffix, scale: snapshot.sourceScale, options: options)
            let url = directory.appendingPathComponent(filename)
            do {
                try AtomicFile.write(data, to: url, beforePublish: { try Task.checkCancellation() })
                return receipt(snapshot, url: url, data: data)
            } catch let error as POSIXError where error.code == .EEXIST { suffix += 1 }
        }
    }

    /// Pass the last receipt's fingerprint for associated saves. For an explicit Replace choice,
    /// read a fresh fingerprint and pass it here. Omitting it never overwrites any existing file.
    func save(_ snapshot: CaptureSnapshot, to destination: URL, options: ExportOptions = .init(),
              replacing expected: FileFingerprint? = nil) throws -> ExportReceipt {
        if let expected { try verify(destination, expected: expected) }
        let data = try encodedData(snapshot, options: options)
        try Task.checkCancellation()
        do {
            try AtomicFile.write(data, to: destination, replacing: expected != nil, beforePublish: {
                try Task.checkCancellation()
                if let expected { try self.verify(destination, expected: expected) }
            })
        } catch let error as POSIXError where error.code == .EEXIST { throw Failure.destinationExists(destination) }
        return receipt(snapshot, url: destination, data: data)
    }

    /// `stem-2@2x.png`: a collision number, then the pixel density when the output keeps Retina
    /// pixels, so macOS and other apps still read the density from the name.
    nonisolated static func filename(stem: String, collision: Int = 1, scale: Double, options: ExportOptions) -> String {
        let density = options.scale == .native && scale > 1 && scale == scale.rounded() ? "@\(Int(scale))x" : ""
        return "\(stem)\(collision == 1 ? "" : "-\(collision)")\(density).\(options.fileExtension)"
    }

    /// Names like `image-2026-09-26-14.17.05`; `filename` adds `@2x` for Retina pixels.
    nonisolated static func filenameStem(date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "'image-'yyyy-MM-dd-HH.mm.ss"
        return formatter.string(from: date)
    }

    private func verify(_ url: URL, expected: FileFingerprint) throws {
        guard expected.matchesFile(at: url) else { throw Failure.externallyModified(url) }
    }

    private nonisolated static func validateDimensions(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= Self.maximumPixels / height else { throw Failure.resourceLimit }
    }

    private func receipt(_ snapshot: CaptureSnapshot, url: URL, data: Data) -> ExportReceipt {
        ExportReceipt(captureID: snapshot.captureID, revision: snapshot.revision, destinationURL: url,
                      fingerprint: FileFingerprint(hashing: data))
    }
}
