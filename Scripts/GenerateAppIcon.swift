import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Generates Shotty's macOS app icon from vector drawing: a system-blue rounded square with a
// white viewfinder, matching the menu bar's `viewfinder` symbol. Every size is drawn directly at
// its pixel dimensions, so small sizes stay crisp and the output is deterministic.
// Run: swift Scripts/GenerateAppIcon.swift Shotty/Assets.xcassets/AppIcon.appiconset

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Shotty/Assets.xcassets/AppIcon.appiconset",
                 isDirectory: true)
let sizes = [16, 32, 128, 256, 512]
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Draws on Apple's 1024-point macOS icon grid, scaled to `pixels`.
func drawIcon(pixels: Int) throws -> Data {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high

    // 824-point body centered on the grid, leaving room for the shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.saveGState()
    // Core Graphics shadows use device pixels rather than the transformed drawing grid.
    context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 24 * scale, color: CGColor(gray: 0, alpha: 0.28))
    context.addPath(shape)
    context.setFillColor(CGColor(srgbRed: 0, green: 0.478, blue: 1, alpha: 1))
    context.fillPath()
    context.restoreGState()

    // A gentle vertical gradient in the system blue family.
    context.saveGState()
    context.addPath(shape)
    context.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [
        CGColor(srgbRed: 0.22, green: 0.6, blue: 1, alpha: 1),
        CGColor(srgbRed: 0, green: 0.42, blue: 0.93, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 512, y: body.maxY), end: CGPoint(x: 512, y: body.minY), options: [])
    context.restoreGState()

    // Four viewfinder corners with rounded caps and joins.
    let frame = body.insetBy(dx: 214, dy: 214)
    let arm: CGFloat = 118
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    context.setLineWidth(56)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    let corners: [(CGPoint, CGFloat, CGFloat)] = [
        (CGPoint(x: frame.minX, y: frame.maxY), 1, -1), (CGPoint(x: frame.maxX, y: frame.maxY), -1, -1),
        (CGPoint(x: frame.minX, y: frame.minY), 1, 1), (CGPoint(x: frame.maxX, y: frame.minY), -1, 1),
    ]
    for (corner, dx, dy) in corners {
        context.move(to: CGPoint(x: corner.x, y: corner.y + dy * arm))
        context.addLine(to: corner)
        context.addLine(to: CGPoint(x: corner.x + dx * arm, y: corner.y))
    }
    context.strokePath()

    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in sizes {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try drawIcon(pixels: size * scale).write(to: output.appendingPathComponent(name))
        images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("Wrote \(images.count) icon images to \(output.path)")
