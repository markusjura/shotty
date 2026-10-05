import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Generates the DMG window background: a plain light canvas with an arrow from Shotty to the Applications
// shortcut. Config/dmg.py places the two icons on either side of the arrow, so keep the geometry in sync.
// Writes DMGBackground.png and DMGBackground@2x.png; dmgbuild combines them into one HiDPI image.
// Run: swift Scripts/GenerateDMGBackground.swift Config

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "Config", isDirectory: true)
let size = CGSize(width: 560, height: 340)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// Draws in window points, scaled to `scale` pixels per point. Core Graphics' origin is the bottom left.
func drawBackground(scale: Int) throws -> Data {
    guard let context = CGContext(data: nil, width: Int(size.width) * scale, height: Int(size.height) * scale, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw CocoaError(.fileWriteUnknown) }
    context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

    context.setFillColor(CGColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))

    // The icons' centers sit 150 points from the top, at x 140 and 420.
    let y = size.height - 150
    context.setStrokeColor(CGColor(gray: 0.62, alpha: 1))
    context.setLineWidth(5)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 235, y: y))
    context.addLine(to: CGPoint(x: 325, y: y))
    context.move(to: CGPoint(x: 305, y: y + 18))
    context.addLine(to: CGPoint(x: 325, y: y))
    context.addLine(to: CGPoint(x: 305, y: y - 18))
    context.strokePath()

    guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    // 72 dpi per point keeps both files the same size in points.
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    return data as Data
}

for (scale, name) in [(1, "DMGBackground.png"), (2, "DMGBackground@2x.png")] {
    try drawBackground(scale: scale).write(to: output.appendingPathComponent(name))
}
