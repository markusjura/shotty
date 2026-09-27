import AppKit

// Synthetic scrolling fixture for exercising Shotty's capture and stitching by hand or from scripts.
// Developer utility only; build it with Scripts/Fixtures/build-scroll-fixture.sh.
//
// Launch options (NSUserDefaults argument domain):
//   -mode vertical|horizontal|table   initial mode, default vertical
//   -scrollers system|legacy|hidden   scroller style, default system (overlay scrollers may fade)
// Offline reference rendering of the scrolled document, without a window:
//   ShottyScrollFixture --render-document vertical|horizontal <scale> <output.png>

/// Fixed geometry in points so every capture starts from the same layout.
enum Layout {
    static let window = NSSize(width: 820, height: 640)
    static let controlsHeight: CGFloat = 44
    static let headerHeight: CGFloat = 56
    static let footerHeight: CGFloat = 48
    static let documentExtent: CGFloat = 6000
    static let verticalDocumentWidth: CGFloat = 780
    static let horizontalDocumentHeight: CGFloat = 440
    static let tableRowHeight: CGFloat = 22
    static let tableRowCount = 270
}

enum FixtureMode: String, CaseIterable {
    case vertical, horizontal, table

    var label: String { rawValue.capitalized }
}

/// One row (vertical) or column (horizontal) of synthetic content along the scroll axis.
struct FixtureItem {
    enum Kind { case section, blank, tall, plain }

    let index: Int
    let start: CGFloat
    let length: CGFloat
    let kind: Kind

    var id: String { FixtureContent.id(prefix: "", index: index) }
}

/// Deterministic synthetic text. The same index and salt always produce the same words.
enum FixtureContent {
    private static let words = [
        "amber", "basalt", "cobalt", "delta", "ember", "fjord", "garnet", "harbor", "indigo", "juniper",
        "kelp", "lantern", "meadow", "nickel", "orchid", "pewter", "quartz", "raven", "saffron", "tundra",
        "umber", "violet", "willow", "xenon", "yarrow", "zephyr", "anchor", "birch", "cinder", "dune",
        "estuary", "fennel", "glacier", "heron", "ivory", "jasper", "kestrel", "lichen", "marble", "nimbus",
        "onyx", "prairie", "quill", "ridge", "sierra", "thistle", "upland", "vapor", "wren", "yonder",
    ]

    static func id(prefix: String, index: Int) -> String {
        prefix + String(format: "%04d", index)
    }

    static func text(index: Int, salt: UInt64 = 0, wordCount: ClosedRange<Int>) -> String {
        var state = UInt64(index) &* 0x100_0193 &+ salt &* 0x9E37_79B9
        func next() -> UInt64 {
            // SplitMix64: well distributed for sequential seeds, including zero.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        let count = wordCount.lowerBound + Int(next() % UInt64(wordCount.count))
        return (0..<count).map { _ in words[Int(next() % UInt64(words.count))] }.joined(separator: " ")
    }

    static func isBlank(_ index: Int) -> Bool { index % 7 == 3 }

    /// Lays items along the axis until the fixed extent is filled, leaving white padding at both ends.
    static func items(sectionEvery: Int, lengths: (FixtureItem.Kind) -> CGFloat) -> [FixtureItem] {
        let padding: CGFloat = 16
        var items: [FixtureItem] = []
        var start = padding
        for index in 1... {
            let kind: FixtureItem.Kind =
                if index % sectionEvery == 0 { .section }
                else if isBlank(index) { .blank }
                else if index % 5 == 1 { .tall }
                else { .plain }
            let length = lengths(kind)
            guard start + length <= Layout.documentExtent - padding else { break }
            items.append(FixtureItem(index: index, start: start, length: length, kind: kind))
            start += length
        }
        return items
    }

    /// Stable, distinct swatch color per index.
    static func swatch(_ index: Int) -> NSColor {
        NSColor(calibratedHue: CGFloat((index * 37) % 360) / 360, saturation: 0.65, brightness: 0.8, alpha: 1)
    }
}

/// Explicit colors and fonts so dark mode or accent colors never change the pixels.
@MainActor
enum Style {
    static let ink = NSColor(white: 0.1, alpha: 1)
    static let muted = NSColor(white: 0.4, alpha: 1)
    static let rule = NSColor(white: 0.82, alpha: 1)
    static let id = attributes(NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), ink)
    static let section = attributes(NSFont.systemFont(ofSize: 20, weight: .semibold), ink)
    static let secondary = attributes(NSFont.systemFont(ofSize: 12), muted)
    static let body = [
        attributes(NSFont.systemFont(ofSize: 13), ink),
        attributes(NSFont.systemFont(ofSize: 13, weight: .medium), ink),
        attributes(NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask), ink),
    ]

    static func attributes(_ font: NSFont, _ color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color]
    }
}

/// Custom-drawn 6000pt document of rows or columns. Only items intersecting the dirty rect are drawn.
final class FixtureDocumentView: NSView {
    let axis: NSEvent.GestureAxis
    private let items: [FixtureItem]

    init(axis: NSEvent.GestureAxis) {
        self.axis = axis
        if axis == .vertical {
            items = FixtureContent.items(sectionEvery: 24) { kind in
                switch kind {
                case .section: 44
                case .blank: 22
                case .tall: 40
                case .plain: 24
                }
            }
            super.init(frame: NSRect(x: 0, y: 0, width: Layout.verticalDocumentWidth, height: Layout.documentExtent))
        } else {
            items = FixtureContent.items(sectionEvery: 12) { kind in
                switch kind {
                case .section: 90
                case .blank: 48
                case .tall: 200
                case .plain: 150
                }
            }
            super.init(frame: NSRect(x: 0, y: 0, width: Layout.documentExtent, height: Layout.horizontalDocumentHeight))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Views no longer clip to bounds by default, so dirtyRect may extend past them.
        let dirtyRect = dirtyRect.intersection(bounds)
        NSColor.white.setFill()
        dirtyRect.fill()
        let visible = axis == .vertical ? dirtyRect.minY...dirtyRect.maxY : dirtyRect.minX...dirtyRect.maxX
        for item in items where item.start + item.length >= visible.lowerBound && item.start <= visible.upperBound {
            if axis == .vertical { drawRow(item) } else { drawColumn(item) }
        }
    }

    private func drawRow(_ item: FixtureItem) {
        let y = item.start
        switch item.kind {
        case .blank:
            return
        case .section:
            let title = "Section \(item.index / 24)  V\(item.id)"
            (title as NSString).draw(at: NSPoint(x: 24, y: y + 10), withAttributes: Style.section)
            Style.rule.setFill()
            NSRect(x: 24, y: y + item.length - 4, width: bounds.width - 48, height: 1).fill()
        case .tall, .plain:
            FixtureContent.swatch(item.index).setFill()
            NSRect(x: 24, y: y + 7, width: 10, height: 10).fill()
            ("V" + item.id as NSString).draw(at: NSPoint(x: 44, y: y + 4), withAttributes: Style.id)
            let text = FixtureContent.text(index: item.index, wordCount: 5...11)
            (text as NSString).draw(at: NSPoint(x: 110, y: y + 3), withAttributes: Style.body[item.index % 3])
            if item.kind == .tall {
                let detail = FixtureContent.text(index: item.index, salt: 1, wordCount: 3...8)
                (detail as NSString).draw(at: NSPoint(x: 110, y: y + 21), withAttributes: Style.secondary)
            }
        }
    }

    private func drawColumn(_ item: FixtureItem) {
        let x = item.start
        switch item.kind {
        case .blank:
            return
        case .section:
            Style.rule.setFill()
            NSRect(x: x + 4, y: 16, width: 1, height: bounds.height - 32).fill()
            ("S\(item.index / 12)" as NSString).draw(at: NSPoint(x: x + 14, y: 16), withAttributes: Style.section)
            ("H" + item.id as NSString).draw(at: NSPoint(x: x + 14, y: 46), withAttributes: Style.id)
        case .tall, .plain:
            FixtureContent.swatch(item.index).setFill()
            NSRect(x: x + 8, y: 20, width: 10, height: 10).fill()
            ("H" + item.id as NSString).draw(at: NSPoint(x: x + 24, y: 17), withAttributes: Style.id)
            let lineCount = item.kind == .tall ? 18 : 14
            for line in 0..<lineCount where !FixtureContent.isBlank(line + item.index) {
                let text = FixtureContent.text(index: item.index, salt: UInt64(line + 1), wordCount: 1...2)
                let rect = NSRect(x: x + 8, y: 44 + CGFloat(line) * 20, width: item.length - 16, height: 18)
                (text as NSString).draw(in: rect, withAttributes: Style.body[(item.index + line) % 3])
            }
        }
    }
}

/// Real NSTableView with a native sticky header and deterministic rows, including blank ones.
@MainActor
final class FixtureTableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    func makeTableView() -> NSTableView {
        let table = NSTableView()
        table.style = .plain
        table.rowHeight = Layout.tableRowHeight
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .white
        table.gridStyleMask = []
        table.selectionHighlightStyle = .none
        for (identifier, title, width) in [("id", "ID", 80.0), ("text", "Text", 660.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        return table
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Layout.tableRowCount }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let identifier = tableColumn?.identifier else { return nil }
        let field = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField
            ?? NSTextField(labelWithString: "")
        field.identifier = identifier
        field.lineBreakMode = .byTruncatingTail
        let index = row + 1
        let isID = identifier.rawValue == "id"
        field.font = isID ? NSFont.monospacedSystemFont(ofSize: 12, weight: .bold) : NSFont.systemFont(ofSize: 13)
        field.textColor = Style.ink
        field.stringValue = FixtureContent.isBlank(index) ? ""
            : isID ? FixtureContent.id(prefix: "T", index: index)
            : FixtureContent.text(index: index, salt: 2, wordCount: 4...10)
        return field
    }
}

/// White band with padded static text, used for the persistent header and footer.
final class WhiteBand: NSView {
    init(text: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        label.textColor = Style.ink
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.intersection(bounds).fill()
    }
}

/// Top-aligns documents shorter than the viewport.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

@MainActor
final class FixtureController: NSObject, NSApplicationDelegate {
    private let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: Layout.window),
        styleMask: [.titled, .closable, .miniaturizable],
        backing: .buffered,
        defer: false
    )
    private let scrollView = NSScrollView()
    private let modeControl = NSSegmentedControl()
    private let tableSource = FixtureTableSource()
    private let unstableLabel = NSTextField(labelWithString: "")
    private var unstableTimer: Timer?
    private var unstableTick = 0
    private let scrollers = UserDefaults.standard.string(forKey: "scrollers")
    private var mode = FixtureMode(rawValue: UserDefaults.standard.string(forKey: "mode") ?? "") ?? .vertical

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        window.title = "Shotty Scrolling Fixture"
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = makeContent()
        apply(mode)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func makeContent() -> NSView {
        let buttons = [
            NSButton(title: "Advance 80", target: self, action: #selector(advance)),
            NSButton(title: "Reverse 40", target: self, action: #selector(reverse)),
            NSButton(title: "Reset", target: self, action: #selector(reset)),
        ]
        modeControl.segmentCount = FixtureMode.allCases.count
        for (segment, mode) in FixtureMode.allCases.enumerated() {
            modeControl.setLabel(mode.label, forSegment: segment)
        }
        modeControl.trackingMode = .selectOne
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        let unstable = NSButton(checkboxWithTitle: "Unstable", target: self, action: #selector(toggleUnstable))

        let controls = NSStackView(views: buttons + [modeControl, unstable])
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        controls.spacing = 10

        scrollView.contentView = FlippedClipView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        if scrollers == "legacy" { scrollView.scrollerStyle = .legacy }

        let header = WhiteBand(text: "Fixture Header  (pinned, white padding)")
        let footer = WhiteBand(text: "Fixture Footer  (pinned)")
        let container = NSView(frame: NSRect(origin: .zero, size: Layout.window))
        let bands = [controls, header, scrollView, footer]
        for view in bands {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: container.topAnchor),
            controls.heightAnchor.constraint(equalToConstant: Layout.controlsHeight),
            header.topAnchor.constraint(equalTo: controls.bottomAnchor),
            header.heightAnchor.constraint(equalToConstant: Layout.headerHeight),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.heightAnchor.constraint(equalToConstant: Layout.footerHeight),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        // Changing text inside the scrolled area, visible only while Unstable is on.
        unstableLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 16, weight: .bold)
        unstableLabel.textColor = .systemRed
        unstableLabel.drawsBackground = true
        unstableLabel.backgroundColor = .white
        unstableLabel.isHidden = true
        unstableLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(unstableLabel)
        NSLayoutConstraint.activate([
            unstableLabel.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 120),
            unstableLabel.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -40),
        ])
        return container
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Shotty Scrolling Fixture", action: #selector(NSApplication.terminate(_:)),
                        keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let menu = NSMenu()
        menu.addItem(appItem)
        return menu
    }

    private func apply(_ newMode: FixtureMode) {
        mode = newMode
        modeControl.selectedSegment = FixtureMode.allCases.firstIndex(of: newMode) ?? 0
        let vertical = newMode != .horizontal
        scrollView.hasVerticalScroller = vertical && scrollers != "hidden"
        scrollView.hasHorizontalScroller = !vertical && scrollers != "hidden"
        scrollView.documentView = switch newMode {
        case .vertical: FixtureDocumentView(axis: .vertical)
        case .horizontal: FixtureDocumentView(axis: .horizontal)
        case .table: tableSource.makeTableView()
        }
        reset()
    }

    /// Moves the clip view instantly within the legal range, including insets such as a table header,
    /// then logs the offset for scripts.
    private func scroll(by delta: CGFloat) {
        let clip = scrollView.contentView
        let insets = clip.contentInsets
        let document = clip.documentRect
        var origin = clip.bounds.origin
        if mode == .horizontal {
            let lower = document.minX - insets.left
            origin.x = min(max(origin.x + delta, lower), max(lower, document.maxX + insets.right - clip.bounds.width))
        } else {
            let lower = document.minY - insets.top
            origin.y = min(max(origin.y + delta, lower), max(lower, document.maxY + insets.bottom - clip.bounds.height))
        }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
        print("mode=\(mode.rawValue) offset=\(Int((mode == .horizontal ? origin.x : origin.y).rounded()))")
        fflush(stdout)
    }

    @objc private func advance() { scroll(by: 80) }
    @objc private func reverse() { scroll(by: -40) }
    @objc private func reset() { scroll(by: -Layout.documentExtent * 2) }

    @objc private func modeChanged() {
        apply(FixtureMode.allCases[modeControl.selectedSegment])
    }

    @objc private func toggleUnstable(_ sender: NSButton) {
        unstableTimer?.invalidate()
        unstableTimer = nil
        unstableLabel.isHidden = sender.state != .on
        guard sender.state == .on else { return }
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        unstableTimer = timer
        tick()
    }

    @objc private func tick() {
        unstableTick += 1
        unstableLabel.stringValue = "tick \(String(format: "%04d", unstableTick))"
    }
}

/// Renders the whole document at a pixel scale for offline seam inspection. Text rasterization can differ
/// slightly from on-screen output, so compare structure and row identity, not exact pixels.
@MainActor
func renderDocument(mode: String, scale: Int, to path: String) throws {
    guard let axis: NSEvent.GestureAxis = ["vertical": .vertical, "horizontal": .horizontal][mode], scale > 0 else {
        throw RenderError.usage
    }
    let view = FixtureDocumentView(axis: axis)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width) * scale, pixelsHigh: Int(view.bounds.height) * scale,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { throw RenderError.allocation }
    rep.size = view.bounds.size
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { throw RenderError.encoding }
    try data.write(to: URL(fileURLWithPath: path))
}

enum RenderError: Error {
    case usage, allocation, encoding
}

@main
struct ShottyScrollFixture {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count > 1, arguments[1] == "--render-document" {
            guard arguments.count == 5, let scale = Int(arguments[3]) else { throw RenderError.usage }
            try renderDocument(mode: arguments[2], scale: scale, to: arguments[4])
            return
        }
        let app = NSApplication.shared
        let controller = FixtureController()
        app.delegate = controller
        app.setActivationPolicy(.regular)
        withExtendedLifetime(controller) { app.run() }
    }
}
