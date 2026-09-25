import CoreGraphics
import Foundation
import ImageIO
import Vision

// Audits exported browser-fixture scrolls against rules in Scripts/Fixtures/scroll-fixture.html only:
// no reference rendering, DOM measurement, or browser automation.
//   swiftc -O Scripts/BrowserExportAudit.swift -o /tmp/shotty-browser-export-audit
//   /tmp/shotty-browser-export-audit page|nested|thread <export.png>
//
// Evidence per row, each derived from the fixture source:
// - page/nested: swatch hue must equal (index * 37) % 360, which is unique for indices 1...360,
//   so the swatch sequence identifies every row independently of OCR. OCR of a crop right of
//   each swatch must read the same ID. Nested rows must also sit on the 28 CSS px (56 px) grid.
// - thread: bubble side (index % 3 == 0 is right-aligned), line count 1 + (index * 7) % 3, and
//   the gap to the next bubble (item height (day ? 36 : 0) + 20 + lines * 22) identify each
//   message; OCR of the bubble's top-left crop must read the same ID.
// Sequence alignment against the expected source order reports missing, duplicated, or
// out-of-order rows. The export is assumed to be at 2 px per CSS px.

struct Raster {
    let width: Int, height: Int
    let rgba: [UInt8]
    let image: CGImage

    init(path: String) {
        image = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil)!, 0, nil)!
        width = image.width; height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        // CSS colors are sRGB; Core Graphics converts the Display P3 export back into sRGB.
        let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        rgba = pixels
    }

    func rgb(_ x: Int, _ y: Int) -> (Double, Double, Double) {
        let i = (y * width + x) * 4
        return (Double(rgba[i]) / 255, Double(rgba[i + 1]) / 255, Double(rgba[i + 2]) / 255)
    }
}

func hsl(_ c: (Double, Double, Double)) -> (h: Double, s: Double, l: Double) {
    let maxV = max(c.0, c.1, c.2), minV = min(c.0, c.1, c.2), l = (maxV + minV) / 2, d = maxV - minV
    guard d > 0.0001 else { return (0, 0, l) }
    let s = d / (1 - abs(2 * l - 1))
    var h: Double
    if maxV == c.0 { h = ((c.1 - c.2) / d).truncatingRemainder(dividingBy: 6) }
    else if maxV == c.1 { h = (c.2 - c.0) / d + 2 } else { h = (c.0 - c.1) / d + 4 }
    h *= 60; if h < 0 { h += 360 }
    return (h, s, l)
}

struct Box { var minX: Int, minY: Int, maxX: Int, maxY: Int, count: Int
    var width: Int { maxX - minX + 1 }; var height: Int { maxY - minY + 1 }
    var midY: Double { Double(minY + maxY) / 2 }
}

/// 4-connected components of a mask on a grid sampled every `step` pixels, in pixel units.
func components(_ raster: Raster, step: Int, _ mask: (Int, Int) -> Bool) -> [Box] {
    let w = raster.width / step, h = raster.height / step
    var label = [Int32](repeating: 0, count: w * h), boxes: [Box] = []
    for start in 0..<(w * h) where label[start] == 0 && mask(start % w * step, start / w * step) {
        var stack = [start]; label[start] = Int32(boxes.count + 1)
        var box = Box(minX: .max, minY: .max, maxX: 0, maxY: 0, count: 0)
        while let p = stack.popLast() {
            let x = p % w, y = p / w
            box.minX = min(box.minX, x * step); box.maxX = max(box.maxX, x * step + step - 1)
            box.minY = min(box.minY, y * step); box.maxY = max(box.maxY, y * step + step - 1); box.count += 1
            for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= 0 && ny >= 0 && nx < w && ny < h {
                let q = ny * w + nx
                if label[q] == 0 && mask(nx * step, ny * step) { label[q] = Int32(boxes.count + 1); stack.append(q) }
            }
        }
        boxes.append(box)
    }
    return boxes
}

func ocr(_ raster: Raster, _ rect: CGRect, prefix: Character) -> Int? {
    let rect = rect.intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height)).integral
    guard !rect.isEmpty, let crop = raster.image.cropping(to: rect) else { return nil }
    let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: crop).perform([request])
    let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    // Normalize common monospace confusions; Cyrillic М/Р/Н look identical to M/P/N.
    let normalized = text.map { c -> Character in
        switch c { case "О", "O", "o": "0"; case "М": "M"; case "Р": "P"; case "Н": "N"; case "l", "I", "|": "1"; default: c }
    }
    let string = String(normalized).replacingOccurrences(of: " ", with: "")
    guard let range = string.range(of: "\(prefix)[0-9]{4}", options: .regularExpression) else { return nil }
    return Int(string[range].dropFirst())
}

/// Needleman-Wunsch style alignment of observed rows to the expected sequence. Observations match
/// only compatible indices; unmatched expected entries are missing, unmatched observations extra.
func align(expected: [Int], observed: Int, compatible: (Int, Int) -> Bool) -> [(Int?, Int?)] {
    let n = expected.count, m = observed
    var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in 0...n { cost[i][0] = i }; for j in 0...m { cost[0][j] = j }
    if n > 0 && m > 0 {
        for i in 1...n { for j in 1...m {
            var best = min(cost[i - 1][j] + 1, cost[i][j - 1] + 1)
            if compatible(expected[i - 1], j - 1) { best = min(best, cost[i - 1][j - 1]) }
            cost[i][j] = best
        } }
    }
    var pairs: [(Int?, Int?)] = [], i = n, j = m
    while i > 0 || j > 0 {
        if i > 0, j > 0, compatible(expected[i - 1], j - 1), cost[i][j] == cost[i - 1][j - 1] { pairs.append((expected[i - 1], j - 1)); i -= 1; j -= 1 }
        else if i > 0, cost[i][j] == cost[i - 1][j] + 1 { pairs.append((expected[i - 1], nil)); i -= 1 }
        else { pairs.append((nil, j - 1)); j -= 1 }
    }
    return pairs.reversed()
}

/// Trims unmatched expected entries at both ends: rows outside the captured span are not missing.
func interior(_ pairs: [(Int?, Int?)]) -> ArraySlice<(Int?, Int?)> {
    guard let first = pairs.firstIndex(where: { $0.0 != nil && $0.1 != nil }),
          let last = pairs.lastIndex(where: { $0.0 != nil && $0.1 != nil }) else { return [] }
    return pairs[first...last]
}

func auditSwatches(_ raster: Raster, prefix: Character, expected: [Int], gridPitch: Int?) {
    let boxes = components(raster, step: 1) { x, y in
        let c = hsl(raster.rgb(x, y)); return c.s > 0.35 && c.l > 0.35 && c.l < 0.75
    }.filter { (16...24).contains($0.width) && (16...24).contains($0.height) && Double($0.count) > 0.85 * Double($0.width * $0.height) }
     .sorted { $0.minY < $1.minY }
    let hues = boxes.map { box -> Double in
        var sum = (0.0, 0.0, 0.0), n = 0.0
        for y in (box.minY + 3)...(box.maxY - 3) { for x in (box.minX + 3)...(box.maxX - 3) {
            let c = raster.rgb(x, y); sum.0 += c.0; sum.1 += c.1; sum.2 += c.2; n += 1 } }
        return hsl((sum.0 / n, sum.1 / n, sum.2 / n)).h
    }
    func hueError(_ index: Int, _ j: Int) -> Double { let d = abs(Double(index * 37 % 360) - hues[j]); return min(d, 360 - d) }
    let pairs = align(expected: expected, observed: boxes.count) { hueError($0, $1) <= 6 }
    let body = interior(pairs)
    let matched = body.compactMap { pair -> (Int, Int)? in pair.0.flatMap { e in pair.1.map { (e, $0) } } }
    let missing = body.filter { $0.1 == nil }.compactMap(\.0)
    let extra = body.filter { $0.0 == nil }.compactMap(\.1).map { "y\(boxes[$0].minY) hue \(Int(hues[$0]))" }
    print("swatches \(boxes.count); hue-aligned rows \(matched.count) (\(prefix)\(matched.first?.0 ?? 0)…\(prefix)\(matched.last?.0 ?? 0)); interior missing \(missing); unexplained swatches \(extra)")
    print(String(format: "max hue error of matched swatches: %.2f°", matched.map { hueError($0.0, $0.1) }.max() ?? 0))
    let beyond = pairs.filter { $0.1 == nil }.compactMap(\.0).filter { $0 > (matched.last?.0 ?? 0) }
    if !beyond.isEmpty { print("expected rows after the last observed swatch: \(beyond.first!)…\(beyond.last!) (\(beyond.count))") }

    var ocrAgree = 0, ocrMissing: [Int] = [], ocrConflict: [String] = []
    for (index, j) in matched {
        let box = boxes[j]
        if let id = ocr(raster, CGRect(x: box.maxX + 4, y: box.minY - 14, width: 150, height: box.height + 28), prefix: prefix) {
            if id == index { ocrAgree += 1 } else { ocrConflict.append("hue says \(index), OCR \(id) at y\(box.minY)") }
        } else { ocrMissing.append(index) }
    }
    print("per-swatch ID OCR: \(ocrAgree)/\(matched.count) agree; unread \(ocrMissing); conflicts \(ocrConflict)")

    if let pitch = gridPitch, let (i0, j0) = matched.first {
        let residuals = matched.map { Double(boxes[$0.1].minY - boxes[j0].minY) - Double(($0.0 - i0) * pitch) }
        print("\(pitch) px grid from \(prefix)\(i0): residual min \(residuals.min()!) max \(residuals.max()!)")
    } else {
        let gaps = zip(matched, matched.dropFirst()).map { boxes[$1.1].minY - boxes[$0.1].minY }
        print("consecutive swatch gaps min \(gaps.min() ?? 0) max \(gaps.max() ?? 0) (variable paragraph heights; order only)")
    }
}

func auditThread(_ raster: Raster) {
    // Bubble fills #f0f0f0 and #dcebff; the capture region's white background separates bubbles.
    func fill(_ x: Int, _ y: Int) -> Int? {
        let i = (y * raster.width + x) * 4, r = Int(raster.rgba[i]), g = Int(raster.rgba[i + 1]), b = Int(raster.rgba[i + 2])
        if abs(r - 240) <= 3 && abs(g - 240) <= 3 && abs(b - 240) <= 3 { return 0 }
        if abs(r - 220) <= 4 && abs(g - 235) <= 4 && abs(b - 255) <= 4 { return 1 }
        return nil
    }
    let bubbles = components(raster, step: 2) { fill($0, $1) != nil }
        .filter { $0.width > 80 && $0.height > 40 }.sorted { $0.minY < $1.minY }
    struct Message { let index: Int, mine: Bool, lines: Int, day: Bool, height: Int }
    let messages = (1...3000).map { i -> Message in
        let lines = 1 + (i * 7) % 3, day = i % 40 == 1
        return Message(index: i, mine: i % 3 == 0, lines: lines, day: day, height: (day ? 36 : 0) + 20 + lines * 22)
    }
    // Bubble height: 8 px padding top and bottom plus lines at 15 px × 1.5 line height, in CSS px.
    func lines(_ box: Box) -> Int { Int(((Double(box.height) / 2 - 16) / 22.5).rounded()) }
    let observations = bubbles.map { (box: $0, mine: Double($0.minX + $0.maxX) / 2 > Double(raster.width) / 2, lines: lines($0)) }
    let clippedEdge = 6
    // Side and line count both depend only on index % 3, so they cannot fix the phase alone.
    // A readable ID anchors the phase; geometry and OCR are then checked against each other.
    let read = observations.map { o -> Int? in
        o.box.minY < clippedEdge ? nil : ocr(raster, CGRect(x: o.box.minX + 8, y: o.box.minY + 4, width: 170, height: 52), prefix: "M")
    }
    let pairs = align(expected: messages.map(\.index), observed: observations.count) { index, j in
        let o = observations[j], m = messages[index - 1]
        let clipped = o.box.minY < clippedEdge || o.box.maxY > raster.height - clippedEdge
        return o.mine == m.mine && (clipped || o.lines == m.lines) && (read[j] == nil || read[j] == index)
    }
    let body = interior(pairs)
    let matched = body.compactMap { pair -> (Int, Int)? in pair.0.flatMap { e in pair.1.map { (e, $0) } } }
    print("bubbles \(bubbles.count); aligned \(matched.count) (M\(matched.first?.0 ?? 0)…M\(matched.last?.0 ?? 0)); interior missing \(body.filter { $0.1 == nil }.compactMap(\.0)); unexplained bubbles \(body.filter { $0.0 == nil }.compactMap(\.1).map { "y\(bubbles[$0].minY) read \(read[$0].map(String.init) ?? "-")" })")
    let outside = pairs.filter { $0.0 == nil }.compactMap(\.1).filter { j in !matched.contains { $0.1 == j } }
    print("bubbles outside the aligned span: \(outside.map { "y\(bubbles[$0].minY)+\(bubbles[$0].height) x\(bubbles[$0].minX)+\(bubbles[$0].width)" })")
    let unanchored = matched.filter { read[$0.1] == nil }.map(\.0)
    let wrongShape = matched.filter { m in
        let o = observations[m.1], clipped = o.box.minY < clippedEdge || o.box.maxY > raster.height - clippedEdge
        return !clipped && (o.lines != messages[m.0 - 1].lines || o.mine != messages[m.0 - 1].mine)
    }
    print("IDs read by OCR: \(matched.count - unanchored.count)/\(matched.count); unread (placed by side, lines, and neighbours) \(unanchored); side/line-count mismatches \(wrongShape.map(\.0))")
    // Geometry: bubble-top gap = 2 × source item height, adjusted by one constant day-header offset.
    let consecutive = zip(matched, matched.dropFirst()).filter { $1.0 == $0.0 + 1 }
    func raw(_ a: (Int, Int), _ b: (Int, Int)) -> Double { Double(bubbles[b.1].minY - bubbles[a.1].minY - 2 * messages[a.0 - 1].height) }
    let dayGaps = consecutive.filter { messages[$0.1.0 - 1].day && !messages[$0.0.0 - 1].day }.map { raw($0.0, $0.1) }.sorted()
    let offset = dayGaps.isEmpty ? 0 : dayGaps[dayGaps.count / 2]
    let residuals = consecutive.map { pair -> Double in
        let (a, b) = pair
        return raw(a, b) - (messages[b.0 - 1].day ? offset : 0) + (messages[a.0 - 1].day ? offset : 0)
    }
    print("day-header bubble offset \(offset) px (from \(dayGaps.count) day starts: \(dayGaps)); gap residual after source heights: min \(residuals.min() ?? 0) max \(residuals.max() ?? 0) over \(residuals.count) consecutive pairs")
    if let last = matched.last { print("last bubble M\(last.0): y \(bubbles[last.1].minY)...\(bubbles[last.1].maxY) of \(raster.height); lines observed \(observations[last.1].lines), source \(messages[last.0 - 1].lines)") }
}

let arguments = CommandLine.arguments
guard arguments.count == 3 else { print("usage: page|nested|thread <export.png>"); exit(2) }
let raster = Raster(path: arguments[2])
print("\(arguments[2]) \(raster.width)x\(raster.height)")
switch arguments[1] {
case "page": auditSwatches(raster, prefix: "P", expected: (1...160).filter { $0 % 20 != 0 && $0 % 7 != 3 }, gridPitch: nil)
case "nested": auditSwatches(raster, prefix: "N", expected: (1...220).filter { $0 % 7 != 3 }, gridPitch: 56)
default: auditThread(raster)
}
