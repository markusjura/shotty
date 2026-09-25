import AppKit
import CoreGraphics

// Run with `swift Scripts/Fixtures/MakePDFFixture.swift /tmp/Shotty-PDF-Fixture.pdf [rows]`.
// A single tall page avoids app-specific page-navigation behavior during registration.
let output = CommandLine.arguments.dropFirst().first ?? "/tmp/Shotty-PDF-Fixture.pdf"
let rows = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) : 190
guard let rows, (1...1_000).contains(rows) else { fatalError("Rows must be between 1 and 1000") }
let pageHeight = max(6000, rows * 31 + 110)
var bounds = CGRect(x: 0, y: 0, width: 760, height: pageHeight)
guard let consumer = CGDataConsumer(url: URL(fileURLWithPath: output) as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
    fatalError("Could not create synthetic PDF")
}
context.beginPDFPage(nil)
context.setFillColor(CGColor(gray: 1, alpha: 1))
context.fill(bounds)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
for row in 0..<rows {
    let text = String(format: "PDF%04d  Synthetic document row %d: %08X", row + 1, row + 1, UInt32(truncatingIfNeeded: (row + 1) * 2654435761))
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 15, weight: .regular), .foregroundColor: NSColor.black]
    (text as NSString).draw(at: CGPoint(x: 32, y: pageHeight - 60 - row * 31), withAttributes: attributes)
}
NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()
print(output)
